import Foundation
import Testing
@testable import DeviceSync

struct DriftEngineTests {
    @Test
    func matchingComponentIsAligned() {
        let snapshot = fixtureSnapshot(components: [
            fixtureComponent(version: "1.2.3", revision: "abcdef123456"),
        ])
        let manifest = FleetManifest(snapshot: snapshot)

        let assessment = DriftEngine().assess(snapshot: snapshot, manifest: manifest)

        #expect(assessment.verdict == .aligned)
        #expect(assessment.drifts.first?.state == .aligned)
    }

    @Test
    func missingRequiredComponentIsCritical() {
        let reference = fixtureSnapshot(components: [fixtureComponent(version: "1.2.3")])
        let target = fixtureSnapshot(components: [
            ComponentObservation(
                id: "authbar",
                name: "AuthBar",
                kind: .application,
                status: .missing,
                evidence: "No bundle"
            ),
        ])

        let assessment = DriftEngine().assess(
            snapshot: target,
            manifest: FleetManifest(snapshot: reference)
        )

        #expect(assessment.verdict == .critical)
        #expect(assessment.drifts.first?.state == .missing)
    }

    @Test
    func dirtyCheckoutBlocksConvergenceEvenWhenVersionMatches() {
        let reference = fixtureSnapshot(components: [fixtureComponent(version: "1.2.3")])
        let dirty = ComponentObservation(
            id: "authbar",
            name: "AuthBar",
            kind: .application,
            status: .installed,
            installedVersion: "1.2.3",
            sourceRevision: "123456789abc",
            sourceDirty: true,
            evidence: "Bundle and checkout"
        )

        let assessment = DriftEngine().assess(
            snapshot: fixtureSnapshot(components: [dirty]),
            manifest: FleetManifest(snapshot: reference)
        )

        #expect(assessment.drifts.first?.state == .localChanges)
        #expect(assessment.drifts.first?.severity == .attention)
    }

    @Test
    func installedAndSourceRevisionDivergenceIsVisible() {
        let observation = ComponentObservation(
            id: "authbar",
            name: "AuthBar",
            kind: .application,
            status: .installed,
            installedVersion: "1.2.3",
            installedRevision: "aaaaaaa",
            sourceRevision: "bbbbbbb",
            sourceDirty: false,
            evidence: "Bundle and checkout"
        )
        let snapshot = fixtureSnapshot(components: [observation])

        let assessment = DriftEngine().assess(
            snapshot: snapshot,
            manifest: FleetManifest(snapshot: snapshot)
        )

        #expect(assessment.drifts.first?.state == .different)
        #expect(assessment.drifts.first?.summary.contains("deployment state") == true)
    }

    @Test
    func noManifestIsUnknownNotHealthy() {
        let assessment = DriftEngine().assess(
            snapshot: fixtureSnapshot(components: [fixtureComponent()]),
            manifest: nil
        )

        #expect(assessment.verdict == .unknown)
        #expect(assessment.drifts.allSatisfy { $0.state == .unknown })
    }

    @Test
    func staleSnapshotRemainsAttentionEvenWhenVersionsMatch() {
        let old = fixtureSnapshot(
            capturedAt: Date(timeIntervalSince1970: 10),
            components: [fixtureComponent()]
        )
        let assessment = DriftEngine(staleInterval: 60).assess(
            snapshot: old,
            manifest: FleetManifest(snapshot: old),
            now: Date(timeIntervalSince1970: 1000)
        )

        #expect(assessment.isStale)
        #expect(assessment.verdict == .attention)
    }

    @Test
    func componentOutsideBaselineStaysVisibleWithoutCreatingAttention() {
        let reference = fixtureSnapshot(components: [fixtureComponent()])
        let extra = ComponentObservation(
            id: "device-sync",
            name: "FleetMesh",
            kind: .application,
            status: .installed,
            installedVersion: "0.1.0",
            evidence: "Installed bundle"
        )
        let observed = fixtureSnapshot(components: [fixtureComponent(), extra])

        let assessment = DriftEngine().assess(
            snapshot: observed,
            manifest: FleetManifest(snapshot: reference)
        )

        #expect(assessment.drifts.contains { $0.componentID == "device-sync" && $0.state == .notManaged })
        #expect(assessment.attentionCount == 0)
        #expect(assessment.verdict == .aligned)
    }

    @Test
    func historicalDeviceSyncNamePresentsAsFleetMeshWithoutRewritingBaseline() {
        let legacy = ComponentObservation(
            id: "device-sync",
            name: "Device Sync",
            kind: .application,
            status: .installed,
            installedVersion: "0.1.3",
            evidence: "Legacy writer"
        )
        let reference = fixtureSnapshot(components: [legacy])
        let current = ComponentObservation(
            id: "device-sync",
            name: "FleetMesh",
            kind: .application,
            status: .installed,
            installedVersion: "0.1.4",
            evidence: "Current writer"
        )

        let manifest = FleetManifest(snapshot: reference)
        let assessment = DriftEngine().assess(
            snapshot: fixtureSnapshot(components: [current]),
            manifest: manifest
        )

        #expect(manifest.target("device-sync")?.name == "Device Sync")
        #expect(assessment.drifts.first { $0.componentID == "device-sync" }?.name == "FleetMesh")
    }

    @Test
    func retiredMeshClawEvidenceIsIgnoredAcrossOldReportsAndBaselines() {
        let retired = ComponentObservation(
            id: "meshclaw-themes",
            name: "MeshClaw themes",
            kind: .theme,
            status: .installed,
            configurationFingerprint: "retired",
            items: ["legacy.json"],
            evidence: "Old writer"
        )
        let reference = fixtureSnapshot(components: [fixtureComponent(), retired])
        let observed = fixtureSnapshot(components: [fixtureComponent(), retired])

        let assessment = DriftEngine().assess(
            snapshot: observed,
            manifest: FleetManifest(snapshot: reference)
        )

        #expect(!assessment.drifts.contains { $0.componentID == "meshclaw-themes" })
        #expect(assessment.attentionCount == 0)
        #expect(!FleetManifest(snapshot: reference).targets.contains { $0.id == "meshclaw-themes" })
        #expect(FleetManifest(snapshot: reference).target("meshclaw-themes") == nil)
    }
}

private func fixtureComponent(
    version: String = "1.0.0",
    revision: String? = nil
) -> ComponentObservation {
    ComponentObservation(
        id: "authbar",
        name: "AuthBar",
        kind: .application,
        status: .installed,
        installedVersion: version,
        installedRevision: revision,
        sourceRevision: revision,
        sourceDirty: false,
        evidence: "Test evidence"
    )
}

private func fixtureSnapshot(
    capturedAt: Date = Date(),
    components: [ComponentObservation]
) -> MachineSnapshot {
    MachineSnapshot(
        machineID: "1cda4cfa-b070-4fd4-96b7-176e1cf0beb8",
        name: "Test Mac",
        hostName: "test-mac",
        modelIdentifier: "Mac99,1",
        architecture: "arm64",
        osVersion: "26.6",
        osBuild: "25G00",
        capturedAt: capturedAt,
        components: components
    )
}
