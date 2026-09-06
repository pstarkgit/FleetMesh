import Foundation
import Testing
@testable import DeviceSync

struct DynamoDBFleetItemTests {
    @Test
    func manifestAndDeviceItemsUseStableKeysAndRedactedPayloads() throws {
        let capturedAt = Date(timeIntervalSince1970: 1_788_000_000)
        let component = ComponentObservation(
            id: "example-app",
            name: "Example App",
            kind: .application,
            status: .installed,
            installedVersion: "1.0.0",
            sourceRevision: "aaaaaaaaaaaa",
            sourceBranch: "feat/private-checkout",
            sourceDirty: true,
            evidence: "Installed"
        )
        let configuration = ComponentObservation(
            id: "example-config",
            name: "Example Config",
            kind: .configuration,
            status: .installed,
            sourceRevision: "bbbbbbbbbbbb",
            sourceBranch: "feat/private-config",
            sourceDirty: true,
            evidence: "Configuration observed"
        )
        let snapshot = MachineSnapshot(
            machineID: "88f61618-c556-438c-a2af-101ca6cedae9",
            name: "DynamoDB fixture",
            hostName: "redacted-host",
            modelIdentifier: "Mac17,6",
            architecture: "arm64",
            osVersion: "26.6",
            osBuild: "25G83",
            platform: .macOS,
            capturedAt: capturedAt,
            components: [component, configuration]
        )
        let manifest = FleetManifest(snapshot: snapshot, updatedAt: capturedAt)

        let manifestItem = try DynamoDBFleetItemCodec.manifest(
            fleetID: "primary",
            manifest: manifest
        )
        #expect(manifestItem.partitionKey == "FLEET#primary")
        #expect(manifestItem.sortKey == "STATE")
        #expect(manifestItem.gsiSortKey == "0#MANIFEST")
        #expect(try DynamoDBFleetItemCodec.decodeManifest(manifestItem) == manifest)

        let deviceItem = try DynamoDBFleetItemCodec.device(
            fleetID: "primary",
            snapshot: snapshot
        )
        #expect(deviceItem.partitionKey == "DEVICE#\(snapshot.machineID)")
        #expect(deviceItem.gsiPartitionKey == "FLEET#primary")
        #expect(deviceItem.gsiSortKey == "1#DEVICE#\(snapshot.machineID)")
        #expect(!deviceItem.payloadJSON.contains("feat/private-checkout"))
        #expect(!deviceItem.payloadJSON.contains("feat/private-config"))
        #expect(!deviceItem.payloadJSON.contains("\"sourceDirty\""))
        #expect(!deviceItem.payloadJSON.contains("aaaaaaaaaaaa"))
        let decoded = try DynamoDBFleetItemCodec.decodeDevice(deviceItem)
        #expect(decoded.machineID == snapshot.machineID)
        #expect(decoded.component("example-app")?.installedVersion == "1.0.0")
        #expect(decoded.component("example-app")?.sourceRevision == nil)
        #expect(decoded.component("example-config")?.sourceRevision == "bbbbbbbbbbbb")
        #expect(decoded.component("example-config")?.sourceBranch == nil)
        #expect(decoded.component("example-config")?.sourceDirty == nil)

        #expect(throws: DynamoDBFleetItemError.self) {
            _ = try DynamoDBFleetItemCodec.manifest(
                fleetID: "bad/fleet",
                manifest: manifest
            )
        }
    }
}
