import CryptoKit
import Darwin
import Foundation

struct CommandResult: Sendable {
    let exitCode: Int32
    let standardOutput: String
    let standardError: String
}

protocol CommandRunning: Sendable {
    func run(
        executable: URL,
        arguments: [String],
        environment: [String: String]?
    ) async -> CommandResult
}

struct ProcessCommandRunner: CommandRunning {
    func run(
        executable: URL,
        arguments: [String],
        environment: [String: String]? = nil
    ) async -> CommandResult {
        await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            if let environment {
                process.environment = ProcessInfo.processInfo.environment.merging(environment) {
                    _, override in override
                }
            }

            let output = Pipe()
            let error = Pipe()
            process.standardOutput = output
            process.standardError = error

            do {
                try process.run()
                process.waitUntilExit()
                return CommandResult(
                    exitCode: process.terminationStatus,
                    standardOutput: String(
                        data: output.fileHandleForReading.readDataToEndOfFile(),
                        encoding: .utf8
                    ) ?? "",
                    standardError: String(
                        data: error.fileHandleForReading.readDataToEndOfFile(),
                        encoding: .utf8
                    ) ?? ""
                )
            } catch {
                return CommandResult(
                    exitCode: -1,
                    standardOutput: "",
                    standardError: error.localizedDescription
                )
            }
        }.value
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

    init(
        id: String,
        name: String,
        bundleIdentifiers: [String],
        preferredPaths: [String],
        sourceRelativePath: String?,
        commitKeys: [String],
        processNames: [String],
        managedVersionProbe: ManagedVersionProbeDefinition? = nil
    ) {
        self.id = id
        self.name = name
        self.bundleIdentifiers = bundleIdentifiers
        self.preferredPaths = preferredPaths
        self.sourceRelativePath = sourceRelativePath
        self.commitKeys = commitKeys
        self.processNames = processNames
        self.managedVersionProbe = managedVersionProbe
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
}

struct InventoryService: Sendable {
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
        async let apps = probeApplications()
        async let clis = probeCLIs()
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

    private func probeApplications() async -> [ComponentObservation] {
        let definitions = Self.applicationDefinitions

        return await withTaskGroup(of: ComponentObservation.self) { group in
            for definition in definitions {
                group.addTask { await probeApplication(definition) }
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
                processNames: [FleetMeshIdentity.executableName]
            ),
            AppProbeDefinition(
                id: "authbar",
                name: "AuthBar",
                bundleIdentifiers: ["dev.starkpat.authbar"],
                preferredPaths: ["/Applications/AuthBar.app"],
                sourceRelativePath: "code/authbar",
                commitKeys: ["ABCommit"],
                processNames: ["AuthBar"]
            ),
            AppProbeDefinition(
                id: "stow",
                name: "Stow",
                bundleIdentifiers: ["dev.starkpat.stow"],
                preferredPaths: ["/Applications/Stow.app"],
                sourceRelativePath: "code/Stow",
                commitKeys: ["STCommit"],
                processNames: ["Stow"]
            ),
            AppProbeDefinition(
                id: "murmr-voice",
                name: "Murmr Voice",
                bundleIdentifiers: ["ai.murmr.labs.voice", "dev.gsdai.murmur.ios"],
                preferredPaths: ["/Applications/Murmr Voice.app"],
                sourceRelativePath: "code/Murmur",
                commitKeys: ["MRCommit"],
                processNames: ["Murmur", "Murmr Voice"]
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
                processNames: ["Model Bridge"]
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
                    executableCandidates: ["~/.toolbox/bin/kirocrew"],
                    arguments: ["--version"]
                )
            ),
        ]

