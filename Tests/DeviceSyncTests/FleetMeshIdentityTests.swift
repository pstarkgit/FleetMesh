import Testing
@testable import DeviceSync

struct FleetMeshIdentityTests {
    @Test
    func visibleProductUsesFleetMeshWithStableCompatibilityIDs() throws {
        #expect(FleetMeshIdentity.productName == "FleetMesh")
        #expect(FleetMeshIdentity.installedAppPath == "/Applications/FleetMesh.app")
        #expect(FleetMeshIdentity.formerFleetForgeAppPath == "/Applications/FleetForge.app")
        #expect(FleetMeshIdentity.bundleIdentifier == "dev.starkpat.devicesync")
        #expect(FleetMeshIdentity.executableName == "DeviceSync")
        #expect(FleetMeshIdentity.componentID == "device-sync")
        #expect(FleetMeshIdentity.snapshotLaunchAgentLabel == "dev.starkpat.devicesync.snapshot")

        let definition = try #require(
            InventoryService.applicationDefinitions.first {
                $0.id == FleetMeshIdentity.componentID
            }
        )
        #expect(definition.name == "FleetMesh")
        #expect(definition.preferredPaths.first == "/Applications/FleetMesh.app")
        #expect(definition.preferredPaths.contains("/Applications/FleetForge.app"))
        #expect(definition.preferredPaths.contains("/Applications/Device Sync.app"))
    }
}
