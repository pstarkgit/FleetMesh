import Foundation

struct LocalDeviceState: Codable, Hashable, Sendable {
    let machineID: String
    var fleetRootPath: String
    var displayName: String? = nil
}

struct LocalStateRepository: Sendable {
    let stateURL: URL
    let homeURL: URL

    private var fileManager: FileManager { .default }

    init(
        stateURL: URL? = nil,
        homeURL: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.homeURL = homeURL
        if let stateURL {
            self.stateURL = stateURL
        } else {
            let support = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first ?? homeURL.appendingPathComponent("Library/Application Support")
            self.stateURL = Self.defaultStateURL(applicationSupportURL: support)
        }
    }

    static func defaultStateURL(applicationSupportURL: URL) -> URL {
        applicationSupportURL
            .appendingPathComponent(
                FleetMeshIdentity.legacyStateDirectoryName,
                isDirectory: true
            )
            .appendingPathComponent("local-state.json")
    }

    static func canonicalSharedFleetURL(homeURL: URL) -> URL {
        homeURL
            .appendingPathComponent(
                "Library/CloudStorage/OneDrive-amazon.com",
                isDirectory: true
            )
            .appendingPathComponent(
                FleetMeshIdentity.legacyFleetDirectoryName,
                isDirectory: true
            )
    }

    static func maySeedInitialManifest(state: LocalDeviceState, homeURL: URL) -> Bool {
        URL(fileURLWithPath: state.fleetRootPath, isDirectory: true).standardizedFileURL
            == canonicalSharedFleetURL(homeURL: homeURL).standardizedFileURL
    }

    func loadOrCreate() throws -> LocalDeviceState {
        if fileManager.fileExists(atPath: stateURL.path) {
            let data = try Data(contentsOf: stateURL)
            return try FleetJSON.decoder.decode(LocalDeviceState.self, from: data)
        }

        let state = LocalDeviceState(
            machineID: UUID().uuidString.lowercased(),
            fleetRootPath: defaultFleetRoot().path,
            displayName: nil
        )
        try save(state)
        return state
    }

    func save(_ state: LocalDeviceState) throws {
        try fileManager.createDirectory(
            at: stateURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let data = try FleetJSON.encoder.encode(state)
        try data.write(to: stateURL, options: .atomic)
        try? fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: stateURL.path
        )
    }

    func updatingFleetRoot(_ root: URL) throws -> LocalDeviceState {
        var state = try loadOrCreate()
        state.fleetRootPath = root.standardizedFileURL.path
        try save(state)
        return state
    }

    func updatingDisplayName(_ displayName: String?) throws -> LocalDeviceState {
        var state = try loadOrCreate()
        let trimmed = displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        state.displayName = trimmed?.isEmpty == false ? trimmed : nil
        try save(state)
        return state
    }

    private func defaultFleetRoot() -> URL {
        let oneDriveRoot = homeURL.appendingPathComponent(
            "Library/CloudStorage/OneDrive-amazon.com",
            isDirectory: true
        )
        if fileManager.fileExists(atPath: oneDriveRoot.path) {
            return Self.canonicalSharedFleetURL(homeURL: homeURL)
        }

        return stateURL.deletingLastPathComponent()
            .appendingPathComponent("Fleet", isDirectory: true)
    }
}
