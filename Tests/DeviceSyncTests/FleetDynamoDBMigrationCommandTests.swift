import Foundation
import Testing
@testable import DeviceSync

struct FleetDynamoDBMigrationCommandTests {
    @Test
    func commandImportsBeforePersistingShadowAndCutoverModes() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("fleetmesh-command-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let fleetRoot = root.appendingPathComponent("fleet")
        let localRepository = LocalStateRepository(
            stateURL: root.appendingPathComponent("local-state.json"),
            homeURL: root
        )
        let snapshot = migrationCommandSnapshot()
        try localRepository.save(LocalDeviceState(
            machineID: snapshot.machineID,
            fleetRootPath: fleetRoot.path
        ))
        let source = JSONFleetRepositoryBackend(rootURL: fleetRoot)
        _ = try await source.replaceBaseline(
            FleetManifest(snapshot: snapshot),
            snapshot: snapshot
        )
        let client = InMemoryDynamoDBFleetClient()
        let factory: DynamoDBFleetClientFactory = { _ in client }

        let shadow = try await FleetDynamoDBMigrationCommand.run(
            mode: .shadow,
            profile: "fleetmesh-auto",
            region: "us-west-2",
            table: "fleetmesh-control-plane",
            fleetID: "primary",
            localRepository: localRepository,
            makeDynamoDBClient: factory
        )
        #expect(shadow.migration.comparison.isMatch)
        #expect(try localRepository.loadOrCreate().effectiveStorageBackend == .shadow)

        let cutover = try await FleetDynamoDBMigrationCommand.run(
            mode: .cutover,
            profile: "fleetmesh-auto",
            region: "us-west-2",
            table: "fleetmesh-control-plane",
            fleetID: "primary",
            localRepository: localRepository,
            makeDynamoDBClient: factory
        )
        #expect(cutover.migration.comparison.isMatch)
        #expect(try localRepository.loadOrCreate().effectiveStorageBackend == .dynamodb)
    }
}

private func migrationCommandSnapshot() -> MachineSnapshot {
    MachineSnapshot(
        machineID: "fff61618-c556-438c-a2af-101ca6cedae9",
        name: "Migration command fixture",
        hostName: "redacted-host",
        modelIdentifier: "Mac17,6",
        architecture: "arm64",
        osVersion: "26.6",
        osBuild: "25G83",
        platform: .macOS,
        capturedAt: Date(timeIntervalSince1970: 1_788_000_000),
        components: [ComponentObservation(
            id: "example-app", name: "Example App", kind: .application,
            status: .installed, installedVersion: "1.0.0", evidence: "Installed"
        )]
    )
}
