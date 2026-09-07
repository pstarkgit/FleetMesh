import Foundation
import Testing
@testable import DeviceSync

struct FleetMeshUpdatesTests {
    @Test
    func releaseNotesParseWrappedBulletsAndCurrentRelease() throws {
        let parsed = FleetMeshReleaseNotes.parse("""
        # Changelog

        ## 0.1.17 — 2026-09-06 — Move fleets

        - Verify destination first and
          preserve the current fleet on failure.
        - Publish Pending evidence.
        """)
        #expect(parsed.map(\.version) == ["0.1.17"])
        #expect(parsed.first?.date == "2026-09-06")
        #expect(parsed.first?.title == "Move fleets")
        #expect(parsed.first?.changes == [
            "Verify destination first and preserve the current fleet on failure.",
            "Publish Pending evidence.",
        ])
    }

    @Test
    func changelogContainsCurrentRelease() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let markdown = try String(contentsOf: root.appendingPathComponent("CHANGELOG.md"), encoding: .utf8)
        let entries = FleetMeshReleaseNotes.parse(markdown)
        #expect(entries.first?.version == DeviceSyncVersion.current)
    }

    @Test
    func releaseManifestAndAssetURLsFailClosed() throws {
        let release = publishedRelease(version: "1.2.3")
        let manifest = releaseManifest(version: "1.2.3")
        try GitHubFleetMeshReleaseService.validate(
            manifest: manifest,
            release: release,
            architecture: "arm64"
        )
        #expect(GitHubFleetMeshReleaseService.isApprovedAssetURL(
            release.archiveURL,
            tag: release.tag
        ))
        #expect(!GitHubFleetMeshReleaseService.isApprovedAssetURL(
            URL(string: "https://example.invalid/FleetMesh-1.2.3-arm64.zip")!,
            tag: release.tag
        ))
        #expect(!GitHubFleetMeshReleaseService.isApprovedAssetURL(
            URL(string: "http://github.com/pstarkgit/FleetMesh/releases/download/v1.2.3/FleetMesh-1.2.3-arm64.zip")!,
            tag: release.tag
        ))

        var tampered = releaseManifest(version: "1.2.3")
        tampered = FleetMeshReleaseManifest(
            schemaVersion: tampered.schemaVersion,
            product: tampered.product,
            version: tampered.version,
            commit: tampered.commit,
            architecture: tampered.architecture,
            bundleIdentifier: tampered.bundleIdentifier,
            teamIdentifier: tampered.teamIdentifier,
            archiveName: tampered.archiveName,
            archiveSHA256: "bad",
            archiveSize: tampered.archiveSize
        )
        #expect(throws: FleetMeshReleaseError.invalidManifest) {
            try GitHubFleetMeshReleaseService.validate(
                manifest: tampered,
                release: release,
                architecture: "arm64"
            )
        }
    }

    @Test
    func archiveChecksumDetectsTampering() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("fleetmesh-release-hash-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let archive = root.appendingPathComponent("archive.zip")
        try Data("trusted".utf8).write(to: archive)
        let trusted = try GitHubFleetMeshReleaseService.sha256(of: archive)
        try Data("tampered".utf8).write(to: archive)
        #expect(try GitHubFleetMeshReleaseService.sha256(of: archive) != trusted)
    }

    @Test
    @MainActor
    func updaterChecksAndInstallsPreparedReleaseWithoutSourceCheckout() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("fleetmesh-prebuilt-updater-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let release = publishedRelease(version: "9.0.0")
        let prepared = PreparedFleetMeshUpdate(
            appURL: root.appendingPathComponent("extracted/FleetMesh.app"),
            installerScriptURL: root.appendingPathComponent("extracted/FleetMesh.app/Contents/Resources/install-prebuilt.sh"),
            manifest: releaseManifest(version: "9.0.0"),
            workRootURL: root
        )
        let service = FixedReleaseService(release: release, prepared: prepared)
        let installer = RecordingPrebuiltInstaller()
        let terminated = TerminationBox()
        let updater = FleetMeshUpdater(
            releaseService: service,
            installer: installer,
            updateLogURL: root.appendingPathComponent("update.log"),
            workRootProvider: { root },
            processIDProvider: { 1234 },
            terminationHandler: { terminated.value = true }
        )

        await updater.check()
        #expect(updater.state == .available(version: "9.0.0"))
        await updater.installAvailableUpdate()
        #expect(await installer.launchCount() == 1)
        #expect(await installer.lastProcessID() == 1234)
        #expect(terminated.value)
        #expect(await service.prepareCount() == 1)
    }

    @Test
    @MainActor
    func updaterReportsBoundedVerificationFailure() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("fleetmesh-prebuilt-failure-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let release = publishedRelease(version: "9.0.0")
        let service = FixedReleaseService(
            release: release,
            prepared: nil,
            prepareError: FleetMeshReleaseError.archiveChecksumMismatch
        )
        let updater = FleetMeshUpdater(
            releaseService: service,
            installer: RecordingPrebuiltInstaller(),
            updateLogURL: root.appendingPathComponent("update.log"),
            workRootProvider: { root },
            terminationHandler: {}
        )
        await updater.installAvailableUpdate()
        guard case .failed(let message) = updater.state else {
            Issue.record("Expected failed state, got \(updater.state)")
            return
        }
        #expect(message.contains("checksum"))
        #expect(message.contains("update.log"))
        #expect(message.count < 700)
    }

    @Test
    func verifierRequiresTrustedSignatureNotarizationProvenanceAndArchitecture() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("fleetmesh-verifier-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = try makeApp(at: root, manifest: releaseManifest(version: "1.2.3"))

        let valid = GitHubFleetMeshReleaseService(commandRunner: VerificationRunner(mode: .valid))
        try await valid.verify(appURL: app, manifest: releaseManifest(version: "1.2.3"))

        for (mode, expected) in [
            (VerificationRunner.Mode.badSignature, FleetMeshReleaseError.untrustedSigningIdentity),
            (.badGatekeeper, .gatekeeperRejected),
            (.badStaple, .notarizationTicketMissing),
            (.badArchitecture, .architectureMismatch),
        ] {
            let service = GitHubFleetMeshReleaseService(commandRunner: VerificationRunner(mode: mode))
            do {
                try await service.verify(appURL: app, manifest: releaseManifest(version: "1.2.3"))
                Issue.record("Expected verifier failure for \(mode)")
            } catch let error as FleetMeshReleaseError {
                #expect(error == expected)
            }
        }

        let wrong = releaseManifest(version: "1.2.4")
        do {
            try await valid.verify(appURL: app, manifest: wrong)
            Issue.record("Expected signed provenance mismatch")
        } catch let error as FleetMeshReleaseError {
            #expect(error == .provenanceMismatch)
        }
    }

    @Test
    func releaseAndInstallerScriptsCarryRequiredSafetyGates() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let release = try String(
            contentsOf: root.appendingPathComponent("scripts/package-release.sh"),
            encoding: .utf8
        )
        let installer = try String(
            contentsOf: root.appendingPathComponent("Resources/install-prebuilt.sh"),
            encoding: .utf8
        )
        for required in ["notarytool submit", "stapler staple", "spctl --assess", "shasum -a 256", "CycloneDX"] {
            #expect(release.contains(required))
        }
        for required in ["codesign --verify", "TeamIdentifier", "stapler validate", "spctl --assess", "BACKUP_APP", "--self-check"] {
            #expect(installer.contains(required))
        }
        #expect(!installer.contains("swift build"))
        #expect(!installer.contains("git pull"))
        #expect(!installer.contains("git fetch"))
    }

    private func publishedRelease(version: String) -> FleetMeshPublishedRelease {
        let base = "https://github.com/pstarkgit/FleetMesh/releases/download/v\(version)"
        return FleetMeshPublishedRelease(
            version: version,
            tag: "v\(version)",
            archiveURL: URL(string: "\(base)/FleetMesh-\(version)-arm64.zip")!,
            manifestURL: URL(string: "\(base)/FleetMesh-\(version)-arm64.json")!
        )
    }

    private func releaseManifest(version: String) -> FleetMeshReleaseManifest {
        FleetMeshReleaseManifest(
            schemaVersion: 1,
            product: "FleetMesh",
            version: version,
            commit: String(repeating: "a", count: 40),
            architecture: "arm64",
            bundleIdentifier: "dev.starkpat.devicesync",
            teamIdentifier: "P2M5LH6CVA",
            archiveName: "FleetMesh-\(version)-arm64.zip",
            archiveSHA256: String(repeating: "b", count: 64),
            archiveSize: 1234
        )
    }

    private func makeApp(
        at root: URL,
        manifest: FleetMeshReleaseManifest
    ) throws -> URL {
        let app = root.appendingPathComponent("FleetMesh.app", isDirectory: true)
        let macOS = app.appendingPathComponent("Contents/MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        try Data().write(to: macOS.appendingPathComponent("DeviceSync"))
        let info: [String: Any] = [
            "CFBundleIdentifier": manifest.bundleIdentifier,
            "CFBundleShortVersionString": manifest.version,
            "CFBundleVersion": manifest.version,
            "DSCommit": manifest.commit,
            "DSArchitecture": manifest.architecture,
            "DSReleaseRepository": "https://github.com/pstarkgit/FleetMesh",
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: info,
            format: .xml,
            options: 0
        )
        try data.write(to: app.appendingPathComponent("Contents/Info.plist"))
        return app
    }
}

