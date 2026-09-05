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

struct FleetRepository: Sendable {
    let rootURL: URL

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
        try write(snapshot, to: destination)
        return destination
    }

    func saveManifest(_ manifest: FleetManifest) throws {
        try ensureDirectories()
        try write(manifest, to: manifestURL)
    }

    func saveManifest(
        _ manifest: FleetManifest,
        replacingRevision expectedRevision: String
    ) throws {
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
        try saveManifest(manifest)
    }

    func load() -> FleetReadResult {
        var issues: [FleetIssue] = []
        let manifest: FleetManifest?

        if fileManager.fileExists(atPath: manifestURL.path) {
            do {
                let decoded = try decode(FleetManifest.self, from: manifestURL)
                guard decoded.schemaVersion <= FleetManifest.currentSchemaVersion else {
                    throw FleetRepositoryError.futureSchema(decoded.schemaVersion)
                }
                manifest = decoded
            } catch {
                manifest = nil
                issues.append(FleetIssue(
                    title: "Baseline could not be read",
                    detail: error.localizedDescription
                ))
            }
        } else {
            manifest = nil
        }

        var machines: [MachineSnapshot] = []
        if fileManager.fileExists(atPath: machinesURL.path) {
            do {
                let urls = try fileManager.contentsOfDirectory(
                    at: machinesURL,
                    includingPropertiesForKeys: [.isRegularFileKey],
                    options: [.skipsHiddenFiles]
                ).filter { $0.pathExtension.lowercased() == "json" }

                for url in urls {
                    do {
                        let snapshot = try decode(MachineSnapshot.self, from: url)
                        guard snapshot.schemaVersion <= MachineSnapshot.currentSchemaVersion else {
                            throw FleetRepositoryError.futureSchema(snapshot.schemaVersion)
                        }
                        guard UUID(uuidString: snapshot.machineID) != nil else {
                            throw FleetRepositoryError.invalidMachineID
                        }
                        machines.append(snapshot)
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

        return FleetReadResult(
            manifest: manifest,
            machines: machines.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending },
            issues: issues
        )
    }

    private func ensureDirectories() throws {
        try fileManager.createDirectory(
            at: machinesURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }

    private func write<T: Encodable>(_ value: T, to url: URL) throws {
        let data = try FleetJSON.encoder.encode(value)
        try data.write(to: url, options: .atomic)
        try? fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
    }

    private func decode<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        return try FleetJSON.decoder.decode(type, from: data)
    }
}

enum FleetRepositoryError: LocalizedError {
    case invalidMachineID
    case futureSchema(Int)
    case missingManifest
    case manifestChanged

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
        }
    }
}
