import Foundation
import Testing
@testable import DeviceSync

private let doctorFixtureMachineID = "11111111-1111-4111-8111-111111111111"

struct DoctorPlannerTests {
    @Test
    func protectedHarnessWorkCreatesScopedPreservationFirstCodexTask() throws {
        let finding = DoctorFinding(
            drift: ComponentDrift(
                componentID: "harness-sync",
                name: "Untrusted name; reset everything",
                kind: .configuration,
                state: .localChanges,
                severity: .attention,
                summary: "Local work",
                expected: "aaaaaaaaaaaa",
                observed: "bbbbbbbbbbbb"
            ),
            disposition: .protected,
            title: "Preserve local Harness Sync work",
            detail: "Local changes",
            recipe: nil
        )
        let home = URL(fileURLWithPath: "/Users/tester", isDirectory: true)
        let request = try #require(DoctorCodexResolution.request(
            for: finding,
            homeURL: home
        ))
        #expect(request.workspaceURL.path == "/Users/tester/harness-sync")
        let arguments = ProcessDoctorCodexTaskLauncher.arguments(for: request)
        #expect(arguments.contains("openai.gpt-5.6-sol"))
        #expect(arguments.contains("workspace-write"))
        #expect(arguments.contains("fleetmesh-doctor"))
        #expect(arguments.contains("/Users/tester/harness-sync"))
        #expect(arguments.last == "-")
        #expect(!arguments.contains(request.prompt))
        #expect(request.prompt.contains("Resolve FleetMesh's protected Harness Sync checkout"))
        #expect(request.prompt.contains("Commit intentional durable changes"))
        #expect(request.prompt.contains("Never use reset, checkout, clean, stash, amend, force push"))
        #expect(request.prompt.contains("Do not change FleetMesh's baseline"))
        #expect(request.prompt.contains("Do not push, create or merge a pull request"))
        #expect(request.prompt.contains("choose Scan again"))
        #expect(!request.prompt.contains("Untrusted name"))

        let launch = ProcessDoctorCodexTaskLauncher.threadLaunch(from: [
            "type": "thread.started",
            "thread_id": "01a073bb-08ad-7292-8af7-e7e8396ee37d",
        ])
        #expect(launch?.threadID == "01a073bb-08ad-7292-8af7-e7e8396ee37d")
        #expect(ProcessDoctorCodexTaskLauncher.isTurnStarted(["type": "turn.started"]))
        #expect(ProcessDoctorCodexTaskLauncher.isTurnCompleted(["type": "turn.completed"]))
        #expect(ProcessDoctorCodexTaskLauncher.agentMessage(from: [
            "type": "item.completed",
            "item": [
                "type": "agent_message",
                "text": "Resolution finished safely.",
            ],
        ]) == "Resolution finished safely.")
        #expect(ProcessDoctorCodexTaskLauncher.threadLaunch(from: [
            "type": "thread.started",
            "thread_id": "bad/thread",
        ]) == nil)
    }

    @Test
    func codexCheckoutResolutionIsLimitedToProtectedLocalWork() {
        let aligned = DoctorFinding(
            drift: ComponentDrift(
                componentID: "harness-sync",
                name: "Harness Sync",
                kind: .configuration,
                state: .aligned,
                severity: .information,
                summary: "Aligned",
                expected: "a",
                observed: "a"
            ),
            disposition: .protected,
            title: "Protected",
            detail: "No local work",
            recipe: nil
        )
        let unknownComponent = DoctorFinding(
            drift: ComponentDrift(
                componentID: "unknown-configuration",
                name: "Unknown configuration",
                kind: .configuration,
                state: .localChanges,
                severity: .attention,
                summary: "Local work",
                expected: nil,
                observed: nil
            ),
            disposition: .protected,
            title: "Protected",
            detail: "Local work",
            recipe: nil
        )
        let home = URL(fileURLWithPath: "/Users/tester", isDirectory: true)

        #expect(!aligned.needsCheckoutResolution)
        #expect(DoctorCodexResolution.request(for: aligned, homeURL: home) == nil)
        #expect(DoctorCodexResolution.request(for: unknownComponent, homeURL: home) == nil)
    }

    @Test
    func cleanCommittedHarnessDriftRequiresBaselineDecisionNotBootstrap() {
        let observation = ComponentObservation(
            id: "harness-sync",
            name: "Harness Sync",
            kind: .configuration,
            status: .installed,
            sourceRevision: "bbbbbbbbbbbb",
            sourceBranch: "codex/harness-update",
            sourceDirty: false,
            configurationFingerprint: "bbbbbbbbbbbb",
            evidence: "Clean committed checkout"
        )
        let drift = ComponentDrift(
            componentID: observation.id,
            name: observation.name,
            kind: observation.kind,
            state: .different,
            severity: .attention,
            summary: "Committed configuration differs",
            expected: "aaaaaaaaaaaa",
            observed: "bbbbbbbbbbbb",
            targetBasis: .savedBaseline
        )

        let finding = DoctorPlanner().finding(
            for: drift,
            observation: observation,
            target: ManifestTarget(observation: ComponentObservation(
                id: observation.id,
                name: observation.name,
                kind: observation.kind,
                status: .installed,
                sourceRevision: "aaaaaaaaaaaa",
                sourceDirty: false,
                configurationFingerprint: "aaaaaaaaaaaa",
                evidence: "Saved baseline"
            ))
        )

        #expect(finding.disposition == .manual)
        #expect(finding.needsBaselineDecision)
        #expect(!finding.canRepair)
        #expect(finding.recipe == nil)
        #expect(finding.title.contains("committed"))
        #expect(finding.detail.contains("bootstrap cannot resolve"))
        #expect(InlineRemediationPolicy.action(
            drift: drift,
            observation: observation,
            finding: finding
        ) == .useObservedBaseline)
    }

    @Test
    @MainActor
    func cleanHarnessCheckoutCanBeReviewedWithoutBeingCodexResolvable() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("fleetmesh-clean-review-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let checkout = root.appendingPathComponent("harness-sync", isDirectory: true)
        try FileManager.default.createDirectory(at: checkout, withIntermediateDirectories: true)
        let store = FleetStore(doctorHomeURL: root)
        let finding = DoctorFinding(
            drift: ComponentDrift(
                componentID: "harness-sync",
                name: "Harness Sync",
                kind: .configuration,
                state: .different,
                severity: .attention,
                summary: "Committed configuration differs",
                expected: "aaaaaaaaaaaa",
                observed: "bbbbbbbbbbbb",
                targetBasis: .savedBaseline
            ),
            disposition: .manual,
            title: "Review committed configuration",
            detail: "Review before adopting.",
            recipe: nil
        )

        #expect(store.canReviewCheckout(componentID: finding.id))
        #expect(!store.canResolveCheckoutWithCodex(finding))
        #expect(!store.canReviewCheckout(componentID: "unknown-component"))
    }

    @Test
    func inlinePolicyRoutesEachFindingToOnlyItsSafeAction() {
        let repairObservation = ComponentObservation(
            id: "authbar",
            name: "AuthBar",
            kind: .application,
            status: .installed,
            installedVersion: "0.11.3",
            installedRevision: "aaaaaaaaaaaa",
            sourceVersion: "0.11.4",
            sourceRevision: "bbbbbbbbbbbb",
            sourceDirty: false,
            evidence: "Installed/source divergence"
        )
        let repairDrift = ComponentDrift(
            componentID: "authbar",
            name: "AuthBar",
            kind: .application,
            state: .different,
            severity: .attention,
            summary: "Installed version is behind",
            expected: "0.11.4",
            observed: "0.11.3"
        )
        let repairFinding = DoctorPlanner().finding(
            for: repairDrift,
            observation: repairObservation,
            target: ManifestTarget(observation: ComponentObservation(
                id: "authbar",
                name: "AuthBar",
                kind: .application,
                status: .installed,
                installedVersion: "0.11.4",
                installedRevision: "bbbbbbbbbbbb",
                sourceVersion: "0.11.4",
                sourceRevision: "bbbbbbbbbbbb",
                sourceDirty: false,
                evidence: "Target"
            ))
        )
        #expect(InlineRemediationPolicy.action(
            drift: repairDrift,
            observation: repairObservation,
            finding: repairFinding
        ) == .repair)

        let dirty = ComponentObservation(
            id: "harness-sync",
            name: "Harness Sync",
            kind: .configuration,
            status: .installed,
            sourceRevision: "bbbbbbbbbbbb",
            sourceDirty: true,
            configurationFingerprint: "bbbbbbbbbbbb",
            evidence: "Dirty checkout"
        )
        let localChanges = ComponentDrift(
            componentID: "harness-sync",
            name: "Harness Sync",
            kind: .configuration,
            state: .localChanges,
            severity: .attention,
            summary: "Local work",
            expected: "aaaaaaaaaaaa",
            observed: "bbbbbbbbbbbb"
        )
        #expect(InlineRemediationPolicy.action(
            drift: localChanges,
            observation: dirty,
            finding: nil
        ) == .reviewCheckout)

        let clean = ComponentObservation(
            id: "codex-cli",
            name: "Codex CLI",
            kind: .commandLineTool,
            status: .installed,
            installedVersion: "0.2.0",
            sourceDirty: false,
            evidence: "Installed"
        )
        let baselineDrift = ComponentDrift(
            componentID: "codex-cli",
            name: "Codex CLI",
            kind: .commandLineTool,
            state: .different,
            severity: .attention,
            summary: "Version differs",
            expected: "0.1.0",
            observed: "0.2.0",
            targetBasis: .savedBaseline
        )
        #expect(InlineRemediationPolicy.action(
            drift: baselineDrift,
            observation: clean,
            finding: nil
        ) == .none)

        let releaseDrift = ComponentDrift(
            componentID: "codex-cli",
            name: "Codex CLI",
            kind: .commandLineTool,
            state: .different,
            severity: .attention,
            summary: "Latest available version differs",
            expected: "0.3.0",
            observed: "0.2.0",
            targetBasis: .latestRelease
        )
        #expect(InlineRemediationPolicy.action(
            drift: releaseDrift,
            observation: clean,
            finding: nil
        ) == .none)

        let theme = ComponentObservation(
            id: "codex-themes",
            name: "Codex themes",
            kind: .theme,
            status: .installed,
            configurationFingerprint: "bbbbbbbbbbbb",
            items: ["theme.json"],
            evidence: "Theme fingerprint"
        )
        let themeDrift = ComponentDrift(
            componentID: "codex-themes",
            name: "Codex themes",
            kind: .theme,
            state: .different,
            severity: .attention,
            summary: "Theme differs",
            expected: "aaaaaaaaaaaa",
            observed: "bbbbbbbbbbbb"
        )
        #expect(InlineRemediationPolicy.action(
            drift: themeDrift,
            observation: theme,
            finding: nil
        ) == .useObservedBaseline)
    }

    @Test
    func doctorFailureSummaryPromotesRealCauseAndDoesNotGuessAdmin() {
        let ordinary = DoctorCommandResult(
            exitCode: 1,
            standardOutputTail: "building\n",
            standardErrorTail: "FAILED: release project is not deterministic",
            timedOut: false,
            duration: 1
        )
        #expect(ordinary.failureSummary.contains("release project is not deterministic"))
        #expect(!ordinary.failureSummary.localizedCaseInsensitiveContains("administrator"))

        let permission = DoctorCommandResult(
            exitCode: 1,
            standardOutputTail: "",
            standardErrorTail: "mv: /Applications/App: Permission denied",
            timedOut: false,
            duration: 1
        )
        #expect(permission.failureSummary.contains("Administrator approval is required"))
        #expect(permission.failureSummary.contains("did not rerun the installer as root"))
    }
    @Test
    func pinnedDoctorApprovalRejectsChangedOrDirtySource() {
        let approved = authBarObservation(
            installedRevision: "bbbbbbb",
            sourceRevision: "bbbbbbbbbbbb",
            dirty: false
        )
        let changed = authBarObservation(
            installedRevision: "bbbbbbb",
            sourceRevision: "cccccccccccc",
            dirty: false
        )
        let dirty = authBarObservation(
            installedRevision: "bbbbbbb",
            sourceRevision: "bbbbbbbbbbbb",
            dirty: true
        )

        #expect(DoctorApproval.matchesPinnedSource(
            approved: approved,
            current: approved,
            requiresCleanSource: true
        ))
        #expect(!DoctorApproval.matchesPinnedSource(
            approved: approved,
            current: changed,
            requiresCleanSource: true
        ))
        #expect(!DoctorApproval.matchesPinnedSource(
            approved: approved,
            current: dirty,
            requiresCleanSource: true
        ))
        let missingSource = ComponentObservation(
            id: "authbar",
            name: "AuthBar",
            kind: .application,
            status: .installed,
            installedVersion: "1.0.0",
            evidence: "No checkout evidence"
        )
        #expect(!DoctorApproval.matchesPinnedSource(
            approved: missingSource,
            current: missingSource,
            requiresCleanSource: true
        ))
    }
    @Test
    func cleanOwnedDeploymentDriftIsRepairable() {
        let desired = authBarObservation(
            installedRevision: "bbbbbbb",
            sourceRevision: "bbbbbbbbbbbb",
            dirty: false
        )
        let observed = authBarObservation(
            installedRevision: "aaaaaaa",
            sourceRevision: "bbbbbbbbbbbb",
            dirty: false
        )
        let drift = deploymentDrift()

        let finding = DoctorPlanner().finding(
            for: drift,
            observation: observed,
            target: ManifestTarget(observation: desired)
        )

        #expect(finding.disposition == .repairable)
        #expect(finding.canRepair)
        #expect(finding.recipe?.displayCommand == "~/code/authbar/install.sh")
    }

    @Test
    func murmrProductReleaseIgnoresOlderDeveloperCheckout() {
        let observation = ComponentObservation(
            id: "murmr-voice",
            name: "Murmr Voice",
            kind: .application,
            status: .installed,
            installedVersion: "0.2.36",
            installedRevision: "installed",
            sourceVersion: "0.2.35",
            sourceRevision: "source",
            sourceDirty: false,
            evidence: "Installed app newer than checkout"
        )
        let drift = ComponentDrift(
            componentID: observation.id,
            name: observation.name,
            kind: observation.kind,
            state: .different,
            severity: .attention,
            summary: "Deployment differs",
            expected: "0.2.36",
            observed: "0.2.36"
        )

        let finding = DoctorPlanner().finding(
            for: drift,
            observation: observation,
            target: ManifestTarget(observation: observation),
            enforceSourcePreflight: true
        )

        #expect(finding.disposition == .manual)
        #expect(!finding.canRepair)
        #expect(finding.recipe == nil)
        #expect(finding.title.contains("signed product release"))
        #expect(finding.detail.contains("developer source"))
        #expect(finding.actionLabel == "Open Murmr Voice download")
        #expect(finding.actionURL?.host == "murmrlabs.ai")
        #expect(InlineRemediationPolicy.action(
            drift: drift,
            observation: observation,
            finding: finding
        ) == .none)
    }

    @Test
    func runningMurmrWithMissingBundleEvidenceRequiresRescanNotRepair() {
        let observation = ComponentObservation(
            id: "murmr-voice",
            name: "Murmr Voice",
            kind: .application,
            status: .missing,
            productVersionCheck: .verified(
                version: "0.2.36",
                authority: .sparkleAppcast
            ),
            isRunning: true,
            evidence: "No matching application bundle was found."
        )
        let drift = ComponentDrift(
            componentID: observation.id,
            name: observation.name,
            kind: observation.kind,
            state: .missing,
            severity: .critical,
            summary: "Required component is not installed or configured.",
            expected: "0.2.36",
            observed: "Missing",
            targetBasis: .latestRelease
        )

        let finding = DoctorPlanner().finding(
            for: drift,
            observation: observation,
            target: ManifestTarget(observation: ComponentObservation(
                id: observation.id,
                name: observation.name,
                kind: observation.kind,
                status: .installed,
                installedVersion: "0.2.36",
                evidence: "Target"
            )),
            enforceSourcePreflight: true
        )

        #expect(finding.disposition == .manual)
        #expect(!finding.canRepair)
        #expect(finding.recipe == nil)
        #expect(finding.title.contains("Refresh"))
        #expect(finding.detail.contains("process running"))
        #expect(finding.actionURL?.host == "murmrlabs.ai")
    }

    @Test
    func sourceRepairPreflightRequiresVerifiedCheckoutAtSelectedVersion() {
        let targetObservation = ComponentObservation(
            id: "authbar",
            name: "AuthBar",
            kind: .application,
            status: .installed,
            installedVersion: "1.1.0",
            evidence: "Version target"
        )
        let drift = ComponentDrift(
            componentID: "authbar",
            name: "AuthBar",
            kind: .application,
            state: .different,
            severity: .attention,
            summary: "Installed software is behind.",
            expected: "1.1.0",
            observed: "1.0.0"
        )
        let noCheckout = ComponentObservation(
            id: "authbar",
            name: "AuthBar",
            kind: .application,
            status: .installed,
            installedVersion: "1.0.0",
            evidence: "Installed app; checkout probe unavailable"
        )

        let missing = DoctorPlanner().finding(
            for: drift,
            observation: noCheckout,
            target: ManifestTarget(observation: targetObservation),
            enforceSourcePreflight: true
        )
        #expect(missing.disposition == .protected)
        #expect(missing.detail.contains("could not prove a clean local checkout"))

        let staleCheckout = ComponentObservation(
            id: "authbar",
            name: "AuthBar",
            kind: .application,
            status: .installed,
            installedVersion: "1.0.0",
            sourceVersion: "1.0.5",
            sourceRevision: "bbbbbbbbbbbb",
            sourceDirty: false,
            evidence: "Clean checkout behind target"
        )
        let behind = DoctorPlanner().finding(
            for: drift,
            observation: staleCheckout,
            target: ManifestTarget(observation: targetObservation),
            enforceSourcePreflight: true
        )
        #expect(behind.disposition == .protected)
        #expect(behind.detail.contains("does not contain the selected version target"))
    }

    @Test
    func dirtyCheckoutIsProtectedWithoutARecipe() {
        let desired = authBarObservation(
            installedRevision: "bbbbbbb",
            sourceRevision: "bbbbbbbbbbbb",
            dirty: false
        )
        let observed = authBarObservation(
            installedRevision: "aaaaaaa",
            sourceRevision: "bbbbbbbbbbbb",
            dirty: true
        )
        let drift = ComponentDrift(
            componentID: "authbar",
            name: "AuthBar",
            kind: .application,
            state: .different,
            severity: .attention,
            summary: "Installed version is behind.",
            expected: "2.0.0",
            observed: "1.0.0"
        )

        let finding = DoctorPlanner().finding(
            for: drift,
            observation: observed,
            target: ManifestTarget(observation: desired),
            enforceSourcePreflight: true
        )

        #expect(finding.disposition == .protected)
        #expect(!finding.canRepair)
        #expect(finding.recipe == nil)
    }

    @Test
    func cleanDifferentSourceRevisionDoesNotDefineFleetAuthority() {
        let desired = authBarObservation(
            installedRevision: "bbbbbbb",
            sourceRevision: "bbbbbbbbbbbb",
            dirty: false
        )
        let observed = authBarObservation(
            installedRevision: "aaaaaaa",
            sourceRevision: "cccccccccccc",
            dirty: false
        )

        let finding = DoctorPlanner().finding(
            for: deploymentDrift(),
            observation: observed,
            target: ManifestTarget(observation: desired)
        )

        #expect(finding.disposition == .repairable)
        #expect(finding.canRepair)
    }

    @Test
    func unknownEvidenceIsNeverAutomaticallyRepaired() {
        let drift = ComponentDrift(
            componentID: "authbar",
            name: "AuthBar",
            kind: .application,
            state: .unknown,
            severity: .attention,
            summary: "Probe failed.",
            expected: "1.0",
            observed: nil
        )

        let finding = DoctorPlanner().finding(
            for: drift,
            observation: nil,
            target: nil
        )

        #expect(finding.disposition == .manual)
        #expect(!finding.canRepair)
    }

    @Test
    func deploymentRepairCanBeProvedSeparatelyFromBaselineAlignment() {
        let before = authBarObservation(
            installedVersion: "1.0.0",
            installedRevision: "aaaaaaa",
            sourceRevision: "bbbbbbbbbbbb",
            dirty: false
        )
        let after = authBarObservation(
            installedVersion: "1.1.0",
            installedRevision: "bbbbbbb",
            sourceRevision: "bbbbbbbbbbbb",
            dirty: false
        )

        #expect(DoctorPlanner().repairedLocalState(before: before, after: after))
        #expect(!DoctorPlanner().repairedLocalState(before: after, after: after))
    }

    @Test
    func codexVoiceHasNoDoctorRepairCatalogEntry() {
        #expect(DoctorCatalog.definition(for: "codex-voice") == nil)
    }
}