private actor FixedReleaseService: FleetMeshReleaseServicing {
    let release: FleetMeshPublishedRelease
    let prepared: PreparedFleetMeshUpdate?
    let prepareError: Error?
    private var preparations = 0

    init(
        release: FleetMeshPublishedRelease,
        prepared: PreparedFleetMeshUpdate?,
        prepareError: Error? = nil
    ) {
        self.release = release
        self.prepared = prepared
        self.prepareError = prepareError
    }

    func latest(architecture: String) async throws -> FleetMeshPublishedRelease {
        release
    }

    func prepare(
        _ release: FleetMeshPublishedRelease,
        architecture: String,
        workRootURL: URL
    ) async throws -> PreparedFleetMeshUpdate {
        preparations += 1
        if let prepareError { throw prepareError }
        return try #require(prepared)
    }

    func prepareCount() -> Int { preparations }
}

private actor RecordingPrebuiltInstaller: FleetMeshPrebuiltInstalling {
    private var count = 0
    private var processID: Int32?

    func launch(
        _ update: PreparedFleetMeshUpdate,
        currentProcessID: Int32,
        logURL: URL
    ) async throws {
        count += 1
        processID = currentProcessID
    }

    func launchCount() -> Int { count }
    func lastProcessID() -> Int32? { processID }
}

