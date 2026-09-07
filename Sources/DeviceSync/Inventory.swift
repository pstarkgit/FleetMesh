import CryptoKit
import Darwin
import Foundation

struct CommandResult: Sendable {
    let exitCode: Int32
    let standardOutput: String
    let standardError: String
    let timedOut: Bool
}

protocol CommandRunning: Sendable {
    func run(
        executable: URL,
        arguments: [String],
        environment: [String: String]?,
        timeout: TimeInterval?
    ) async -> CommandResult
}

extension CommandRunning {
    func run(
        executable: URL,
        arguments: [String],
        environment: [String: String]?
    ) async -> CommandResult {
        await run(
            executable: executable,
            arguments: arguments,
            environment: environment,
            timeout: nil
        )
    }
}

struct ProcessCommandRunner: CommandRunning {
    static let maximumCapturedBytes = 1_048_576

    func run(
        executable: URL,
        arguments: [String],
        environment: [String: String]? = nil,
        timeout: TimeInterval? = nil
    ) async -> CommandResult {
        let worker = Task.detached(priority: .utility) {
            Self.cleanupStaleCaptureDirectories()

            let output = BoundedPipeCapture(limit: Self.maximumCapturedBytes)
            let standardErrorCapture = BoundedPipeCapture(limit: Self.maximumCapturedBytes)
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            process.standardOutput = output.pipe
            process.standardError = standardErrorCapture.pipe
            if let environment {
                process.environment = ProcessInfo.processInfo.environment.merging(environment) {
                    _, override in override
                }
            }

            output.start()
            standardErrorCapture.start()
            do {
                try process.run()
                output.closeParentWriter()
                standardErrorCapture.closeParentWriter()

                var timedOut = false
                let deadline = Date().addingTimeInterval(timeout ?? 5)
                while process.isRunning, Date() < deadline, !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(20))
                }
                if process.isRunning {
                    timedOut = !Task.isCancelled
                    process.terminate()
                    let terminationDeadline = Date().addingTimeInterval(1)
                    while process.isRunning, Date() < terminationDeadline {
                        try? await Task.sleep(for: .milliseconds(20))
                    }
                    if process.isRunning {
                        Darwin.kill(process.processIdentifier, SIGKILL)
                    }
                }
                if process.isRunning {
                    let killDeadline = Date().addingTimeInterval(1)
                    while process.isRunning, Date() < killDeadline {
                        try? await Task.sleep(for: .milliseconds(20))
                    }
                }
                if !process.isRunning {
                    process.waitUntilExit()
                }
                output.finish()
                standardErrorCapture.finish()
                return CommandResult(
                    exitCode: process.isRunning ? -1 : process.terminationStatus,
                    standardOutput: output.stringValue,
                    standardError: Task.isCancelled
                        ? "Command cancelled."
                        : standardErrorCapture.stringValue,
                    timedOut: timedOut
                )
            } catch let launchError {
                if process.isRunning {
                    process.terminate()
                    Darwin.kill(process.processIdentifier, SIGKILL)
                }
                output.closeParentWriter()
                standardErrorCapture.closeParentWriter()
                output.finish()
                standardErrorCapture.finish()
                return CommandResult(
                    exitCode: -1,
                    standardOutput: output.stringValue,
                    standardError: launchError.localizedDescription,
                    timedOut: false
                )
            }
        }
        return await withTaskCancellationHandler {
            await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    private static func cleanupStaleCaptureDirectories(
        olderThan age: TimeInterval = 7 * 24 * 60 * 60
    ) {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
        guard let entries = try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        let now = Date()
        for entry in entries where entry.lastPathComponent.hasPrefix("fleetmesh-command-") {
            guard let values = try? entry.resourceValues(
                forKeys: [.isDirectoryKey, .contentModificationDateKey]
            ), values.isDirectory == true,
            let modified = values.contentModificationDate,
            now.timeIntervalSince(modified) >= age else { continue }
            try? fileManager.removeItem(at: entry)
        }
    }
}

private final class BoundedPipeCapture: @unchecked Sendable {
    let pipe = Pipe()

    private let limit: Int
    private let lock = NSLock()
    private let completion = DispatchSemaphore(value: 0)
    private var buffer = Data()
    private var completed = false

    init(limit: Int) {
        self.limit = limit
    }

    func start() {
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            guard let self else { return }
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                self.markCompleted()
                return
            }
            self.append(chunk)
        }
    }

    func closeParentWriter() {
        try? pipe.fileHandleForWriting.close()
    }

    func finish() {
        closeParentWriter()
        if completion.wait(timeout: .now() + 1) == .timedOut {
            pipe.fileHandleForReading.readabilityHandler = nil
            markCompleted()
        }
        try? pipe.fileHandleForReading.close()
    }

    var stringValue: String {
        lock.lock()
        let data = buffer
        lock.unlock()
        return String(data: data, encoding: .utf8) ?? ""
    }

    private func append(_ data: Data) {
        lock.lock()
        let remaining = max(0, limit - buffer.count)
        if remaining > 0 {
            buffer.append(data.prefix(remaining))
        }
        lock.unlock()
    }

    private func markCompleted() {
        lock.lock()
        let shouldSignal = !completed
        completed = true
        lock.unlock()
        if shouldSignal {
            completion.signal()
        }
    }
}

