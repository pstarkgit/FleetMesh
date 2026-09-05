import Foundation
import Testing
@testable import DeviceSync

struct FleetRepositoryTests {
    @Test
    func processRunnerDrainsOutputWhileChildIsRunning() async throws {
        let result = await ProcessCommandRunner().run(
            executable: URL(fileURLWithPath: "/usr/bin/yes"),
            arguments: [String(repeating: "x", count: 256)],
            environment: nil,
            timeout: 0.2
        )

        #expect(result.timedOut)
        #expect(result.standardOutput.utf8.count > 16_384)
        #expect(result.standardOutput.utf8.count <= 1_048_576)
    }

    @Test
    func processRunnerReturnsWhenExecutableCannotLaunch() async {
        let result = await ProcessCommandRunner().run(
            executable: URL(fileURLWithPath: "/definitely/not/a/fleetmesh-command"),
            arguments: [],
            environment: nil,
            timeout: 0.2
        )

        #expect(result.exitCode == -1)
        #expect(!result.timedOut)
        #expect(!result.standardError.isEmpty)
    }

    @Test
    func connectPublishesOnlyAgainstPinnedManifestRevision() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let snapshot = repositoryFixtureSnapshot()
        let repository = FleetRepository(rootURL: root)
        let manifest = FleetManifest(snapshot: snapshot)
        try repository.saveManifest(manifest)

        let (read, localState) = try await FleetRepositoryAccess().connect(
            snapshot: snapshot,
            rootURL: root,
            persistLocalRoot: { root in
                LocalDeviceState(machineID: snapshot.machineID, fleetRootPath: root.path)
            }
        )

