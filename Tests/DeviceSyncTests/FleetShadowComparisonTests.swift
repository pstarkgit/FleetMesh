import Foundation
import Testing
@testable import DeviceSync

struct FleetShadowComparisonTests {
    @Test
    func comparisonReportsExactAndDivergentFleetPayloads() throws {
        let first = shadowSnapshot(
            machineID: "44f61618-c556-438c-a2af-101ca6cedae9",
            name: "First",
            version: "1.0.0"
        )
        let second = shadowSnapshot(
            machineID: "55f61618-c556-438c-a2af-101ca6cedae9",
            name: "Second",
            version: "1.0.0"
        )
        let extra = shadowSnapshot(
            machineID: "66f61618-c556-438c-a2af-101ca6cedae9",
            name: "Extra",
            version: "1.0.0"
        )
        let changedFirst = shadowSnapshot(
            machineID: first.machineID,
            name: first.name,
            version: "2.0.0"
        )
        let manifest = FleetManifest(
            snapshot: first,
            updatedAt: Date(timeIntervalSince1970: 1_788_000_000)
        )
        let authority = FleetReadResult(
            manifest: manifest,
            machines: [first, second],
            issues: []
        )

        let exact = try FleetShadowComparator.compare(
            authority: authority,
            shadow: authority
        )
        #expect(exact.isMatch)

        let divergent = try FleetShadowComparator.compare(
            authority: authority,
            shadow: FleetReadResult(
                manifest: manifest,
                machines: [changedFirst, extra],
                issues: []
            )
        )
        #expect(!divergent.isMatch)
        #expect(divergent.manifestMatches)
        #expect(divergent.missingDeviceIDs == [second.machineID])
        #expect(divergent.extraDeviceIDs == [extra.machineID])
        #expect(divergent.mismatchedDeviceIDs == [first.machineID])
    }
}

private func shadowSnapshot(
    machineID: String,
    name: String,
    version: String
) -> MachineSnapshot {
    MachineSnapshot(
        machineID: machineID,
        name: name,
        hostName: "redacted-host",
        modelIdentifier: "Mac17,6",
        architecture: "arm64",
        osVersion: "26.6",
        osBuild: "25G83",
        platform: .macOS,
        capturedAt: Date(timeIntervalSince1970: 1_788_000_000),
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
