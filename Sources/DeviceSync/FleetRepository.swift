import Foundation

enum FleetJSON {
    static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

struct FleetReadResult: Sendable {
    let manifest: FleetManifest?
    let machines: [MachineSnapshot]
    let issues: [FleetIssue]
}

struct FleetManifestReadResult: Sendable {
    let manifest: FleetManifest?
    let issue: FleetIssue?
}

struct FleetRepository: Sendable {
    let rootURL: URL

    private static let processManifestLock = NSLock()

    private var fileManager: FileManager { .default }

    init(rootURL: URL) {
        self.rootURL = rootURL.standardizedFileURL
    }

    var manifestURL: URL {
        rootURL.appendingPathComponent("fleet-manifest.json")
    }

    var machinesURL: URL {
        rootURL.appendingPathComponent("machines", isDirectory: true)
    }

    var manifestRevisionsURL: URL {
        rootURL.appendingPathComponent("manifest-revisions", isDirectory: true)
    }

    var manifestExists: Bool {
        fileManager.fileExists(atPath: manifestURL.path)
    }

    func publish(_ snapshot: MachineSnapshot) throws -> URL {
        guard UUID(uuidString: snapshot.machineID) != nil else {
            throw FleetRepositoryError.invalidMachineID
        }
        try ensureDirectories()
        let destination = machinesURL
            .appendingPathComponent(snapshot.machineID.lowercased())
            .appendingPathExtension("json")
        // Software checkout details are Doctor-local preflight evidence. The
        // shared fleet protocol contains installed/product-version evidence,
        // never developer branch, dirtiness, source revision, or Git trees.
        try write(snapshot.removingSoftwareCheckoutEvidence(), to: destination)
        return destination
    }

    func saveManifest(_ manifest: FleetManifest) throws {
        Self.processManifestLock.lock()
        defer { Self.processManifestLock.unlock() }
        try ensureDirectories()
        try writeRevisionRecordIfNeeded(manifest, parentRevision: nil)
        try write(manifest, to: manifestURL)
    }

    func saveManifest(
        _ manifest: FleetManifest,
        replacingRevision expectedRevision: String
    ) throws {
        Self.processManifestLock.lock()
        defer { Self.processManifestLock.unlock() }
        guard fileManager.fileExists(atPath: manifestURL.path) else {
            throw FleetRepositoryError.missingManifest
        }
        let current = try decode(FleetManifest.self, from: manifestURL)
        guard current.schemaVersion <= FleetManifest.currentSchemaVersion else {
            throw FleetRepositoryError.futureSchema(current.schemaVersion)
        }
        guard current.revision == expectedRevision else {
            throw FleetRepositoryError.manifestChanged
        }
        try writeRevisionRecordIfNeeded(manifest, parentRevision: expectedRevision)
        try write(manifest, to: manifestURL)
    }

    func load() -> FleetReadResult {
        let manifestRead = loadManifest()
        var issues = manifestRead.issue.map { [$0] } ?? []
        let manifest = manifestRead.manifest

        var machineReportsByID: [String: LoadedMachineReport] = [:]
        var duplicateReportCountsByID: [String: Int] = [:]
        if fileManager.fileExists(atPath: machinesURL.path) {
            do {
                let urls = try fileManager.contentsOfDirectory(
                    at: machinesURL,
                    includingPropertiesForKeys: [.isRegularFileKey],
                    options: [.skipsHiddenFiles]
                )
                .filter { $0.pathExtension.lowercased() == "json" }
                .sorted {
                    $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent)
                        == .orderedAscending
                }

                for url in urls {
                    do {
                        let snapshot = try decode(MachineSnapshot.self, from: url)
                        guard snapshot.schemaVersion <= MachineSnapshot.currentSchemaVersion else {
                            throw FleetRepositoryError.futureSchema(snapshot.schemaVersion)
                        }
                        guard UUID(uuidString: snapshot.machineID) != nil else {
                            throw FleetRepositoryError.invalidMachineID
                        }
                        let report = LoadedMachineReport(snapshot: snapshot, sourceURL: url)
                        if let existing = machineReportsByID[snapshot.machineID] {
                            duplicateReportCountsByID[snapshot.machineID, default: 0] += 1
                            machineReportsByID[snapshot.machineID] = preferredMachineReport(
                                between: existing,
                                and: report
                            )
                        } else {
                            machineReportsByID[snapshot.machineID] = report
                        }
                    } catch {
                        issues.append(FleetIssue(
                            id: url.lastPathComponent,
                            title: "One machine report is unreadable",
                            detail: "\(url.lastPathComponent): \(error.localizedDescription)"
                        ))
                    }
                }
            } catch {
                issues.append(FleetIssue(
                    title: "Machine reports could not be listed",
                    detail: error.localizedDescription
                ))
            }
        }

