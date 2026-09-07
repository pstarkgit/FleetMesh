import CryptoKit
import Foundation

struct DoctorManagedFilesRecipe: Hashable, Sendable {
    let componentID: String
    let bundledDirectoryName: String
    let destinationHomeRelativeDirectory: String
    let allowedExtensions: Set<String>

    var displayAction: String {
        "Approved FleetMesh assets → ~/\(destinationHomeRelativeDirectory)"
    }
}

struct DoctorGitFastForwardRecipe: Hashable, Sendable {
    let componentID: String
    let checkoutHomeRelativeDirectory: String
    let expectedOriginURL: String

    var displayAction: String {
        "git fetch origin + verified fast-forward in ~/\(checkoutHomeRelativeDirectory)"
    }
}

struct DoctorManagedFilesRepairer: Sendable {
    func run(
        recipe: DoctorManagedFilesRecipe,
        expectedFingerprint: String,
        homeURL: URL,
        assetsRootURL: URL
    ) async -> DoctorCommandResult {
        await Task.detached(priority: .userInitiated) {
            Self.apply(
                recipe: recipe,
                expectedFingerprint: expectedFingerprint,
                homeURL: homeURL,
                assetsRootURL: assetsRootURL
            )
        }.value
    }

    private static func apply(
        recipe: DoctorManagedFilesRecipe,
        expectedFingerprint: String,
        homeURL: URL,
        assetsRootURL: URL
    ) -> DoctorCommandResult {
        let startedAt = Date()
        let fileManager = FileManager.default
        let expected = expectedFingerprint.lowercased()
        guard expected.count == 64,
              expected.unicodeScalars.allSatisfy(
                CharacterSet(charactersIn: "0123456789abcdef").contains
              ),
              safeRelativePath(recipe.destinationHomeRelativeDirectory),
              safeRelativePath(recipe.bundledDirectoryName),
              !recipe.allowedExtensions.isEmpty else {
            return failure("The DDB target or built-in asset recipe failed validation.", startedAt: startedAt)
        }

        let source = assetsRootURL
            .appendingPathComponent(recipe.bundledDirectoryName, isDirectory: true)
            .standardizedFileURL
        let destination = homeURL
            .appendingPathComponent(recipe.destinationHomeRelativeDirectory, isDirectory: true)
            .standardizedFileURL
        guard source.path.hasPrefix(assetsRootURL.standardizedFileURL.path + "/"),
              destination.path.hasPrefix(homeURL.standardizedFileURL.path + "/") else {
            return failure("The approved asset path escaped its allowed root.", startedAt: startedAt)
        }

        do {
            let files = try approvedFiles(
                in: source,
                allowedExtensions: recipe.allowedExtensions,
                fileManager: fileManager
            )
            guard fingerprint(files: files, relativeTo: source) == expected else {
                return failure(
                    "The bundled approved assets do not match the DDB desired-state fingerprint. No files changed.",
                    startedAt: startedAt
                )
            }

            let parent = destination.deletingLastPathComponent()
            try fileManager.createDirectory(
                at: parent,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let stage = parent.appendingPathComponent(
                ".fleetmesh-stage-\(recipe.componentID)-\(UUID().uuidString)",
                isDirectory: true
            )
            try fileManager.createDirectory(
                at: stage,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            defer { try? fileManager.removeItem(at: stage) }

            for file in files {
                try fileManager.copyItem(
                    at: file.url,
                    to: stage.appendingPathComponent(file.relativePath)
                )
            }
            let stagedFiles = try approvedFiles(
                in: stage,
                allowedExtensions: recipe.allowedExtensions,
                fileManager: fileManager
            )
            guard fingerprint(files: stagedFiles, relativeTo: stage) == expected else {
                return failure(
                    "The staged repair assets failed fingerprint verification. No files changed.",
                    startedAt: startedAt
                )
            }

            var backupURL: URL?
            if fileManager.fileExists(atPath: destination.path) {
                let backupRoot = homeURL
                    .appendingPathComponent("Library/Application Support", isDirectory: true)
                    .appendingPathComponent(FleetMeshIdentity.legacyStateDirectoryName, isDirectory: true)
                    .appendingPathComponent("Doctor Backups", isDirectory: true)
                    .appendingPathComponent(
                        "\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString)",
                        isDirectory: true
                    )
                try fileManager.createDirectory(
                    at: backupRoot,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
                let backup = backupRoot.appendingPathComponent(recipe.componentID, isDirectory: true)
                try fileManager.moveItem(at: destination, to: backup)
                backupURL = backup
            }

            do {
                try fileManager.moveItem(at: stage, to: destination)
            } catch {
                if let backupURL, !fileManager.fileExists(atPath: destination.path) {
                    try? fileManager.moveItem(at: backupURL, to: destination)
                }
                throw error
            }

            let installedFiles = try approvedFiles(
                in: destination,
                allowedExtensions: recipe.allowedExtensions,
                fileManager: fileManager
            )
            guard fingerprint(files: installedFiles, relativeTo: destination) == expected else {
                if let backupURL {
                    try? fileManager.removeItem(at: destination)
                    try? fileManager.moveItem(at: backupURL, to: destination)
                }
                return failure(
                    "The installed repair assets did not prove the DDB fingerprint; the prior directory was restored.",
                    startedAt: startedAt
                )
            }

            let backupDetail = backupURL.map { " Backup: \($0.path)." } ?? ""
            return DoctorCommandResult(
                exitCode: 0,
                standardOutputTail: "Restored \(installedFiles.count) approved file(s).\(backupDetail)",
                standardErrorTail: "",
                timedOut: false,
                duration: Date().timeIntervalSince(startedAt)
            )
        } catch {
            return failure(error.localizedDescription, startedAt: startedAt)
        }
    }

    private struct ApprovedFile {
        let relativePath: String
        let url: URL
        let size: Int
    }

    private static func approvedFiles(
        in directory: URL,
        allowedExtensions: Set<String>,
        fileManager: FileManager
    ) throws -> [ApprovedFile] {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw DoctorRepairError.missingApprovedAssets
        }
        let values = try directory.resourceValues(forKeys: [.isSymbolicLinkKey])
        guard values.isSymbolicLink != true else { throw DoctorRepairError.unsafeApprovedAsset }

        let candidates = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        )
        var files: [ApprovedFile] = []
        var totalBytes = 0
        for candidate in candidates {
            let resource = try candidate.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
            )
            guard resource.isRegularFile == true,
                  resource.isSymbolicLink != true,
                  allowedExtensions.contains(candidate.pathExtension.lowercased()),
                  !candidate.lastPathComponent.contains("/"),
                  candidate.lastPathComponent.count <= 160 else {
                throw DoctorRepairError.unsafeApprovedAsset
            }
            let size = resource.fileSize ?? 0
            guard size <= 1_048_576 else { throw DoctorRepairError.assetsExceedBounds }
            totalBytes += size
            guard totalBytes <= 8_388_608 else { throw DoctorRepairError.assetsExceedBounds }
            files.append(ApprovedFile(
                relativePath: candidate.lastPathComponent,
                url: candidate,
                size: size
            ))
        }
        guard !files.isEmpty, files.count <= 100 else {
            throw DoctorRepairError.assetsExceedBounds
        }
        return files.sorted { $0.relativePath < $1.relativePath }
    }

