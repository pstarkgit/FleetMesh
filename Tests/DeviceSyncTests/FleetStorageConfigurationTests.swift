import Testing
@testable import DeviceSync

struct FleetStorageConfigurationTests {
    @Test
    func legacyStateDefaultsToJSONAndCloudModesRequireValidFields() throws {
        var state = LocalDeviceState(
            machineID: "aaf61618-c556-438c-a2af-101ca6cedae9",
            fleetRootPath: "/tmp/fleet"
        )
        #expect(state.effectiveStorageBackend == .json)
        #expect(try state.dynamoDBConfiguration() == nil)

        state.storageBackend = .shadow
        #expect(throws: FleetStorageConfigurationError.self) {
            _ = try state.dynamoDBConfiguration()
        }

        state.awsProfile = "fleetmesh-auto"
        state.awsRegion = "us-west-2"
        state.dynamoDBTable = "fleetmesh-control-plane"
        state.fleetID = "primary"
        #expect(try state.dynamoDBConfiguration() == FleetDynamoDBConfiguration(
            profile: "fleetmesh-auto",
            region: "us-west-2",
            table: "fleetmesh-control-plane",
            fleetID: "primary"
        ))

        state.dynamoDBTable = "bad/table"
        #expect(throws: FleetStorageConfigurationError.self) {
            _ = try state.dynamoDBConfiguration()
        }
    }
}
