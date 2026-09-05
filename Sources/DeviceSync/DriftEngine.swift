import Foundation

struct DriftEngine: Sendable {
    let staleInterval: TimeInterval

    init(staleInterval: TimeInterval = 24 * 60 * 60) {
        self.staleInterval = staleInterval
    }

    func assess(
        snapshot: MachineSnapshot,
        manifest: FleetManifest?,
        now: Date = Date()
    ) -> MachineAssessment {
        let drifts: [ComponentDrift]
        if let manifest {
            let activeTargets = manifest.scopedTargets(for: snapshot)
            let activeObservations = snapshot.components.filter {
                ComponentLifecycle.isActive($0.id)
            }
            let targetDrifts = activeTargets.map { target in
                let applicability = target.applicability(to: snapshot)
                guard applicability.isApplicable else {
                    return ComponentDrift(
                        componentID: target.id,
                        name: ComponentLifecycle.displayName(
                            for: target.id,
                            fallback: target.name
                        ),
                        kind: target.kind,
                        state: .notApplicable,
                        severity: .information,
                        summary: applicability.reason,
                        expected: nil,
                        observed: snapshot.component(target.id).flatMap(observedSummary)
                    )
                }
                return assess(target: target, observation: snapshot.component(target.id))
            }
            let targetIDs = Set(activeTargets.map(\.id))
            let observedOnly = activeObservations
                .filter { !targetIDs.contains($0.id) }
                .map { observation in
                    ComponentDrift(
                        componentID: observation.id,
                        name: ComponentLifecycle.displayName(
                            for: observation.id,
                            fallback: observation.name
                        ),
                        kind: observation.kind,
                        state: .notManaged,
                        severity: .information,
                        summary: observation.status == .missing
                            ? "This optional component is absent and is not required by the baseline."
                            : "This component is observed on the device but is not part of the fleet baseline.",
                        expected: nil,
                        observed: observation.status == .missing ? "Missing" : observedSummary(observation)
                    )
                }
            drifts = (targetDrifts + observedOnly).sorted { lhs, rhs in
                if lhs.severity != rhs.severity { return lhs.severity > rhs.severity }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
        } else {
            drifts = snapshot.components
                .filter { ComponentLifecycle.isActive($0.id) }
                .map { observation in
                ComponentDrift(
                    componentID: observation.id,
                    name: ComponentLifecycle.displayName(
                        for: observation.id,
                        fallback: observation.name
                    ),
                    kind: observation.kind,
                    state: .unknown,
                    severity: .information,
                    summary: "No fleet baseline exists yet.",
                    expected: nil,
                    observed: observation.primaryVersion
                )
            }
        }

        return MachineAssessment(
            snapshot: snapshot,
            drifts: drifts,
            isStale: now.timeIntervalSince(snapshot.capturedAt) > staleInterval
        )
    }

    private func assess(
        target: ManifestTarget,
        observation: ComponentObservation?
    ) -> ComponentDrift {
        let displayName = ComponentLifecycle.displayName(
            for: target.id,
            fallback: target.name
        )
        guard let observation else {
            return ComponentDrift(
                componentID: target.id,
                name: displayName,
                kind: target.kind,
                state: .unknown,
                severity: target.required ? .critical : .attention,
                summary: "This machine did not report the component.",
                expected: expectedSummary(target),
                observed: nil
            )
        }

        switch observation.status {
        case .missing:
            return ComponentDrift(
                componentID: target.id,
                name: displayName,
                kind: target.kind,
                state: .missing,
                severity: target.required ? .critical : .attention,
                summary: "Required component is not installed or configured.",
                expected: expectedSummary(target),
                observed: "Missing"
            )
        case .unknown:
            return ComponentDrift(
                componentID: target.id,
                name: displayName,
                kind: target.kind,
                state: .unknown,
                severity: .attention,
                summary: "The probe could not verify current state.",
                expected: expectedSummary(target),
                observed: "Unknown"
            )
        case .installed:
            break
        }

        if observation.sourceDirty == true {
            return ComponentDrift(
                componentID: target.id,
                name: displayName,
                kind: target.kind,
                state: .localChanges,
                severity: .attention,
                summary: "Source checkout has local work; convergence is intentionally blocked.",
                expected: expectedSummary(target),
                observed: observedSummary(observation)
            )
        }

        if let installed = observation.installedRevision,
           let source = observation.sourceRevision,
           !revisionsMatch(installed, source) {
            return ComponentDrift(
                componentID: target.id,
                name: displayName,
                kind: target.kind,
                state: .different,
                severity: .attention,
                summary: "Installed build and source checkout are different revisions; deployment state is not converged.",
                expected: "Installed \(installed)",
                observed: "Source \(source)"
            )
        }

        if let expected = target.expectedVersion {
            guard let observed = observation.installedVersion else {
                return unknownVersion(target: target, observation: observation)
            }
            if expected != observed {
                return mismatch(
                    target: target,
                    observation: observation,
                    summary: "Installed version differs from the fleet baseline.",
                    expected: expected,
                    observed: observed
                )
            }
        }

        if let expected = target.expectedInstalledRevision {
            guard let observed = observation.installedRevision else {
                return ComponentDrift(
                    componentID: target.id,
                    name: displayName,
                    kind: target.kind,
                    state: .unknown,
                    severity: .attention,
                    summary: "The baseline has an installed revision, but this build does not expose one.",
                    expected: expected,
                    observed: observation.installedVersion
                )
            }
            if !revisionsMatch(expected, observed) {
                return mismatch(
                    target: target,
                    observation: observation,
                    summary: "Installed build revision differs from the fleet baseline.",
                    expected: expected,
                    observed: observed
                )
            }
        }

        if let expected = target.expectedConfigurationFingerprint {
            guard let observed = observation.configurationFingerprint else {
                return ComponentDrift(
                    componentID: target.id,
                    name: displayName,
                    kind: target.kind,
                    state: .unknown,
                    severity: .attention,
                    summary: "Configuration fingerprint is unavailable.",
                    expected: shortFingerprint(expected),
                    observed: nil
                )
            }
            if expected != observed {
                return mismatch(
                    target: target,
                    observation: observation,
                    summary: "Configuration or theme set differs from the fleet baseline.",
                    expected: shortFingerprint(expected),
                    observed: shortFingerprint(observed)
                )
            }
        }

        if let expected = target.expectedSourceRevision,
           let observed = observation.sourceRevision,
           !revisionsMatch(expected, observed) {
            return mismatch(
                target: target,
                observation: observation,
                summary: "Source checkout differs from the fleet baseline; nothing was pulled or installed.",
                expected: expected,
                observed: observed
            )
        }

        return ComponentDrift(
            componentID: target.id,
            name: displayName,
            kind: target.kind,
            state: .aligned,
            severity: .information,
            summary: "Observed state matches the fleet baseline.",
            expected: expectedSummary(target),
            observed: observedSummary(observation)
        )
    }

    private func unknownVersion(
        target: ManifestTarget,
        observation: ComponentObservation
    ) -> ComponentDrift {
        ComponentDrift(
            componentID: target.id,
            name: ComponentLifecycle.displayName(for: target.id, fallback: target.name),
            kind: target.kind,
            state: .unknown,
            severity: .attention,
            summary: "Installed version could not be read.",
            expected: target.expectedVersion,
            observed: observedSummary(observation)
        )
    }

    private func mismatch(
        target: ManifestTarget,
        observation: ComponentObservation,
        summary: String,
        expected: String,
        observed: String
    ) -> ComponentDrift {
        ComponentDrift(
            componentID: target.id,
            name: ComponentLifecycle.displayName(for: target.id, fallback: target.name),
            kind: target.kind,
            state: .different,
            severity: .attention,
            summary: summary,
            expected: expected,
            observed: observed
        )
    }

    private func expectedSummary(_ target: ManifestTarget) -> String? {
        target.expectedVersion
            ?? target.expectedInstalledRevision
            ?? target.expectedSourceRevision
            ?? target.expectedConfigurationFingerprint.map(shortFingerprint)
    }

    private func observedSummary(_ observation: ComponentObservation) -> String? {
        observation.installedVersion
            ?? observation.installedRevision
            ?? observation.sourceRevision
            ?? observation.configurationFingerprint.map(shortFingerprint)
    }

    private func revisionsMatch(_ lhs: String, _ rhs: String) -> Bool {
        lhs == rhs || lhs.hasPrefix(rhs) || rhs.hasPrefix(lhs)
    }

    private func shortFingerprint(_ value: String) -> String {
        String(value.prefix(12))
    }
}
