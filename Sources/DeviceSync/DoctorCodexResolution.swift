import Foundation
import Darwin

struct DoctorCodexResolutionRequest: Equatable, Sendable {
    let workspaceURL: URL
    let prompt: String
}

struct DoctorCodexTaskLaunch: Equatable, Sendable {
    let threadID: String
    let summary: String?
}

protocol DoctorCodexTaskLaunching: Sendable {
    func launch(_ request: DoctorCodexResolutionRequest) async throws -> DoctorCodexTaskLaunch
}

struct ProcessDoctorCodexTaskLauncher: DoctorCodexTaskLaunching {
    let homeURL: URL
    let completionTimeout: TimeInterval

    init(
        homeURL: URL = FileManager.default.homeDirectoryForCurrentUser,
        completionTimeout: TimeInterval = 30 * 60
    ) {
        self.homeURL = homeURL
        self.completionTimeout = completionTimeout
    }

    func launch(_ request: DoctorCodexResolutionRequest) async throws -> DoctorCodexTaskLaunch {
        try await Task.detached(priority: .utility) {
            let fileManager = FileManager.default
            guard request.workspaceURL.isFileURL,
                  request.workspaceURL.standardizedFileURL.path.hasPrefix("/") else {
                throw DoctorCodexTaskLaunchError.invalidWorkspace
            }
            guard let executable = Self.executableCandidates(homeURL: homeURL).first(where: {
                fileManager.isExecutableFile(atPath: $0.path)
            }) else {
                throw DoctorCodexTaskLaunchError.codexUnavailable
            }

            let root = fileManager.temporaryDirectory.appendingPathComponent(
                "fleetmesh-codex-resolution-\(UUID().uuidString)",
                isDirectory: true
            )
            let outputURL = root.appendingPathComponent("events.jsonl")
            let errorURL = root.appendingPathComponent("stderr.log")
            let process = Process()
            var processGroupID: pid_t?
            do {
                try fileManager.createDirectory(
                    at: root,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
                for url in [outputURL, errorURL] {
                    _ = fileManager.createFile(
                        atPath: url.path,
                        contents: nil,
                        attributes: [.posixPermissions: 0o600]
                    )
                }

                let outputHandle = try FileHandle(forWritingTo: outputURL)
                let errorHandle = try FileHandle(forWritingTo: errorURL)
                let input = Pipe()
                process.executableURL = executable
                process.arguments = Self.arguments(for: request)
                process.currentDirectoryURL = request.workspaceURL
                process.standardInput = input
                process.standardOutput = outputHandle
                process.standardError = errorHandle
                try process.run()
                try? outputHandle.close()
                try? errorHandle.close()
                let processID = process.processIdentifier
                guard process.isRunning, getpgid(processID) == processID else {
                    throw DoctorCodexTaskLaunchError.processIsolationUnavailable
                }
                processGroupID = processID
                try input.fileHandleForWriting.write(contentsOf: Data((request.prompt + "\n").utf8))
                try? input.fileHandleForWriting.close()

                let deadline = Date().addingTimeInterval(completionTimeout)
                var launch: DoctorCodexTaskLaunch?
                var turnStarted = false
                var turnCompleted = false
                var finalSummary: String?
                var failure: String?
                var eventOffset: UInt64 = 0
                var eventRemainder = Data()
                while Date() < deadline {
                    let events = Self.readEvents(
                        from: outputURL,
                        offset: &eventOffset,
                        remainder: &eventRemainder
                    )
                    if launch == nil {
                        launch = events.compactMap(Self.threadLaunch(from:)).first
                    }
                    turnStarted = turnStarted || events.contains(where: Self.isTurnStarted)
                    turnCompleted = turnCompleted || events.contains(where: Self.isTurnCompleted)
                    finalSummary = events.compactMap(Self.agentMessage(from:)).last ?? finalSummary
                    failure = failure ?? events.compactMap(Self.failure(from:)).first
                    if let failure {
                        throw DoctorCodexTaskLaunchError.taskFailed(failure)
                    }
                    if !process.isRunning {
                        if let launch,
                           turnStarted,
                           turnCompleted,
                           process.terminationReason == .exit,
                           process.terminationStatus == 0 {
                            guard let finalSummary else {
                                throw DoctorCodexTaskLaunchError.missingFinalSummary
                            }
                            Self.stopProcessGroup(processGroupID, process: process)
                            try? fileManager.removeItem(at: root)
                            return DoctorCodexTaskLaunch(
                                threadID: launch.threadID,
                                summary: finalSummary
                            )
                        }
                        throw DoctorCodexTaskLaunchError.taskFailed(
                            Self.failureDetail(from: errorURL)
                        )
                    }
                    try? await Task.sleep(for: .milliseconds(100))
                }
                throw DoctorCodexTaskLaunchError.timedOut
            } catch {
                Self.stopProcessGroup(processGroupID, process: process)
                try? fileManager.removeItem(at: root)
                throw error
            }
        }.value
    }

    static func executableCandidates(homeURL: URL) -> [URL] {
        [
            homeURL.appendingPathComponent(".toolbox/bin/codex"),
            homeURL.appendingPathComponent(".local/bin/codex"),
            URL(fileURLWithPath: "/opt/homebrew/bin/codex"),
            URL(fileURLWithPath: "/usr/local/bin/codex"),
        ]
    }

    static func arguments(for request: DoctorCodexResolutionRequest) -> [String] {
        [
            "-a", "never",
            "-m", "openai.gpt-5.6-sol",
            "exec",
            "--json",
            "--sandbox", "workspace-write",
            "--thread-source", "fleetmesh-doctor",
            "-C", request.workspaceURL.standardizedFileURL.path,
            "-",
        ]
    }

    static func threadLaunch(from event: [String: Any]) -> DoctorCodexTaskLaunch? {
        guard event["type"] as? String == "thread.started",
              let threadID = event["thread_id"] as? String,
              validThreadID(threadID) else { return nil }
        return DoctorCodexTaskLaunch(threadID: threadID, summary: nil)
    }

    static func isTurnStarted(_ event: [String: Any]) -> Bool {
        event["type"] as? String == "turn.started"
    }

    static func isTurnCompleted(_ event: [String: Any]) -> Bool {
        event["type"] as? String == "turn.completed"
    }

    static func failure(from event: [String: Any]) -> String? {
        guard event["type"] as? String == "turn.failed" else { return nil }
        if let error = event["error"] as? [String: Any],
           let message = error["message"] as? String {
            return String(message.prefix(300))
        }
        return "Codex could not start the resolution turn."
    }

    static func agentMessage(from event: [String: Any]) -> String? {
        guard event["type"] as? String == "item.completed",
              let item = event["item"] as? [String: Any],
              item["type"] as? String == "agent_message",
              let text = item["text"] as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(12_000))
    }

