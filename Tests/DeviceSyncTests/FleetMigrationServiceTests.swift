import Foundation
import Testing
@testable import DeviceSync

struct FleetMigrationServiceTests {
    @Test
    func importIsIdempotentAndProducesExactShadowMatch() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("fleetmesh-migration-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = JSONFleetRepositoryBackend(rootURL: root)
        let client = InMemoryDynamoDBFleetClient()
        let target = DynamoDBFleetRepository(fleetID: "primary", client: client)
        let first = migrationSnapshot(
            machineID: "ccf61618-c556-438c-a2af-101ca6cedae9",
            name: "First"
        )
        let second = migrationSnapshot(
            machineID: "ddf61618-c556-438c-a2af-101ca6cedae9",
            name: "Second"
        )
        let manifest = FleetManifest(snapshot: first)
        _ = try await source.replaceBaseline(manifest, snapshot: first)
        _ = try await source.publish(second)
        let migration = FleetMigrationService(source: source, target: target)

        let initial = try await migration.importAndCompare()
        #expect(initial.manifestRevision == manifest.revision)
        #expect(initial.importedDeviceCount == 2)
        #expect(initial.comparison.isMatch)

        let repeated = try await migration.importAndCompare()
        #expect(repeated.comparison.isMatch)
        #expect((await target.load()).machines.count == 2)
    }
}

private func migrationSnapshot(
    machineID: String,
    name: String
) -> MachineSnapshot {
    MachineSnapshot(
        machineID: machineID,
        name: name,
        hostName: "redacted-host",
        modelIdentifier: "Mac17,6",
        architecture: "arm64",
        osVersion: "26.6",
        osBuild: "25G83",
        platform: .macOS,
        capturedAt: Date(timeIntervalSince1970: 1_788_000_000),
        components: [
            ComponentObservation(
                id: "example-app",
                name: "Example App",
                kind: .application,
                status: .installed,
                installedVersion: "1.0.0",
                evidence: "Installed"
            ),
        ]
    )
}