struct AppProbeDefinition: Sendable {
    let id: String
    let name: String
    let bundleIdentifiers: [String]
    let preferredPaths: [String]
    let sourceRelativePath: String?
    let commitKeys: [String]
    let processNames: [String]
    let managedVersionProbe: ManagedVersionProbeDefinition?
    let sourceVersionProbe: SourceVersionProbeDefinition?
    let productVersionProbe: ProductVersionProbeDefinition?

    init(
        id: String,
        name: String,
        bundleIdentifiers: [String],
        preferredPaths: [String],
        sourceRelativePath: String?,
        commitKeys: [String],
        processNames: [String],
        managedVersionProbe: ManagedVersionProbeDefinition? = nil,
        sourceVersionProbe: SourceVersionProbeDefinition? = nil,
        productVersionProbe: ProductVersionProbeDefinition? = nil
    ) {
        self.id = id
        self.name = name
        self.bundleIdentifiers = bundleIdentifiers
        self.preferredPaths = preferredPaths
        self.sourceRelativePath = sourceRelativePath
        self.commitKeys = commitKeys
        self.processNames = processNames
        self.managedVersionProbe = managedVersionProbe
        self.sourceVersionProbe = sourceVersionProbe
        self.productVersionProbe = productVersionProbe
    }
}

struct ManagedVersionProbeDefinition: Sendable {
    let executableCandidates: [String]
    let arguments: [String]
}

struct CLIProbeDefinition: Sendable {
    let id: String
    let name: String
    let executableCandidates: [String]
    let versionArguments: [String]
    let sourceRelativePath: String?
    let sourceVersionProbe: SourceVersionProbeDefinition?
}

enum SourceVersionFormat: Sendable {
    case swiftStaticCurrent
    case cargoPackage
    case packageJSON
}

struct SourceVersionProbeDefinition: Sendable {
    let relativePath: String
    let format: SourceVersionFormat
}

enum ProductVersionProbeDefinition: Sendable {
    case sparkleAppcast(URL)
}

struct ThemeProbeDefinition: Sendable {
    let id: String
    let name: String
    let relativeDirectory: String
    let allowedExtensions: Set<String>
    let recursive: Bool

    init(
        id: String,
        name: String,
        relativeDirectory: String,
        allowedExtensions: Set<String>,
        recursive: Bool = false
    ) {
        self.id = id
        self.name = name
        self.relativeDirectory = relativeDirectory
        self.allowedExtensions = allowedExtensions
        self.recursive = recursive
    }
}

protocol InventoryCapturing: Sendable {
    func capture(machineID: String, displayName: String?) async -> MachineSnapshot
    func captureForDoctor(
        machineID: String,
        displayName: String?,
        componentID: String
    ) async -> MachineSnapshot
}

extension InventoryCapturing {
    func captureForDoctor(
        machineID: String,
        displayName: String?,
        componentID: String
    ) async -> MachineSnapshot {
        await capture(machineID: machineID, displayName: displayName)
    }
}

struct InventoryService: Sendable {
    static let kiroCrewThemesRelativeDirectory = ".kiro/crew/workspace/themes"

    let homeURL: URL
    let commandRunner: any CommandRunning

    private var fileManager: FileManager { .default }

    init(
        homeURL: URL = FileManager.default.homeDirectoryForCurrentUser,
        commandRunner: any CommandRunning = ProcessCommandRunner()
    ) {
        self.homeURL = homeURL
        self.commandRunner = commandRunner
    }

