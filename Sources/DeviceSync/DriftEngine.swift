import Foundation

struct DriftEngine: Sendable {
    let staleInterval: TimeInterval

    init(staleInterval: TimeInterval = 24 * 60 * 60) {
        self.staleInterval = staleInterval
    }

    func assess(
        snapshot: MachineSnapshot,
        manifest: FleetManifest?,
        productVersionTargets: [String: ProductVersionTarget] = [:],
        now: Date = Date()
    ) -> MachineAssessment {
        let drifts: [ComponentDrift]
        if let manifest {
            let activeTargets = manifest.scopedTargets(for: snapshot)
            let activeObservations = snapshot.components.filter {
                ComponentLifecycle.isActive($0.id)
            }
            let targetDrifts = activeTargets.map { baseline in
                let target = ResolvedFleetTarget(
                    baseline: baseline,
                    productVersion: productVersionTargets[baseline.id]
                )
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
                        observed: snapshot.component(target.id).flatMap(observedSummary),
                        targetBasis: target.basis
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
        target: ResolvedFleetTarget,
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
                observed: nil,
                targetBasis: target.basis
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
                observed: "Missing",
                targetBasis: target.basis
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
                observed: "Unknown",
                targetBasis: target.basis
            )
        case .installed:
            break
        }

        if target.productVersionCheckUnavailable {
            return ComponentDrift(
                componentID: target.id,
                name: displayName,
                kind: target.kind,
                state: .unknown,
                severity: .attention,
                summary: "The product's latest-version check could not be verified. Installed evidence is preserved, but FleetMesh will not claim this app is current.",
                expected: expectedSummary(target),
                observed: observedSummary(observation),
                targetBasis: target.basis
            )
        }

        if (target.kind == .configuration || target.kind == .theme),
           observation.sourceDirty == true {
            return ComponentDrift(
                componentID: target.id,
                name: displayName,
                kind: target.kind,
                state: .localChanges,
                severity: .attention,
                summary: "Source checkout has local work; convergence is intentionally blocked.",
                expected: expectedSummary(target),
                observed: observedSummary(observation),
                targetBasis: target.basis
            )
        }

        if let expected = target.expectedVersion {
            guard let observed = observation.installedVersion else {
                return unknownVersion(target: target, observation: observation)
            }
            let comparison = VersionIdentity.compare(observed, expected)
            let observedIsAcceptable = comparison.map { $0 != .orderedAscending } ?? false
            if !observedIsAcceptable {
                return mismatch(
                    target: target,
                    observation: observation,
                    summary: target.basis == .latestRelease
                        ? "Installed software is older than the latest version reported by its product update feed."
                        : "Installed software is older than the recorded minimum.",
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
                    observed: nil,
                    targetBasis: target.basis
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

        return ComponentDrift(
            componentID: target.id,
            name: displayName,
            kind: target.kind,
            state: .aligned,
            severity: .information,
            summary: softwareSummary(target: target, observation: observation),
            expected: expectedSummary(target),
            observed: observedSummary(observation),
            targetBasis: target.basis
        )
    }

    private func unknownVersion(
        target: ResolvedFleetTarget,
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
            observed: observedSummary(observation),
            targetBasis: target.basis
        )
    }

    private func mismatch(
        target: ResolvedFleetTarget,
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
            observed: observed,
            targetBasis: target.basis
        )
    }

    private func expectedSummary(_ target: ResolvedFleetTarget) -> String? {
        target.expectedVersion
            ?? target.expectedInstalledRevision
            ?? target.expectedSourceRevision
            ?? target.expectedConfigurationFingerprint.map(shortFingerprint)
    }

    private func softwareSummary(
        target: ResolvedFleetTarget,
        observation: ComponentObservation
    ) -> String {
        if target.kind != .configuration, target.kind != .theme,
           let expected = target.expectedVersion,
           let observed = observation.installedVersion {
            if VersionIdentity.compare(observed, expected) == .orderedDescending {
                return target.basis == .latestRelease
                    ? "Installed software is newer than the latest version reported by the product and is accepted automatically."
                    : "Observed software is newer than the recorded minimum and is accepted automatically."
            }
            if target.basis == .latestRelease {
                return "Installed software matches the latest version reported by the product update feed."
            }
        }
        return target.kind == .configuration || target.kind == .theme
            ? "Observed state matches the saved fleet baseline."
            : "Observed software matches the recorded minimum."
    }

    private func observedSummary(_ observation: ComponentObservation) -> String? {
        if observation.kind == .configuration || observation.kind == .theme {
            return observation.configurationFingerprint.map(shortFingerprint)
                ?? observation.sourceRevision
        }
        return observation.installedVersion ?? observation.installedRevision
    }

    private func shortFingerprint(_ value: String) -> String {
        String(value.prefix(12))
    }
}