        for (machineID, ignoredCount) in duplicateReportCountsByID.sorted(by: { $0.key < $1.key }) {
            issues.append(FleetIssue(
                id: "duplicate-machine-report-\(machineID.lowercased())",
                title: "Duplicate machine report ignored",
                detail: "Multiple machine report files claimed the same privacy-preserving machine ID. FleetMesh kept the freshest capturedAt snapshot and ignored \(ignoredCount) duplicate report(s)."
            ))
        }
        let machines = machineReportsByID.values.map(\.snapshot)
        return FleetReadResult(
            manifest: manifest,
            machines: machines.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending },
            issues: issues
        )
    }

    func loadManifest() -> FleetManifestReadResult {
        guard fileManager.fileExists(atPath: manifestURL.path) else {
            return FleetManifestReadResult(manifest: nil, issue: nil)
        }
        do {
            let decoded = try decode(FleetManifest.self, from: manifestURL)
            guard decoded.schemaVersion <= FleetManifest.currentSchemaVersion else {
                throw FleetRepositoryError.futureSchema(decoded.schemaVersion)
            }
            if let conflict = try manifestConflictIssue(for: decoded) {
                return FleetManifestReadResult(manifest: nil, issue: conflict)
            }
            return FleetManifestReadResult(manifest: decoded, issue: nil)
        } catch {
            return FleetManifestReadResult(
                manifest: nil,
                issue: FleetIssue(
                    title: "Baseline could not be read",
                    detail: error.localizedDescription
                )
            )
        }
    }

    private func ensureDirectories() throws {
        try fileManager.createDirectory(
            at: machinesURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.createDirectory(
            at: manifestRevisionsURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }

    private func writeRevisionRecordIfNeeded(
        _ manifest: FleetManifest,
        parentRevision: String?
    ) throws {
        let record = FleetManifestRevisionRecord(
            parentRevision: parentRevision,
            manifest: manifest
        )
        let url = manifestRevisionsURL
            .appendingPathComponent(manifest.revision.lowercased())
            .appendingPathExtension("json")
        do {
            try writeNew(record, to: url)
        } catch CocoaError.fileWriteFileExists {
            let existing = try decode(FleetManifestRevisionRecord.self, from: url)
            guard existing == record else {
                throw FleetRepositoryError.manifestRevisionCollision(manifest.revision)
            }
        }
    }

    private func manifestConflictIssue(for manifest: FleetManifest) throws -> FleetIssue? {
        guard fileManager.fileExists(atPath: manifestRevisionsURL.path) else { return nil }
        let urls = try fileManager.contentsOfDirectory(
            at: manifestRevisionsURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ).filter { $0.pathExtension.lowercased() == "json" }
        var childrenByParent: [String: Set<String>] = [:]
        var recordsByRevision: [String: FleetManifestRevisionRecord] = [:]
        for url in urls {
            let record = try decode(FleetManifestRevisionRecord.self, from: url)
            if let existing = recordsByRevision[record.manifest.revision], existing != record {
                throw FleetRepositoryError.manifestRevisionCollision(record.manifest.revision)
            }
            recordsByRevision[record.manifest.revision] = record
            guard let parent = record.parentRevision else { continue }
            childrenByParent[parent, default: []].insert(record.manifest.revision)
        }
        if !childrenByParent[manifest.revision, default: []].isEmpty {
            return FleetIssue(
                id: "manifest-revision-pending",
                title: "Fleet policy is waiting for cloud convergence",
                detail: "A newer immutable fleet policy revision is present, but fleet-manifest.json still points to its parent. FleetMesh stopped using desired state until cloud sync converges or you explicitly replace the baseline."
            )
        }
        // A parentless record is an explicit baseline replacement and starts a
        // new authority lineage. Historical conflicts remain preserved on disk
        // but do not poison the consciously chosen replacement.
        guard let currentRecord = recordsByRevision[manifest.revision],
              currentRecord.parentRevision != nil else { return nil }
        var cursor = manifest.revision
        var visited: Set<String> = []
        while visited.insert(cursor).inserted,
              let record = recordsByRevision[cursor],
              let parent = record.parentRevision {
            if childrenByParent[parent, default: []].count > 1 {
                return FleetIssue(
                    id: "manifest-revision-conflict",
                    title: "Fleet policy has conflicting revisions",
                    detail: "Two Macs changed the same fleet policy revision before cloud sync converged. FleetMesh stopped using desired state so neither branch is silently lost. Each complete candidate policy is preserved in manifest-revisions. Review them and explicitly replace the baseline with the intended policy before continuing. Current manifest revision: \(manifest.revision)."
                )
            }
            cursor = parent
        }
        return nil
    }

    private func write<T: Encodable>(_ value: T, to url: URL) throws {
        let data = try FleetJSON.encoder.encode(value)
        try data.write(to: url, options: .atomic)
        try? fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
    }

    private func writeNew<T: Encodable>(_ value: T, to url: URL) throws {
        let data = try FleetJSON.encoder.encode(value)
        try data.write(to: url, options: [.withoutOverwriting])
        try? fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
    }

    private func decode<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        return try FleetJSON.decoder.decode(type, from: data)
    }

    private func preferredMachineReport(
        between first: LoadedMachineReport,
        and second: LoadedMachineReport
    ) -> LoadedMachineReport {
        if first.snapshot.capturedAt != second.snapshot.capturedAt {
            return first.snapshot.capturedAt > second.snapshot.capturedAt ? first : second
        }

        let firstIsCanonical = first.isCanonicalMachineReport
        let secondIsCanonical = second.isCanonicalMachineReport
        if firstIsCanonical != secondIsCanonical {
            return firstIsCanonical ? first : second
        }

        let ordering = first.sourceURL.lastPathComponent.localizedStandardCompare(
            second.sourceURL.lastPathComponent
        )
        return ordering == .orderedDescending ? second : first
    }
}