        #expect(read.manifest?.revision == manifest.revision)
        #expect(read.machines.map(\.machineID) == [snapshot.machineID])
        #expect(localState.fleetRootPath == root.path)
    }

    @Test
    func connectRestoresPriorReportWhenLocalPointerCannotPersist() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let old = repositoryFixtureSnapshot(name: "Old report")
        let fresh = repositoryFixtureSnapshot(name: "Fresh report")
        let repository = FleetRepository(rootURL: root)
        try repository.saveManifest(FleetManifest(snapshot: old))
        _ = try repository.publish(old)

        await #expect(throws: TestConnectError.self) {
            _ = try await FleetRepositoryAccess().connect(
                snapshot: fresh,
                rootURL: root,
                persistLocalRoot: { _ in throw TestConnectError.pointerWriteFailed }
            )
        }

        #expect(repository.load().machines.first?.name == "Old report")
    }

    @Test
    func connectRollbackDoesNotOverwriteConcurrentFreshReport() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let old = repositoryFixtureSnapshot(name: "Old report")
        let connecting = repositoryFixtureSnapshot(name: "Connecting report")
        let concurrent = repositoryFixtureSnapshot(name: "Concurrent report")
        let repository = FleetRepository(rootURL: root)
        try repository.saveManifest(FleetManifest(snapshot: old))
        _ = try repository.publish(old)

        await #expect(throws: TestConnectError.self) {
            _ = try await FleetRepositoryAccess().connect(
                snapshot: connecting,
                rootURL: root,
                persistLocalRoot: { _ in
                    _ = try repository.publish(concurrent)
                    throw TestConnectError.pointerWriteFailed
                }
            )
        }

        #expect(repository.load().machines.first?.name == "Concurrent report")
    }
    @Test
    func oneComponentCanLeaveAndRejoinFleetScopeWithoutChangingOthers() throws {
        let authBar = ComponentObservation(
            id: "authbar",
            name: "AuthBar",
            kind: .application,
            status: .installed,
            installedVersion: "1.0.0",
            evidence: "Installed"
        )
        let codexVoice = ComponentObservation(
            id: "codex-voice",
            name: "Codex Voice",
            kind: .application,
            status: .installed,
            installedVersion: "0.1.0",
            evidence: "Installed"
        )
        let snapshot = repositoryFixtureSnapshot(components: [authBar, codexVoice])
        let original = FleetManifest(snapshot: snapshot)

        let added = try original.settingManaged(
            componentID: "codex-voice",
            managed: true,
            observation: codexVoice,
            updatedByMachineID: snapshot.machineID
        )
        let removed = try added.settingManaged(
            componentID: "codex-voice",
            managed: false,
            observation: codexVoice,
            updatedByMachineID: snapshot.machineID
        )
        let restored = try removed.settingManaged(
            componentID: "codex-voice",
            managed: true,
            observation: codexVoice,
            updatedByMachineID: snapshot.machineID
        )

        #expect(original.target("codex-voice")?.isManagedByDefault == false)
        #expect(original.target("authbar") == removed.target("authbar"))
        #expect(removed.target("codex-voice")?.isManagedByDefault == false)
        #expect(restored.target("codex-voice")?.expectedVersion == "0.1.0")
        #expect(restored.revision != removed.revision)
    }

    @Test
    func missingComponentCannotBeAddedAsDesiredState() throws {
        let missing = ComponentObservation(
            id: "future-app",
            name: "Future App",
            kind: .application,
            status: .missing,
            evidence: "Not installed"
        )
        let snapshot = repositoryFixtureSnapshot(components: [missing])
        let manifest = FleetManifest(snapshot: snapshot)

        #expect(throws: FleetManifestError.self) {
            try manifest.settingManaged(
                componentID: missing.id,
                managed: true,
                observation: missing,
                updatedByMachineID: snapshot.machineID
            )
        }
    }

    @Test
    func staleManifestRevisionCannotOverwriteNewerFleetScope() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = FleetRepository(rootURL: root)
        let snapshot = repositoryFixtureSnapshot()
        let first = FleetManifest(snapshot: snapshot)
        try repository.saveManifest(first)
        let second = try first.settingManaged(
            componentID: "codex-themes",
            managed: false,
            observation: snapshot.component("codex-themes"),
            updatedByMachineID: snapshot.machineID
        )
        try repository.saveManifest(second, replacingRevision: first.revision)

        #expect(throws: FleetRepositoryError.self) {
            try repository.saveManifest(first, replacingRevision: first.revision)
        }
        #expect(repository.load().manifest?.revision == second.revision)
    }

    @Test
    func concurrentChildrenOfOneRevisionFailClosedAfterCloudMerge() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = FleetRepository(rootURL: root)
        let snapshot = repositoryFixtureSnapshot()
        let parent = FleetManifest(snapshot: snapshot)
        try repository.saveManifest(parent)
        let firstChild = try parent.settingManaged(
            componentID: "codex-themes",
            managed: false,
            observation: snapshot.component("codex-themes"),
            updatedByMachineID: snapshot.machineID
        )
        try repository.saveManifest(firstChild, replacingRevision: parent.revision)

        // Simulate OneDrive merging an independently-created sibling revision
        // record from another Mac after both had read the same parent.
        let sibling = "11f61618-c556-438c-a2af-101ca6cedae9"
        let siblingManifestData = try FleetJSON.encoder.encode(firstChild)
        var siblingManifest = try #require(
            JSONSerialization.jsonObject(with: siblingManifestData) as? [String: Any]
        )
        siblingManifest["revision"] = sibling
        siblingManifest["updatedByMachineID"] = "44f61618-c556-438c-a2af-101ca6cedae9"
        let siblingJSON: [String: Any] = [
            "parentRevision": parent.revision,
            "manifest": siblingManifest,
        ]
        try JSONSerialization.data(
            withJSONObject: siblingJSON,
            options: [.prettyPrinted, .sortedKeys]
        ).write(
            to: repository.manifestRevisionsURL
                .appendingPathComponent(sibling)
                .appendingPathExtension("json"),
            options: .atomic
        )

        let read = repository.loadManifest()

        #expect(read.manifest == nil)
        #expect(read.issue?.title == "Fleet policy has conflicting revisions")
        #expect(read.issue?.detail.contains(firstChild.revision) == true)

        let replacementSnapshot = repositoryFixtureSnapshot(name: "Chosen baseline")
        let replacement = FleetManifest(snapshot: replacementSnapshot)
        try repository.saveManifest(replacement)
        #expect(repository.loadManifest().manifest?.revision == replacement.revision)
        #expect(repository.loadManifest().issue == nil)
    }

    @Test
    func revisionRecordArrivingBeforeManifestPointerFailsClosed() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = FleetRepository(rootURL: root)
        let snapshot = repositoryFixtureSnapshot()
        let parent = FleetManifest(snapshot: snapshot)
        try repository.saveManifest(parent)
        let child = try parent.settingManaged(
            componentID: "codex-themes",
            managed: false,
            observation: snapshot.component("codex-themes"),
            updatedByMachineID: snapshot.machineID
        )
        try repository.saveManifest(child, replacingRevision: parent.revision)
        try FleetJSON.encoder.encode(parent).write(
            to: repository.manifestURL,
            options: .atomic
        )

        let read = repository.loadManifest()

        #expect(read.manifest == nil)
        #expect(read.issue?.title == "Fleet policy is waiting for cloud convergence")
    }
    @Test
    func malformedMachineDoesNotHideValidMachine() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = FleetRepository(rootURL: root)
        let snapshot = repositoryFixtureSnapshot()
        _ = try repository.publish(snapshot)
        try Data("{not-json".utf8).write(
            to: repository.machinesURL.appendingPathComponent("broken.json")
        )

        let result = repository.load()

        #expect(result.machines.count == 1)
        #expect(result.machines.first?.machineID == snapshot.machineID)
        #expect(result.issues.count == 1)
        #expect(result.issues.first?.title == "One machine report is unreadable")
    }

    @Test
    func duplicateMachineReportsKeepFreshestSnapshotAndReportIgnoredEvidence() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = FleetRepository(rootURL: root)
        try FileManager.default.createDirectory(
            at: repository.machinesURL,
            withIntermediateDirectories: true
        )
        let machineID = "b41f9f4f-0fce-4792-a3c6-c93a73fcb4cd"
        let older = repositoryFixtureSnapshot(
            machineID: machineID,
            name: "Older report",
            capturedAt: Date(timeIntervalSince1970: 1_000)
        )
        let newer = repositoryFixtureSnapshot(
            machineID: machineID,
            name: "Newer report",
            capturedAt: Date(timeIntervalSince1970: 2_000)
        )
        try writeMachineReport(
            older,
            to: repository.machinesURL.appendingPathComponent("(machineID).json")
        )
        try writeMachineReport(
            newer,
            to: repository.machinesURL.appendingPathComponent(
                "dev-dsk-starkpat-1d-19238b71.us-east-1.amazon.com-secret-token.json"
            )
        )

        let result = repository.load()

        #expect(result.machines.map(\.machineID) == [machineID])
        #expect(result.machines.first?.name == "Newer report")
        let issue = try #require(result.issues.first {
            $0.title == "Duplicate machine report ignored"
        })
        #expect(issue.detail.contains("freshest capturedAt snapshot"))
        #expect(!issue.id.contains("dev-dsk-starkpat"))
        #expect(!issue.id.contains("secret-token"))
        #expect(!issue.detail.contains("dev-dsk-starkpat"))
        #expect(!issue.detail.contains("secret-token"))
    }

    @Test
    func duplicateMachineReportsWithEqualTimestampsResolveDeterministically() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = FleetRepository(rootURL: root)
        try FileManager.default.createDirectory(
            at: repository.machinesURL,
            withIntermediateDirectories: true
        )
        let machineID = "b41f9f4f-0fce-4792-a3c6-c93a73fcb4cd"
        let capturedAt = Date(timeIntervalSince1970: 3_000)
        let canonical = repositoryFixtureSnapshot(
            machineID: machineID,
            name: "Canonical report",
            capturedAt: capturedAt
        )
        let duplicate = repositoryFixtureSnapshot(
            machineID: machineID,
            name: "Duplicate report",
            capturedAt: capturedAt
        )
        try writeMachineReport(
            duplicate,
            to: repository.machinesURL.appendingPathComponent("000-duplicate.json")
        )
        try writeMachineReport(
            canonical,
            to: repository.machinesURL.appendingPathComponent("\(machineID).json")
        )

        let firstLoad = repository.load()
        let secondLoad = repository.load()

        #expect(firstLoad.machines.map(\.name) == ["Canonical report"])
        #expect(secondLoad.machines.map(\.name) == ["Canonical report"])
        #expect(firstLoad.issues.first?.id == secondLoad.issues.first?.id)
    }

    @Test
    func snapshotJSONExcludesSensitiveMachineData() throws {
        let sensitive = [
            "CRX9606TPW",
            "2CD77E45-E274-5413-BDFC-E0EA0A07C947",
            "/Users/starkpat",
            "secret-token-value",
            "platform_UUID",
            "serial_number",
        ]
        let snapshot = repositoryFixtureSnapshot()

        let data = try FleetJSON.encoder.encode(snapshot)
        let json = try #require(String(data: data, encoding: .utf8))

        for forbidden in sensitive {
            #expect(!json.contains(forbidden))
        }
    }

    @Test
    func applicationEvidenceDoesNotPublishDeveloperNamespace() {
        let plistEvidence = InventoryService.applicationEvidence(managedVersion: nil)
        let executableEvidence = InventoryService.applicationEvidence(managedVersion: "1.2.3")

        #expect(plistEvidence == "Installed application; version read from its signed Info.plist.")
        #expect(executableEvidence == "Installed application; version returned by its managed executable.")
        #expect(!plistEvidence.localizedCaseInsensitiveContains("bundle"))
        #expect(!executableEvidence.localizedCaseInsensitiveContains("bundle"))
        #expect(!plistEvidence.localizedCaseInsensitiveContains("starkpat"))
        #expect(!executableEvidence.localizedCaseInsensitiveContains("starkpat"))
    }

    @Test
    func machineIDMustBeRandomUUIDShape() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = FleetRepository(rootURL: root)
        let invalid = MachineSnapshot(
            machineID: "hardware-serial-number",
            name: "Mac",
            hostName: "mac",
            modelIdentifier: "Mac99,1",
            architecture: "arm64",
            osVersion: "26.6",
            osBuild: "25G00",
            components: []
        )

        #expect(throws: FleetRepositoryError.self) {
            try repository.publish(invalid)
        }
    }

    @Test
    func localStateIsStableAcrossLoads() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = LocalStateRepository(
            stateURL: root.appendingPathComponent("state/local-state.json"),
            homeURL: root
        )

        let first = try repository.loadOrCreate()
        let second = try repository.loadOrCreate()

        #expect(first.machineID == second.machineID)
        #expect(UUID(uuidString: first.machineID) != nil)
    }

    @Test
    func fleetForgeRetainsLegacyLocalStateAuthority() {
        let support = URL(fileURLWithPath: "/tmp/Application Support", isDirectory: true)

        #expect(
            LocalStateRepository.defaultStateURL(applicationSupportURL: support).path
                == "/tmp/Application Support/Device Sync/local-state.json"
        )
        #expect(FleetMeshIdentity.legacyFleetDirectoryName == "Device Sync")
    }

    @Test
    func canonicalSharedFleetPathRemainsStableWithoutGrantingSeedAuthority() {
        let home = URL(fileURLWithPath: "/Users/tester", isDirectory: true)
        let shared = LocalStateRepository.canonicalSharedFleetURL(homeURL: home)

        #expect(
            shared.path
                == "/Users/tester/Library/CloudStorage/OneDrive-amazon.com/Device Sync"
        )
    }

    @Test
    func olderLocalStateWithoutDisplayNameStillDecodes() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let stateURL = root.appendingPathComponent("local-state.json")
        try Data(#"{"fleetRootPath":"/tmp/fleet","machineID":"b41f9f4f-0fce-4792-a3c6-c93a73fcb4cd"}"#.utf8)
            .write(to: stateURL)
        let repository = LocalStateRepository(stateURL: stateURL, homeURL: root)

        let state = try repository.loadOrCreate()

        #expect(state.displayName == nil)
        #expect(state.machineID == "b41f9f4f-0fce-4792-a3c6-c93a73fcb4cd")
    }

    @Test
    func hiddenCatalogItemsPersistLocallyAndCanBeRestored() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let stateURL = root.appendingPathComponent("state/local-state.json")
        let repository = LocalStateRepository(stateURL: stateURL, homeURL: root)

        let initial = try repository.loadOrCreate()
        let hidden = try repository.settingComponentHidden(
            componentID: "codex-voice",
            hidden: true
        )
        let persistedJSON = try String(contentsOf: stateURL, encoding: .utf8)

        #expect(hidden.machineID == initial.machineID)
        #expect(hidden.hiddenComponents == ["codex-voice"])
        #expect(try repository.loadOrCreate().hiddenComponents == ["codex-voice"])
        #expect(persistedJSON.contains("codex-voice"))

        let restored = try repository.settingComponentHidden(
            componentID: "codex-voice",
            hidden: false
        )
        #expect(restored.hiddenComponents.isEmpty)
        #expect(try repository.loadOrCreate().hiddenComponents.isEmpty)
    }
}

