import Testing
@testable import DeviceSync

struct DynamoDBFleetClientTests {
    @Test
    func conditionalWritesRejectStaleManifestAndDeviceState() async throws {
        let client = InMemoryDynamoDBFleetClient()
        let manifest = clientItem(pk: "FLEET#primary", revision: "r1", timestamp: 10)
        try await client.put(manifest, condition: .manifestRevision(nil))
        let next = clientItem(pk: "FLEET#primary", revision: "r2", timestamp: 20)
        try await client.put(next, condition: .manifestRevision("r1"))
        await #expect(throws: DynamoDBFleetClientError.self) {
            try await client.put(manifest, condition: .manifestRevision("r1"))
        }

        let device = clientItem(pk: "DEVICE#id", revision: nil, timestamp: 20)
        try await client.put(device, condition: .newerTimestamp(20))
        await #expect(throws: DynamoDBFleetClientError.self) {
            try await client.put(device, condition: .newerTimestamp(20))
        }
        #expect(try await client.queryFleet(gsiPartitionKey: "FLEET#primary").count == 2)
    }
}

private func clientItem(
    pk: String,
    revision: String?,
    timestamp: Int64
) -> DynamoDBFleetItem {
    DynamoDBFleetItem(
        partitionKey: pk,
        sortKey: "STATE",
        gsiPartitionKey: "FLEET#primary",
        gsiSortKey: pk.hasPrefix("FLEET#") ? "0#MANIFEST" : "1#DEVICE#id",
        entityType: pk.hasPrefix("FLEET#") ? .manifest : .device,
        schemaVersion: 1,
        revision: revision,
        timestampEpochMs: timestamp,
        payloadJSON: "{}"
    )
}
