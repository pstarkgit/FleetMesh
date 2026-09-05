import Darwin
import Foundation

enum DoctorDisposition: String, Sendable {
    case repairable
    case protected
    case manual

    var label: String {
        switch self {
        case .repairable: "Ready to repair"
        case .protected: "Protected"
        case .manual: "Decision required"
        }
    }
}

struct DoctorFinding: Identifiable, Hashable, Sendable {
    let drift: ComponentDrift
    let disposition: DoctorDisposition
    let title: String
    let detail: String
    let recipe: DoctorRecipe?

    var id: String { drift.componentID }
    var canRepair: Bool { disposition == .repairable && recipe != nil }
}

struct DoctorRecipe: Hashable, Sendable {
    let componentID: String
    let homeRelativeExecutable: String
    let arguments: [String]
    let homeRelativeWorkingDirectory: String?
    let timeout: TimeInterval
    let requiresCleanSource: Bool

    init(
        componentID: String,
        homeRelativeExecutable: String,
        arguments: [String] = [],
        homeRelativeWorkingDirectory: String? = nil,
        timeout: TimeInterval = 30 * 60,
        requiresCleanSource: Bool = true
    ) {
        self.componentID = componentID
        self.homeRelativeExecutable = homeRelativeExecutable
        self.arguments = arguments
        self.homeRelativeWorkingDirectory = homeRelativeWorkingDirectory
        self.timeout = timeout
        self.requiresCleanSource = requiresCleanSource
    }

    var displayCommand: String {
        (["~/\(homeRelativeExecutable)"] + arguments).joined(separator: " ")
    }

    func resolve(homeURL: URL) -> DoctorResolvedCommand {
        DoctorResolvedCommand(
            componentID: componentID,
            executableURL: resolve(homeRelativeExecutable, from: homeURL),
            arguments: arguments,
            workingDirectoryURL: homeRelativeWorkingDirectory.map { resolve($0, from: homeURL) },
            timeout: timeout
        )
    }

    private func resolve(_ path: String, from homeURL: URL) -> URL {
        path.split(separator: "/").reduce(homeURL) { partial, component in
            partial.appendingPathComponent(String(component))
        }
    }
}

struct DoctorActionDefinition: Sendable {
    let title: String
    let detail: String
    let recipe: DoctorRecipe?
}

enum DoctorCatalog {
    static func definition(for componentID: String) -> DoctorActionDefinition? {
        definitions[componentID]
    }

    private static let definitions: [String: DoctorActionDefinition] = [
        "ai-continuum": DoctorActionDefinition(
            title: "Install and restore ai-continuum",
            detail: "Use ai-continuum's guarded new-laptop workflow. Its SQLite and WAL files remain on local storage.",
            recipe: DoctorRecipe(
                componentID: "ai-continuum",
                homeRelativeExecutable: "code/ai-continuum/scripts/aic-bootstrap.sh",
                homeRelativeWorkingDirectory: "code/ai-continuum"
            )
        ),
        "authbar": DoctorActionDefinition(
            title: "Deploy the clean AuthBar checkout",
            detail: "Run AuthBar's transactional installer, then compare the newly installed build with the fleet baseline.",
            recipe: DoctorRecipe(
                componentID: "authbar",
                homeRelativeExecutable: "code/authbar/install.sh",
                homeRelativeWorkingDirectory: "code/authbar"
            )
        ),
        "stow": DoctorActionDefinition(
            title: "Deploy the clean Stow checkout",
            detail: "Use Stow's transactional installer, preserve its Accessibility identity, and verify the installed app.",
            recipe: DoctorRecipe(
                componentID: "stow",
                homeRelativeExecutable: "code/Stow/install.sh",
                homeRelativeWorkingDirectory: "code/Stow"
            )
        ),
        "murmr-voice": DoctorActionDefinition(
            title: "Deploy the clean Murmr Voice checkout",
            detail: "Use Murmr Voice's installer, then re-scan its signed app, revision, and running state.",
            recipe: DoctorRecipe(
                componentID: "murmr-voice",
                homeRelativeExecutable: "code/Murmur/install.sh",
                homeRelativeWorkingDirectory: "code/Murmur"
            )
        ),
        "model-bridge": DoctorActionDefinition(
            title: "Deploy the clean Model Bridge checkout",
            detail: "Use Model Bridge's signed package workflow; account validation remains read-only.",
            recipe: DoctorRecipe(
                componentID: "model-bridge",
                homeRelativeExecutable: "code/ModelBridge/install.sh",
                homeRelativeWorkingDirectory: "code/ModelBridge"
            )
        ),
        "harness-sync": DoctorActionDefinition(
            title: "Run the harness-sync bootstrap",
            detail: "Let harness-sync own Claude and OMP links. Per-machine identity and token steps remain manual.",
            recipe: DoctorRecipe(
                componentID: "harness-sync",
                homeRelativeExecutable: "harness-sync/bootstrap.sh",
                homeRelativeWorkingDirectory: "harness-sync"
            )
        ),
        "kiro-crew": DoctorActionDefinition(
            title: "Install Kiro Crew through Builder Toolbox",
            detail: "Use the managed Kiro Crew package, then verify its signed desktop app and runtime evidence.",
            recipe: DoctorRecipe(
                componentID: "kiro-crew",
                homeRelativeExecutable: ".toolbox/bin/toolbox",
                arguments: ["install", "kirocrew"],
                requiresCleanSource: false
            )
        ),
        "codex-desktop": DoctorActionDefinition(
            title: "Install the approved Codex Desktop build",
            detail: "Choose the approved distribution build; FleetMesh will verify the signed bundle afterward.",
            recipe: nil
        ),
        "codex-cli": DoctorActionDefinition(
            title: "Install the approved Codex CLI build",
            detail: "Choose the managed CLI distribution for this Mac, then re-scan its reported version.",
            recipe: nil
        ),
        "codex-themes": DoctorActionDefinition(
            title: "Review Codex theme drift",
            detail: "Choose which named files should win. Doctor never copies or overwrites theme contents automatically.",
            recipe: nil
        ),
        "warp-themes": DoctorActionDefinition(
            title: "Review Warp theme drift",
            detail: "Choose which named files should win. Doctor never copies or overwrites theme contents automatically.",
            recipe: nil
        ),
        "kiro-crew-themes": DoctorActionDefinition(
            title: "Review Kiro Crew theme drift",
            detail: "Choose which native theme files should win. Doctor never overwrites a local theme automatically.",
            recipe: nil
        ),
    ]
}

