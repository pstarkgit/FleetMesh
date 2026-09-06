import Foundation
import Testing
@testable import DeviceSync

struct FleetStoragePersistenceTests {
    @Test
    func storageSelectionPersistsAndInvalidUpdateDoesNotOverwrite() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("fleetmesh-storage-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = LocalStateRepository(
            stateURL: root.appendingPathComponent("local-state.json"),
            homeURL: root
        )
        _ = try repository.loadOrCreate()
        let updated = try repository.updatingStorage(
            backend: .shadow,
            profile: "fleetmesh-auto",
            region: "us-west-2",
            table: "fleetmesh-control-plane",
            fleetID: "primary",
            cachePath: root.appendingPathComponent("cache.json").path
        )
        #expect(updated.effectiveStorageBackend == .shadow)
        #expect(try repository.loadOrCreate().dynamoDBConfiguration()?.table == "fleetmesh-control-plane")

        #expect(throws: FleetStorageConfigurationError.self) {
            _ = try repository.updatingStorage(
                backend: .dynamodb,
                profile: "fleetmesh-auto",
                region: "us-west-2",
                table: "bad/table",
                fleetID: "primary"
            )
        }
        #expect(try repository.loadOrCreate().effectiveStorageBackend == .shadow)
    }
}
