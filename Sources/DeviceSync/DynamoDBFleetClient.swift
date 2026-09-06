import Foundation

enum DynamoDBFleetWriteCondition: Sendable {
    case none
    case manifestRevision(String?)
    case newerTimestamp(Int64)
}

protocol DynamoDBFleetClient: Sendable {
    func get(partitionKey: String, sortKey: String) async throws -> DynamoDBFleetItem?
    func queryFleet(gsiPartitionKey: String) async throws -> [DynamoDBFleetItem]
    func put(
        _ item: DynamoDBFleetItem,
        condition: DynamoDBFleetWriteCondition
    ) async throws
}

actor InMemoryDynamoDBFleetClient: DynamoDBFleetClient {
    private var items: [String: DynamoDBFleetItem] = [:]

    func get(
        partitionKey: String,
        sortKey: String
    ) async throws -> DynamoDBFleetItem? {
        items[key(partitionKey, sortKey)]
    }

    func queryFleet(
        gsiPartitionKey: String
    ) async throws -> [DynamoDBFleetItem] {
        items.values
            .filter { $0.gsiPartitionKey == gsiPartitionKey }
            .sorted { $0.gsiSortKey < $1.gsiSortKey }
    }

    func put(
        _ item: DynamoDBFleetItem,
        condition: DynamoDBFleetWriteCondition
    ) async throws {
        let itemKey = key(item.partitionKey, item.sortKey)
        let current = items[itemKey]
        switch condition {
        case .none:
            break
        case .manifestRevision(let expected):
            guard current?.revision == expected else {
                throw DynamoDBFleetClientError.conditionalCheckFailed
            }
        case .newerTimestamp(let timestamp):
            guard current == nil || current!.timestampEpochMs < timestamp else {
                throw DynamoDBFleetClientError.conditionalCheckFailed
            }
        }
        items[itemKey] = item
    }

    private func key(_ partitionKey: String, _ sortKey: String) -> String {
        "\(partitionKey)\u{1f}\(sortKey)"
    }
}

enum DynamoDBFleetClientError: LocalizedError {
    case conditionalCheckFailed

    var errorDescription: String? {
        switch self {
        case .conditionalCheckFailed:
            "DynamoDB conditional write rejected stale fleet state."
        }
    }
}