struct DoctorPlanner: Sendable {
    func findings(
        for assessment: MachineAssessment,
        manifest: FleetManifest?
    ) -> [DoctorFinding] {
        assessment.drifts.compactMap { drift in
            guard drift.state != .aligned
                && drift.state != .notManaged
                && drift.state != .notApplicable else { return nil }
            return finding(
                for: drift,
                observation: assessment.snapshot.component(drift.componentID),
                target: manifest?.target(drift.componentID)
            )
        }
    }

    func finding(
        for drift: ComponentDrift,
        observation: ComponentObservation?,
        target: ManifestTarget?
    ) -> DoctorFinding {
        let definition = DoctorCatalog.definition(for: drift.componentID)

        if drift.state == .localChanges || observation?.sourceDirty == true {
            return DoctorFinding(
                drift: drift,
                disposition: .protected,
                title: "Preserve local \(drift.name) work",
                detail: "The checkout has local changes. Doctor will not pull, reset, build, or install over them.",
                recipe: nil
            )
        }

        if drift.state == .unknown {
            return DoctorFinding(
                drift: drift,
                disposition: .manual,
                title: "Restore \(drift.name) evidence",
                detail: "The current state could not be verified, so Doctor cannot safely choose a repair.",
                recipe: nil
            )
        }

        if let expected = target?.expectedSourceRevision,
           let observed = observation?.sourceRevision,
           !doctorRevisionsMatch(expected, observed) {
            return DoctorFinding(
                drift: drift,
                disposition: .manual,
                title: "Choose the approved \(drift.name) source revision",
                detail: "Doctor will not pull, switch branches, or install from a checkout that differs from the fleet baseline.",
                recipe: nil
            )
        }

        guard let recipe = definition?.recipe else {
            return DoctorFinding(
                drift: drift,
                disposition: .manual,
                title: definition?.title ?? "Review \(drift.name)",
                detail: definition?.detail ?? "This item needs an explicit operator decision before it can be changed.",
                recipe: nil
            )
        }

        return DoctorFinding(
            drift: drift,
            disposition: .repairable,
            title: definition?.title ?? "Repair \(drift.name)",
            detail: definition?.detail ?? "Run the component-owned repair and verify the resulting installed state.",
            recipe: recipe
        )
    }
}

enum DoctorRunOutcome: String, Sendable {
    case running
    case repaired
    case repairedNeedsBaselineReview
    case needsAttention
    case protected
    case failed

    var label: String {
        switch self {
        case .running: "Repairing"
        case .repaired: "Verified"
        case .repairedNeedsBaselineReview: "Machine fixed"
        case .needsAttention: "Still needs attention"
        case .protected: "Stopped safely"
        case .failed: "Repair failed"
        }
    }
}

extension DoctorPlanner {
    func repairedLocalState(
        before: ComponentObservation?,
        after: ComponentObservation?
    ) -> Bool {
        guard let after, after.status == .installed, after.sourceDirty != true else {
            return false
        }

        if before?.status == .missing {
            return true
        }

        guard let beforeInstalled = before?.installedRevision,
              let beforeSource = before?.sourceRevision,
              !doctorRevisionsMatch(beforeInstalled, beforeSource),
              let afterInstalled = after.installedRevision,
              let afterSource = after.sourceRevision else {
            return false
        }
        return doctorRevisionsMatch(afterInstalled, afterSource)
    }
}

private func doctorRevisionsMatch(_ lhs: String, _ rhs: String) -> Bool {
    lhs == rhs || lhs.hasPrefix(rhs) || rhs.hasPrefix(lhs)
}

