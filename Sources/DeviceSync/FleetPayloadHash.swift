import CryptoKit
import Foundation

/// Stable hashes used to prove that JSON and DynamoDB represent the same fleet
/// authority during shadow reads and dual writes.
enum FleetPayloadHash {
    static func manifest(_ manifest: FleetManifest) throws -> String {
        try hash(manifest)
    }

    static func machine(_ snapshot: MachineSnapshot) throws -> String {
        try hash(snapshot.removingSoftwareCheckoutEvidence())
    }

    private static func hash<T: Encodable>(_ value: T) throws -> String {
        let payload = try FleetJSON.encoder.encode(value)
        return SHA256.hash(data: payload)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
