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
            command: "/Applications/Device Sync.app/Contents/MacOS/DeviceSync --snapshot",
            requiresReview: false
        ))

        return deduplicate(steps)
    }

    private func step(for drift: ComponentDrift) -> BootstrapStep {
        let definition = Self.actions[drift.componentID]
        let phase: BootstrapPhase = drift.kind == .configuration || drift.kind == .theme
            ? .configuration
            : .applications

        if drift.state == .localChanges {
            return BootstrapStep(
                id: "review-\(drift.componentID)",
                phase: phase,
                componentID: drift.componentID,
                title: "Review local \(drift.name) work",
                detail: "Preserve or reconcile the checkout before any pull, build, or install. Device Sync will not overwrite it.",
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
            command: definition?.command,
            requiresReview: true
        )
    }

    private func deduplicate(_ steps: [BootstrapStep]) -> [BootstrapStep] {
        var seen = Set<String>()
        return steps.filter { seen.insert($0.id).inserted }
    }

    private struct Action: Sendable {
        let title: String
        let detail: String
        let command: String?
    }

    private static let actions: [String: Action] = [
        "ai-continuum": Action(
            title: "Install and restore ai-continuum",
            detail: "Use ai-continuum's guarded new-laptop workflow. Its SQLite and WAL files must remain on local storage.",
            command: "~/code/ai-continuum/scripts/aic-bootstrap.sh"
        ),
        "authbar": Action(
            title: "Install AuthBar from its source checkout",
            detail: "Run AuthBar's transactional installer and require its installed --check acceptance gate.",
            command: "~/code/authbar/install.sh"
        ),
        "stow": Action(
            title: "Install Stow from its source checkout",
            detail: "Use Stow's transactional installer; preserve Accessibility identity and verify the live menu-bar app.",
            command: "~/code/Stow/install.sh"
        ),
        "murmr-voice": Action(
            title: "Install Murmr Voice",
            detail: "Use Murmr's own installer and re-validate microphone and accessibility permissions on this Mac.",
            command: "~/code/Murmur/install.sh"
        ),
        "model-bridge": Action(
            title: "Install Model Bridge",
            detail: "Use Model Bridge's signed package workflow; account validation must remain read-only.",
            command: "~/code/ModelBridge/install.sh"
        ),
        "codex-voice": Action(
            title: "Install Codex Voice",
            detail: "Build and install through Codex Voice's own installer, then validate its live app process.",
            command: "~/code/CodexVoice/install.sh"
        ),
        "harness-sync": Action(
            title: "Run the harness-sync bootstrap",
            detail: "Let harness-sync own Claude/OMP links. Review its manual per-machine token and identity steps separately.",
            command: "~/harness-sync/bootstrap.sh"
        ),
        "codex-desktop": Action(
            title: "Install the approved Codex Desktop build",
            detail: "Install through the approved distribution channel, then let Device Sync read the signed bundle version.",
            command: nil
        ),
        "codex-cli": Action(
            title: "Install the approved Codex CLI build",
            detail: "Use the managed CLI distribution for this Mac and verify its reported version.",
            command: nil
        ),
        "codex-themes": Action(
            title: "Review Codex theme drift",
            detail: "Compare named theme files with the reference Mac before copying; Device Sync never publishes theme contents.",
            command: nil
        ),
        "warp-themes": Action(
            title: "Review Warp theme drift",
            detail: "Compare the theme set with the reference Mac and explicitly choose which files to converge.",
            command: nil
        ),
        "meshclaw-themes": Action(
            title: "Review MeshClaw theme drift",
            detail: "Use MeshClaw's theme ownership and validation path; do not overwrite a locally edited theme silently.",
            command: nil
        ),
    ]
}