struct DoctorRunRecord: Identifiable, Hashable, Sendable {
    var id: String { componentID }
    let componentID: String
    let componentName: String
    let outcome: DoctorRunOutcome
    let summary: String
    let output: String?
    let startedAt: Date
    let finishedAt: Date?
}

struct DoctorResolvedCommand: Hashable, Sendable {
    let componentID: String
    let executableURL: URL
    let arguments: [String]
    let workingDirectoryURL: URL?
    let timeout: TimeInterval
}

struct DoctorCommandResult: Hashable, Sendable {
    let exitCode: Int32
    let standardOutputTail: String
    let standardErrorTail: String
    let timedOut: Bool
    let duration: TimeInterval

    var combinedOutput: String? {
        let sections = [standardOutputTail, standardErrorTail]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return sections.isEmpty ? nil : sections.joined(separator: "\n")
    }
}

protocol DoctorCommandRunning: Sendable {
    func run(_ command: DoctorResolvedCommand) async -> DoctorCommandResult
}

struct ProcessDoctorCommandRunner: DoctorCommandRunning {
    private let maximumCapturedBytes = 48 * 1024

    func run(_ command: DoctorResolvedCommand) async -> DoctorCommandResult {
        await Task.detached(priority: .userInitiated) {
            let startedAt = Date()
            let fileManager = FileManager.default
            let scratch = fileManager.temporaryDirectory
                .appendingPathComponent("device-sync-doctor-\(UUID().uuidString)", isDirectory: true)
            let outputURL = scratch.appendingPathComponent("stdout.log")
            let errorURL = scratch.appendingPathComponent("stderr.log")

            do {
                try fileManager.createDirectory(
                    at: scratch,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
                guard fileManager.createFile(atPath: outputURL.path, contents: nil),
                      fileManager.createFile(atPath: errorURL.path, contents: nil) else {
                    throw DoctorRunnerError.couldNotCreateCaptureFiles
                }
                let outputHandle = try FileHandle(forWritingTo: outputURL)
                let errorHandle = try FileHandle(forWritingTo: errorURL)
                defer {
                    try? outputHandle.close()
                    try? errorHandle.close()
                    try? fileManager.removeItem(at: scratch)
                }

                let process = Process()
                process.executableURL = command.executableURL
                process.arguments = command.arguments
                process.currentDirectoryURL = command.workingDirectoryURL
                process.standardInput = FileHandle.nullDevice
                process.standardOutput = outputHandle
                process.standardError = errorHandle
                var environment = ProcessInfo.processInfo.environment
                let home = FileManager.default.homeDirectoryForCurrentUser
                let preferredPath = [
                    home.appendingPathComponent(".toolbox/bin").path,
                    home.appendingPathComponent(".local/bin").path,
                    home.appendingPathComponent(".cargo/bin").path,
                    "/opt/homebrew/bin",
                    "/usr/local/bin",
                    "/Applications/Xcode.app/Contents/Developer/usr/bin",
                    "/usr/bin",
                    "/bin",
                    "/usr/sbin",
                    "/sbin",
                    environment["PATH"],
                ]
                .compactMap { $0 }
                .joined(separator: ":")
                environment["PATH"] = preferredPath
                environment["DEVICE_SYNC_DOCTOR"] = "1"
                process.environment = environment

                try process.run()
                let deadline = Date().addingTimeInterval(command.timeout)
                while process.isRunning && Date() < deadline {
                    try? await Task.sleep(for: .milliseconds(100))
                }

                var timedOut = false
                if process.isRunning {
                    timedOut = true
                    process.terminate()
                    let terminationDeadline = Date().addingTimeInterval(3)
                    while process.isRunning && Date() < terminationDeadline {
                        try? await Task.sleep(for: .milliseconds(100))
                    }
                    if process.isRunning {
                        Darwin.kill(process.processIdentifier, SIGKILL)
                    }
                }
                process.waitUntilExit()
                try? outputHandle.synchronize()
                try? errorHandle.synchronize()

                return DoctorCommandResult(
                    exitCode: process.terminationStatus,
                    standardOutputTail: readTail(outputURL, maximumBytes: maximumCapturedBytes),
                    standardErrorTail: readTail(errorURL, maximumBytes: maximumCapturedBytes),
                    timedOut: timedOut,
                    duration: Date().timeIntervalSince(startedAt)
                )
            } catch {
                try? fileManager.removeItem(at: scratch)
                return DoctorCommandResult(
                    exitCode: -1,
                    standardOutputTail: "",
                    standardErrorTail: error.localizedDescription,
                    timedOut: false,
                    duration: Date().timeIntervalSince(startedAt)
                )
            }
        }.value
    }

    private func readTail(_ url: URL, maximumBytes: Int) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let start = size > UInt64(maximumBytes) ? size - UInt64(maximumBytes) : 0
        try? handle.seek(toOffset: start)
        let data = (try? handle.readToEnd()) ?? Data()
        return String(data: data, encoding: .utf8) ?? ""
    }
}

private enum DoctorRunnerError: LocalizedError {
    case couldNotCreateCaptureFiles

    var errorDescription: String? {
        switch self {
        case .couldNotCreateCaptureFiles:
            "Doctor could not create its private output capture files."
        }
    }
}
