import Foundation

/// Protocol adapter for the legacy shared-folder authority. This keeps the
/// existing JSON behavior intact while FleetStore migrates to a storage-neutral
/// dependency and DynamoDB is implemented behind the same contract.
actor JSONFleetRepositoryBackend: FleetRepositoryProtocol {
    let rootURL: URL
    nonisolated let sourceDescription = "Shared JSON folder"

    init(rootURL: URL) {
        self.rootURL = rootURL.standardizedFileURL
    }

    func load() async -> FleetReadResult {
        FleetRepository(rootURL: rootURL).load()
    }

    func loadManifest() async -> FleetManifestReadResult {
        FleetRepository(rootURL: rootURL).loadManifest()
    }

    func replaceBaseline(
        _ manifest: FleetManifest,
        snapshot: MachineSnapshot
    ) async throws -> FleetReadResult {
        let repository = FleetRepository(rootURL: rootURL)
        _ = try repository.publish(snapshot)
        try repository.saveManifest(manifest)
        return repository.load()
    }

    func publish(_ snapshot: MachineSnapshot) async throws -> FleetReadResult {
        let repository = FleetRepository(rootURL: rootURL)
        _ = try repository.publish(snapshot)
        return repository.load()
    }

    func publishAndSave(
        _ snapshot: MachineSnapshot,
        manifest: FleetManifest,
        replacingRevision: String
    ) async throws -> FleetReadResult {
        let repository = FleetRepository(rootURL: rootURL)
        _ = try repository.publish(snapshot)
        try repository.saveManifest(
            manifest,
            replacingRevision: replacingRevision
        )
        return repository.load()
    }

    func save(
        _ manifest: FleetManifest,
        replacingRevision: String
    ) async throws -> FleetReadResult {
        let repository = FleetRepository(rootURL: rootURL)
        try repository.saveManifest(
            manifest,
            replacingRevision: replacingRevision
        )
        return repository.load()
    }
}
