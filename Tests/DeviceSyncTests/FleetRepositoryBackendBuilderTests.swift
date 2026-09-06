import Foundation
import Testing
@testable import DeviceSync

struct FleetRepositoryBackendBuilderTests {
    @Test
    func builderSelectsValidatedStorageMode() async throws {
        var state = LocalDeviceState(
            machineID: "bbf61618-c556-438c-a2af-101ca6cedae9",
            fleetRootPath: "/tmp/fleet"
        )
        let client = InMemoryDynamoDBFleetClient()
        let factory: DynamoDBFleetClientFactory = { _ in client }

        let json = try await FleetRepositoryBackendBuilder.make(
            state: state,
            rootURL: URL(fileURLWithPath: state.fleetRootPath),
            makeDynamoDBClient: factory
        )
        #expect(json.sourceDescription == "Shared JSON folder")

        state.storageBackend = .shadow
        await #expect(throws: FleetStorageConfigurationError.self) {
            _ = try await FleetRepositoryBackendBuilder.make(
                state: state,
                rootURL: URL(fileURLWithPath: state.fleetRootPath),
                makeDynamoDBClient: factory
            )
        }

        state.awsProfile = "fleetmesh-auto"
        state.awsRegion = "us-west-2"
        state.dynamoDBTable = "fleetmesh-control-plane"
        state.fleetID = "primary"
        let shadow = try await FleetRepositoryBackendBuilder.make(
            state: state,
            rootURL: URL(fileURLWithPath: state.fleetRootPath),
            makeDynamoDBClient: factory
        )
        #expect(shadow.sourceDescription.contains("shadow validation"))

        state.storageBackend = .dynamodb
        let dynamoDB = try await FleetRepositoryBackendBuilder.make(
            state: state,
            rootURL: URL(fileURLWithPath: state.fleetRootPath),
            makeDynamoDBClient: factory
        )
        #expect(dynamoDB.sourceDescription == "DynamoDB control plane with JSON cache")
    }
}
