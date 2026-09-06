import Foundation

enum FleetDynamoDBClientFactories {
    static let production: DynamoDBFleetClientFactory = { configuration in
        try AWSDynamoDBFleetClient(
            tableName: configuration.table,
            region: configuration.region,
            profile: configuration.profile
        )
    }
}