    private static func fingerprint(files: [ApprovedFile], relativeTo directory: URL) -> String {
        var aggregate = Data()
        for file in files {
            guard let data = try? Data(contentsOf: file.url, options: [.mappedIfSafe]) else {
                return ""
            }
            aggregate.append(Data(file.relativePath.utf8))
            aggregate.append(0)
            aggregate.append(Data(SHA256.hash(data: data)))
        }
        return SHA256.hash(data: aggregate)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func safeRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\") else { return false }
        return path.split(separator: "/").allSatisfy { component in
            component != "." && component != ".." && !component.isEmpty
        }
    }

    private static func failure(_ detail: String, startedAt: Date) -> DoctorCommandResult {
        DoctorCommandResult(
            exitCode: 1,
            standardOutputTail: "",
            standardErrorTail: String(detail.prefix(600)),
            timedOut: false,
            duration: Date().timeIntervalSince(startedAt)
        )
    }
}

struct DoctorGitFastForwardRepairer: Sendable {
    func run(
        recipe: DoctorGitFastForwardRecipe,
        expectedRevision: String,
        homeURL: URL,
        runner: any DoctorCommandRunning
    ) async -> DoctorCommandResult {
        let startedAt = Date()
        let requested = expectedRevision.lowercased()
        guard (7...40).contains(requested.count),
              requested.unicodeScalars.allSatisfy(
                CharacterSet(charactersIn: "0123456789abcdef").contains
              ),
              !recipe.checkoutHomeRelativeDirectory.hasPrefix("/"),
              !recipe.checkoutHomeRelativeDirectory.split(separator: "/").contains("..") else {
            return failure("The DDB source revision or built-in checkout recipe failed validation.", startedAt: startedAt)
        }
        let checkout = homeURL
            .appendingPathComponent(recipe.checkoutHomeRelativeDirectory, isDirectory: true)
            .standardizedFileURL
        guard checkout.path.hasPrefix(homeURL.standardizedFileURL.path + "/") else {
            return failure("The approved checkout path escaped the home directory.", startedAt: startedAt)
        }

        var output: [String] = []
        func git(_ arguments: [String], timeout: TimeInterval = 60) async -> DoctorCommandResult {
            await runner.run(DoctorResolvedCommand(
                componentID: recipe.componentID,
                executableURL: URL(fileURLWithPath: "/usr/bin/git"),
                arguments: ["-C", checkout.path] + arguments,
                workingDirectoryURL: checkout,
                timeout: timeout
            ))
        }
        func record(_ result: DoctorCommandResult) {
            if let combined = result.combinedOutput, !combined.isEmpty { output.append(combined) }
        }
        func failed(_ result: DoctorCommandResult) -> DoctorCommandResult {
            DoctorCommandResult(
                exitCode: result.exitCode == 0 ? 1 : result.exitCode,
                standardOutputTail: output.joined(separator: "\n"),
                standardErrorTail: result.standardErrorTail,
                timedOut: result.timedOut,
                duration: Date().timeIntervalSince(startedAt)
            )
        }

        let origin = await git(["remote", "get-url", "origin"])
        record(origin)
        guard origin.exitCode == 0,
              origin.standardOutputTail.trimmingCharacters(in: .whitespacesAndNewlines)
                == recipe.expectedOriginURL else {
            return failure(
                "The checkout origin does not match FleetMesh's approved repository. No source changed.",
                startedAt: startedAt,
                output: output
            )
        }

        let clean = await git(["status", "--porcelain"])
        record(clean)
        guard clean.exitCode == 0,
              clean.standardOutputTail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return failure("The checkout is not clean. No source changed.", startedAt: startedAt, output: output)
        }