    func capture(machineID: String, displayName: String? = nil) async -> MachineSnapshot {
        let context = await captureContext()
        async let apps = probeApplications(context: context)
        async let clis = probeCLIs(context: context)
        async let themes = probeThemes()
        async let harness = probeHarnessSync()

        let components = await (apps + clis + themes + [harness])
            .sorted { lhs, rhs in
                if lhs.kind != rhs.kind { return lhs.kind.rawValue < rhs.kind.rawValue }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
        let observedName: String
        if let configured = displayName?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty {
            observedName = configured
        } else {
            observedName = await computerName()
        }

        return MachineSnapshot(
            machineID: machineID,
            name: observedName,
            hostName: await localHostName(),
            modelIdentifier: sysctlString("hw.model") ?? "Unknown model",
            architecture: architecture(),
            osVersion: operatingSystemVersion(),
            osBuild: await osBuild(),
            components: components
        )
    }

    private struct CaptureContext: Sendable {
        let applicationDiscovery: ApplicationDiscovery
        let runningProcessNames: Set<String>?
        let runningApplicationBundles: [String: [URL]]
    }

    struct RunningProcessInventory: Sendable {
        let names: Set<String>
        let applicationBundles: [String: [URL]]
    }

    private struct ApplicationDiscovery: Sendable {
        let applicationsByBundleID: [String: URL]
        let isComplete: Bool
    }

    private func captureContext() async -> CaptureContext {
        async let applications = Task.detached(priority: .utility) {
            Self.applicationIndex(homeURL: homeURL)
        }.value
        async let processes = commandRunner.run(
            executable: URL(fileURLWithPath: "/bin/ps"),
            arguments: ["-axo", "ucomm=,comm="],
            environment: nil,
            timeout: 5
        )
        let (applicationIndex, processResult) = await (applications, processes)
        let processInventory: RunningProcessInventory?
        if processResult.exitCode == 0, !processResult.timedOut {
            processInventory = Self.parseRunningProcesses(processResult.standardOutput)
        } else {
            processInventory = nil
        }
        return CaptureContext(
            applicationDiscovery: applicationIndex,
            runningProcessNames: processInventory?.names,
            runningApplicationBundles: processInventory?.applicationBundles ?? [:]
        )
    }

    static func parseRunningProcesses(_ output: String) -> RunningProcessInventory {
        var names: Set<String> = []
        var bundles: [String: [URL]] = [:]
        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let fields = rawLine.split(
                maxSplits: 1,
                omittingEmptySubsequences: true,
                whereSeparator: { $0.isWhitespace }
            )
            guard let rawName = fields.first else { continue }
            let name = String(rawName)
            names.insert(name)
            guard fields.count == 2,
                  let bundleURL = appBundleURL(
                    executablePath: String(fields[1]).trimmingCharacters(
                        in: .whitespacesAndNewlines
                    )
                  ) else { continue }
            var candidates = bundles[name, default: []]
            if !candidates.contains(bundleURL) {
                candidates.append(bundleURL)
            }
            bundles[name] = candidates
        }
        return RunningProcessInventory(names: names, applicationBundles: bundles)
    }