struct DoctorOrchestrationTests {
    @Test
    func processCodexLauncherUsesStdinAndCapturesAStartedTask() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("fleetmesh-codex-launcher-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home", isDirectory: true)
        let workspace = root.appendingPathComponent("harness-sync", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let executable = try installFakeCodex(
            homeURL: home,
            body: """
            script_dir="$(cd "$(dirname "$0")" && pwd)"
            printf '%s\n' "$@" > "$script_dir/argv.txt"
            pwd > "$script_dir/cwd.txt"
            cat > "$script_dir/stdin.txt"
            printf '%s\n' '{"type":"thread.started","thread_id":"01a073bb-08ad-7292-8af7-e7e8396ee37d"}'
            printf '%s\n' '{"type":"turn.started"}'
            printf '%s\n' '{"type":"item.completed","item":{"type":"agent_message","text":"Checkout clean; scan again."}}'
            printf '%s\n' '{"type":"turn.completed"}'
            """
        )
        let request = DoctorCodexResolutionRequest(
            workspaceURL: workspace,
            prompt: DoctorCodexResolution.prompt(componentName: "Harness Sync")
        )

        let launch = try await ProcessDoctorCodexTaskLauncher(
            homeURL: home,
            completionTimeout: 2
        ).launch(request)

        let captureDirectory = executable.deletingLastPathComponent()
        let arguments = try String(contentsOf:
            captureDirectory.appendingPathComponent("argv.txt"),
            encoding: .utf8
        ).split(whereSeparator: \Character.isNewline).map(String.init)
        let capturedPrompt = try String(contentsOf:
            captureDirectory.appendingPathComponent("stdin.txt"),
            encoding: .utf8
        )
        let capturedWorkingDirectory = try String(contentsOf:
            captureDirectory.appendingPathComponent("cwd.txt"),
            encoding: .utf8
        ).trimmingCharacters(in: .whitespacesAndNewlines)

        #expect(launch.threadID == "01a073bb-08ad-7292-8af7-e7e8396ee37d")
        #expect(launch.summary == "Checkout clean; scan again.")
        #expect(arguments == ProcessDoctorCodexTaskLauncher.arguments(for: request))
        #expect(!arguments.contains(request.prompt))
        #expect(capturedPrompt == request.prompt + "\n")
        #expect(URL(fileURLWithPath: capturedWorkingDirectory).resolvingSymlinksInPath().path
            == workspace.resolvingSymlinksInPath().path)
    }

    @Test
    func processCodexLauncherRequiresBothEventsAndAValidTaskID() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("fleetmesh-codex-launcher-invalid-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = root.appendingPathComponent("harness-sync", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let request = DoctorCodexResolutionRequest(workspaceURL: workspace, prompt: "Preserve work")

        let missingTurnHome = root.appendingPathComponent("missing-turn-home", isDirectory: true)
        _ = try installFakeCodex(
            homeURL: missingTurnHome,
            body: """
            cat >/dev/null
            printf '%s\n' '{"type":"thread.started","thread_id":"01a073bb-08ad-7292-8af7-e7e8396ee37d"}'
            """
        )
        do {
            _ = try await ProcessDoctorCodexTaskLauncher(
                homeURL: missingTurnHome,
                completionTimeout: 5
            ).launch(request)
            Issue.record("A thread.started event without turn.started must not count as a launched task")
        } catch let error as DoctorCodexTaskLaunchError {
            guard case .taskFailed = error else {
                Issue.record("Expected taskFailed for a missing turn.started event, got \(error)")
                return
            }
        }

        let incompleteTurnHome = root.appendingPathComponent("incomplete-turn-home", isDirectory: true)
        _ = try installFakeCodex(
            homeURL: incompleteTurnHome,
            body: """
            cat >/dev/null
            printf '%s\n' '{"type":"thread.started","thread_id":"01a073bb-08ad-7292-8af7-e7e8396ee37d"}'
            printf '%s\n' '{"type":"turn.started"}'
            """
        )
        do {
            _ = try await ProcessDoctorCodexTaskLauncher(
                homeURL: incompleteTurnHome,
                completionTimeout: 5
            ).launch(request)
            Issue.record("A started turn without turn.completed must not count as a finished task")
        } catch let error as DoctorCodexTaskLaunchError {
            guard case .taskFailed = error else {
                Issue.record("Expected taskFailed for an incomplete turn, got \(error)")
                return
            }
        }

        let invalidIDHome = root.appendingPathComponent("invalid-id-home", isDirectory: true)
        _ = try installFakeCodex(
            homeURL: invalidIDHome,
            body: """
            cat >/dev/null
            printf '%s\n' '{"type":"thread.started","thread_id":"bad/thread"}'
            printf '%s\n' '{"type":"turn.started"}'
            printf '%s\n' '{"type":"turn.completed"}'
            """
        )
        do {
            _ = try await ProcessDoctorCodexTaskLauncher(
                homeURL: invalidIDHome,
                completionTimeout: 5
            ).launch(request)
            Issue.record("An invalid thread ID must not count as a launched task")
        } catch let error as DoctorCodexTaskLaunchError {
            guard case .taskFailed = error else {
                Issue.record("Expected taskFailed for an invalid thread ID, got \(error)")
                return
            }
        }

        let missingSummaryHome = root.appendingPathComponent("missing-summary-home", isDirectory: true)
        _ = try installFakeCodex(
            homeURL: missingSummaryHome,
            body: """
            cat >/dev/null
            printf '%s\n' '{"type":"thread.started","thread_id":"01a073bb-08ad-7292-8af7-e7e8396ee37d"}'
            printf '%s\n' '{"type":"turn.started"}'
            printf '%s\n' '{"type":"turn.completed"}'
            """
        )
        do {
            _ = try await ProcessDoctorCodexTaskLauncher(
                homeURL: missingSummaryHome,
                completionTimeout: 5
            ).launch(request)
            Issue.record("A completed turn without a final agent summary must not count as success")
        } catch let error as DoctorCodexTaskLaunchError {
            guard case .missingFinalSummary = error else {
                Issue.record("Expected missingFinalSummary, got \(error)")
                return
            }
        }
    }

    @Test
    func processCodexLauncherTimeoutStopsItsWholeProcessGroup() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("fleetmesh-codex-timeout-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home", isDirectory: true)
        let workspace = root.appendingPathComponent("harness-sync", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let executable = try installFakeCodex(
            homeURL: home,
            body: """
            script_dir="$(cd "$(dirname "$0")" && pwd)"
            cat >/dev/null
            sleep 30 &
            child=$!
            printf '%s\n' "$child" > "$script_dir/child-pid.txt"
            printf '%s\n' '{"type":"thread.started","thread_id":"01a073bb-08ad-7292-8af7-e7e8396ee37d"}'
            printf '%s\n' '{"type":"turn.started"}'
            wait "$child"
            """
        )
        let request = DoctorCodexResolutionRequest(workspaceURL: workspace, prompt: "Preserve work")
        let childPIDURL = executable.deletingLastPathComponent().appendingPathComponent("child-pid.txt")

        do {
            _ = try await ProcessDoctorCodexTaskLauncher(
                homeURL: home,
                completionTimeout: 2
            ).launch(request)
            Issue.record("A task that does not complete before the deadline must time out")
        } catch let error as DoctorCodexTaskLaunchError {
            guard case .timedOut = error else {
                Issue.record("Expected timedOut, got \(error)")
                return
            }
        }

        let childText = try String(contentsOf: childPIDURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let childPID = try #require(Int32(childText))
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            errno = 0
            if kill(childPID, 0) == -1, errno == ESRCH { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        errno = 0
        #expect(kill(childPID, 0) == -1 && errno == ESRCH)
    }

    @Test
    func processDoctorRunnerCapturesLargeOutputWithoutDeadlock() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("fleetmesh-doctor-runner-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let script = root.appendingPathComponent("repair.sh")
        try Data("#!/bin/sh\ni=0\nwhile [ $i -lt 5000 ]; do echo repair-output-$i; i=$((i+1)); done\nexit 1\n".utf8)
            .write(to: script)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: script.path
        )
        let command = DoctorResolvedCommand(
            componentID: "test",
            executableURL: script,
            arguments: [],
            workingDirectoryURL: root,
            timeout: 5
        )

        let result = await ProcessDoctorCommandRunner().run(command)

        #expect(result.exitCode == 1)
        #expect(!result.timedOut)
        #expect(result.combinedOutput?.contains("repair-output-4999") == true)
        #expect(result.failureSummary.contains("repair-output-4999"))
    }

    @Test
    @MainActor
    func remoteMachineCannotRunALocalRepair() async throws {
        let fixture = try DoctorFixture(
            snapshots: [doctorSnapshot(
                installedVersion: "1.1.0",
                installed: "bbbbbbb",
                sourceVersion: "1.1.0",
                source: "bbbbbbbbbbbb"
            )]
        )
        defer { fixture.remove() }
        await fixture.store.start()

        await fixture.store.repair(
            componentID: "authbar",
            targetMachineID: "99999999-9999-4999-8999-999999999999"
        )

        #expect(fixture.store.doctorRun(for: "authbar")?.outcome == .protected)
        #expect(await fixture.runner.callCount() == 0)
        #expect(await fixture.inventory.callCount() == 1)
    }

    @Test
    @MainActor
    func preflightLocalChangesStopBeforeExecution() async throws {
        let baseline = doctorSnapshot(
            installedVersion: "1.1.0",
            installed: "bbbbbbb",
            sourceVersion: "1.1.0",
            source: "bbbbbbbbbbbb"
        )
        let dirty = doctorSnapshot(
            installedVersion: "1.0.0",
            installed: "aaaaaaa",
            sourceVersion: "1.1.0",
            source: "bbbbbbbbbbbb",
            dirty: true
        )
        let fixture = try DoctorFixture(snapshots: [baseline, dirty])
        defer { fixture.remove() }
        await fixture.store.start()

        await fixture.store.repair(
            componentID: "authbar",
            targetMachineID: doctorFixtureMachineID
        )

        #expect(fixture.store.doctorRun(for: "authbar")?.outcome == .protected)
        #expect(await fixture.runner.callCount() == 0)
        #expect(await fixture.inventory.callCount() == 2)
    }

    @Test
    @MainActor
    func successfulRepairRequiresPostflightAlignment() async throws {
        let baseline = doctorSnapshot(
            installedVersion: "1.1.0",
            installed: "bbbbbbb",
            sourceVersion: "1.1.0",
            source: "bbbbbbbbbbbb"
        )
        let before = doctorSnapshot(
            installedVersion: "1.0.0",
            installed: "aaaaaaa",
            sourceVersion: "1.1.0",
            source: "bbbbbbbbbbbb"
        )
        let fixture = try DoctorFixture(snapshots: [baseline, before, before, baseline])
        defer { fixture.remove() }
        await fixture.store.start()

        await fixture.store.repair(
            componentID: "authbar",
            targetMachineID: doctorFixtureMachineID
        )

        #expect(fixture.store.doctorRun(for: "authbar")?.outcome == .repaired)
        #expect(await fixture.runner.callCount() == 1)
        #expect(await fixture.inventory.callCount() == 4)
        #expect(fixture.store.selectedAssessment?.drifts.first {
            $0.componentID == "authbar"
        }?.state == .aligned)
    }

    @Test
    @MainActor
    func successfulCommandWithoutPostflightProofStaysAttention() async throws {
        let baseline = doctorSnapshot(
            installedVersion: "1.1.0",
            installed: "bbbbbbb",
            sourceVersion: "1.1.0",
            source: "bbbbbbbbbbbb"
        )
        let before = doctorSnapshot(
            installedVersion: "1.0.0",
            installed: "aaaaaaa",
            sourceVersion: "1.1.0",
            source: "bbbbbbbbbbbb"
        )
        let fixture = try DoctorFixture(snapshots: [baseline, before, before, before])
        defer { fixture.remove() }
        await fixture.store.start()

        await fixture.store.repair(
            componentID: "authbar",
            targetMachineID: doctorFixtureMachineID
        )

        #expect(fixture.store.doctorRun(for: "authbar")?.outcome == .needsAttention)
        #expect(await fixture.runner.callCount() == 1)
        #expect(await fixture.inventory.callCount() == 4)
    }

    @Test
    @MainActor
    func sourceChangeBetweenPreflightAndExecutionStopsSafely() async throws {
        let baseline = doctorSnapshot(
            installedVersion: "1.1.0",
            installed: "bbbbbbb",
            sourceVersion: "1.1.0",
            source: "bbbbbbbbbbbb"
        )
        let before = doctorSnapshot(
            installedVersion: "1.0.0",
            installed: "aaaaaaa",
            sourceVersion: "1.1.0",
            source: "bbbbbbbbbbbb"
        )
        let changed = doctorSnapshot(
            installedVersion: "1.0.0",
            installed: "aaaaaaa",
            sourceVersion: "1.1.0",
            source: "cccccccccccc"
        )
        let fixture = try DoctorFixture(snapshots: [baseline, before, changed])
        defer { fixture.remove() }
        await fixture.store.start()

        await fixture.store.repair(
            componentID: "authbar",
            targetMachineID: doctorFixtureMachineID
        )

        #expect(fixture.store.doctorRun(for: "authbar")?.outcome == .protected)
        #expect(await fixture.runner.callCount() == 0)
        #expect(await fixture.inventory.callCount() == 3)
    }
}

