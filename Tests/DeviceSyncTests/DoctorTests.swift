import Foundation
import Testing
@testable import DeviceSync

private let doctorFixtureMachineID = "11111111-1111-4111-8111-111111111111"

struct DoctorPlannerTests {
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
}

struct DoctorOrchestrationTests {
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
        let fixture = try DoctorFixture(snapshots: [baseline, before, baseline])
        defer { fixture.remove() }
        await fixture.store.start()

        await fixture.store.repair(
            componentID: "authbar",
            targetMachineID: doctorFixtureMachineID
        )

        #expect(fixture.store.doctorRun(for: "authbar")?.outcome == .repaired)
        #expect(await fixture.runner.callCount() == 1)
        #expect(await fixture.inventory.callCount() == 3)
        #expect(fixture.store.selectedAssessment?.drifts.first {
            $0.componentID == "authbar"
        }?.state == .aligned)
    }

    @Test
    @MainActor
    func successfulCommandWithoutPostflightProofStaysAttention() async throws {
        let baseline = doctorSnapshot(installed: "bbbbbbb", source: "bbbbbbbbbbbb")
        let before = doctorSnapshot(installed: "aaaaaaa", source: "bbbbbbbbbbbb")
        let fixture = try DoctorFixture(snapshots: [baseline, before, before])
        defer { fixture.remove() }
        await fixture.store.start()

        await fixture.store.repair(
            componentID: "authbar",
            targetMachineID: doctorFixtureMachineID
        )

        #expect(fixture.store.doctorRun(for: "authbar")?.outcome == .needsAttention)
        #expect(await fixture.runner.callCount() == 1)
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