        let fetch = await git(["fetch", "--prune", "origin"], timeout: 120)
        record(fetch)
        guard fetch.exitCode == 0, !fetch.timedOut else { return failed(fetch) }

        let resolved = await git(["rev-parse", "--verify", "\(requested)^{commit}"])
        record(resolved)
        let target = resolved.standardOutputTail.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard resolved.exitCode == 0,
              target.count == 40,
              target.hasPrefix(requested),
              target.unicodeScalars.allSatisfy(
                CharacterSet(charactersIn: "0123456789abcdef").contains
              ) else {
            return failure(
                "The DDB revision is not present in the approved repository. No source changed.",
                startedAt: startedAt,
                output: output
            )
        }

        let head = await git(["rev-parse", "HEAD"])
        record(head)
        let current = head.standardOutputTail.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard head.exitCode == 0, current.count == 40 else { return failed(head) }
        if current != target {
            let ancestor = await git(["merge-base", "--is-ancestor", current, target])
            record(ancestor)
            guard ancestor.exitCode == 0 else {
                return failure(
                    "The DDB revision is not a safe fast-forward from this checkout. No source changed.",
                    startedAt: startedAt,
                    output: output
                )
            }
            let merge = await git(["merge", "--ff-only", target], timeout: 120)
            record(merge)
            guard merge.exitCode == 0, !merge.timedOut else { return failed(merge) }
        }