    private func probeApplication(_ definition: AppProbeDefinition) async -> ComponentObservation {
        let appURL = locateApplication(definition)
        let source = await sourceState(relativePath: definition.sourceRelativePath)
        let isRunning = await processIsRunning(names: definition.processNames)

        guard let appURL,
              let bundle = Bundle(url: appURL),
              let info = bundle.infoDictionary else {
            return ComponentObservation(
                id: definition.id,
                name: definition.name,
                kind: .application,
                status: .missing,
                sourceRevision: source?.revision,
                sourceBranch: source?.branch,
                sourceDirty: source?.dirty,
                isRunning: false,
                evidence: "No matching application bundle was found."
            )
        }

        let installedCommit = definition.commitKeys.compactMap {
            info[$0] as? String
        }.first { !$0.isEmpty }
        let bundleID = info["CFBundleIdentifier"] as? String ?? "unknown bundle"
        let managedVersion = await probeManagedVersion(definition.managedVersionProbe)

        return ComponentObservation(
            id: definition.id,
            name: definition.name,
            kind: .application,
            status: .installed,
            installedVersion: managedVersion
                ?? info["CFBundleShortVersionString"] as? String,
            build: info["CFBundleVersion"] as? String,
            installedRevision: installedCommit,
            sourceRevision: source?.revision,
            sourceBranch: source?.branch,
            sourceDirty: source?.dirty,
            isRunning: isRunning,
            evidence: managedVersion == nil
                ? "Installed bundle \(bundleID); version read from its signed Info.plist."
                : "Installed bundle \(bundleID); version returned by its managed executable."
        )
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
            environment: nil
        )
        guard result.exitCode == 0 else { return nil }
        return parseVersion(
            from: (result.standardOutput + " " + result.standardError)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    private func probeCLIs() async -> [ComponentObservation] {
        let definitions = [
            CLIProbeDefinition(
                id: "ai-continuum",
                name: "ai-continuum",
                executableCandidates: [
                    "~/.local/bin/ai-continuum-ctl",
                    "/opt/homebrew/bin/ai-continuum-ctl",
                    "/usr/local/bin/ai-continuum-ctl",
                ],
                versionArguments: ["--version"],
                sourceRelativePath: "code/ai-continuum"
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
                sourceRelativePath: nil
            ),
        ]

        return await withTaskGroup(of: ComponentObservation.self) { group in
            for definition in definitions {
                group.addTask { await probeCLI(definition) }
            }
            var observations: [ComponentObservation] = []
            for await observation in group { observations.append(observation) }
            return observations
        }
    }

    private func probeCLI(_ definition: CLIProbeDefinition) async -> ComponentObservation {
        let source = await sourceState(relativePath: definition.sourceRelativePath)
        guard let executable = definition.executableCandidates
            .map(expandedURL)
            .first(where: { fileManager.isExecutableFile(atPath: $0.path) }) else {
            return ComponentObservation(
                id: definition.id,
                name: definition.name,
                kind: definition.id == "ai-continuum" ? .service : .commandLineTool,
                status: .missing,
                sourceRevision: source?.revision,
                sourceBranch: source?.branch,
                sourceDirty: source?.dirty,
                evidence: "No executable was found in the managed candidate locations."
            )
        }

        let result = await commandRunner.run(
            executable: executable,
            arguments: definition.versionArguments,
            environment: nil
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
            sourceRevision: source?.revision,
            sourceBranch: source?.branch,
            sourceDirty: source?.dirty,
            isRunning: definition.id == "ai-continuum"
                ? await processIsRunning(names: ["ai-continuum-daemon"])
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
                relativeDirectory: ".kiro/crew/themes",
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

    private func locateApplication(_ definition: AppProbeDefinition) -> URL? {
        for path in definition.preferredPaths {
            let url = expandedURL(path)
            if fileManager.fileExists(atPath: url.path) { return url }
        }

        for root in [URL(fileURLWithPath: "/Applications"), homeURL.appendingPathComponent("Applications")] {
            guard let entries = try? fileManager.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else { continue }
            for entry in entries where entry.pathExtension == "app" {
                guard let bundle = Bundle(url: entry), let identifier = bundle.bundleIdentifier else {
                    continue
                }
                if definition.bundleIdentifiers.contains(identifier) { return entry }
            }
        }
        return nil
    }

    private struct SourceState: Sendable {
        let revision: String
        let branch: String?
        let dirty: Bool
    }

    private func sourceState(relativePath: String?) async -> SourceState? {
        guard let relativePath else { return nil }
        let url: URL
        if relativePath.hasPrefix("../") {
            url = homeURL.appendingPathComponent(String(relativePath.dropFirst(3)))
        } else {
            url = homeURL.appendingPathComponent(relativePath)
        }
        let git = url.appendingPathComponent(".git")
        guard fileManager.fileExists(atPath: git.path) else { return nil }

        let revisionResult = await gitCommand(["-C", url.path, "rev-parse", "--short=12", "HEAD"])
        guard revisionResult.exitCode == 0 else { return nil }
        let branchResult = await gitCommand(["-C", url.path, "branch", "--show-current"])
        let statusResult = await gitCommand(["-C", url.path, "status", "--porcelain"])
        return SourceState(
            revision: revisionResult.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines),
            branch: branchResult.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            dirty: !statusResult.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        )
    }

    private func gitCommand(_ arguments: [String]) async -> CommandResult {
        await commandRunner.run(
            executable: URL(fileURLWithPath: "/usr/bin/git"),
            arguments: arguments,
            environment: ["GIT_OPTIONAL_LOCKS": "0"]
        )
    }

    private func processIsRunning(names: [String]) async -> Bool {
        let result = await commandRunner.run(
            executable: URL(fileURLWithPath: "/bin/ps"),
            arguments: ["-axo", "ucomm="],
            environment: nil
        )
        guard result.exitCode == 0 else { return false }
        let runningNames = Set(result.standardOutput.split(separator: "\n").map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        })
        return names.contains { runningNames.contains($0) }
    }

    private func computerName() async -> String {
        let result = await commandRunner.run(
            executable: URL(fileURLWithPath: "/usr/sbin/scutil"),
            arguments: ["--get", "ComputerName"],
            environment: nil
        )
        return result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? Host.current().localizedName
            ?? "Unnamed Mac"
    }

    private func localHostName() async -> String {
        let result = await commandRunner.run(
            executable: URL(fileURLWithPath: "/usr/sbin/scutil"),
            arguments: ["--get", "LocalHostName"],
            environment: nil
        )
        return result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? ProcessInfo.processInfo.hostName
    }

    private func osBuild() async -> String {
        let result = await commandRunner.run(
            executable: URL(fileURLWithPath: "/usr/bin/sw_vers"),
            arguments: ["-buildVersion"],
            environment: nil
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
        let pattern = #"\b\d+(?:\.\d+){1,3}(?:[-+][A-Za-z0-9.-]+)?\b"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(
                in: output,
                range: NSRange(output.startIndex..., in: output)
              ),
              let range = Range(match.range, in: output) else { return output.nilIfEmpty }
        return String(output[range])
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
