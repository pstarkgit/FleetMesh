import Foundation
import Testing
@testable import DeviceSync

struct RepositoryTargetResolverTests {
    @Test
    func cleanRepoVersionAdvancesStaleSavedTargetWithoutMutatingManifestJSON() throws {
        let authority = targetSnapshot(
            machineID: "b41f9f4f-0fce-4792-a3c6-c93a73fcb4cd",
            installedVersion: "0.10.5",
            sourceVersion: "0.10.5",
            revision: "881c9caa2712"
        )
        let manifest = FleetManifest(snapshot: authority)
        let current = targetSnapshot(
            machineID: authority.machineID,
            installedVersion: "0.11.3",
            sourceVersion: "0.11.3",
            revision: "82f9208bcb8a",
            capturedAt: Date(timeIntervalSince1970: 2_000)
        )

        let targets = RepositoryTargetResolver().resolve(
            manifest: manifest,
            localSnapshot: current,
            now: Date(timeIntervalSince1970: 2_010)
        )
        #expect(manifest.target("authbar")?.expectedVersion == "0.10.5")
        #expect(targets["authbar"]?.version == "0.11.3")
        #expect(targets["authbar"]?.sourceRevision == "82f9208bcb8a")
        let encoded = try #require(String(
            data: FleetJSON.encoder.encode(manifest),
            encoding: .utf8
        ))
        #expect(!encoded.contains("0.11.3"))
    }

    @Test
    func cleanNewerCheckoutBecomesUpdateTargetBeforeInstallation() {
        let machineID = "b41f9f4f-0fce-4792-a3c6-c93a73fcb4cd"
        let baseline = targetSnapshot(
            machineID: machineID,
            installedVersion: "1.0.0",
            sourceVersion: "1.0.0",
            revision: "aaaaaaaaaaaa"
        )
        let observation = ComponentObservation(
            id: "authbar",
            name: "AuthBar",
            kind: .application,
            status: .installed,
            installedVersion: "1.0.0",
            installedRevision: "aaaaaaaaaaaa",
            sourceVersion: "1.1.0",
            sourceRevision: "bbbbbbbbbbbb",
            sourceDirty: false,
            sourceTree: String(repeating: "b", count: 40),
            evidence: "Clean newer checkout"
        )
        let current = targetSnapshot(
            machineID: machineID,
            installedVersion: "1.0.0",
            sourceVersion: "1.0.0",
            revision: "aaaaaaaaaaaa"
        ).replacingComponents([observation])

        let target = RepositoryTargetResolver().resolve(
            manifest: FleetManifest(snapshot: baseline),
            localSnapshot: current,
            now: Date(timeIntervalSince1970: 1_010)
        )["authbar"]

        #expect(target?.version == "1.1.0")
        #expect(target?.sourceRevision == "bbbbbbbbbbbb")
        #expect(target?.installedRevision == nil)
    }

    @Test
    func olderCheckoutCannotBecomeTargetForNewerInstalledSoftware() {
        let machineID = "b41f9f4f-0fce-4792-a3c6-c93a73fcb4cd"
        let baseline = targetSnapshot(
            machineID: machineID,
            installedVersion: "1.0.0",
            sourceVersion: "1.0.0",
            revision: "aaaaaaaaaaaa"
        )
        let observation = ComponentObservation(
            id: "authbar",
            name: "AuthBar",
            kind: .application,
            status: .installed,
            installedVersion: "1.2.0",
            installedRevision: "cccccccccccc",
            sourceVersion: "1.1.0",
            sourceRevision: "bbbbbbbbbbbb",
            sourceDirty: false,
            sourceTree: String(repeating: "b", count: 40),
            evidence: "Older checkout"
        )
        let current = targetSnapshot(
            machineID: machineID,
            installedVersion: "1.2.0",
            sourceVersion: "1.2.0",
            revision: "cccccccccccc"
        ).replacingComponents([observation])

        #expect(RepositoryTargetResolver().resolve(
            manifest: FleetManifest(snapshot: baseline),
            localSnapshot: current,
            now: Date(timeIntervalSince1970: 1_010)
        ).isEmpty)
    }

    @Test
    func mergeCommitWithIdenticalTreeRemainsLatestRepositoryTarget() {
        let machineID = "b41f9f4f-0fce-4792-a3c6-c93a73fcb4cd"
        let baseline = targetSnapshot(
            machineID: machineID,
            installedVersion: "0.1.1",
            sourceVersion: "0.1.1",
            revision: "aaaaaaaaaaaa"
        )
        let manifest = FleetManifest(snapshot: baseline)
        let tree = "8908725ae4859bc6c4ec5c2d26835fe572b5a8fa"
        let observation = ComponentObservation(
            id: "authbar",
            name: "FleetMesh",
            kind: .application,
            status: .installed,
            installedVersion: "0.1.8",
            installedRevision: "c1f8f22",
            sourceVersion: "0.1.8",
            sourceRevision: "1a6a930566ff",
            sourceDirty: false,
            sourceTree: tree,
            installedTree: tree,
            evidence: "Merge tree proof"
        )
        let current = targetSnapshot(
            machineID: machineID,
            installedVersion: "0.1.8",
            sourceVersion: "0.1.8",
            revision: "c1f8f22"
        ).replacingComponents([observation])

        let target = RepositoryTargetResolver().resolve(
            manifest: manifest,
            localSnapshot: current,
            now: Date(timeIntervalSince1970: 1_010)
        )

        #expect(target["authbar"]?.version == "0.1.8")
        #expect(target["authbar"]?.installedRevision == "c1f8f22")
        #expect(target["authbar"]?.sourceRevision == "1a6a930566ff")
    }

    @Test
    func sameVersionDifferentTreesCannotBecomeRepositoryTarget() {
        let machineID = "b41f9f4f-0fce-4792-a3c6-c93a73fcb4cd"
        let baseline = targetSnapshot(
            machineID: machineID,
            installedVersion: "0.1.1",
            sourceVersion: "0.1.1",
            revision: "aaaaaaaaaaaa"
        )
        let manifest = FleetManifest(snapshot: baseline)
        let observation = ComponentObservation(
            id: "authbar",
            name: "FleetMesh",
            kind: .application,
            status: .installed,
            installedVersion: "0.1.8",
            installedRevision: "c1f8f22",
            sourceVersion: "0.1.8",
            sourceRevision: "1a6a930566ff",
            sourceDirty: false,
            sourceTree: String(repeating: "a", count: 40),
            installedTree: String(repeating: "b", count: 40),
            evidence: "Different trees"
        )
        let current = targetSnapshot(
            machineID: machineID,
            installedVersion: "0.1.8",
            sourceVersion: "0.1.8",
            revision: "c1f8f22"
        ).replacingComponents([observation])

        #expect(RepositoryTargetResolver().resolve(
            manifest: manifest,
            localSnapshot: current,
            now: Date(timeIntervalSince1970: 1_010)
        ).isEmpty)
    }

    @Test
    func pendingDirtyAndOlderLocalRepositoriesCannotAdvanceTarget() throws {
        let authority = targetSnapshot(
            machineID: "b41f9f4f-0fce-4792-a3c6-c93a73fcb4cd",
            installedVersion: "0.10.5",
            sourceVersion: "0.10.5",
            revision: "aaaaaaaaaaaa"
        )
        var manifest = FleetManifest(snapshot: authority)
        let pending = targetSnapshot(
            machineID: "9c694b70-14b7-48f6-83e1-cd23603ac157",
            installedVersion: "0.12.0",
            sourceVersion: "0.12.0",
            revision: "bbbbbbbbbbbb"
        )
        let dirty = targetSnapshot(
            machineID: authority.machineID,
            installedVersion: "0.11.3",
            sourceVersion: "0.11.3",
            revision: "cccccccccccc",
            dirty: true
        )
        let older = targetSnapshot(
            machineID: authority.machineID,
            installedVersion: "0.9.9",
            sourceVersion: "0.9.9",
            revision: "dddddddddddd"
        )

        #expect(RepositoryTargetResolver().resolve(
            manifest: manifest,
            localSnapshot: pending,
            now: Date(timeIntervalSince1970: 1_010)
        ).isEmpty)
        #expect(RepositoryTargetResolver().resolve(
            manifest: manifest,
            localSnapshot: dirty,
            now: Date(timeIntervalSince1970: 1_010)
        ).isEmpty)
        #expect(RepositoryTargetResolver().resolve(
            manifest: manifest,
            localSnapshot: older,
            now: Date(timeIntervalSince1970: 1_010)
        ).isEmpty)

        manifest = try manifest.settingDeviceEnrollment(
            snapshot: pending,
            enrolled: true,
            role: .workstation,
            knownSnapshots: [authority, pending],
            updatedByMachineID: authority.machineID
        )
        let promoted = RepositoryTargetResolver().resolve(
            manifest: manifest,
            localSnapshot: pending,
            now: Date(timeIntervalSince1970: 1_010)
        )
        #expect(promoted["authbar"]?.version == "0.12.0")
    }

    @Test
    func parsesProductOwnedVersionSources() {
        let swift = Data(#"enum Version { static let current = "0.11.3" }"#.utf8)
        let cargo = Data(#"""
        [package]
        name = "app"
        version = "0.4.33"

        [dependencies]
        thing = "9.9.9"
        """#.utf8)
        let package = Data(#"{"name":"model-bridge","version":"0.2.12"}"#.utf8)
        let workspaceCargo = Data(#"""
        [workspace]
        members = ["crates/app"]

        [workspace.package]
        version = "0.4.33"
        edition = "2021"
        """#.utf8)

        #expect(InventoryService.parseSourceVersion(
            data: swift,
            format: .swiftStaticCurrent
        ) == "0.11.3")
        #expect(InventoryService.parseSourceVersion(
            data: cargo,
            format: .cargoPackage
        ) == "0.4.33")
        #expect(InventoryService.parseSourceVersion(
            data: package,
            format: .packageJSON
        ) == "0.2.12")
        #expect(InventoryService.parseSourceVersion(
            data: workspaceCargo,
            format: .cargoPackage
        ) == "0.4.33")
        #expect(VersionIdentity.matches("v1.2.3", "1.2.3"))
        #expect(VersionIdentity.compare("1.10.0", "1.9.9") == .orderedDescending)
        #expect(VersionIdentity.compare("1.2.3-beta.1", "1.2.3") == .orderedAscending)
        #expect(VersionIdentity.normalizedDeclaration("next") == nil)
        #expect(!VersionIdentity.matches("next", "other"))
    }

    @Test
    func staleAndMalformedRepositoryEvidenceCannotBecomeTarget() {
        let machineID = "b41f9f4f-0fce-4792-a3c6-c93a73fcb4cd"
        let baseline = targetSnapshot(
            machineID: machineID,
            installedVersion: "0.10.5",
            sourceVersion: "0.10.5",
            revision: "aaaaaaaaaaaa",
            capturedAt: Date(timeIntervalSince1970: 1_000)
        )
        let manifest = FleetManifest(snapshot: baseline)
        let stale = targetSnapshot(
            machineID: machineID,
            installedVersion: "0.12.0",
            sourceVersion: "0.12.0",
            revision: "bbbbbbbbbbbb",
            capturedAt: Date(timeIntervalSince1970: 1_000)
        )
        let malformed = targetSnapshot(
            machineID: machineID,
            installedVersion: "0.12.0",
            sourceVersion: "next",
            revision: "cccccccccccc",
            capturedAt: Date(timeIntervalSince1970: 200_000)
        )

        let resolved = RepositoryTargetResolver(freshnessInterval: 60).resolve(
            manifest: manifest,
            localSnapshot: stale,
            now: Date(timeIntervalSince1970: 200_010)
        )

        #expect(resolved.isEmpty)
        #expect(RepositoryTargetResolver(freshnessInterval: 60).resolve(
            manifest: manifest,
            localSnapshot: malformed,
            now: Date(timeIntervalSince1970: 200_010)
        ).isEmpty)
    }

    @Test
    func futureAndMalformedRevisionEvidenceCannotBecomeTarget() {
        let machineID = "b41f9f4f-0fce-4792-a3c6-c93a73fcb4cd"
        let baseline = targetSnapshot(
            machineID: machineID,
            installedVersion: "0.10.5",
            sourceVersion: "0.10.5",
            revision: "aaaaaaaaaaaa",
            capturedAt: Date(timeIntervalSince1970: 1_000)
        )
        let manifest = FleetManifest(snapshot: baseline)
        let future = targetSnapshot(
            machineID: machineID,
            installedVersion: "0.11.3",
            sourceVersion: "0.11.3",
            revision: "bbbbbbbbbbbb",
            capturedAt: Date(timeIntervalSince1970: 10_000)
        )
        let malformedRevision = targetSnapshot(
            machineID: machineID,
            installedVersion: "0.11.3",
            sourceVersion: "0.11.3",
            revision: "not-a-revision",
            capturedAt: Date(timeIntervalSince1970: 1_000)
        )

        #expect(RepositoryTargetResolver().resolve(
            manifest: manifest,
            localSnapshot: future,
            now: Date(timeIntervalSince1970: 1_000)
        ).isEmpty)
        #expect(RepositoryTargetResolver().resolve(
            manifest: manifest,
            localSnapshot: malformedRevision,
            now: Date(timeIntervalSince1970: 1_010)
        ).isEmpty)
    }

    @Test
    func versionOnlyInstalledEvidenceStaysOnSavedBaseline() {
        let machineID = "b41f9f4f-0fce-4792-a3c6-c93a73fcb4cd"
        let baseline = targetSnapshot(
            machineID: machineID,
            installedVersion: "0.10.5",
            sourceVersion: "0.10.5",
            revision: "aaaaaaaaaaaa",
            capturedAt: Date(timeIntervalSince1970: 1_000)
        )
        let manifest = FleetManifest(snapshot: baseline)
        let observation = ComponentObservation(
            id: "authbar",
            name: "AuthBar",
            kind: .application,
            status: .installed,
            installedVersion: "0.11.3",
            installedRevision: nil,
            sourceVersion: "0.11.3",
            sourceRevision: "bbbbbbbbbbbb",
            sourceBranch: "release",
            sourceDirty: false,
            evidence: "Version only"
        )
        let versionOnly = MachineSnapshot(
            machineID: machineID,
            name: "Target Mac",
            hostName: "target-mac",
            modelIdentifier: "Mac17,6",
            architecture: "arm64",
            osVersion: "26.6",
            osBuild: "25G83",
            capturedAt: Date(timeIntervalSince1970: 1_000),
            components: [observation]
        )

        #expect(RepositoryTargetResolver().resolve(
            manifest: manifest,
            localSnapshot: versionOnly,
            now: Date(timeIntervalSince1970: 1_010)
        ).isEmpty)
    }

    @Test
    func missingStatusCannotBecomeRepositoryTargetEvenWithForgedVersionFields() {
        let machineID = "b41f9f4f-0fce-4792-a3c6-c93a73fcb4cd"
        let baseline = targetSnapshot(
            machineID: machineID,
            installedVersion: "0.10.5",
            sourceVersion: "0.10.5",
            revision: "aaaaaaaaaaaa"
        )
        let manifest = FleetManifest(snapshot: baseline)
        let forged = ComponentObservation(
            id: "authbar",
            name: "AuthBar",
            kind: .application,
            status: .missing,
            installedVersion: "0.11.3",
            installedRevision: "bbbbbbbbbbbb",
            sourceVersion: "0.11.3",
            sourceRevision: "bbbbbbbbbbbb",
            sourceDirty: false,
            evidence: "Malformed evidence"
        )
        let snapshot = MachineSnapshot(
            machineID: machineID,
            name: "Target Mac",
            hostName: "target-mac",
            modelIdentifier: "Mac17,6",
            architecture: "arm64",
            osVersion: "26.6",
            osBuild: "25G83",
            components: [forged]
        )

        #expect(RepositoryTargetResolver().resolve(
            manifest: manifest,
            localSnapshot: snapshot
        ).isEmpty)
    }
}

private func targetSnapshot(
    machineID: String,
    installedVersion: String,
    sourceVersion: String,
    revision: String,
    capturedAt: Date = Date(timeIntervalSince1970: 1_000),
    dirty: Bool = false
) -> MachineSnapshot {
    MachineSnapshot(
        machineID: machineID,
        name: "Target Mac",
        hostName: "target-mac",
        modelIdentifier: "Mac17,6",
        architecture: "arm64",
        osVersion: "26.6",
        osBuild: "25G83",
        capturedAt: capturedAt,
        components: [
            ComponentObservation(
                id: "authbar",
                name: "AuthBar",
                kind: .application,
                status: .installed,
                installedVersion: installedVersion,
                installedRevision: revision,
                sourceVersion: sourceVersion,
                sourceRevision: revision,
                sourceBranch: "release",
                sourceDirty: dirty,
                evidence: "Test repository evidence"
            ),
        ]
    )
}

private extension MachineSnapshot {
    func replacingComponents(_ components: [ComponentObservation]) -> MachineSnapshot {
        MachineSnapshot(
            machineID: machineID,
            name: name,
            hostName: hostName,
            modelIdentifier: modelIdentifier,
            architecture: architecture,
            osVersion: osVersion,
            osBuild: osBuild,
            platform: effectivePlatform,
            capabilities: Array(effectiveCapabilities),
            capturedAt: capturedAt,
            deviceSyncVersion: deviceSyncVersion,
            components: components
        )
    }
}
