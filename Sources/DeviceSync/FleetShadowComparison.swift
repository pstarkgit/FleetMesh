import Foundation

struct FleetShadowComparison: Equatable, Sendable {
    let manifestMatches: Bool
    let missingDeviceIDs: [String]
    let extraDeviceIDs: [String]
    let mismatchedDeviceIDs: [String]

    var isMatch: Bool {
        manifestMatches
            && missingDeviceIDs.isEmpty
            && extraDeviceIDs.isEmpty
            && mismatchedDeviceIDs.isEmpty
    }
}

enum FleetShadowComparator {
    static func compare(
        authority: FleetReadResult,
        shadow: FleetReadResult
    ) throws -> FleetShadowComparison {
        let authorityManifestHash = try authority.manifest.map(
            FleetPayloadHash.manifest
        )
        let shadowManifestHash = try shadow.manifest.map(
            FleetPayloadHash.manifest
        )
        let authorityMachines = Dictionary(
            authority.machines.map { ($0.machineID, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let shadowMachines = Dictionary(
            shadow.machines.map { ($0.machineID, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let authorityIDs = Set(authorityMachines.keys)
        let shadowIDs = Set(shadowMachines.keys)
        let mismatched = try authorityIDs.intersection(shadowIDs).filter { machineID in
            guard let authorityMachine = authorityMachines[machineID],
                  let shadowMachine = shadowMachines[machineID] else {
                return true
            }
            return try FleetPayloadHash.machine(authorityMachine)
                != FleetPayloadHash.machine(shadowMachine)
        }

        return FleetShadowComparison(
            manifestMatches: authorityManifestHash == shadowManifestHash,
            missingDeviceIDs: authorityIDs.subtracting(shadowIDs).sorted(),
            extraDeviceIDs: shadowIDs.subtracting(authorityIDs).sorted(),
            mismatchedDeviceIDs: mismatched.sorted()
        )
    }
}