        let finalHead = await git(["rev-parse", "HEAD"])
        let finalStatus = await git(["status", "--porcelain"])
        record(finalHead)
        record(finalStatus)
        guard finalHead.exitCode == 0,
              finalHead.standardOutputTail.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == target,
              finalStatus.exitCode == 0,
              finalStatus.standardOutputTail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return failure(
                "The fast-forward did not finish at a clean DDB-pinned revision.",
                startedAt: startedAt,
                output: output
            )
        }

        output.append("Harness Sync source is clean at DDB revision \(String(target.prefix(12))).")
        return DoctorCommandResult(
            exitCode: 0,
            standardOutputTail: output.joined(separator: "\n"),
            standardErrorTail: "",
            timedOut: false,
            duration: Date().timeIntervalSince(startedAt)
        )
    }

    private func failure(
        _ detail: String,
        startedAt: Date,
        output: [String] = []
    ) -> DoctorCommandResult {
        DoctorCommandResult(
            exitCode: 1,
            standardOutputTail: output.joined(separator: "\n"),
            standardErrorTail: String(detail.prefix(600)),
            timedOut: false,
            duration: Date().timeIntervalSince(startedAt)
        )
    }
}

private enum DoctorRepairError: LocalizedError {
    case missingApprovedAssets
    case unsafeApprovedAsset
    case assetsExceedBounds

    var errorDescription: String? {
        switch self {
        case .missingApprovedAssets:
            "FleetMesh's approved repair assets are missing."
        case .unsafeApprovedAsset:
            "FleetMesh rejected an unsafe repair asset."
        case .assetsExceedBounds:
            "FleetMesh's repair assets exceed the allowed count or size."
        }
    }
}

enum DoctorRepairCatalog {
    static func managedFilesRecipe(for componentID: String) -> DoctorManagedFilesRecipe? {
        switch componentID {
        case "codex-themes":
            DoctorManagedFilesRecipe(
                componentID: componentID,
                bundledDirectoryName: "codex-themes",
                destinationHomeRelativeDirectory: "CodexThemes",
                allowedExtensions: ["json"]
            )
        case "warp-themes":
            DoctorManagedFilesRecipe(
                componentID: componentID,
                bundledDirectoryName: "warp-themes",
                destinationHomeRelativeDirectory: ".warp/themes",
                allowedExtensions: ["yaml", "yml"]
            )
        default:
            nil
        }
    }

    static func gitFastForwardRecipe(for componentID: String) -> DoctorGitFastForwardRecipe? {
        guard componentID == "harness-sync" else { return nil }
        return DoctorGitFastForwardRecipe(
            componentID: componentID,
            checkoutHomeRelativeDirectory: "harness-sync",
            expectedOriginURL: "git@ssh.gitlab.aws.dev:starkpat/harness-sync.git"
        )
    }

    static func hasRepair(for componentID: String) -> Bool {
        managedFilesRecipe(for: componentID) != nil
            || gitFastForwardRecipe(for: componentID) != nil
    }

    static func displayAction(for componentID: String, command: DoctorRecipe?) -> String? {
        if let managed = managedFilesRecipe(for: componentID) { return managed.displayAction }
        if let git = gitFastForwardRecipe(for: componentID) {
            if let command {
                return "\(git.displayAction) + \(command.displayCommand)"
            }
            return git.displayAction
        }
        return command?.displayCommand
    }
}
