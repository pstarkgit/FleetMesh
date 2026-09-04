import Foundation
import Testing
@testable import DeviceSync

struct FleetRepositoryTests {
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
}

private func repositoryFixtureSnapshot() -> MachineSnapshot {
    MachineSnapshot(
        machineID: "b41f9f4f-0fce-4792-a3c6-c93a73fcb4cd",
        name: "Patrick's Mac",
        hostName: "patricks-mac",
        modelIdentifier: "Mac17,6",
        architecture: "arm64",
        osVersion: "26.6.2",
        osBuild: "25G83",
        components: [
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

private func temporaryDirectory() -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("device-sync-tests-\(UUID().uuidString)", isDirectory: true)
    try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}
