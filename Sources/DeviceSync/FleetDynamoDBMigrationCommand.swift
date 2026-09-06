import Foundation

enum FleetDynamoDBMigrationMode: String, Sendable {
    case shadow
    case cutover
}

struct FleetDynamoDBMigrationCommandResult: Sendable {
    let migration: FleetMigrationResult
    let backend: FleetStorageBackend
}

enum FleetDynamoDBMigrationCommand {
    static func run(
        mode: FleetDynamoDBMigrationMode,
        profile: String,
        region: String,
        table: String,
        fleetID: String,
        localRepository: LocalStateRepository = LocalStateRepository(),
        makeDynamoDBClient: DynamoDBFleetClientFactory =
            FleetDynamoDBClientFactories.production
    ) async throws -> FleetDynamoDBMigrationCommandResult {
        let state = try localRepository.loadOrCreate()
        let rootURL = URL(
            fileURLWithPath: state.fleetRootPath,
            isDirectory: true
        )
        let configurationState = LocalDeviceState(
            machineID: state.machineID,
            fleetRootPath: state.fleetRootPath,
            displayName: state.displayName,
            storageBackend: .shadow,
            awsProfile: profile,
            awsRegion: region,
            dynamoDBTable: table,
            fleetID: fleetID,
            cachePath: state.cachePath,
            remoteDevices: state.remoteDevices,
            hiddenComponentIDs: state.hiddenComponentIDs
        )
        let configuration = try configurationState.dynamoDBConfiguration()
        guard let configuration else {
            throw FleetStorageConfigurationError.incompleteDynamoDBConfiguration
        }
        let client = try await makeDynamoDBClient(configuration)
        let source = JSONFleetRepositoryBackend(rootURL: rootURL)
        let target = DynamoDBFleetRepository(
            fleetID: configuration.fleetID,
            client: client
        )
        let migration = try await FleetMigrationService(
            source: source,
            target: target
        ).importAndCompare()
        let backend: FleetStorageBackend = mode == .cutover
            ? .dynamodb
            : .shadow
        let cachePath = localRepository.stateURL
            .deletingLastPathComponent()
            .appendingPathComponent("dynamodb-cache", isDirectory: true)
            .path
        _ = try localRepository.updatingStorage(
            backend: backend,
            profile: configuration.profile,
            region: configuration.region,
            table: configuration.table,
            fleetID: configuration.fleetID,
            cachePath: cachePath
        )
        return FleetDynamoDBMigrationCommandResult(
            migration: migration,
            backend: backend
        )
    }
}
