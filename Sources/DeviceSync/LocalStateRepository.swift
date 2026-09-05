import Foundation

struct RemoteDeviceConnection: Codable, Identifiable, Hashable, Sendable {
    let machineID: String
    let host: String
    let displayName: String
    let role: DeviceRole
    let createdAt: Date

    var id: String { machineID }

    init(
        machineID: String = UUID().uuidString.lowercased(),
        host: String,
        displayName: String,
        role: DeviceRole,
        createdAt: Date = Date()
    ) throws {
        let normalizedHost = try Self.validate(host: host)
        let normalizedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard UUID(uuidString: machineID) != nil else {
            throw RemoteDeviceConnectionError.invalidMachineID
        }
        guard !normalizedName.isEmpty, normalizedName.count <= 80 else {
            throw RemoteDeviceConnectionError.invalidDisplayName
        }
        let endpointName = normalizedHost.split(separator: "@", maxSplits: 1).last.map(String.init)
            ?? normalizedHost
        guard normalizedName.caseInsensitiveCompare(normalizedHost) != .orderedSame,
              normalizedName.caseInsensitiveCompare(endpointName) != .orderedSame else {
            throw RemoteDeviceConnectionError.displayNameMatchesHost
        }
        self.machineID = machineID.lowercased()
        self.host = normalizedHost
        self.displayName = normalizedName
        self.role = role
        self.createdAt = createdAt
    }

    func settingRole(_ role: DeviceRole) throws -> RemoteDeviceConnection {
        try RemoteDeviceConnection(
            machineID: machineID,
            host: host,
            displayName: displayName,
            role: role,
            createdAt: createdAt
        )
    }

    static func validate(host: String) throws -> String {
        let value = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= 253, !value.hasPrefix("-") else {
            throw RemoteDeviceConnectionError.invalidHost
        }

        // FleetMesh invokes /usr/bin/ssh directly, never a shell. Restrict the
        // destination further so an endpoint cannot be interpreted as an SSH
        // option or smuggle command syntax into a future implementation.
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-@")
        guard value.unicodeScalars.allSatisfy(allowed.contains),
              value.filter({ $0 == "@" }).count <= 1,
              !value.hasSuffix("@") else {
            throw RemoteDeviceConnectionError.invalidHost
        }
        return value
    }
}

struct LocalDeviceState: Codable, Hashable, Sendable {
    let machineID: String
    var fleetRootPath: String
    var displayName: String? = nil
    // Connection endpoints are private controller state. They never enter a
    // shared manifest or machine report, and credentials stay in ssh-agent,
    // Keychain, or the user's SSH configuration.
    var remoteDevices: [RemoteDeviceConnection]? = nil
    // Local presentation preference only. These stable component IDs never
    // enter the shared manifest or machine report, and hiding one does not
    // suppress inventory evidence.
    var hiddenComponentIDs: [String]? = nil

    var remoteConnections: [RemoteDeviceConnection] {
        remoteDevices ?? []
    }

    var hiddenComponents: Set<String> {
        Set(hiddenComponentIDs ?? [])
    }
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

    func settingComponentHidden(
        componentID: String,
        hidden: Bool
    ) throws -> LocalDeviceState {
        var state = try loadOrCreate()
        var hiddenIDs = state.hiddenComponents
        if hidden {
            hiddenIDs.insert(componentID)
        } else {
            hiddenIDs.remove(componentID)
        }
        state.hiddenComponentIDs = hiddenIDs.isEmpty ? nil : hiddenIDs.sorted()
        try save(state)
        return state
    }

    func addingRemoteDevice(_ connection: RemoteDeviceConnection) throws -> LocalDeviceState {
        var state = try loadOrCreate()
        guard !state.remoteConnections.contains(where: {
            $0.host.caseInsensitiveCompare(connection.host) == .orderedSame
        }) else {
            throw RemoteDeviceConnectionError.duplicateHost(connection.host)
        }
        guard !state.remoteConnections.contains(where: { $0.machineID == connection.machineID }) else {
            throw RemoteDeviceConnectionError.duplicateMachineID
        }
        state.remoteDevices = (state.remoteConnections + [connection]).sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
        try save(state)
        return state
    }

    func updatingRemoteDeviceRole(
        machineID: String,
        role: DeviceRole
    ) throws -> LocalDeviceState {
        var state = try loadOrCreate()
        guard let index = state.remoteConnections.firstIndex(where: {
            $0.machineID == machineID
        }) else {
            throw RemoteDeviceConnectionError.unknownConnection
        }
        var connections = state.remoteConnections
        connections[index] = try connections[index].settingRole(role)
        state.remoteDevices = connections
        try save(state)
        return state
    }

    func removingRemoteDevice(machineID: String) throws -> LocalDeviceState {
        var state = try loadOrCreate()
        let remaining = state.remoteConnections.filter { $0.machineID != machineID }
        guard remaining.count != state.remoteConnections.count else {
            throw RemoteDeviceConnectionError.unknownConnection
        }
        state.remoteDevices = remaining
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

enum RemoteDeviceConnectionError: LocalizedError {
    case invalidHost
    case invalidDisplayName
    case displayNameMatchesHost
    case invalidMachineID
    case duplicateHost(String)
    case duplicateMachineID
    case unknownConnection

    var errorDescription: String? {
        switch self {
        case .invalidHost:
            "Enter a valid SSH host or SSH config alias using only letters, numbers, dots, hyphens, underscores, and an optional user@ prefix."
        case .invalidDisplayName:
            "Give the device a name between 1 and 80 characters."
        case .displayNameMatchesHost:
            "Use a fleet display name that does not repeat the private SSH endpoint."
        case .invalidMachineID:
            "The remote device does not have a valid privacy-preserving identifier."
        case .duplicateHost(let host):
            "\(host) is already connected to FleetMesh on this Mac."
        case .duplicateMachineID:
            "That remote device identifier is already in use."
        case .unknownConnection:
            "FleetMesh no longer has a local connection record for that device."
        }
    }
}
