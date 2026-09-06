import Foundation

actor CachedDynamoDBFleetRepositoryBackend: FleetRepositoryProtocol {
    nonisolated let sourceDescription = "DynamoDB control plane with JSON cache"

    private let authority: any FleetRepositoryProtocol
    private let cache: any FleetRepositoryProtocol

    init(
        authority: any FleetRepositoryProtocol,
        cache: any FleetRepositoryProtocol
    ) {
        self.authority = authority
        self.cache = cache
    }

    func load() async -> FleetReadResult {
        let remote = await authority.load()
        if remote.issues.isEmpty, remote.manifest != nil {
            await refreshCache(from: remote)
            return remote
        }
        let cached = await cache.load()
        guard cached.manifest != nil else { return remote }
        return FleetReadResult(
            manifest: cached.manifest,
            machines: cached.machines,
            issues: cached.issues + [FleetIssue(
                id: "dynamodb-cache-fallback",
                title: "DynamoDB unavailable; showing cached fleet state",
                detail: "Shared writes are blocked until DynamoDB is reachable."
            )]
        )
    }

    func loadManifest() async -> FleetManifestReadResult {
        let remote = await authority.loadManifest()
        if remote.manifest != nil, remote.issue == nil { return remote }
        let cached = await cache.loadManifest()
        guard cached.manifest != nil else { return remote }
        return FleetManifestReadResult(
            manifest: cached.manifest,
            issue: FleetIssue(
                id: "dynamodb-cache-fallback",
                title: "DynamoDB unavailable; showing cached fleet baseline",
                detail: "Policy changes are blocked until DynamoDB is reachable."
            )
        )
    }

    func replaceBaseline(
        _ manifest: FleetManifest,
        snapshot: MachineSnapshot
    ) async throws -> FleetReadResult {
        let read = try await authority.replaceBaseline(manifest, snapshot: snapshot)
        _ = try await cache.replaceBaseline(manifest, snapshot: snapshot)
        return read
    }

    func publish(_ snapshot: MachineSnapshot) async throws -> FleetReadResult {
        let read = try await authority.publish(snapshot)
        _ = try await cache.publish(snapshot)
        return read
    }

    func publishAndSave(
        _ snapshot: MachineSnapshot,
        manifest: FleetManifest,
        replacingRevision: String
    ) async throws -> FleetReadResult {
        let read = try await authority.publishAndSave(
            snapshot,
            manifest: manifest,
            replacingRevision: replacingRevision
        )
        _ = try await cache.publishAndSave(
            snapshot,
            manifest: manifest,
            replacingRevision: replacingRevision
        )
        return read
    }

    func save(
        _ manifest: FleetManifest,
        replacingRevision: String
    ) async throws -> FleetReadResult {
        let read = try await authority.save(
            manifest,
            replacingRevision: replacingRevision
        )
        _ = try await cache.save(
            manifest,
            replacingRevision: replacingRevision
        )
        return read
    }

    private func refreshCache(from read: FleetReadResult) async {
        guard let manifest = read.manifest,
              let first = read.machines.first else { return }
        do {
            _ = try await cache.replaceBaseline(manifest, snapshot: first)
            for machine in read.machines.dropFirst() {
                _ = try await cache.publish(machine)
            }
        } catch {
            // Cache refresh never changes or invalidates the shared authority.
        }
    }
}
