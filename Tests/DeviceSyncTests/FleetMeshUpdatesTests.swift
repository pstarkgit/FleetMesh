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

        ## 0.1.16 — 2026-09-06

        - Add invitations.
        """)

        #expect(parsed.map(\.version) == ["0.1.17", "0.1.16"])
        #expect(parsed.first?.date == "2026-09-06")
        #expect(parsed.first?.title == "Move fleets")
        #expect(parsed.first?.changes == [
            "Verify destination first and preserve the current fleet on failure.",
            "Publish Pending evidence.",
        ])
        #expect(FleetMeshReleaseNotes.entry(for: "0.1.16", in: parsed)?.changes == [
            "Add invitations."
        ])
    }

    @Test
    func changelogContainsCurrentRelease() throws {
        let testFile = URL(fileURLWithPath: #filePath)
        let root = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let markdown = try String(
            contentsOf: root.appendingPathComponent("CHANGELOG.md"),
            encoding: .utf8
        )
        let entries = FleetMeshReleaseNotes.parse(markdown)
        #expect(entries.first?.version == DeviceSyncVersion.current)
        #expect(entries.first?.version == "0.1.19")
    }

    @Test
    @MainActor
    func updateCheckDistinguishesCurrentAvailableDirtyAndDiverged() async {
        let source = URL(fileURLWithPath: "/tmp/fleetmesh-update-test", isDirectory: true)

        let current = FleetMeshUpdater(
            sourceDirectory: source,
            commandRunner: UpdateRunner(mode: .current)
        )
        await current.check()
        guard case .upToDate = current.state else {
            Issue.record("Expected upToDate, got \(current.state)")
            return
        }

        let available = FleetMeshUpdater(
            sourceDirectory: source,
            commandRunner: UpdateRunner(mode: .available)
        )
        await available.check()
        #expect(available.state == .available(version: "0.1.18"))

        let dirty = FleetMeshUpdater(
            sourceDirectory: source,
            commandRunner: UpdateRunner(mode: .dirty)
        )
        await dirty.check()
        guard case .blocked(let dirtyReason) = dirty.state else {
            Issue.record("Expected dirty checkout block, got \(dirty.state)")
            return
        }
        #expect(dirtyReason.contains("local changes"))

        let diverged = FleetMeshUpdater(
            sourceDirectory: source,
            commandRunner: UpdateRunner(mode: .diverged)
        )
        await diverged.check()
        guard case .blocked(let divergedReason) = diverged.state else {
            Issue.record("Expected divergence block, got \(diverged.state)")
            return
        }
        #expect(divergedReason.contains("diverged"))
    }

    @Test
    @MainActor
    func updateFastForwardsBeforeRunningMonitoredProductInstaller() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("fleetmesh-updater-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try makeExecutableInstaller(at: root)
        let logURL = root.appendingPathComponent("update.log")
        let updater = FleetMeshUpdater(
            sourceDirectory: root,
            commandRunner: UpdateRunner(mode: .available),
            installerRunner: FixedInstallerRunner(result: CommandResult(
                exitCode: 0,
                standardOutput: "install complete",
                standardError: "",
                timedOut: false
            )),
            updateLogURL: logURL
        )

        await updater.installAvailableUpdate()

        guard case .upToDate = updater.state else {
            Issue.record("Expected monitored success, got \(updater.state)")
            return
        }
        let log = try String(contentsOf: logURL, encoding: .utf8)
        #expect(log.contains("exit=0"))
        #expect(log.contains("install complete"))
    }

    @Test
    @MainActor
    func installerFailureLeavesUpdatingStateAndSurfacesBoundedDetail() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("fleetmesh-updater-failure-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try makeExecutableInstaller(at: root)
        let logURL = root.appendingPathComponent("update.log")
        let detail = "Xcode path missing\n" + String(repeating: "x", count: 2_000)
        let updater = FleetMeshUpdater(
            sourceDirectory: root,
            commandRunner: UpdateRunner(mode: .available),
            installerRunner: FixedInstallerRunner(result: CommandResult(
                exitCode: 1,
                standardOutput: "",
                standardError: detail,
                timedOut: false
            )),
            updateLogURL: logURL
        )

        await updater.installAvailableUpdate()

        guard case .failed(let message) = updater.state else {
            Issue.record("Expected installer failure, got \(updater.state)")
            return
        }
        #expect(message.contains("status 1"))
        #expect(message.contains("update.log"))
        #expect(message.count < 1_600)
        #expect(!message.contains("\n"))
        let log = try String(contentsOf: logURL, encoding: .utf8)
        #expect(log.contains("Xcode path missing"))
        #expect(log.contains("exit=1"))
    }

    @Test
    @MainActor
    func installerTimeoutBecomesFailureInsteadOfInfiniteSpinner() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("fleetmesh-updater-timeout-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try makeExecutableInstaller(at: root)
        let updater = FleetMeshUpdater(
            sourceDirectory: root,
            commandRunner: UpdateRunner(mode: .available),
            installerRunner: FixedInstallerRunner(result: CommandResult(
                exitCode: 143,
                standardOutput: "",
                standardError: "Installer timed out",
                timedOut: true
            )),
            updateLogURL: root.appendingPathComponent("update.log")
        )

        await updater.installAvailableUpdate()

        guard case .failed(let message) = updater.state else {
            Issue.record("Expected timeout failure, got \(updater.state)")
            return
        }
        #expect(message.contains("exceeded 30 minutes"))
    }

    private func makeExecutableInstaller(at root: URL) throws {
        let installer = root.appendingPathComponent("install.sh")
        try Data("#!/bin/bash\nexit 0\n".utf8).write(to: installer)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: installer.path
        )
    }
}

private actor FixedInstallerRunner: CommandRunning {
    let result: CommandResult

    init(result: CommandResult) {
        self.result = result
    }

    func run(
        executable: URL,
        arguments: [String],
        environment: [String: String]?,
        timeout: TimeInterval?
    ) async -> CommandResult {
        result
    }
}

private actor UpdateRunner: CommandRunning {
    enum Mode: Sendable {
        case current
        case available
        case dirty
        case diverged
    }

    let mode: Mode

    init(mode: Mode) {
        self.mode = mode
    }

    func run(
        executable: URL,
        arguments: [String],
        environment: [String: String]?,
        timeout: TimeInterval?
    ) async -> CommandResult {
        let command = Array(arguments.dropFirst(2))
        switch command.first {
        case "fetch", "pull":
            return result()
        case "status":
            return result(output: mode == .dirty ? " M Sources/DeviceSync/App.swift\n" : "")
        case "rev-parse":
            switch mode {
            case .current:
                return result(output: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\naaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n")
            case .available, .dirty, .diverged:
                return result(output: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\nbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\n")
            }
        case "merge-base":
            return mode == .diverged ? result(exitCode: 1) : result()
        case "show":
            return result(output: "enum DeviceSyncVersion { static let current = \"0.1.18\" }\n")
        default:
            return result(exitCode: 1)
        }
    }

    private func result(
        exitCode: Int32 = 0,
        output: String = ""
    ) -> CommandResult {
        CommandResult(
            exitCode: exitCode,
            standardOutput: output,
            standardError: "",
            timedOut: false
        )
    }
}