/// Serializes cloud-backed fleet-folder I/O away from the main actor. Callers
/// compute policy changes in memory, then submit one bounded repository
/// transaction and apply the returned read model on the UI actor.
actor FleetRepositoryAccess {
    func load(rootURL: URL) -> FleetReadResult {
        FleetRepository(rootURL: rootURL).load()
    }

    func loadManifest(rootURL: URL) -> FleetManifestReadResult {
        FleetRepository(rootURL: rootURL).loadManifest()
    }

    func replaceBaseline(
        _ manifest: FleetManifest,
        snapshot: MachineSnapshot,
        rootURL: URL
    ) throws -> FleetReadResult {
        let repository = FleetRepository(rootURL: rootURL)
        _ = try repository.publish(snapshot)
        // Desired-state authority is the commit point. If evidence publication
        // fails, the existing baseline remains byte-for-byte unchanged.
        try repository.saveManifest(manifest)
        return repository.load()
    }

    func publish(
        _ snapshot: MachineSnapshot,
        rootURL: URL
    ) throws -> FleetReadResult {
        let repository = FleetRepository(rootURL: rootURL)
        _ = try repository.publish(snapshot)
        return repository.load()
    }

    func publishAndSave(
        _ snapshot: MachineSnapshot,
        manifest: FleetManifest,
        replacingRevision: String,
        rootURL: URL
    ) throws -> FleetReadResult {
        let repository = FleetRepository(rootURL: rootURL)
        _ = try repository.publish(snapshot)
        try repository.saveManifest(manifest, replacingRevision: replacingRevision)
        return repository.load()
    }

    func save(
        _ manifest: FleetManifest,
        replacingRevision: String,
        rootURL: URL
    ) throws -> FleetReadResult {
        let repository = FleetRepository(rootURL: rootURL)
        try repository.saveManifest(manifest, replacingRevision: replacingRevision)
        return repository.load()
    }

    /// Revalidates authority and publishes before the local fleet pointer is
    /// changed. A failed connection therefore needs no rollback.
    func connect(
        snapshot: MachineSnapshot,
        rootURL: URL,
        persistLocalRoot: @Sendable (URL) throws -> LocalDeviceState
    ) throws -> (FleetReadResult, LocalDeviceState) {
        let repository = FleetRepository(rootURL: rootURL)
        guard let pinnedManifest = repository.loadManifest().manifest else {
            throw FleetRepositoryError.missingManifest
        }

        let reportURL = repository.machinesURL
            .appendingPathComponent(snapshot.machineID.lowercased())
            .appendingPathExtension("json")
        let reportExisted = FileManager.default.fileExists(atPath: reportURL.path)
        let previousReport: Data?
        if reportExisted {
            // Existing evidence is not ours to destroy. If it cannot be backed
            // up exactly, connecting fails before publishing anything.
            previousReport = try Data(contentsOf: reportURL, options: [.mappedIfSafe])
        } else {
            previousReport = nil
        }
        var published = false
        var publishedReport: Data?
        do {
            _ = try repository.publish(snapshot)
            published = true
            publishedReport = try Data(contentsOf: reportURL, options: [.mappedIfSafe])
            let read = repository.load()
            guard let liveManifest = read.manifest else {
                throw FleetRepositoryError.missingManifest
            }
            guard liveManifest.revision == pinnedManifest.revision else {
                throw FleetRepositoryError.manifestChanged
            }
            let localState = try persistLocalRoot(rootURL)
            return (read, localState)
        } catch {
            if published {
                let currentReport = try? Data(contentsOf: reportURL, options: [.mappedIfSafe])
                // Restore only while the file still contains this transaction's
                // bytes. A concurrent check-in owns any different current data.
                if currentReport == publishedReport {
                    if let previousReport {
                        try previousReport.write(to: reportURL, options: .atomic)
                        try? FileManager.default.setAttributes(
                            [.posixPermissions: 0o600],
                            ofItemAtPath: reportURL.path
                        )
                    } else if FileManager.default.fileExists(atPath: reportURL.path) {
                        try FileManager.default.removeItem(at: reportURL)
                    }
                }
            }
            throw error
        }
    }
}

