import Foundation
import Testing
@testable import DeviceSync

private let doctorFixtureMachineID = "11111111-1111-4111-8111-111111111111"

struct DoctorPlannerTests {
    @Test
    func inlinePolicyRoutesEachFindingToOnlyItsSafeAction() {
        let repairObservation = ComponentObservation(
            id: "murmr-voice",
            name: "Murmr Voice",
            kind: .application,
            status: .installed,
            installedVersion: "0.2.36",
            installedRevision: "aaaaaaaaaaaa",
            sourceVersion: "0.2.36",
            sourceRevision: "bbbbbbbbbbbb",
            sourceDirty: false,
            evidence: "Installed/source divergence"
        )
        let repairDrift = ComponentDrift(
            componentID: "murmr-voice",
            name: "Murmr Voice",
            kind: .application,
            state: .different,
            severity: .attention,
            summary: "Installed/source divergence",
            expected: "0.2.36",
            observed: "0.2.36"
        )
        let repairFinding = DoctorPlanner().finding(
            for: repairDrift,
            observation: repairObservation,
            target: ManifestTarget(observation: ComponentObservation(
                id: "murmr-voice",
                name: "Murmr Voice",
                kind: .application,
                status: .installed,
                installedVersion: "0.2.36",
                installedRevision: "bbbbbbbbbbbb",
                sourceVersion: "0.2.36",
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

        let repositoryDrift = ComponentDrift(
            componentID: "codex-cli",
            name: "Codex CLI",
            kind: .commandLineTool,
            state: .different,
            severity: .attention,
            summary: "Repository differs",
            expected: "0.3.0",
            observed: "0.2.0",
            targetBasis: .latestRepository
        )
        #expect(InlineRemediationPolicy.action(
            drift: repositoryDrift,
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
    func olderCleanCheckoutCannotDowngradeNewerInstalledSoftware() {
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
            target: ManifestTarget(observation: observation)
        )

        #expect(finding.disposition == .protected)
        #expect(!finding.canRepair)
        #expect(finding.title.contains("Update"))
        #expect(finding.detail.contains("will not run an installer that could downgrade"))
        #expect(InlineRemediationPolicy.action(
            drift: drift,
            observation: observation,
            finding: finding
        ) == .updateCheckout)
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
            state: .localChanges,
            severity: .attention,
            summary: "Source checkout has local work.",
            expected: "bbbbbbb",
            observed: "bbbbbbbbbbbb"
        )

        let finding = DoctorPlanner().finding(
            for: drift,
            observation: observed,
            target: ManifestTarget(observation: desired)
        )

        #expect(finding.disposition == .protected)
        #expect(!finding.canRepair)
        #expect(finding.recipe == nil)
    }

    @Test
    func unapprovedSourceRevisionRequiresDecision() {
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

        #expect(finding.disposition == .manual)
        #expect(!finding.canRepair)
        #expect(finding.title.contains("approved"))
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
            installedRevision: "aaaaaaa",
            sourceRevision: "bbbbbbbbbbbb",
            dirty: false
        )
        let after = authBarObservation(
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
            snapshots: [doctorSnapshot(installed: "bbbbbbb", source: "bbbbbbbbbbbb")]
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
        let baseline = doctorSnapshot(installed: "bbbbbbb", source: "bbbbbbbbbbbb")
        let dirty = doctorSnapshot(
            installed: "aaaaaaa",
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
        let baseline = doctorSnapshot(installed: "bbbbbbb", source: "bbbbbbbbbbbb")
        let before = doctorSnapshot(installed: "aaaaaaa", source: "bbbbbbbbbbbb")
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
        let baseline = doctorSnapshot(installed: "bbbbbbb", source: "bbbbbbbbbbbb")
        let before = doctorSnapshot(installed: "aaaaaaa", source: "bbbbbbbbbbbb")
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
        let baseline = doctorSnapshot(installed: "bbbbbbb", source: "bbbbbbbbbbbb")
        let before = doctorSnapshot(installed: "aaaaaaa", source: "bbbbbbbbbbbb")
        let changed = doctorSnapshot(installed: "aaaaaaa", source: "cccccccccccc")
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
    installed: String,
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
            installedRevision: installed,
            sourceRevision: source,
            dirty: dirty
        )]
    )
}

private func authBarObservation(
    installedRevision: String,
    sourceRevision: String,
    dirty: Bool
) -> ComponentObservation {
    ComponentObservation(
        id: "authbar",
        name: "AuthBar",
        kind: .application,
        status: .installed,
        installedVersion: "1.0.0",
        installedRevision: installedRevision,
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
