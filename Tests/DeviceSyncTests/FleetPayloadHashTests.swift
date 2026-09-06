import Foundation
import Testing
@testable import DeviceSync

struct FleetPayloadHashTests {
    @Test
    func canonicalHashesAreStableAndExcludeDoctorOnlySourceEvidence() throws {
        let capturedAt = Date(timeIntervalSince1970: 1_788_000_000)
        let component = ComponentObservation(
            id: "example-app",
            name: "Example App",
            kind: .application,
            status: .installed,
            installedVersion: "1.2.3",
            sourceVersion: "1.2.3",
            sourceRevision: "aaaaaaaaaaaa",
            sourceBranch: "feat/local-work",
            sourceDirty: true,
            evidence: "Installed"
        )
        let snapshot = MachineSnapshot(
            machineID: "44f61618-c556-438c-a2af-101ca6cedae9",
            name: "Hash fixture",
            hostName: "hash-fixture",
            modelIdentifier: "Mac17,6",
            architecture: "arm64",
            osVersion: "26.6",
            osBuild: "25G83",
            platform: .macOS,
            capturedAt: capturedAt,
            components: [component]
        )
        let manifest = FleetManifest(snapshot: snapshot, updatedAt: capturedAt)
        let decodedManifest = try FleetJSON.decoder.decode(
            FleetManifest.self,
            from: FleetJSON.encoder.encode(manifest)
        )
        let withoutSource = snapshot.replacingComponent(
            component.removingSoftwareCheckoutEvidence()
        )

        let manifestHash = try FleetPayloadHash.manifest(manifest)
        let decodedManifestHash = try FleetPayloadHash.manifest(decodedManifest)
        let snapshotHash = try FleetPayloadHash.machine(snapshot)
        let withoutSourceHash = try FleetPayloadHash.machine(withoutSource)
        #expect(manifestHash.count == 64)
        #expect(manifestHash == decodedManifestHash)
        #expect(snapshotHash == withoutSourceHash)
    }
}
