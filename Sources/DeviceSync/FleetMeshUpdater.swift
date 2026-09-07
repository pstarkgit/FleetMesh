import Foundation
import Observation

@MainActor
@Observable
final class FleetMeshUpdater {
    enum State: Equatable {
        case idle
        case checking
        case upToDate(Date)
        case available(version: String)
        case blocked(String)
        case updating
        case failed(String)
    }

    private(set) var state: State = .idle

    private let sourceDirectory: URL?
    private let commandRunner: any CommandRunning
    private let installerLauncher: @MainActor (URL) throws -> Void

    init(
        sourceDirectory: URL? = FleetMeshUpdater.installedSourceDirectory,
        commandRunner: any CommandRunning = ProcessCommandRunner(),
        installerLauncher: @escaping @MainActor (URL) throws -> Void = FleetMeshUpdater.launchInstaller
    ) {
        self.sourceDirectory = sourceDirectory
        self.commandRunner = commandRunner
        self.installerLauncher = installerLauncher
    }

    static var installedSourceDirectory: URL? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "DSSourceDir") as? String,
              !value.isEmpty else { return nil }
        let url = URL(fileURLWithPath: value, isDirectory: true).standardizedFileURL
        guard FileManager.default.fileExists(
            atPath: url.appendingPathComponent(".git").path
        ) else { return nil }
        return url
    }

    var canCheck: Bool { sourceDirectory != nil }

    func check() async {
        guard let sourceDirectory else {
            state = .blocked("No verified source checkout is attached to this build.")
            return
        }
        state = .checking

        let fetch = await git(
            ["fetch", "--quiet", "origin", "main"],
            sourceDirectory: sourceDirectory,
            timeout: 20
        )
        guard fetch.exitCode == 0, !fetch.timedOut else {
            state = .failed("Could not fetch origin/main. Check network and repository access.")
            return
        }

        let status = await git(
            ["status", "--porcelain"],
            sourceDirectory: sourceDirectory,
            timeout: 5
        )
        guard status.exitCode == 0 else {
            state = .failed("Could not inspect the FleetMesh source checkout.")
            return
        }
        guard status.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            state = .blocked("The FleetMesh source checkout has local changes. Commit or preserve them before updating.")
            return
        }

        let revisions = await git(
            ["rev-parse", "HEAD", "origin/main"],
            sourceDirectory: sourceDirectory,
            timeout: 5
        )
        let lines = revisions.standardOutput
            .split(separator: "\n")
            .map(String.init)
        guard revisions.exitCode == 0, lines.count == 2 else {
            state = .failed("Could not compare the installed build with origin/main.")
            return
        }
        let local = lines[0]
        let remote = lines[1]
        if local != remote {
            let ancestry = await git(
                ["merge-base", "--is-ancestor", local, remote],
                sourceDirectory: sourceDirectory,
                timeout: 5
            )
            guard ancestry.exitCode == 0 else {
                state = .blocked("The source checkout has diverged from origin/main. FleetMesh will not merge or overwrite it.")
                return
            }
        }

        let installedCommit = FleetMeshBuildIdentity.commit ?? "dev"
        let installedIsCurrent = installedCommit == "dev"
            ? local == remote
            : remote.hasPrefix(installedCommit) || installedCommit.hasPrefix(remote)
        guard local != remote || !installedIsCurrent else {
            state = .upToDate(Date())
            return
        }

        let latest = await git(
            ["show", "origin/main:Sources/DeviceSync/DeviceSyncVersion.swift"],
            sourceDirectory: sourceDirectory,
            timeout: 5
        )
        let version = VersionIdentity.extract(from: latest.standardOutput) ?? "new build"
        state = .available(version: version)
    }

    func installAvailableUpdate() async {
        await check()
        guard case .available = state, let sourceDirectory else { return }
        state = .updating

        let pull = await git(
            ["pull", "--ff-only", "origin", "main"],
            sourceDirectory: sourceDirectory,
            timeout: 30
        )
        guard pull.exitCode == 0, !pull.timedOut else {
            state = .failed("The clean fast-forward update failed. No installer was launched.")
            return
        }

        do {
            try installerLauncher(sourceDirectory)
        } catch {
            state = .failed("The update was fetched, but FleetMesh could not launch its signed installer: \(error.localizedDescription)")
        }
    }

    private func git(
        _ arguments: [String],
        sourceDirectory: URL,
        timeout: TimeInterval
    ) async -> CommandResult {
        await commandRunner.run(
            executable: URL(fileURLWithPath: "/usr/bin/git"),
            arguments: ["-C", sourceDirectory.path] + arguments,
            environment: nil,
            timeout: timeout
        )
    }

    private static func launchInstaller(_ sourceDirectory: URL) throws {
        let installer = sourceDirectory.appendingPathComponent("install.sh")
        guard FileManager.default.isExecutableFile(atPath: installer.path) else {
            throw FleetMeshUpdaterError.missingInstaller
        }
        let logDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/FleetForge", isDirectory: true)
        try FileManager.default.createDirectory(
            at: logDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let logURL = logDirectory.appendingPathComponent("update.log")
        if !FileManager.default.fileExists(atPath: logURL.path) {
            _ = FileManager.default.createFile(
                atPath: logURL.path,
                contents: nil,
                attributes: [.posixPermissions: 0o600]
            )
        }
        let log = try FileHandle(forWritingTo: logURL)
        try log.seekToEnd()

        let process = Process()
        process.executableURL = installer
        process.currentDirectoryURL = sourceDirectory
        process.standardOutput = log
        process.standardError = log
        process.environment = ProcessInfo.processInfo.environment
        try process.run()
    }
}

enum FleetMeshUpdaterError: LocalizedError {
    case missingInstaller

    var errorDescription: String? {
        "The verified FleetMesh source checkout does not contain an executable install.sh."
    }
}