    static func appBundleURL(executablePath: String) -> URL? {
        guard let marker = executablePath.range(
            of: ".app/Contents/MacOS/",
            options: .caseInsensitive
        ) else { return nil }
        let bundlePath = String(executablePath[..<marker.lowerBound]) + ".app"
        guard bundlePath.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: bundlePath).standardizedFileURL
    }

    private static func applicationIndex(homeURL: URL) -> ApplicationDiscovery {
        var result: [String: URL] = [:]
        let roots = [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            homeURL.appendingPathComponent("Applications", isDirectory: true),
        ]
        var isComplete = true
        for root in roots {
            let resourceValues = try? root.resourceValues(forKeys: [.isDirectoryKey])
            if resourceValues?.isDirectory != true {
                // A root that does not exist cannot contain an application and
                // is not a discovery failure. An existing unreadable root is.
                if FileManager.default.fileExists(atPath: root.path) { isComplete = false }
                continue
            }
            guard let entries = try? FileManager.default.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else {
                isComplete = false
                continue
            }
            for entry in entries where entry.pathExtension == "app" {
                guard let bundle = Bundle(url: entry),
                      let identifier = bundle.bundleIdentifier,
                      bundle.infoDictionary != nil else {
                    isComplete = false
                    continue
                }
                result[identifier] = result[identifier] ?? entry
            }
        }
        return ApplicationDiscovery(
            applicationsByBundleID: result,
            isComplete: isComplete
        )
    }

    private func probeApplications(context: CaptureContext) async -> [ComponentObservation] {
        let definitions = Self.applicationDefinitions

        return await withTaskGroup(of: ComponentObservation.self) { group in
            for definition in definitions {
                group.addTask { await probeApplication(definition, context: context) }
            }
            var observations: [ComponentObservation] = []
            for await observation in group { observations.append(observation) }
            return observations
        }
    }

    static let applicationDefinitions = [
            AppProbeDefinition(
                id: FleetMeshIdentity.componentID,
                name: FleetMeshIdentity.productName,
                bundleIdentifiers: [FleetMeshIdentity.bundleIdentifier],
                preferredPaths: [
                    FleetMeshIdentity.installedAppPath,
                    FleetMeshIdentity.formerFleetForgeAppPath,
                    FleetMeshIdentity.legacyInstalledAppPath,
                ],
                sourceRelativePath: "code/device-sync",
                commitKeys: ["DSCommit"],
                processNames: [FleetMeshIdentity.executableName],
                sourceVersionProbe: SourceVersionProbeDefinition(
                    relativePath: "Sources/DeviceSync/DeviceSyncVersion.swift",
                    format: .swiftStaticCurrent
                )
            ),
            AppProbeDefinition(
                id: "authbar",
                name: "AuthBar",
                bundleIdentifiers: ["dev.starkpat.authbar"],
                preferredPaths: ["/Applications/AuthBar.app"],
                sourceRelativePath: "code/authbar",
                commitKeys: ["ABCommit"],
                processNames: ["AuthBar"],
                sourceVersionProbe: SourceVersionProbeDefinition(
                    relativePath: "Sources/AuthBar/AuthBarVersion.swift",
                    format: .swiftStaticCurrent
                )
            ),
            AppProbeDefinition(
                id: "stow",
                name: "Stow",
                bundleIdentifiers: ["dev.starkpat.stow"],
                preferredPaths: ["/Applications/Stow.app"],
                sourceRelativePath: "code/Stow",
                commitKeys: ["STCommit"],
                processNames: ["Stow"],
                sourceVersionProbe: SourceVersionProbeDefinition(
                    relativePath: "Sources/Stow/StowVersion.swift",
                    format: .swiftStaticCurrent
                )
            ),
            AppProbeDefinition(
                id: "murmr-voice",
                name: "Murmr Voice",
                bundleIdentifiers: ["ai.murmr.labs.voice", "dev.gsdai.murmur.ios"],
                preferredPaths: ["/Applications/Murmr Voice.app"],
                sourceRelativePath: "code/Murmur",
                commitKeys: ["MRCommit"],
                processNames: ["Murmur", "Murmr Voice"],
                sourceVersionProbe: SourceVersionProbeDefinition(
                    relativePath: "Sources/Murmur/MurmurVersion.swift",
                    format: .swiftStaticCurrent
                ),
                productVersionProbe: .sparkleAppcast(
                    URL(string: "https://murmr-ai.com/updates/macos/stable/appcast.xml")!
                )
            ),
            AppProbeDefinition(
                id: "model-bridge",
                name: "Model Bridge",
                bundleIdentifiers: ["com.amazon.modelbridge"],
                preferredPaths: [
                    "~/Applications/Model Bridge.app",
                    "/Applications/Model Bridge.app",
                ],
                sourceRelativePath: "code/ModelBridge",
                commitKeys: [],
                processNames: ["Model Bridge"],
                sourceVersionProbe: SourceVersionProbeDefinition(
                    relativePath: "package.json",
                    format: .packageJSON
                )
            ),
            AppProbeDefinition(
                id: "codex-desktop",
                name: "Codex Desktop",
                bundleIdentifiers: ["com.openai.codex"],
                preferredPaths: ["/Applications/ChatGPT.app", "/Applications/Codex.app"],
                sourceRelativePath: nil,
                commitKeys: [],
                processNames: ["ChatGPT", "Codex"]
            ),
            AppProbeDefinition(
                id: "codex-voice",
                name: "Codex Voice",
                bundleIdentifiers: ["dev.starkpat.codexvoice"],
                preferredPaths: ["/Applications/Codex Voice.app"],
                sourceRelativePath: "code/CodexVoice",
                commitKeys: [],
                processNames: ["CodexVoice", "Codex Voice"]
            ),
            AppProbeDefinition(
                id: "kiro-crew",
                name: "Kiro Crew",
                bundleIdentifiers: ["com.amazon.kiro.crew"],
                preferredPaths: [
                    "~/Library/Application Support/KiroCrewInternal/KiroCrew.app",
                    "/Applications/KiroCrew.app",
                ],
                sourceRelativePath: nil,
                commitKeys: [],
                processNames: ["KiroCrew"],
                managedVersionProbe: ManagedVersionProbeDefinition(
                    executableCandidates: [
                        "~/.toolbox/bin/kirocrew",
                        "~/.local/bin/kirocrew",
                    ],
                    arguments: ["--version"]
                )
            ),
        ]

    private func probeApplication(
        _ definition: AppProbeDefinition,
        context: CaptureContext
    ) async -> ComponentObservation {
        let appURL = locateApplication(
            definition,
            applicationsByBundleID: context.applicationDiscovery.applicationsByBundleID,
            runningApplicationBundles: context.runningApplicationBundles
        )
        async let productVersionCheck = probeProductVersion(definition.productVersionProbe)
        let isRunning = context.runningProcessNames.map { runningNames in
            definition.processNames.contains { runningNames.contains($0) }
        }

        if appURL == nil, !context.applicationDiscovery.isComplete {
            return ComponentObservation(
                id: definition.id,
                name: definition.name,
                kind: .application,
                status: .unknown,
                productVersionCheck: await productVersionCheck,
                isRunning: isRunning,
                evidence: "Application discovery could not be completed."
            )
        }

        guard let appURL else {
            return ComponentObservation(
                id: definition.id,
                name: definition.name,
                kind: .application,
                status: .missing,
                productVersionCheck: await productVersionCheck,
                isRunning: isRunning,
                evidence: "No matching application bundle was found."
            )
        }

        guard let bundle = Bundle(url: appURL),
              let info = bundle.infoDictionary else {
            return ComponentObservation(
                id: definition.id,
                name: definition.name,
                kind: .application,
                status: .unknown,
                productVersionCheck: await productVersionCheck,
                isRunning: isRunning,
                evidence: "A matching application exists, but its bundle metadata could not be read."
            )
        }

        let installedCommit = definition.commitKeys.compactMap {
            info[$0] as? String
        }.first { !$0.isEmpty }
        let managedVersion = await probeManagedVersion(definition.managedVersionProbe)
        let location = installationLocation(for: appURL)

        return ComponentObservation(
            id: definition.id,
            name: definition.name,
            kind: .application,
            status: .installed,
            installedVersion: managedVersion
                ?? info["CFBundleShortVersionString"] as? String,
            build: info["CFBundleVersion"] as? String,
            installedRevision: installedCommit,
            productVersionCheck: await productVersionCheck,
            installationLocation: location,
            isRunning: isRunning,
            evidence: Self.applicationEvidence(
                managedVersion: managedVersion,
                installationLocation: location
            )
        )
    }

    /// Shared observations describe how version evidence was obtained without
    /// publishing a bundle identifier. Developer namespaces can contain a
    /// username and are not needed for fleet drift evaluation.
    static func applicationEvidence(
        managedVersion: String?,
        installationLocation: ApplicationInstallationLocation? = nil
    ) -> String {
        let versionEvidence = managedVersion == nil
            ? "version read from its signed Info.plist"
            : "version returned by its managed executable"
        switch installationLocation {
        case .runningBundle:
            return "Installed application discovered from its matching running bundle; \(versionEvidence)."
        case .systemApplications, .userApplications:
            return "Installed application; \(versionEvidence)."
        case nil:
            return "Installed application; \(versionEvidence)."
        }
    }

    private func probeManagedVersion(
        _ definition: ManagedVersionProbeDefinition?
    ) async -> String? {
        guard let definition,
              let executable = definition.executableCandidates
                .map(expandedURL)
                .first(where: { fileManager.isExecutableFile(atPath: $0.path) }) else {
            return nil
        }
        let result = await commandRunner.run(
            executable: executable,
            arguments: definition.arguments,
            environment: nil,
            timeout: 5
        )
        guard result.exitCode == 0 else { return nil }
        return parseVersion(
            from: (result.standardOutput + " " + result.standardError)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    private func probeProductVersion(
        _ definition: ProductVersionProbeDefinition?
    ) async -> ProductVersionCheck? {
        guard let definition else { return nil }
        switch definition {
        case .sparkleAppcast(let url):
            let result = await commandRunner.run(
                executable: URL(fileURLWithPath: "/usr/bin/curl"),
                arguments: [
                    "--fail", "--silent", "--show-error", "--location",
                    "--proto", "=https", "--tlsv1.2",
                    "--max-time", "5", "--max-filesize", "262144",
                    url.absoluteString,
                ],
                environment: nil,
                timeout: 7
            )
            guard result.exitCode == 0,
                  !result.timedOut,
                  let version = Self.parseSparkleAppcast(Data(result.standardOutput.utf8)) else {
                return .unavailable(authority: .sparkleAppcast)
            }
            return .verified(version: version, authority: .sparkleAppcast)
        }
    }

    static let cliDefinitions = [
            CLIProbeDefinition(
                id: "ai-continuum",
                name: "ai-continuum",
                executableCandidates: [
                    "~/.local/bin/ai-continuum-ctl",
                    "/opt/homebrew/bin/ai-continuum-ctl",
                    "/usr/local/bin/ai-continuum-ctl",
                ],
                versionArguments: ["--version"],
                sourceRelativePath: "code/ai-continuum",
                sourceVersionProbe: SourceVersionProbeDefinition(
                    relativePath: "Cargo.toml",
                    format: .cargoPackage
                )
            ),
            CLIProbeDefinition(
                id: "codex-cli",
                name: "Codex CLI",
                executableCandidates: [
                    "~/.toolbox/bin/codex",
                    "~/.local/bin/codex",
                    "/opt/homebrew/bin/codex",
                    "/usr/local/bin/codex",
                ],
                versionArguments: ["--version"],
                sourceRelativePath: nil,
                sourceVersionProbe: nil
            ),
        ]

    private func probeCLIs(context: CaptureContext) async -> [ComponentObservation] {
        let definitions = Self.cliDefinitions

        return await withTaskGroup(of: ComponentObservation.self) { group in
            for definition in definitions {
                group.addTask { await probeCLI(definition, context: context) }
            }
            var observations: [ComponentObservation] = []
            for await observation in group { observations.append(observation) }
            return observations
        }
    }

    private func probeCLI(
        _ definition: CLIProbeDefinition,
        context: CaptureContext
    ) async -> ComponentObservation {
        guard let executable = definition.executableCandidates
            .map(expandedURL)
            .first(where: { fileManager.isExecutableFile(atPath: $0.path) }) else {
            return ComponentObservation(
                id: definition.id,
                name: definition.name,
                kind: definition.id == "ai-continuum" ? .service : .commandLineTool,
                status: .missing,
                evidence: "No executable was found in the managed candidate locations."
            )
        }

        let result = await commandRunner.run(
            executable: executable,
            arguments: definition.versionArguments,
            environment: nil,
            timeout: 5
        )
        let output = (result.standardOutput + " " + result.standardError)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let version = parseVersion(from: output)

        return ComponentObservation(
            id: definition.id,
            name: definition.name,
            kind: definition.id == "ai-continuum" ? .service : .commandLineTool,
            status: result.exitCode == 0 ? .installed : .unknown,
            installedVersion: version,
            isRunning: definition.id == "ai-continuum"
                ? context.runningProcessNames.map { $0.contains("ai-continuum-daemon") }
                : nil,
            evidence: result.exitCode == 0
                ? "Version returned by the installed executable."
                : "The executable exists but its version command failed."
        )
    }

    private func probeThemes() async -> [ComponentObservation] {
        let definitions = [
            ThemeProbeDefinition(
                id: "codex-themes",
                name: "Codex themes",
                relativeDirectory: "CodexThemes",
                allowedExtensions: ["json"]
            ),
            ThemeProbeDefinition(
                id: "warp-themes",
                name: "Warp themes",
                relativeDirectory: ".warp/themes",
                allowedExtensions: ["yaml", "yml"]
            ),
            ThemeProbeDefinition(
                id: "kiro-crew-themes",
                name: "Kiro Crew themes",
                relativeDirectory: Self.kiroCrewThemesRelativeDirectory,
                allowedExtensions: ["json"],
                recursive: true
            ),
        ]

        return definitions.map(probeTheme)
    }

    private func probeTheme(_ definition: ThemeProbeDefinition) -> ComponentObservation {
        let directory = homeURL.appendingPathComponent(
            definition.relativeDirectory,
            isDirectory: true
        )
        guard fileManager.fileExists(atPath: directory.path) else {
            return ComponentObservation(
                id: definition.id,
                name: definition.name,
                kind: .theme,
                status: .missing,
                items: [],
                evidence: "The managed theme directory does not exist."
            )
        }

        let candidates: [URL]
        if definition.recursive {
            let enumerator = fileManager.enumerator(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            )
            candidates = enumerator?.allObjects.compactMap { $0 as? URL } ?? []
        } else {
            candidates = (try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )) ?? []
        }
        let files = candidates.filter {
            definition.allowedExtensions.contains($0.pathExtension.lowercased())
                && ((try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) ?? false)
        }.sorted {
            relativePath(of: $0, under: directory) < relativePath(of: $1, under: directory)
        }

        let fingerprint = aggregateFingerprint(files: files, relativeTo: directory)
        return ComponentObservation(
            id: definition.id,
            name: definition.name,
            kind: .theme,
            status: files.isEmpty ? .missing : .installed,
            configurationFingerprint: fingerprint,
            items: files.map { relativePath(of: $0, under: directory) },
            evidence: "Fingerprint covers \(files.count) theme file(s); file contents are not published."
        )
    }

    private func probeHarnessSync() async -> ComponentObservation {
        let homeCheckout = await sourceState(relativePath: "../harness-sync")
        let source: SourceState?
        if let homeCheckout {
            source = homeCheckout
        } else {
            source = await sourceState(relativePath: "code/harness-sync")
        }

        guard let source else {
            return ComponentObservation(
                id: "harness-sync",
                name: "Harness Sync",
                kind: .configuration,
                status: .missing,
                evidence: "The harness-sync checkout was not found."
            )
        }

        return ComponentObservation(
            id: "harness-sync",
            name: "Harness Sync",
            kind: .configuration,
            status: .installed,
            sourceRevision: source.revision,
            sourceBranch: source.branch,
            sourceDirty: source.dirty,
            configurationFingerprint: source.revision,
            evidence: "Revision and local-change posture read from the harness-sync checkout."
        )
    }

    func locateApplication(
        _ definition: AppProbeDefinition,
        applicationsByBundleID: [String: URL],
        runningApplicationBundles: [String: [URL]]
    ) -> URL? {
        for path in definition.preferredPaths {
            let url = expandedURL(path)
            if fileManager.fileExists(atPath: url.path) { return url }
        }

        for identifier in definition.bundleIdentifiers {
            if let indexed = applicationsByBundleID[identifier] { return indexed }
        }

        for processName in definition.processNames {
            for candidate in runningApplicationBundles[processName] ?? [] {
                guard fileManager.fileExists(atPath: candidate.path),
                      let bundle = Bundle(url: candidate),
                      let identifier = bundle.bundleIdentifier,
                      definition.bundleIdentifiers.contains(identifier),
                      bundle.infoDictionary != nil else { continue }
                return candidate
            }
        }
        return nil
    }

    func installationLocation(for appURL: URL) -> ApplicationInstallationLocation {
        let path = appURL.standardizedFileURL.path
        if path.hasPrefix("/Applications/") {
            return .systemApplications
        }
        let userApplications = homeURL
            .appendingPathComponent("Applications", isDirectory: true)
            .standardizedFileURL.path + "/"
        if path.hasPrefix(userApplications) {
            return .userApplications
        }
        return .runningBundle
    }

    private struct SourceState: Sendable {
        let revision: String
        let tree: String
        let branch: String?
        let dirty: Bool
        let version: String?
    }

    private func sourceState(
        relativePath: String?,
        versionProbe: SourceVersionProbeDefinition? = nil
    ) async -> SourceState? {
        guard let relativePath else { return nil }
        let url: URL
        if relativePath.hasPrefix("../") {
            url = homeURL.appendingPathComponent(String(relativePath.dropFirst(3)))
        } else {
            url = homeURL.appendingPathComponent(relativePath)
        }
        let git = url.appendingPathComponent(".git")
        guard fileManager.fileExists(atPath: git.path) else { return nil }

        let revisionResult = await gitCommand(["-C", url.path, "rev-parse", "HEAD"])
        guard revisionResult.exitCode == 0, !revisionResult.timedOut else { return nil }
        let revision = revisionResult.standardOutput
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard revision.count == 40,
              revision.unicodeScalars.allSatisfy(
                CharacterSet(charactersIn: "0123456789abcdefABCDEF").contains
              ) else { return nil }
        let branchResult = await gitCommand(["-C", url.path, "branch", "--show-current"])
        let statusResult = await gitCommand(["-C", url.path, "status", "--porcelain"])
        let treeResult = await gitCommand(["-C", url.path, "rev-parse", "\(revision)^{tree}"])
        guard branchResult.exitCode == 0, !branchResult.timedOut,
              statusResult.exitCode == 0, !statusResult.timedOut,
              treeResult.exitCode == 0, !treeResult.timedOut else { return nil }
        guard let tree = validFullObjectID(treeResult.standardOutput) else { return nil }
        let sourceVersion: String?
        if let versionProbe {
            let versionResult = await gitCommand([
                "-C", url.path, "show", "\(revision):\(versionProbe.relativePath)",
            ])
            sourceVersion = versionResult.exitCode == 0 && !versionResult.timedOut
                ? Self.parseSourceVersion(
                    data: Data(versionResult.standardOutput.utf8),
                    format: versionProbe.format
                )
                : nil
        } else {
            sourceVersion = nil
        }
        let finalRevisionResult = await gitCommand(["-C", url.path, "rev-parse", "HEAD"])
        let finalStatusResult = await gitCommand(["-C", url.path, "status", "--porcelain"])
        let finalRevision = finalRevisionResult.standardOutput
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let initialStatus = statusResult.standardOutput
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let finalStatus = finalStatusResult.standardOutput
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard finalRevisionResult.exitCode == 0, !finalRevisionResult.timedOut,
              finalStatusResult.exitCode == 0, !finalStatusResult.timedOut,
              finalRevision == revision,
              finalStatus == initialStatus else { return nil }
        return SourceState(
            revision: String(revision.prefix(12)),
            tree: tree,
            branch: branchResult.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            dirty: !finalStatus.isEmpty,
            version: sourceVersion
        )
    }

    private func sourceTree(revision: String?, relativePath: String?) async -> String? {
        guard let revision, let relativePath else { return nil }
        let url = relativePath.hasPrefix("../")
            ? homeURL.appendingPathComponent(String(relativePath.dropFirst(3)))
            : homeURL.appendingPathComponent(relativePath)
        guard fileManager.fileExists(atPath: url.appendingPathComponent(".git").path) else {
            return nil
        }
        let result = await gitCommand(["-C", url.path, "rev-parse", "\(revision)^{tree}"])
        guard result.exitCode == 0, !result.timedOut else { return nil }
        return validFullObjectID(result.standardOutput)
    }

    private func validFullObjectID(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count == 40,
              trimmed.unicodeScalars.allSatisfy(
                CharacterSet(charactersIn: "0123456789abcdefABCDEF").contains
              ) else { return nil }
        return trimmed.lowercased()
    }

    static func parseSourceVersion(
        data: Data,
        format: SourceVersionFormat
    ) -> String? {
        switch format {
        case .packageJSON:
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let version = object["version"] as? String else { return nil }
            return VersionIdentity.normalizedDeclaration(version)
        case .swiftStaticCurrent:
            guard let text = String(data: data, encoding: .utf8) else { return nil }
            return captureVersion(
                in: text,
                pattern: #"static\s+let\s+current\s*=\s*\"([^\"]+)\""#
            )
        case .cargoPackage:
            guard let text = String(data: data, encoding: .utf8),
                  let packageRange = text.range(
                    of: #"(?ms)^\[(?:workspace\.)?package\]\s*$.*?(?=^\[|\z)"#,
                    options: .regularExpression
                  ) else { return nil }
            return captureVersion(
                in: String(text[packageRange]),
                pattern: #"(?m)^\s*version\s*=\s*\"([^\"]+)\""#
            )
        }
    }

    static func parseSparkleAppcast(_ data: Data) -> String? {
        guard data.count <= 262_144,
              let text = String(data: data, encoding: .utf8) else { return nil }
        let patterns = [
            #"<sparkle:shortVersionString>\s*([^<\s]+)\s*</sparkle:shortVersionString>"#,
            #"sparkle:shortVersionString\s*=\s*\"([^\"]+)\""#,
        ]
        var versions: [String] = []
        for pattern in patterns {
            guard let expression = try? NSRegularExpression(
                pattern: pattern,
                options: [.caseInsensitive]
            ) else { continue }
            let range = NSRange(text.startIndex..., in: text)
            for match in expression.matches(in: text, range: range) {
                guard match.numberOfRanges > 1,
                      let valueRange = Range(match.range(at: 1), in: text),
                      let version = VersionIdentity.normalizedDeclaration(String(text[valueRange])) else {
                    continue
                }
                versions.append(version)
            }
        }
        return versions.max { lhs, rhs in
            VersionIdentity.compare(lhs, rhs) == .orderedAscending
        }
    }

    func captureForDoctor(
        machineID: String,
        displayName: String?,
        componentID: String
    ) async -> MachineSnapshot {
        let snapshot = await capture(machineID: machineID, displayName: displayName)
        guard let observation = snapshot.component(componentID),
              observation.kind != .configuration,
              observation.kind != .theme,
              let definition = sourceDefinition(componentID: componentID),
              let source = await sourceState(
                relativePath: definition.relativePath,
                versionProbe: definition.versionProbe
              ) else { return snapshot }
        let installedTree = await sourceTree(
            revision: observation.installedRevision,
            relativePath: definition.relativePath
        )
        return snapshot.replacingComponent(observation.addingSoftwareCheckoutEvidence(
            version: source.version,
            revision: source.revision,
            branch: source.branch,
            dirty: source.dirty,
            sourceTree: source.tree,
            installedTree: installedTree
        ))
    }

    private func sourceDefinition(
        componentID: String
    ) -> (relativePath: String, versionProbe: SourceVersionProbeDefinition?)? {
        if let app = Self.applicationDefinitions.first(where: { $0.id == componentID }),
           let path = app.sourceRelativePath {
            return (path, app.sourceVersionProbe)
        }
        let cliDefinitions = Self.cliDefinitions
        if let cli = cliDefinitions.first(where: { $0.id == componentID }),
           let path = cli.sourceRelativePath {
            return (path, cli.sourceVersionProbe)
        }
        return nil
    }

    private static func captureVersion(in text: String, pattern: String) -> String? {
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(
                in: text,
                range: NSRange(text.startIndex..., in: text)
              ),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return VersionIdentity.normalizedDeclaration(String(text[range]))
    }

    private func gitCommand(_ arguments: [String]) async -> CommandResult {
        await commandRunner.run(
            executable: URL(fileURLWithPath: "/usr/bin/git"),
            arguments: arguments,
            environment: [
                "GIT_OPTIONAL_LOCKS": "0",
                "GIT_TERMINAL_PROMPT": "0",
            ],
            timeout: 5
        )
    }

    private func computerName() async -> String {
        let result = await commandRunner.run(
            executable: URL(fileURLWithPath: "/usr/sbin/scutil"),
            arguments: ["--get", "ComputerName"],
            environment: nil,
            timeout: 5
        )
        return result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? Host.current().localizedName
            ?? "Unnamed Mac"
    }

    private func localHostName() async -> String {
        let result = await commandRunner.run(
            executable: URL(fileURLWithPath: "/usr/sbin/scutil"),
            arguments: ["--get", "LocalHostName"],
            environment: nil,
            timeout: 5
        )
        return result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? ProcessInfo.processInfo.hostName
    }

    private func osBuild() async -> String {
        let result = await commandRunner.run(
            executable: URL(fileURLWithPath: "/usr/bin/sw_vers"),
            arguments: ["-buildVersion"],
            environment: nil,
            timeout: 5
        )
        return result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? "Unknown build"
    }

    private func expandedURL(_ path: String) -> URL {
        if path == "~" { return homeURL }
        if path.hasPrefix("~/") {
            return homeURL.appendingPathComponent(String(path.dropFirst(2)))
        }
        return URL(fileURLWithPath: path)
    }

    private func aggregateFingerprint(files: [URL], relativeTo directory: URL) -> String? {
        guard !files.isEmpty else { return nil }
        var aggregate = Data()
        for file in files {
            guard let data = try? Data(contentsOf: file, options: [.mappedIfSafe]) else {
                continue
            }
            aggregate.append(Data(relativePath(of: file, under: directory).utf8))
            aggregate.append(0)
            aggregate.append(Data(SHA256.hash(data: data)))
        }
        guard !aggregate.isEmpty else { return nil }
        return SHA256.hash(data: aggregate)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private func relativePath(of file: URL, under directory: URL) -> String {
        let root = directory.standardizedFileURL.path
        let path = file.standardizedFileURL.path
        guard path.hasPrefix(root + "/") else { return file.lastPathComponent }
        return String(path.dropFirst(root.count + 1))
    }

    private func parseVersion(from output: String) -> String? {
        VersionIdentity.extract(from: output)
    }

    private func architecture() -> String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }

    private func operatingSystemVersion() -> String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }

    private func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }
}

extension InventoryService: InventoryCapturing {}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
