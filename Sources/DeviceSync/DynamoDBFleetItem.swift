import Foundation

enum DynamoDBFleetEntityType: String, Codable, Sendable {
    case manifest
    case device
}

struct DynamoDBFleetItem: Equatable, Sendable {
    let partitionKey: String
    let sortKey: String
    let gsiPartitionKey: String
    let gsiSortKey: String
    let entityType: DynamoDBFleetEntityType
    let schemaVersion: Int
    let revision: String?
    let timestampEpochMs: Int64
    let payloadJSON: String
}

enum DynamoDBFleetItemCodec {
    static func manifest(
        fleetID: String,
        manifest: FleetManifest
    ) throws -> DynamoDBFleetItem {
        try validateFleetID(fleetID)
        return DynamoDBFleetItem(
            partitionKey: "FLEET#\(fleetID)",
            sortKey: "STATE",
            gsiPartitionKey: "FLEET#\(fleetID)",
            gsiSortKey: "0#MANIFEST",
            entityType: .manifest,
            schemaVersion: manifest.schemaVersion,
            revision: manifest.revision,
            timestampEpochMs: epochMilliseconds(manifest.updatedAt),
            payloadJSON: try payload(manifest)
        )
    }

    static func device(
        fleetID: String,
        snapshot: MachineSnapshot
    ) throws -> DynamoDBFleetItem {
        try validateFleetID(fleetID)
        guard UUID(uuidString: snapshot.machineID) != nil else {
            throw DynamoDBFleetItemError.invalidMachineID
        }
        let redacted = snapshot.removingSoftwareCheckoutEvidence()
        return DynamoDBFleetItem(
            partitionKey: "DEVICE#\(snapshot.machineID.lowercased())",
            sortKey: "STATE",
            gsiPartitionKey: "FLEET#\(fleetID)",
            gsiSortKey: "1#DEVICE#\(snapshot.machineID.lowercased())",
            entityType: .device,
            schemaVersion: snapshot.schemaVersion,
            revision: nil,
            timestampEpochMs: epochMilliseconds(snapshot.capturedAt),
            payloadJSON: try payload(redacted)
        )
    }

    static func decodeManifest(_ item: DynamoDBFleetItem) throws -> FleetManifest {
        guard item.entityType == .manifest,
              item.partitionKey.hasPrefix("FLEET#"),
              item.sortKey == "STATE" else {
            throw DynamoDBFleetItemError.wrongEntityType
        }
        return try decode(FleetManifest.self, payloadJSON: item.payloadJSON)
    }

    static func decodeDevice(_ item: DynamoDBFleetItem) throws -> MachineSnapshot {
        guard item.entityType == .device,
              item.partitionKey.hasPrefix("DEVICE#"),
              item.sortKey == "STATE" else {
            throw DynamoDBFleetItemError.wrongEntityType
        }
        let snapshot = try decode(
            MachineSnapshot.self,
            payloadJSON: item.payloadJSON
        )
        guard item.partitionKey == "DEVICE#\(snapshot.machineID.lowercased())" else {
            throw DynamoDBFleetItemError.machineIDMismatch
        }
        return snapshot
    }

    private static func validateFleetID(_ fleetID: String) throws {
        let allowed = CharacterSet(
            charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-"
        )
        guard !fleetID.isEmpty,
              fleetID.count <= 128,
              fleetID.unicodeScalars.allSatisfy(allowed.contains) else {
            throw DynamoDBFleetItemError.invalidFleetID
        }
    }

    private static func payload<T: Encodable>(_ value: T) throws -> String {
        let data = try FleetJSON.encoder.encode(value)
        guard let string = String(data: data, encoding: .utf8) else {
            throw DynamoDBFleetItemError.invalidPayloadEncoding
        }
        return string
    }

    private static func decode<T: Decodable>(
        _ type: T.Type,
        payloadJSON: String
    ) throws -> T {
        guard let data = payloadJSON.data(using: .utf8) else {
            throw DynamoDBFleetItemError.invalidPayloadEncoding
        }
        return try FleetJSON.decoder.decode(type, from: data)
    }

    private static func epochMilliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1_000).rounded())
    }
}

enum DynamoDBFleetItemError: LocalizedError {
    case invalidFleetID
    case invalidMachineID
    case wrongEntityType
    case machineIDMismatch
    case invalidPayloadEncoding

    var errorDescription: String? {
        switch self {
        case .invalidFleetID:
            "Fleet ID contains unsupported characters or length."
        case .invalidMachineID:
            "Device evidence has an invalid privacy-preserving machine ID."
        case .wrongEntityType:
            "DynamoDB item type or key does not match the requested fleet entity."
        case .machineIDMismatch:
            "DynamoDB device key does not match its redacted payload."
        case .invalidPayloadEncoding:
            "Fleet payload could not be represented as UTF-8 JSON."
        }
    }
}
