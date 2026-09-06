import Foundation
import Testing
@testable import DeviceSync

struct DynamoDBFleetRepositoryTests {
    @Test
    func repositoryEnforcesManifestAndReportOrdering() async throws {
        let client = InMemoryDynamoDBFleetClient()
        let repository = DynamoDBFleetRepository(
            fleetID: "primary",
            client: client
        )
        let first = dynamoRepositorySnapshot(version: "1.0.0", offset: 0)
        let newer = dynamoRepositorySnapshot(version: "2.0.0", offset: 60)
        let firstManifest = FleetManifest(snapshot: first)

        let created = try await repository.replaceBaseline(
            firstManifest,
            snapshot: first
        )
        #expect(created.manifest?.revision == firstManifest.revision)
        #expect(created.machines.first?.component("example-app")?.installedVersion == "1.0.0")

        let nextManifest = FleetManifest(snapshot: newer)
        _ = try await repository.save(
            nextManifest,
            replacingRevision: firstManifest.revision
        )
        await #expect(throws: FleetRepositoryError.self) {
            _ = try await repository.save(
                firstManifest,
                replacingRevision: firstManifest.revision
            )
        }

        _ = try await repository.publish(newer)
        _ = try await repository.publish(newer)
        await #expect(throws: DynamoDBFleetClientError.self) {
            _ = try await repository.publish(first)
        }
        let final = await repository.load()
        #expect(final.manifest?.revision == nextManifest.revision)
        #expect(final.machines.first?.component("example-app")?.installedVersion == "2.0.0")
    }

    @Test
    func malformedItemBecomesIssueWithoutHidingValidState() async throws {
        let client = InMemoryDynamoDBFleetClient()
        let repository = DynamoDBFleetRepository(fleetID: "primary", client: client)
        let snapshot = dynamoRepositorySnapshot(version: "1.0.0", offset: 0)
        let manifest = FleetManifest(snapshot: snapshot)
        _ = try await repository.replaceBaseline(manifest, snapshot: snapshot)
        let malformed = DynamoDBFleetItem(
            partitionKey: "DEVICE#aa000000-0000-4000-8000-000000000000",
            sortKey: "STATE",
            gsiPartitionKey: "FLEET#primary",
            gsiSortKey: "1#DEVICE#aa000000-0000-4000-8000-000000000000",
            entityType: .device,
            schemaVersion: 1,
            revision: nil,
            timestampEpochMs: 1,
            payloadJSON: "{}"
        )
        try await client.put(malformed, condition: .none)

        let read = await repository.load()
        #expect(read.manifest?.revision == manifest.revision)
        #expect(read.machines.map(\.machineID) == [snapshot.machineID])
        #expect(read.issues.count == 1)
        #expect(read.issues.first?.title == "One DynamoDB fleet item is unreadable")
    }
}

private func dynamoRepositorySnapshot(
    version: String,
    offset: TimeInterval
) -> MachineSnapshot {
    MachineSnapshot(
        machineID: "99f61618-c556-438c-a2af-101ca6cedae9",
        name: "DynamoDB repository fixture",
        hostName: "redacted-host",
        modelIdentifier: "Mac17,6",
        architecture: "arm64",
        osVersion: "26.6",
        osBuild: "25G83",
        platform: .macOS,
        capturedAt: Date(timeIntervalSince1970: 1_788_000_000 + offset),
        components: [
            ComponentObservation(
                id: "example-app",
                name: "Example App",
                kind: .application,
                status: .installed,
                installedVersion: version,
                evidence: "Installed"
            ),
        ]
    )
}
