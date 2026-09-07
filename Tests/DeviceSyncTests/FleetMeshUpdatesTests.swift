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
        #expect(entries.first?.version == "0.1.17")
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
    func updateFastForwardsBeforeLaunchingProductInstaller() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("fleetmesh-updater-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let marker = root.appendingPathComponent("installer-launched")
        let updater = FleetMeshUpdater(
            sourceDirectory: root,
            commandRunner: UpdateRunner(mode: .available),
            installerLauncher: { _ in
                _ = FileManager.default.createFile(atPath: marker.path, contents: Data())
            }
        )

        await updater.installAvailableUpdate()

        #expect(FileManager.default.fileExists(atPath: marker.path))
        #expect(updater.state == .updating)
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
