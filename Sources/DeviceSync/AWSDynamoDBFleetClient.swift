import AWSDynamoDB
import AWSSDKIdentity
import Foundation

actor AWSDynamoDBFleetClient: DynamoDBFleetClient {
    private let tableName: String
    private let client: DynamoDBClient

    init(tableName: String, region: String, profile: String) throws {
        self.tableName = tableName
        let resolver = ProfileAWSCredentialIdentityResolver(
            profileName: profile
        )
        let configuration = try DynamoDBClient.DynamoDBClientConfig(
            awsCredentialIdentityResolver: resolver,
            region: region
        )
        client = DynamoDBClient(config: configuration)
    }

    func get(partitionKey: String, sortKey: String) async throws -> DynamoDBFleetItem? {
        let output = try await client.getItem(input: GetItemInput(
            consistentRead: true,
            key: ["PK": .s(partitionKey), "SK": .s(sortKey)],
            tableName: tableName
        ))
        return try output.item.map(decode)
    }

    func queryFleet(gsiPartitionKey: String) async throws -> [DynamoDBFleetItem] {
        var result: [DynamoDBFleetItem] = []
        var cursor: [String: DynamoDBClientTypes.AttributeValue]?
        repeat {
            let output = try await client.query(input: QueryInput(
                exclusiveStartKey: cursor,
                expressionAttributeNames: ["#fleet": "GSI1PK"],
                expressionAttributeValues: [":fleet": .s(gsiPartitionKey)],
                indexName: "GSI1",
                keyConditionExpression: "#fleet = :fleet",
                tableName: tableName
            ))
            result.append(contentsOf: try (output.items ?? []).map(decode))
            cursor = output.lastEvaluatedKey
        } while cursor?.isEmpty == false
        return result
    }

    func put(_ item: DynamoDBFleetItem, condition: DynamoDBFleetWriteCondition) async throws {
        let expression: (String?, [String: String]?, [String: DynamoDBClientTypes.AttributeValue]?)
        switch condition {
        case .none:
            expression = (nil, nil, nil)
        case .manifestRevision(let expected):
            expression = expected.map {
                ("#revision = :revision", ["#revision": "revision"], [":revision": .s($0)])
            } ?? ("attribute_not_exists(#revision)", ["#revision": "revision"], nil)
        case .newerTimestamp(let timestamp):
            expression = (
                "attribute_not_exists(#timestamp) OR #timestamp < :timestamp",
                ["#timestamp": "timestampEpochMs"],
                [":timestamp": .n(String(timestamp))]
            )
        }
        do {
            _ = try await client.putItem(input: PutItemInput(
                conditionExpression: expression.0,
                expressionAttributeNames: expression.1,
                expressionAttributeValues: expression.2,
                item: encode(item),
                tableName: tableName
            ))
        } catch {
            if String(describing: error).contains("ConditionalCheckFailed") {
                throw DynamoDBFleetClientError.conditionalCheckFailed
            }
            throw error
        }
    }

    private func encode(_ item: DynamoDBFleetItem) -> [String: DynamoDBClientTypes.AttributeValue] {
        var value: [String: DynamoDBClientTypes.AttributeValue] = [
            "PK": .s(item.partitionKey), "SK": .s(item.sortKey),
            "GSI1PK": .s(item.gsiPartitionKey), "GSI1SK": .s(item.gsiSortKey),
            "entityType": .s(item.entityType.rawValue),
            "schemaVersion": .n(String(item.schemaVersion)),
            "timestampEpochMs": .n(String(item.timestampEpochMs)),
            "payloadJSON": .s(item.payloadJSON),
        ]
        if let revision = item.revision { value["revision"] = .s(revision) }
        return value
    }

    private func decode(_ value: [String: DynamoDBClientTypes.AttributeValue]) throws -> DynamoDBFleetItem {
        func string(_ key: String) throws -> String {
            guard case .s(let value)? = value[key] else { throw DynamoDBFleetItemError.invalidPayloadEncoding }
            return value
        }
        func number(_ key: String) throws -> Int64 {
            guard case .n(let value)? = value[key], let number = Int64(value) else { throw DynamoDBFleetItemError.invalidPayloadEncoding }
            return number
        }
        guard let type = DynamoDBFleetEntityType(rawValue: try string("entityType")) else {
            throw DynamoDBFleetItemError.wrongEntityType
        }
        let revision: String?
        if case .s(let value)? = value["revision"] { revision = value } else { revision = nil }
        return DynamoDBFleetItem(
            partitionKey: try string("PK"), sortKey: try string("SK"),
            gsiPartitionKey: try string("GSI1PK"), gsiSortKey: try string("GSI1SK"),
            entityType: type, schemaVersion: Int(try number("schemaVersion")),
            revision: revision, timestampEpochMs: try number("timestampEpochMs"),
            payloadJSON: try string("payloadJSON")
        )
    }
}
