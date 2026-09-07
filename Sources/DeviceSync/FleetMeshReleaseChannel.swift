import AppKit
import CryptoKit
import Foundation

struct FleetMeshReleaseManifest: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let product: String
    let version: String
    let commit: String
    let architecture: String
    let bundleIdentifier: String
    let teamIdentifier: String
    let archiveName: String
    let archiveSHA256: String
    let archiveSize: Int64
}

struct FleetMeshPublishedRelease: Equatable, Sendable {
    let version: String
    let tag: String
    let archiveURL: URL
    let manifestURL: URL
}

struct PreparedFleetMeshUpdate: Equatable, Sendable {
    let appURL: URL
    let installerScriptURL: URL
    let manifest: FleetMeshReleaseManifest
    let workRootURL: URL
}

protocol FleetMeshReleaseServicing: Sendable {
    func latest(architecture: String) async throws -> FleetMeshPublishedRelease
    func prepare(
        _ release: FleetMeshPublishedRelease,
        architecture: String,
        workRootURL: URL
    ) async throws -> PreparedFleetMeshUpdate
}

protocol FleetMeshPrebuiltInstalling: Sendable {
    func launch(
        _ update: PreparedFleetMeshUpdate,
        currentProcessID: Int32,
        logURL: URL
    ) async throws
}

struct ProcessFleetMeshPrebuiltInstaller: FleetMeshPrebuiltInstalling {
    func launch(
        _ update: PreparedFleetMeshUpdate,
        currentProcessID: Int32,
        logURL: URL
    ) async throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: logURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        if !fileManager.fileExists(atPath: logURL.path) {
            _ = fileManager.createFile(
                atPath: logURL.path,
                contents: nil,
                attributes: [.posixPermissions: 0o600]
            )
        }
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: logURL.path)
        let logHandle = try FileHandle(forWritingTo: logURL)
        try logHandle.seekToEnd()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [
            update.installerScriptURL.path,
            update.appURL.path,
            update.manifest.version,
            update.manifest.commit,
            update.manifest.architecture,
            String(currentProcessID),
            update.workRootURL.path,
            String(update.manifest.schemaVersion),
        ]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = logHandle
        process.standardError = logHandle
        try process.run()
        // The helper must outlive FleetMesh. Process retains the file descriptor;
        // intentionally do not close it before the app terminates.
    }
}