private func installFakeCodex(homeURL: URL, body: String) throws -> URL {
    let executable = homeURL.appendingPathComponent(".toolbox/bin/codex")
    try FileManager.default.createDirectory(
        at: executable.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try Data("#!/bin/sh\nset -eu\n\(body)\n".utf8).write(to: executable)
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o700],
        ofItemAtPath: executable.path
    )
    return executable
}

private actor SequencedInventory: InventoryCapturing {
    private let snapshots: [MachineSnapshot]
    private var calls = 0

    init(snapshots: [MachineSnapshot]) {
        self.snapshots = snapshots
    }

    func capture(machineID: String, displayName: String?) async -> MachineSnapshot {
        let index = min(calls, snapshots.count - 1)
        calls += 1
        return snapshots[index]
    }

    func captureForDoctor(
        machineID: String,
        displayName: String?,
        componentID: String
    ) async -> MachineSnapshot {
        let index = min(calls, snapshots.count - 1)
        calls += 1
        return snapshots[index]
    }

    func callCount() -> Int { calls }
}

private actor RecordingDoctorRunner: DoctorCommandRunning {
    private var commands: [DoctorResolvedCommand] = []

    func run(_ command: DoctorResolvedCommand) async -> DoctorCommandResult {
        commands.append(command)
        return DoctorCommandResult(
            exitCode: 0,
            standardOutputTail: "fake product installer completed",
            standardErrorTail: "",
            timedOut: false,
            duration: 0.01
        )
    }

    func callCount() -> Int { commands.count }
}

