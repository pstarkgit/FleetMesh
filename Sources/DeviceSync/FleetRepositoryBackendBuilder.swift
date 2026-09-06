import Foundation

typealias DynamoDBFleetClientFactory =
    @Sendable (FleetDynamoDBConfiguration) async throws -> any DynamoDBFleetClient

enum FleetRepositoryBackendBuilder {
    static func make(
        state: LocalDeviceState,
        rootURL: URL,
        makeDynamoDBClient: DynamoDBFleetClientFactory
    ) async throws -> any FleetRepositoryProtocol {
        let json = JSONFleetRepositoryBackend(rootURL: rootURL)
        switch state.effectiveStorageBackend {
        case .json:
            return json
        case .shadow:
            let configuration = try requiredConfiguration(state)
            let client = try await makeDynamoDBClient(configuration)
            let dynamoDB = DynamoDBFleetRepository(
                fleetID: configuration.fleetID,
                sourceDescription: "DynamoDB shadow",
                client: client
            )
            return ShadowFleetRepositoryBackend(
                authority: json,
                shadow: dynamoDB
            )
        case .dynamodb:
            let configuration = try requiredConfiguration(state)
            let client = try await makeDynamoDBClient(configuration)
            let dynamoDB = DynamoDBFleetRepository(
                fleetID: configuration.fleetID,
                sourceDescription: "DynamoDB control plane",
                client: client
            )
            let cacheRoot = state.cachePath.map {
                URL(fileURLWithPath: $0, isDirectory: true)
            } ?? defaultCacheRoot()
            return CachedDynamoDBFleetRepositoryBackend(
                authority: dynamoDB,
                cache: JSONFleetRepositoryBackend(rootURL: cacheRoot)
            )
        }
    }

    private static func defaultCacheRoot() -> URL {
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support")
        return support
            .appendingPathComponent(
                FleetMeshIdentity.legacyStateDirectoryName,
                isDirectory: true
            )
            .appendingPathComponent("dynamodb-cache", isDirectory: true)
    }

    private static func requiredConfiguration(
        _ state: LocalDeviceState
    ) throws -> FleetDynamoDBConfiguration {
        guard let configuration = try state.dynamoDBConfiguration() else {
            throw FleetStorageConfigurationError.incompleteDynamoDBConfiguration
        }
        return configuration
    }
}