actor GitHubFleetMeshReleaseService: FleetMeshReleaseServicing {
    static let repository = "pstarkgit/FleetMesh"
    static let owner = "pstarkgit"
    static let repositoryName = "FleetMesh"
    static let bundleIdentifier = "dev.starkpat.devicesync"
    static let teamIdentifier = "P2M5LH6CVA"
    static let maximumAPIBytes = 1_048_576
    static let maximumManifestBytes = 65_536
    static let maximumArchiveBytes: Int64 = 250 * 1_024 * 1_024

    private let commandRunner: any CommandRunning
    private let session: URLSession

    init(
        commandRunner: any CommandRunning = ProcessCommandRunner(),
        session: URLSession = .shared
    ) {
        self.commandRunner = commandRunner
        self.session = session
    }

    func latest(architecture: String) async throws -> FleetMeshPublishedRelease {
        guard Self.supportedArchitectures.contains(architecture) else {
            throw FleetMeshReleaseError.unsupportedArchitecture(architecture)
        }
        let url = URL(string: "https://api.github.com/repos/\(Self.repository)/releases/latest")!
        let data = try await boundedData(from: url, maximumBytes: Self.maximumAPIBytes)
        let response = try JSONDecoder().decode(GitHubReleaseResponse.self, from: data)
        guard !response.draft, !response.prerelease,
              let version = Self.version(fromTag: response.tagName) else {
            throw FleetMeshReleaseError.invalidReleaseMetadata
        }
        let archiveName = Self.archiveName(version: version, architecture: architecture)
        let manifestName = Self.manifestName(version: version, architecture: architecture)
        guard let archive = response.assets.first(where: { $0.name == archiveName }),
              let manifest = response.assets.first(where: { $0.name == manifestName }),
              Self.isApprovedAssetURL(archive.browserDownloadURL, tag: response.tagName),
              Self.isApprovedAssetURL(manifest.browserDownloadURL, tag: response.tagName) else {
            throw FleetMeshReleaseError.missingReleaseAssets
        }
        return FleetMeshPublishedRelease(
            version: version,
            tag: response.tagName,
            archiveURL: archive.browserDownloadURL,
            manifestURL: manifest.browserDownloadURL
        )
    }

    func prepare(
        _ release: FleetMeshPublishedRelease,
        architecture: String,
        workRootURL: URL
    ) async throws -> PreparedFleetMeshUpdate {
        guard Self.supportedArchitectures.contains(architecture),
              Self.version(fromTag: release.tag) == release.version,
              Self.isApprovedAssetURL(release.archiveURL, tag: release.tag),
              Self.isApprovedAssetURL(release.manifestURL, tag: release.tag) else {
            throw FleetMeshReleaseError.invalidReleaseMetadata
        }
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: workRootURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: workRootURL.path)

        let manifestData = try await boundedData(
            from: release.manifestURL,
            maximumBytes: Self.maximumManifestBytes
        )
        let manifest = try JSONDecoder().decode(FleetMeshReleaseManifest.self, from: manifestData)
        try Self.validate(
            manifest: manifest,
            release: release,
            architecture: architecture
        )

        let archiveURL = workRootURL.appendingPathComponent(manifest.archiveName)
        let downloaded = try await download(from: release.archiveURL)
        defer { try? fileManager.removeItem(at: downloaded) }
        try fileManager.moveItem(at: downloaded, to: archiveURL)
        let values = try archiveURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true,
              let size = values.fileSize,
              Int64(size) == manifest.archiveSize,
              manifest.archiveSize > 0,
              manifest.archiveSize <= Self.maximumArchiveBytes else {
            throw FleetMeshReleaseError.archiveSizeMismatch
        }
        guard try Self.sha256(of: archiveURL) == manifest.archiveSHA256 else {
            throw FleetMeshReleaseError.archiveChecksumMismatch
        }

        let extracted = workRootURL.appendingPathComponent("extracted", isDirectory: true)
        try fileManager.createDirectory(at: extracted, withIntermediateDirectories: false)
        let unzip = await commandRunner.run(
            executable: URL(fileURLWithPath: "/usr/bin/ditto"),
            arguments: ["-x", "-k", archiveURL.path, extracted.path],
            environment: Self.verificationEnvironment,
            timeout: 120
        )
        guard unzip.exitCode == 0, !unzip.timedOut else {
            throw FleetMeshReleaseError.archiveExtractionFailed
        }
        let entries = try fileManager.contentsOfDirectory(
            at: extracted,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )
        guard entries.count == 1,
              entries[0].lastPathComponent == "FleetMesh.app",
              try entries[0].resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]).isDirectory == true,
              try entries[0].resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]).isSymbolicLink != true else {
            throw FleetMeshReleaseError.invalidArchiveLayout
        }
        let appURL = entries[0]
        try await verify(appURL: appURL, manifest: manifest)

        let installer = appURL
            .appendingPathComponent("Contents/Resources", isDirectory: true)
            .appendingPathComponent("install-prebuilt.sh")
        let installerValues = try installer.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard installerValues.isRegularFile == true, installerValues.isSymbolicLink != true else {
            throw FleetMeshReleaseError.missingInstallerHelper
        }
        return PreparedFleetMeshUpdate(
            appURL: appURL,
            installerScriptURL: installer,
            manifest: manifest,
            workRootURL: workRootURL
        )
    }

    func verify(
        appURL: URL,
        manifest: FleetMeshReleaseManifest
    ) async throws {
        let codesign = await commandRunner.run(
            executable: URL(fileURLWithPath: "/usr/bin/codesign"),
            arguments: ["--verify", "--deep", "--strict", "--verbose=2", appURL.path],
            environment: Self.verificationEnvironment,
            timeout: 30
        )
        guard codesign.exitCode == 0, !codesign.timedOut else {
            throw FleetMeshReleaseError.invalidCodeSignature
        }
        let signature = await commandRunner.run(
            executable: URL(fileURLWithPath: "/usr/bin/codesign"),
            arguments: ["-dv", "--verbose=4", appURL.path],
            environment: Self.verificationEnvironment,
            timeout: 30
        )
        let signatureText = signature.standardOutput + "\n" + signature.standardError
        guard signature.exitCode == 0,
              signatureText.contains("Authority=Developer ID Application: Patrick Stark (P2M5LH6CVA)"),
              signatureText.contains("TeamIdentifier=\(Self.teamIdentifier)"),
              signatureText.contains("flags=0x10000(runtime)"),
              signatureText.contains("Timestamp=") else {
            throw FleetMeshReleaseError.untrustedSigningIdentity
        }
        let gatekeeper = await commandRunner.run(
            executable: URL(fileURLWithPath: "/usr/sbin/spctl"),
            arguments: ["--assess", "--type", "execute", "--verbose=2", appURL.path],
            environment: Self.verificationEnvironment,
            timeout: 30
        )
        guard gatekeeper.exitCode == 0, !gatekeeper.timedOut else {
            throw FleetMeshReleaseError.gatekeeperRejected
        }
        let staple = await commandRunner.run(
            executable: URL(fileURLWithPath: "/usr/bin/xcrun"),
            arguments: ["stapler", "validate", appURL.path],
            environment: Self.verificationEnvironment,
            timeout: 30
        )
        guard staple.exitCode == 0, !staple.timedOut else {
            throw FleetMeshReleaseError.notarizationTicketMissing
        }

        let infoURL = appURL.appendingPathComponent("Contents/Info.plist")
        guard let info = NSDictionary(contentsOf: infoURL),
              info["CFBundleIdentifier"] as? String == manifest.bundleIdentifier,
              info["CFBundleShortVersionString"] as? String == manifest.version,
              info["CFBundleVersion"] as? String == manifest.version,
              info["DSCommit"] as? String == manifest.commit,
              info["DSArchitecture"] as? String == manifest.architecture,
              info["DSReleaseRepository"] as? String == "https://github.com/\(Self.repository)" else {
            throw FleetMeshReleaseError.provenanceMismatch
        }
        let executable = appURL.appendingPathComponent("Contents/MacOS/DeviceSync")
        let architectures = await commandRunner.run(
            executable: URL(fileURLWithPath: "/usr/bin/lipo"),
            arguments: ["-archs", executable.path],
            environment: Self.verificationEnvironment,
            timeout: 15
        )
        let archs = Set(architectures.standardOutput.split(whereSeparator: \Character.isWhitespace).map(String.init))
        guard architectures.exitCode == 0, archs == [manifest.architecture] else {
            throw FleetMeshReleaseError.architectureMismatch
        }
    }

    private func boundedData(from url: URL, maximumBytes: Int) async throws -> Data {
        try Self.requireHTTPS(url)
        var request = URLRequest(url: url)
        request.setValue("FleetMesh/\(DeviceSyncVersion.current)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode),
              data.count <= maximumBytes else {
            throw FleetMeshReleaseError.downloadRejected
        }
        return data
    }

    private func download(from url: URL) async throws -> URL {
        try Self.requireHTTPS(url)
        var request = URLRequest(url: url)
        request.setValue("FleetMesh/\(DeviceSyncVersion.current)", forHTTPHeaderField: "User-Agent")
        let (temporary, response) = try await session.download(for: request)
        guard let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode) else {
            throw FleetMeshReleaseError.downloadRejected
        }
        return temporary
    }

    static let supportedArchitectures: Set<String> = ["arm64"]
    static let verificationEnvironment = [
        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
        "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
    ]

    static func archiveName(version: String, architecture: String) -> String {
        "FleetMesh-\(version)-\(architecture).zip"
    }

    static func manifestName(version: String, architecture: String) -> String {
        "FleetMesh-\(version)-\(architecture).json"
    }

    static func version(fromTag tag: String) -> String? {
        let value = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        return VersionIdentity.normalizedDeclaration(value)
    }

    static func isApprovedAssetURL(_ url: URL, tag: String) -> Bool {
        guard url.scheme == "https", url.host == "github.com" else { return false }
        let prefix = "/\(owner)/\(repositoryName)/releases/download/\(tag)/"
        return url.path.hasPrefix(prefix) && !url.path.contains("..")
    }

    static func validate(
        manifest: FleetMeshReleaseManifest,
        release: FleetMeshPublishedRelease,
        architecture: String
    ) throws {
        guard manifest.schemaVersion == FleetMeshReleaseManifest.currentSchemaVersion,
              manifest.product == "FleetMesh",
              manifest.version == release.version,
              manifest.architecture == architecture,
              manifest.bundleIdentifier == bundleIdentifier,
              manifest.teamIdentifier == teamIdentifier,
              manifest.archiveName == archiveName(version: release.version, architecture: architecture),
              manifest.archiveSHA256.count == 64,
              manifest.archiveSHA256.unicodeScalars.allSatisfy(
                CharacterSet(charactersIn: "0123456789abcdef").contains
              ),
              manifest.commit.count == 40,
              manifest.commit.unicodeScalars.allSatisfy(
                CharacterSet(charactersIn: "0123456789abcdef").contains
              ),
              manifest.archiveSize > 0,
              manifest.archiveSize <= maximumArchiveBytes else {
            throw FleetMeshReleaseError.invalidManifest
        }
    }

    static func sha256(of url: URL) throws -> String {
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func requireHTTPS(_ url: URL) throws {
        guard url.scheme == "https" else { throw FleetMeshReleaseError.downloadRejected }
    }
}

