import Foundation
import Testing
@testable import DeviceSync

struct CachedDynamoDBFleetRepositoryBackendTests {
    @Test
    func successfulReadRefreshesCacheAndOutageFallsBackVisibly() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("fleetmesh-cache-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = JSONFleetRepositoryBackend(rootURL: root)
        let client = InMemoryDynamoDBFleetClient()
        let authority = DynamoDBFleetRepository(fleetID: "primary", client: client)
        let snapshot = cachedSnapshot()
        let manifest = FleetManifest(snapshot: snapshot)
        _ = try await authority.replaceBaseline(manifest, snapshot: snapshot)
        let backend = CachedDynamoDBFleetRepositoryBackend(
            authority: authority,
            cache: cache
        )

        let remote = await backend.load()
        #expect(remote.issues.isEmpty)
        #expect((await cache.load()).manifest?.revision == manifest.revision)

        let offline = CachedDynamoDBFleetRepositoryBackend(
            authority: UnavailableFleetRepositoryBackend(),
            cache: cache
        )
        let fallback = await offline.load()
        #expect(fallback.manifest?.revision == manifest.revision)
        #expect(fallback.issues.contains { $0.id == "dynamodb-cache-fallback" })
    }
}

private actor UnavailableFleetRepositoryBackend: FleetRepositoryProtocol {
    nonisolated let sourceDescription = "Unavailable"
    func load() async -> FleetReadResult {
        FleetReadResult(manifest: nil, machines: [], issues: [FleetIssue(
            id: "offline", title: "Offline", detail: "Test"
        )])
    }
    func loadManifest() async -> FleetManifestReadResult {
        FleetManifestReadResult(manifest: nil, issue: FleetIssue(
            id: "offline", title: "Offline", detail: "Test"
        ))
    }
    func replaceBaseline(_ manifest: FleetManifest, snapshot: MachineSnapshot) async throws -> FleetReadResult { throw FleetStorageConfigurationError.incompleteDynamoDBConfiguration }
    func publish(_ snapshot: MachineSnapshot) async throws -> FleetReadResult { throw FleetStorageConfigurationError.incompleteDynamoDBConfiguration }
    func publishAndSave(_ snapshot: MachineSnapshot, manifest: FleetManifest, replacingRevision: String) async throws -> FleetReadResult { throw FleetStorageConfigurationError.incompleteDynamoDBConfiguration }
    func save(_ manifest: FleetManifest, replacingRevision: String) async throws -> FleetReadResult { throw FleetStorageConfigurationError.incompleteDynamoDBConfiguration }
}

private func cachedSnapshot() -> MachineSnapshot {
    MachineSnapshot(
        machineID: "eef61618-c556-438c-a2af-101ca6cedae9",
        name: "Cache fixture",
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