    static func validThreadID(_ value: String) -> Bool {
        UUID(uuidString: value) != nil
    }

    private static func readEvents(
        from url: URL,
        offset: inout UInt64,
        remainder: inout Data
    ) -> [[String: Any]] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: offset)
            guard let chunk = try handle.read(upToCount: 1_000_000), !chunk.isEmpty else {
                return []
            }
            offset += UInt64(chunk.count)
            var pending = remainder
            pending.append(chunk)
            guard pending.count <= 2_000_000 else {
                remainder.removeAll(keepingCapacity: false)
                return []
            }
            var events: [[String: Any]] = []
            var lineStart = pending.startIndex
            for index in pending.indices where pending[index] == 0x0A {
                let line = pending[lineStart..<index]
                if let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] {
                    events.append(object)
                }
                lineStart = pending.index(after: index)
            }
            remainder = Data(pending[lineStart...])
            return events
        } catch {
            return []
        }
    }

    private static func stopProcessGroup(_ processGroupID: pid_t?, process: Process) {
        if let processGroupID, processGroupID > 1 {
            errno = 0
            let groupExists = kill(-processGroupID, 0) == 0 || errno == EPERM
            guard groupExists else { return }
            _ = kill(-processGroupID, SIGTERM)
            let deadline = Date().addingTimeInterval(2)
            while Date() < deadline {
                errno = 0
                if kill(-processGroupID, 0) == -1, errno == ESRCH { return }
                Thread.sleep(forTimeInterval: 0.05)
            }
            _ = kill(-processGroupID, SIGKILL)
        } else if process.isRunning {
            process.terminate()
        }
    }

    private static func failureDetail(from url: URL) -> String {
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data.suffix(8_192), encoding: .utf8) else {
            return "Codex exited before creating a resolution task."
        }
        return text.split(whereSeparator: \Character.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .last(where: { !$0.isEmpty })
            .map { String($0.prefix(300)) }
            ?? "Codex exited before creating a resolution task."
    }
}