private struct GitHubReleaseResponse: Decodable {
    struct Asset: Decodable {
        let name: String
        let browserDownloadURL: URL

        enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadURL = "browser_download_url"
        }
    }

    let tagName: String
    let draft: Bool
    let prerelease: Bool
    let assets: [Asset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case draft
        case prerelease
        case assets
    }
}

enum FleetMeshReleaseError: LocalizedError, Equatable {
    case unsupportedArchitecture(String)
    case invalidReleaseMetadata
    case missingReleaseAssets
    case downloadRejected
    case invalidManifest
    case archiveSizeMismatch
    case archiveChecksumMismatch
    case archiveExtractionFailed
    case invalidArchiveLayout
    case invalidCodeSignature
    case untrustedSigningIdentity
    case gatekeeperRejected
    case notarizationTicketMissing
    case provenanceMismatch
    case architectureMismatch
    case missingInstallerHelper

    var errorDescription: String? {
        switch self {
        case .unsupportedArchitecture(let architecture):
            "No FleetMesh release is published for \(architecture)."
        case .invalidReleaseMetadata:
            "GitHub returned invalid FleetMesh release metadata."
        case .missingReleaseAssets:
            "The release is missing the exact archive or manifest for this Mac."
        case .downloadRejected:
            "FleetMesh rejected the release download or response size."
        case .invalidManifest:
            "FleetMesh rejected the release manifest schema or provenance."
        case .archiveSizeMismatch:
            "The downloaded archive size does not match the release manifest."
        case .archiveChecksumMismatch:
            "The downloaded archive checksum does not match the release manifest."
        case .archiveExtractionFailed:
            "FleetMesh could not safely extract the release archive."
        case .invalidArchiveLayout:
            "The release archive must contain exactly one FleetMesh.app."
        case .invalidCodeSignature:
            "The downloaded FleetMesh app has an invalid code signature."
        case .untrustedSigningIdentity:
            "The downloaded app is not timestamped and signed by FleetMesh's trusted Developer ID team."
        case .gatekeeperRejected:
            "Gatekeeper rejected the downloaded FleetMesh app."
        case .notarizationTicketMissing:
            "The downloaded FleetMesh app has no valid stapled notarization ticket."
        case .provenanceMismatch:
            "The signed app metadata does not match the published release manifest."
        case .architectureMismatch:
            "The downloaded FleetMesh binary does not match this Mac's architecture."
        case .missingInstallerHelper:
            "The signed FleetMesh app is missing its prebuilt installer helper."
        }
    }
}