private struct LoadedMachineReport: Sendable {
    let snapshot: MachineSnapshot
    let sourceURL: URL

    var isCanonicalMachineReport: Bool {
        sourceURL.deletingPathExtension().lastPathComponent.lowercased()
            == snapshot.machineID.lowercased()
    }
}

private struct FleetManifestRevisionRecord: Codable, Hashable, Sendable {
    let parentRevision: String?
    let manifest: FleetManifest
}

enum FleetRepositoryError: LocalizedError {
    case invalidMachineID
    case futureSchema(Int)
    case missingManifest
    case manifestChanged
    case manifestRevisionCollision(String)

    var errorDescription: String? {
        switch self {
        case .invalidMachineID:
            "The machine report has an invalid privacy-preserving identifier."
        case .futureSchema(let version):
            "Schema version \(version) is newer than this FleetMesh build supports."
        case .missingManifest:
            "The fleet baseline disappeared before the change could be saved. Scan again before changing scope."
        case .manifestChanged:
            "Another Mac changed the fleet baseline. FleetMesh reloaded it instead of overwriting newer desired state. Review the latest scope and try again."
        case .manifestRevisionCollision(let revision):
            "Fleet policy revision \(revision) already has different ancestry. FleetMesh did not overwrite it."
        }
    }
}
