import Foundation

struct FleetDynamoDBConfiguration: Equatable, Sendable {
    let profile: String
    let region: String
    let table: String
    let fleetID: String
}

extension LocalDeviceState {
    var effectiveStorageBackend: FleetStorageBackend {
        storageBackend ?? .json
    }

    func dynamoDBConfiguration() throws -> FleetDynamoDBConfiguration? {
        guard effectiveStorageBackend != .json else { return nil }
        guard let profile = validated(awsProfile, allowed: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-"),
              let region = validated(awsRegion, allowed: "abcdefghijklmnopqrstuvwxyz0123456789-"),
              let table = validated(dynamoDBTable, allowed: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-"),
              let fleetID = validated(fleetID, allowed: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-") else {
            throw FleetStorageConfigurationError.incompleteDynamoDBConfiguration
        }
        return FleetDynamoDBConfiguration(
            profile: profile,
            region: region,
            table: table,
            fleetID: fleetID
        )
    }

    private func validated(_ value: String?, allowed: String) -> String? {
        guard let value, !value.isEmpty, value.count <= 255 else { return nil }
        let set = CharacterSet(charactersIn: allowed)
        return value.unicodeScalars.allSatisfy(set.contains) ? value : nil
    }
}

enum FleetStorageConfigurationError: LocalizedError {
    case incompleteDynamoDBConfiguration

    var errorDescription: String? {
        "DynamoDB storage requires a valid local profile, Region, table, and fleet ID."
    }
}
