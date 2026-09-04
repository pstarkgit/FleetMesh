import Foundation

/// Customer-facing FleetMesh identity plus compatibility authorities that
/// must remain stable across the Device Sync -> FleetForge -> FleetMesh rename.
enum FleetMeshIdentity {
    static let productName = "FleetMesh"
    static let installedAppPath = "/Applications/FleetMesh.app"
    static let formerFleetForgeAppPath = "/Applications/FleetForge.app"

    // Legacy identifiers are persisted on existing Macs and in fleet JSON.
    // Changing them would split the fleet, reset menu placement, or orphan
    // scheduled snapshots.
    static let bundleIdentifier = "dev.starkpat.devicesync"
    static let executableName = "DeviceSync"
    static let componentID = "device-sync"
    static let legacyInstalledAppPath = "/Applications/Device Sync.app"
    static let legacyStateDirectoryName = "Device Sync"
    static let legacyFleetDirectoryName = "Device Sync"
    static let statusItemAutosaveName = "DeviceSync"
    static let snapshotLaunchAgentLabel = "dev.starkpat.devicesync.snapshot"

    static var executablePath: String {
        "\(installedAppPath)/Contents/MacOS/\(executableName)"
    }
}
