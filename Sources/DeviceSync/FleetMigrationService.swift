import Foundation

struct FleetMigrationResult: Sendable {
    let manifestRevision: String
    let importedDeviceCount: Int
    let comparison: FleetShadowComparison
}

struct FleetMigrationService: Sendable {
    let source: any FleetRepositoryProtocol
    let target: any FleetRepositoryProtocol

    func importAndCompare() async throws -> FleetMigrationResult {
        let sourceRead = await source.load()
        guard sourceRead.issues.isEmpty else {
            throw FleetMigrationError.sourceHasIssues
        }
        guard let sourceManifest = sourceRead.manifest else {
            throw FleetMigrationError.missingSourceManifest
        }
        guard let firstMachine = sourceRead.machines.first else {
            throw FleetMigrationError.noSourceDevices
        }

        let targetBefore = await target.load()
        guard targetBefore.issues.isEmpty else {
            throw FleetMigrationError.targetHasIssues
        }
        if let targetManifest = targetBefore.manifest {
            guard try FleetPayloadHash.manifest(targetManifest)
                == FleetPayloadHash.manifest(sourceManifest) else {
                throw FleetMigrationError.targetManifestConflict
            }
        } else {
            _ = try await target.replaceBaseline(
                sourceManifest,
                snapshot: firstMachine
            )
        }

        for machine in sourceRead.machines {
            _ = try await target.publish(machine)
        }
        let targetAfter = await target.load()
        guard targetAfter.issues.isEmpty else {
            throw FleetMigrationError.targetHasIssues
        }
        let comparison = try FleetShadowComparator.compare(
            authority: sourceRead,
            shadow: targetAfter
        )
        guard comparison.isMatch else {
            throw FleetMigrationError.shadowMismatch(comparison)
        }
        return FleetMigrationResult(
            manifestRevision: sourceManifest.revision,
            importedDeviceCount: sourceRead.machines.count,
            comparison: comparison
        )
    }
}

enum FleetMigrationError: LocalizedError {
    case sourceHasIssues
    case missingSourceManifest
    case noSourceDevices
    case targetHasIssues
    case targetManifestConflict
    case shadowMismatch(FleetShadowComparison)

    var errorDescription: String? {
        switch self {
        case .sourceHasIssues:
            "OneDrive fleet state has read issues; migration stopped before writing."
        case .missingSourceManifest:
            "OneDrive fleet state has no manifest to migrate."
        case .noSourceDevices:
            "OneDrive fleet state has no device evidence to seed DynamoDB."
        case .targetHasIssues:
            "DynamoDB fleet state has read issues; migration stopped."
        case .targetManifestConflict:
            "DynamoDB already contains a different fleet manifest."
        case .shadowMismatch:
            "DynamoDB import does not match the OneDrive authority."
        }
    }
}