enum DoctorCodexTaskLaunchError: LocalizedError {
    case invalidWorkspace
    case codexUnavailable
    case processIsolationUnavailable
    case taskFailed(String)
    case missingFinalSummary
    case timedOut

    var errorDescription: String? {
        switch self {
        case .invalidWorkspace:
            "The protected checkout path is not a valid local workspace."
        case .codexUnavailable:
            "The Codex CLI is not installed in a supported location."
        case .processIsolationUnavailable:
            "FleetMesh could not isolate the Codex task for safe timeout cleanup. No task was left running."
        case .taskFailed(let detail):
            "Codex did not complete the resolution task: \(detail)"
        case .missingFinalSummary:
            "Codex completed without a final review summary, so FleetMesh did not report success. No fleet baseline changed."
        case .timedOut:
            "Codex did not finish the resolution task within 30 minutes. FleetMesh stopped its task group, and no fleet baseline changed."
        }
    }
}

enum DoctorCodexResolution {
    static func request(
        for finding: DoctorFinding,
        homeURL: URL
    ) -> DoctorCodexResolutionRequest? {
        guard finding.disposition == .protected,
              finding.drift.state == .localChanges,
              let workspaceURL = FleetComponentPaths.sourceCheckout(
                componentID: finding.id,
                homeURL: homeURL
              ) else { return nil }

        let componentName: String
        switch finding.id {
        case "harness-sync": componentName = "Harness Sync"
        default: componentName = finding.id
        }

        return DoctorCodexResolutionRequest(
            workspaceURL: workspaceURL,
            prompt: prompt(componentName: componentName)
        )
    }

    static func prompt(componentName: String) -> String {
        """
        Resolve FleetMesh's protected \(componentName) checkout safely and completely.

        Required outcome:
        1. Start read-only. Inspect repository instructions, status, tracked diffs, untracked files, branch/upstream state, and product-owned validation commands.
        2. Classify every change as intentional durable configuration, generated/transient backup, or uncertain. Preserve all user work. Never use reset, checkout, clean, stash, amend, force push, or destructive deletion to make the tree look clean.
        3. Commit intentional durable changes on a focused codex/ branch after relevant tests and checks pass. Inspect likely backup files before removing them; preserve anything uncertain outside the repository instead of deleting it.
        4. Do not change FleetMesh's baseline merely to hide an uncommitted checkout. Do not push, create or merge a pull request, or run a configuration-changing bootstrap/sync workflow unless Patrick explicitly authorizes that action in this task.
        5. When the checkout is clean and the intentional work is committed, summarize exactly what changed and tell Patrick to return to FleetMesh and choose Scan again. If the newly committed configuration fingerprint differs, FleetMesh baseline adoption is a separate explicit decision after review.
        """
    }

}
