import Foundation

/// Storage-agnostic authority for FleetMesh's shared desired state and redacted
/// device evidence. Implementations must preserve optimistic manifest writes,
/// monotonic device reports, schema validation, and partial-read issue
/// reporting.
protocol FleetRepositoryProtocol: Sendable {
    /// Human-readable authority description for status and diagnostics. It must
    /// never include credentials or private SSH endpoints.
    var sourceDescription: String { get }

    func load() async -> FleetReadResult
    func loadManifest() async -> FleetManifestReadResult

    /// Replaces the fleet baseline only through an explicit baseline action.
    func replaceBaseline(
        _ manifest: FleetManifest,
        snapshot: MachineSnapshot
    ) async throws -> FleetReadResult

    /// Publishes one device's redacted observation without changing policy.
    func publish(_ snapshot: MachineSnapshot) async throws -> FleetReadResult

    /// Publishes evidence and conditionally commits a policy revision.
    func publishAndSave(
        _ snapshot: MachineSnapshot,
        manifest: FleetManifest,
        replacingRevision: String
    ) async throws -> FleetReadResult

    /// Conditionally commits a policy revision without publishing evidence.
    func save(
        _ manifest: FleetManifest,
        replacingRevision: String
    ) async throws -> FleetReadResult
}