private enum TestConnectError: Error {
    case pointerWriteFailed
}

struct FleetScopeOrchestrationTests {
    @Test
    @MainActor
    func removingCodexVoiceChangesOnlyManifestScopeAndPublishesFreshEvidence() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home", isDirectory: true)
        let fleet = root.appendingPathComponent("fleet", isDirectory: true)
        let localRepository = LocalStateRepository(
            stateURL: root.appendingPathComponent("state/local-state.json"),
            homeURL: home
        )
        let machineID = "b41f9f4f-0fce-4792-a3c6-c93a73fcb4cd"
        try localRepository.save(LocalDeviceState(
            machineID: machineID,
            fleetRootPath: fleet.path,
            displayName: "Scope Test Mac"
        ))

        let authBar = ComponentObservation(
            id: "authbar",
            name: "AuthBar",
            kind: .application,
            status: .installed,
            installedVersion: "1.0.0",
            evidence: "Installed"
        )
        let codexVoice = ComponentObservation(
            id: "codex-voice",
            name: "Codex Voice",
            kind: .application,
            status: .installed,
            installedVersion: "0.1.0",
            sourceDirty: true,
            evidence: "Installed with local source work"
        )
        let snapshot = MachineSnapshot(
            machineID: machineID,
            name: "Scope Test Mac",
            hostName: "scope-test",
            modelIdentifier: "Mac99,1",
            architecture: "arm64",
            osVersion: "26.6",
            osBuild: "25G83",
            components: [authBar, codexVoice]
        )
        let seeded = FleetManifest(snapshot: snapshot)
        let managed = try seeded.settingManaged(
            componentID: "codex-voice",
            managed: true,
            observation: codexVoice,
            updatedByMachineID: snapshot.machineID
        )
        try FleetRepository(rootURL: fleet).saveManifest(managed)
        let inventory = ScopeInventory(snapshot: snapshot)
        let runner = RecordingScopeDoctorRunner()
        let store = FleetStore(
            localRepository: localRepository,
            inventory: inventory,
            doctorCommandRunner: runner,
            doctorHomeURL: home
        )

