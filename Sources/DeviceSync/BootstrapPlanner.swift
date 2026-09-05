import Foundation

struct BootstrapPlanner: Sendable {
    func plan(for assessment: MachineAssessment) -> [BootstrapStep] {
        var steps: [BootstrapStep] = [
            BootstrapStep(
                id: "foundation-fleet",
                phase: .foundation,
                title: "Confirm the fleet folder",
                detail: "Verify that this Mac can read the shared manifest and other machine reports before changing software.",
                requiresReview: false
            ),
        ]

        for drift in assessment.drifts
            where drift.state != .aligned && drift.state != .notManaged {
            steps.append(step(for: drift))
        }

        steps.append(BootstrapStep(
            id: "validation-snapshot",
            phase: .validation,
            title: "Re-scan and publish proof",
            detail: "Run every read-only probe again, publish a fresh snapshot, and require the dashboard to show the resulting state.",
            command: "\(FleetMeshIdentity.executablePath) --snapshot",
            requiresReview: false
        ))

        return deduplicate(steps)
    }

    private func step(for drift: ComponentDrift) -> BootstrapStep {
        let definition = DoctorCatalog.definition(for: drift.componentID)
        let phase: BootstrapPhase = drift.kind == .configuration || drift.kind == .theme
            ? .configuration
            : .applications

        if drift.state == .localChanges {
            return BootstrapStep(
                id: "review-\(drift.componentID)",
                phase: phase,
                componentID: drift.componentID,
                title: "Review local \(drift.name) work",
                detail: "Preserve or reconcile the checkout before any pull, build, or install. FleetMesh will not overwrite it.",
                command: nil,
                requiresReview: true
            )
        }

        return BootstrapStep(
            id: "converge-\(drift.componentID)",
            phase: phase,
            componentID: drift.componentID,
            title: definition?.title ?? "Converge \(drift.name)",
            detail: definition?.detail ?? "Use the product's approved installation or configuration workflow, then verify the observed result.",
            command: definition?.recipe?.displayCommand,
            requiresReview: true
        )
    }

    private func deduplicate(_ steps: [BootstrapStep]) -> [BootstrapStep] {
        var seen = Set<String>()
        return steps.filter { seen.insert($0.id).inserted }
    }

}