@MainActor
private final class TerminationBox: @unchecked Sendable {
    var value = false
}

private actor VerificationRunner: CommandRunning {
    enum Mode: Sendable {
        case valid
        case badSignature
        case badGatekeeper
        case badStaple
        case badArchitecture
    }

    let mode: Mode
    init(mode: Mode) { self.mode = mode }

    func run(
        executable: URL,
        arguments: [String],
        environment: [String: String]?,
        timeout: TimeInterval?
    ) async -> CommandResult {
        if executable.path == "/usr/bin/codesign", arguments.first == "-dv" {
            let valid = """
            Authority=Developer ID Application: Patrick Stark (P2M5LH6CVA)
            TeamIdentifier=P2M5LH6CVA
            flags=0x10000(runtime)
            Timestamp=Sep 7, 2026
            """
            return result(error: mode == .badSignature ? "TeamIdentifier=EVIL" : valid)
        }
        if executable.path == "/usr/sbin/spctl" {
            return result(exitCode: mode == .badGatekeeper ? 1 : 0)
        }
        if executable.path == "/usr/bin/xcrun" {
            return result(exitCode: mode == .badStaple ? 1 : 0)
        }
        if executable.path == "/usr/bin/lipo" {
            return result(output: mode == .badArchitecture ? "x86_64\n" : "arm64\n")
        }
        return result()
    }

    private func result(
        exitCode: Int32 = 0,
        output: String = "",
        error: String = ""
    ) -> CommandResult {
        CommandResult(
            exitCode: exitCode,
            standardOutput: output,
            standardError: error,
            timedOut: false
        )
    }
}