        await store.start()
        await store.setComponentManaged(componentID: "codex-voice", managed: false)

        let read = FleetRepository(rootURL: fleet).load()
        #expect(read.manifest?.target("codex-voice")?.isManagedByDefault == false)
        #expect(read.manifest?.target("authbar") != nil)
        #expect(read.machines.first?.component("codex-voice") != nil)
        #expect(store.fleetScopeItems.first { $0.id == "codex-voice" }?.isManaged == false)
        #expect(store.selectedAssessment?.managedDrifts.contains {
            $0.componentID == "codex-voice"
        } == false)
        #expect(store.lastActionMessage?.contains("Nothing was uninstalled or deleted") == true)
        #expect(await inventory.callCount() == 2)
        #expect(await runner.callCount() == 0)
    }
}

private actor ScopeInventory: InventoryCapturing {
    private let snapshot: MachineSnapshot
    private var calls = 0

    init(snapshot: MachineSnapshot) {
        self.snapshot = snapshot
    }

    func capture(machineID: String, displayName: String?) async -> MachineSnapshot {
        calls += 1
        return snapshot
    }

    func callCount() -> Int { calls }
}

private actor RecordingScopeDoctorRunner: DoctorCommandRunning {
    private var calls = 0

    func run(_ command: DoctorResolvedCommand) async -> DoctorCommandResult {
        calls += 1
        return DoctorCommandResult(
            exitCode: 0,
            standardOutputTail: "",
            standardErrorTail: "",
            timedOut: false,
            duration: 0
        )
    }

    func callCount() -> Int { calls }
}

private func repositoryFixtureSnapshot(
    machineID: String = "b41f9f4f-0fce-4792-a3c6-c93a73fcb4cd",
    name: String = "Patrick's Mac",
    capturedAt: Date = Date(),
    components: [ComponentObservation]? = nil
) -> MachineSnapshot {
    MachineSnapshot(
        machineID: machineID,
        name: name,
        hostName: "patricks-mac",
        modelIdentifier: "Mac17,6",
        architecture: "arm64",
        osVersion: "26.6.2",
        osBuild: "25G83",
        capturedAt: capturedAt,
        components: components ?? [
            ComponentObservation(
                id: "codex-themes",
                name: "Codex themes",
                kind: .theme,
                status: .installed,
                configurationFingerprint: "839e53f571fd1cae",
                items: ["UOpsOS.codex-theme.json"],
                evidence: "Hashed theme set"
            ),
        ]
    )
}

private func writeMachineReport(_ snapshot: MachineSnapshot, to url: URL) throws {
    let data = try FleetJSON.encoder.encode(snapshot)
    try data.write(to: url, options: .atomic)
}

private func temporaryDirectory() -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("device-sync-tests-\(UUID().uuidString)", isDirectory: true)
    try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}
