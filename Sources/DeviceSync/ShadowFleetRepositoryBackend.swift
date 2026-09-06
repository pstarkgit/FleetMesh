import Foundation

/// Migration backend that keeps one authority unchanged while validating a
/// secondary store. Shadow mismatches are diagnostic only and never alter fleet
/// posture or authorize writes.
actor ShadowFleetRepositoryBackend: FleetRepositoryProtocol {
    nonisolated let sourceDescription: String

    private let authority: any FleetRepositoryProtocol
    private let shadow: any FleetRepositoryProtocol
    private var comparison: FleetShadowComparison?
    private var comparisonError: String?

    init(
        authority: any FleetRepositoryProtocol,
        shadow: any FleetRepositoryProtocol
    ) {
        self.authority = authority
        self.shadow = shadow
        sourceDescription = "\(authority.sourceDescription) with shadow validation"
    }

    func load() async -> FleetReadResult {
        async let authorityRead = authority.load()
        async let shadowRead = shadow.load()
        let reads = await (authorityRead, shadowRead)
        recordComparison(authority: reads.0, shadow: reads.1)
        return reads.0
    }

    func loadManifest() async -> FleetManifestReadResult {
        async let authorityRead = authority.loadManifest()
        async let shadowRead = shadow.loadManifest()
        let reads = await (authorityRead, shadowRead)
        recordComparison(
            authority: FleetReadResult(
                manifest: reads.0.manifest,
                machines: [],
                issues: reads.0.issue.map { [$0] } ?? []
            ),
            shadow: FleetReadResult(
                manifest: reads.1.manifest,
                machines: [],
                issues: reads.1.issue.map { [$0] } ?? []
            )
        )
        return reads.0
    }

    func replaceBaseline(
        _ manifest: FleetManifest,
        snapshot: MachineSnapshot
    ) async throws -> FleetReadResult {
        try await authority.replaceBaseline(manifest, snapshot: snapshot)
    }

    func publish(_ snapshot: MachineSnapshot) async throws -> FleetReadResult {
        try await authority.publish(snapshot)
    }

    func publishAndSave(
        _ snapshot: MachineSnapshot,
        manifest: FleetManifest,
        replacingRevision: String
    ) async throws -> FleetReadResult {
        try await authority.publishAndSave(
            snapshot,
            manifest: manifest,
            replacingRevision: replacingRevision
        )
    }

    func save(
        _ manifest: FleetManifest,
        replacingRevision: String
    ) async throws -> FleetReadResult {
        try await authority.save(
            manifest,
            replacingRevision: replacingRevision
        )
    }

    func lastComparison() -> FleetShadowComparison? {
        comparison
    }

    func lastComparisonError() -> String? {
        comparisonError
    }

    private func recordComparison(
        authority: FleetReadResult,
        shadow: FleetReadResult
    ) {
        do {
            comparison = try FleetShadowComparator.compare(
                authority: authority,
                shadow: shadow
            )
            comparisonError = nil
        } catch {
            comparison = nil
            comparisonError = "Shadow payload comparison failed."
        }
    }
}
