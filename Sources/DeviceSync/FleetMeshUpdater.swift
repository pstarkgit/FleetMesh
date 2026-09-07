import AppKit
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

    private let releaseService: any FleetMeshReleaseServicing
    private let installer: any FleetMeshPrebuiltInstalling
    private let updateLogURL: URL
    private let workRootProvider: @Sendable () -> URL
    private let processIDProvider: @Sendable () -> Int32
    private let terminationHandler: @MainActor @Sendable () -> Void
    private var availableRelease: FleetMeshPublishedRelease?

    init(
        releaseService: any FleetMeshReleaseServicing = GitHubFleetMeshReleaseService(),
        installer: any FleetMeshPrebuiltInstalling = ProcessFleetMeshPrebuiltInstaller(),
        updateLogURL: URL = FleetMeshUpdater.defaultUpdateLogURL,
        workRootProvider: @escaping @Sendable () -> URL = FleetMeshUpdater.defaultWorkRoot,
        processIDProvider: @escaping @Sendable () -> Int32 = {
            ProcessInfo.processInfo.processIdentifier
        },
        terminationHandler: @escaping @MainActor @Sendable () -> Void = {
            NSApp.terminate(nil)
        }
    ) {
        self.releaseService = releaseService
        self.installer = installer
        self.updateLogURL = updateLogURL
        self.workRootProvider = workRootProvider
        self.processIDProvider = processIDProvider
        self.terminationHandler = terminationHandler
    }

    static var defaultUpdateLogURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/FleetForge", isDirectory: true)
            .appendingPathComponent("update.log")
    }

    nonisolated static func defaultWorkRoot() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/FleetMesh/Updates", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    static var architecture: String {
        #if arch(arm64)
        "arm64"
        #elseif arch(x86_64)
        "x86_64"
        #else
        "unknown"
        #endif
    }

    var canCheck: Bool { true }

    func check() async {
        if case .updating = state { return }
        state = .checking
        do {
            let release = try await releaseService.latest(architecture: Self.architecture)
            guard let comparison = VersionIdentity.compare(
                release.version,
                FleetMeshBuildIdentity.version
            ) else {
                throw FleetMeshReleaseError.invalidReleaseMetadata
            }
            if comparison == .orderedDescending {
                availableRelease = release
                state = .available(version: release.version)
            } else {
                availableRelease = nil
                state = .upToDate(Date())
            }
        } catch {
            availableRelease = nil
            state = .failed(Self.safeMessage(error))
        }
    }

    func installAvailableUpdate() async {
        if availableRelease == nil {
            await check()
        }
        guard case .available = state, let release = availableRelease else { return }

        state = .updating
        let workRoot = workRootProvider().standardizedFileURL
        do {
            try prepareUpdateLog(release: release)
            let prepared = try await releaseService.prepare(
                release,
                architecture: Self.architecture,
                workRootURL: workRoot
            )
            try await installer.launch(
                prepared,
                currentProcessID: processIDProvider(),
                logURL: updateLogURL
            )
            terminationHandler()
            // Test harnesses use a no-op termination handler. A real app exits
            // here while the signed downloaded helper performs the swap.
            state = .upToDate(Date())
        } catch {
            try? FileManager.default.removeItem(at: workRoot)
            let message = Self.safeMessage(error)
            try? appendUpdateLog("FAILED: \(message)\n")
            state = .failed("\(message) See ~/Library/Logs/FleetForge/update.log.")
        }
    }

    private func prepareUpdateLog(release: FleetMeshPublishedRelease) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: updateLogURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let header = "FleetMesh prebuilt update started \(Date().ISO8601Format()) tag=\(release.tag)\n"
        try Data(header.utf8).write(to: updateLogURL, options: .atomic)
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: updateLogURL.path)
    }

    private func appendUpdateLog(_ text: String) throws {
        let handle = try FileHandle(forWritingTo: updateLogURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: updateLogURL.path)
    }

    static func safeMessage(_ error: Error, limit: Int = 500) -> String {
        let message = (error as? LocalizedError)?.errorDescription
            ?? error.localizedDescription
        return String(message
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .prefix(limit))
    }
}
