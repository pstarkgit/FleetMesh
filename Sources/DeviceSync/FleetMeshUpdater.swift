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
    private let installerRunner: any CommandRunning
    private let updateLogURL: URL

    init(
        sourceDirectory: URL? = FleetMeshUpdater.installedSourceDirectory,
        commandRunner: any CommandRunning = ProcessCommandRunner(),
        installerRunner: any CommandRunning = ProcessCommandRunner(),
        updateLogURL: URL = FleetMeshUpdater.defaultUpdateLogURL
    ) {
        self.sourceDirectory = sourceDirectory
        self.commandRunner = commandRunner
        self.installerRunner = installerRunner
        self.updateLogURL = updateLogURL
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

    static var defaultUpdateLogURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/FleetForge", isDirectory: true)
            .appendingPathComponent("update.log")
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

        let pull = await git(
            ["pull", "--ff-only", "origin", "main"],
            sourceDirectory: sourceDirectory,
            timeout: 30
        )
        guard pull.exitCode == 0, !pull.timedOut else {
            state = .failed("The clean fast-forward update failed. No installer was launched.")
            return
        }

        let installer = sourceDirectory.appendingPathComponent("install.sh")
        guard FileManager.default.isExecutableFile(atPath: installer.path) else {
            state = .failed("The verified FleetMesh checkout has no executable install.sh.")
            return
        }

        state = .updating
        try? prepareUpdateLog()
        let result = await installerRunner.run(
            executable: installer,
            arguments: [],
            environment: ["FLEETMESH_UPDATE": "1"],
            timeout: 30 * 60
        )
        try? persistUpdateLog(result)

        if result.timedOut {
            state = .failed(
                "The installer exceeded 30 minutes and was stopped. \(Self.failureDetail(result)) See ~/Library/Logs/FleetForge/update.log."
            )
        } else if result.exitCode != 0 {
            state = .failed(
                "The installer exited with status \(result.exitCode). \(Self.failureDetail(result)) See ~/Library/Logs/FleetForge/update.log."
            )
        } else {
            // A successful installer normally replaces this process and relaunches
            // FleetMesh before control returns. This state covers test runners and
            // an installer that completed without terminating the old process.
            state = .upToDate(Date())
        }
    }

    private func prepareUpdateLog() throws {
        try FileManager.default.createDirectory(
            at: updateLogURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let header = "FleetMesh update started \(Date().ISO8601Format())\n"
        try Data(header.utf8).write(to: updateLogURL, options: .atomic)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: updateLogURL.path
        )
    }

    private func persistUpdateLog(_ result: CommandResult) throws {
        let output = [result.standardOutput, result.standardError]
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        let body = "exit=\(result.exitCode) timedOut=\(result.timedOut)\n\(output)\n"
        try Data(body.utf8).write(to: updateLogURL, options: .atomic)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: updateLogURL.path
        )
    }

    static func failureDetail(_ result: CommandResult, limit: Int = 1_200) -> String {
        let combined = [result.standardError, result.standardOutput]
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !combined.isEmpty else { return "No installer detail was captured." }
        let tail = String(combined.suffix(limit))
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        return tail
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

}