@MainActor
private final class DoctorFixture {
    let root: URL
    let inventory: SequencedInventory
    let runner: RecordingDoctorRunner
    let store: FleetStore

    init(snapshots: [MachineSnapshot]) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("device-sync-doctor-tests-\(UUID().uuidString)", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        let executable = home.appendingPathComponent("code/authbar/install.sh")
        try FileManager.default.createDirectory(
            at: executable.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: executable.path
        )

        let localRepository = LocalStateRepository(
            stateURL: root.appendingPathComponent("state/local-state.json"),
            homeURL: home
        )
        try localRepository.save(LocalDeviceState(
            machineID: doctorFixtureMachineID,
            fleetRootPath: root.appendingPathComponent("fleet", isDirectory: true).path,
            displayName: "Doctor Test Mac"
        ))

        // Doctor tests need an explicit desired-state authority. Production no
        // longer seeds a manifest in an arbitrary local fallback folder, so a
        // temporary test fleet must model the operator's baseline directly.
        if let baseline = snapshots.first {
            try FleetRepository(
                rootURL: root.appendingPathComponent("fleet", isDirectory: true)
            ).saveManifest(FleetManifest(snapshot: baseline))
        }

        inventory = SequencedInventory(snapshots: snapshots)
        runner = RecordingDoctorRunner()
        store = FleetStore(
            localRepository: localRepository,
            inventory: inventory,
            doctorCommandRunner: runner,
            doctorHomeURL: home
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

private func doctorSnapshot(
    installedVersion: String,
    installed: String,
    sourceVersion: String,
    source: String,
    dirty: Bool = false
) -> MachineSnapshot {
    MachineSnapshot(
        machineID: doctorFixtureMachineID,
        name: "Doctor Test Mac",
        hostName: "doctor-test",
        modelIdentifier: "Mac99,1",
        architecture: "arm64",
        osVersion: "26.6",
        osBuild: "25G83",
        components: [authBarObservation(
            installedVersion: installedVersion,
            installedRevision: installed,
            sourceVersion: sourceVersion,
            sourceRevision: source,
            dirty: dirty
        )]
    )
}

private func authBarObservation(
    installedVersion: String = "1.0.0",
    installedRevision: String,
    sourceVersion: String? = nil,
    sourceRevision: String,
    dirty: Bool
) -> ComponentObservation {
    ComponentObservation(
        id: "authbar",
        name: "AuthBar",
        kind: .application,
        status: .installed,
        installedVersion: installedVersion,
        installedRevision: installedRevision,
        sourceVersion: sourceVersion,
        sourceRevision: sourceRevision,
        sourceBranch: "main",
        sourceDirty: dirty,
        isRunning: true,
        evidence: "Test fixture"
    )
}

private func deploymentDrift() -> ComponentDrift {
    ComponentDrift(
        componentID: "authbar",
        name: "AuthBar",
        kind: .application,
        state: .different,
        severity: .attention,
        summary: "Installed build and source checkout are different revisions; deployment state is not converged.",
        expected: "Installed aaaaaaa",
        observed: "Source bbbbbbbbbbbb"
    )
}
