import Foundation

actor DynamoDBFleetRepository: FleetRepositoryProtocol {
    nonisolated let sourceDescription: String

    private let fleetID: String
    private let client: any DynamoDBFleetClient

    init(
        fleetID: String,
        sourceDescription: String = "DynamoDB control plane",
        client: any DynamoDBFleetClient
    ) {
        self.fleetID = fleetID
        self.sourceDescription = sourceDescription
        self.client = client
    }

    func load() async -> FleetReadResult {
        do {
            let items = try await client.queryFleet(
                gsiPartitionKey: "FLEET#\(fleetID)"
            )
            var manifest: FleetManifest?
            var machines: [MachineSnapshot] = []
            var issues: [FleetIssue] = []
            for item in items {
                do {
                    switch item.entityType {
                    case .manifest:
                        let decoded = try DynamoDBFleetItemCodec.decodeManifest(item)
                        guard decoded.schemaVersion <= FleetManifest.currentSchemaVersion else {
                            throw FleetRepositoryError.futureSchema(decoded.schemaVersion)
                        }
                        manifest = decoded
                    case .device:
                        let decoded = try DynamoDBFleetItemCodec.decodeDevice(item)
                        guard decoded.schemaVersion <= MachineSnapshot.currentSchemaVersion else {
                            throw FleetRepositoryError.futureSchema(decoded.schemaVersion)
                        }
                        machines.append(decoded)
                    }
                } catch {
                    issues.append(FleetIssue(
                        id: "dynamodb-\(item.partitionKey)-\(item.sortKey)",
                        title: "One DynamoDB fleet item is unreadable",
                        detail: error.localizedDescription
                    ))
                }
            }
            return FleetReadResult(
                manifest: manifest,
                machines: machines.sorted {
                    $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                },
                issues: issues
            )
        } catch {
            return FleetReadResult(
                manifest: nil,
                machines: [],
                issues: [FleetIssue(
                    id: "dynamodb-read-failed",
                    title: "DynamoDB fleet authority could not be read",
                    detail: error.localizedDescription
                )]
            )
        }
    }

    func loadManifest() async -> FleetManifestReadResult {
        do {
            guard let item = try await client.get(
                partitionKey: "FLEET#\(fleetID)",
                sortKey: "STATE"
            ) else {
                return FleetManifestReadResult(manifest: nil, issue: nil)
            }
            let manifest = try DynamoDBFleetItemCodec.decodeManifest(item)
            guard manifest.schemaVersion <= FleetManifest.currentSchemaVersion else {
                throw FleetRepositoryError.futureSchema(manifest.schemaVersion)
            }
            return FleetManifestReadResult(manifest: manifest, issue: nil)
        } catch {
            return FleetManifestReadResult(
                manifest: nil,
                issue: FleetIssue(
                    id: "dynamodb-manifest-read-failed",
                    title: "DynamoDB fleet baseline could not be read",
                    detail: error.localizedDescription
                )
            )
        }
    }

    func replaceBaseline(
        _ manifest: FleetManifest,
        snapshot: MachineSnapshot
    ) async throws -> FleetReadResult {
        try await putDevice(snapshot)
        let item = try DynamoDBFleetItemCodec.manifest(
            fleetID: fleetID,
            manifest: manifest
        )
        try await client.put(item, condition: .none)
        return await load()
    }

    func publish(_ snapshot: MachineSnapshot) async throws -> FleetReadResult {
        try await putDevice(snapshot)
        return await load()
    }

    func publishAndSave(
        _ snapshot: MachineSnapshot,
        manifest: FleetManifest,
        replacingRevision: String
    ) async throws -> FleetReadResult {
        try await putDevice(snapshot)
        return try await save(
            manifest,
            replacingRevision: replacingRevision
        )
    }

    func save(
        _ manifest: FleetManifest,
        replacingRevision: String
    ) async throws -> FleetReadResult {
        let item = try DynamoDBFleetItemCodec.manifest(
            fleetID: fleetID,
            manifest: manifest
        )
        do {
            try await client.put(
                item,
                condition: .manifestRevision(replacingRevision)
            )
        } catch DynamoDBFleetClientError.conditionalCheckFailed {
            throw FleetRepositoryError.manifestChanged
        }
        return await load()
    }

    private func putDevice(_ snapshot: MachineSnapshot) async throws {
        let item = try DynamoDBFleetItemCodec.device(
            fleetID: fleetID,
            snapshot: snapshot
        )
        do {
            try await client.put(
                item,
                condition: .newerTimestamp(item.timestampEpochMs)
            )
        } catch DynamoDBFleetClientError.conditionalCheckFailed {
            let existing = try await client.get(
                partitionKey: item.partitionKey,
                sortKey: item.sortKey
            )
            guard existing == item else { throw DynamoDBFleetClientError.conditionalCheckFailed }
        }
    }
}
