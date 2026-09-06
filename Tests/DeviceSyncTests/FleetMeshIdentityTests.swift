import Testing
@testable import DeviceSync

struct FleetMeshIdentityTests {
    @Test
    func selfCheckIsDistinctFromFleetHealthCheck() {
        #expect(HeadlessOperation(arguments: ["DeviceSync", "--self-check"]) == .selfCheck)
        #expect(HeadlessOperation(arguments: ["DeviceSync", "--check"]) == .check)
    }
    @Test
    func dynamoDBMigrationArgumentsAreExplicitAndNonSecret() {
        let arguments = [
            "DeviceSync", "--migrate-dynamodb", "fleetmesh-auto",
            "us-west-2", "fleetmesh-control-plane", "primary",
        ]
        #expect(HeadlessOperation(arguments: arguments) == .migrateDynamoDB(
            mode: .shadow,
            profile: "fleetmesh-auto",
            region: "us-west-2",
            table: "fleetmesh-control-plane",
            fleetID: "primary"
        ))
        #expect(HeadlessOperation(arguments: arguments + ["--cutover"]) == .migrateDynamoDB(
            mode: .cutover,
            profile: "fleetmesh-auto",
            region: "us-west-2",
            table: "fleetmesh-control-plane",
            fleetID: "primary"
        ))
        #expect(HeadlessOperation(arguments: ["DeviceSync", "--migrate-dynamodb"]) == nil)
    }

    @Test
    func headlessScopeCommandsRequireExplicitComponentIDs() {
        #expect(
            HeadlessOperation(arguments: ["DeviceSync", "--remove-from-scope", "codex-voice"])
                == .setManaged(componentID: "codex-voice", managed: false)
        )
        #expect(
            HeadlessOperation(arguments: ["DeviceSync", "--add-to-scope", "codex-voice"])
                == .setManaged(componentID: "codex-voice", managed: true)
        )
        #expect(HeadlessOperation(arguments: ["DeviceSync", "--remove-from-scope"]) == nil)
    }
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

    @Test
    func sidebarFooterUsesHumanVisibleFleetMeshVersion() {
        #expect(FleetMeshBuildIdentity.footerLabel(version: "0.1.9") == "FleetMesh 0.1.9")
        #expect(FleetMeshBuildIdentity.footerLabel.hasPrefix("FleetMesh "))
    }

    @Test
    func softwareFallbackIsLabeledAsRecordedMinimum() {
        let software = ComponentDrift(
            componentID: "app",
            name: "App",
            kind: .application,
            state: .aligned,
            severity: .information,
            summary: "Current",
            expected: "1.0.0",
            observed: "2.0.0"
        )
        let theme = ComponentDrift(
            componentID: "theme",
            name: "Theme",
            kind: .theme,
            state: .aligned,
            severity: .information,
            summary: "Current",
            expected: "abc",
            observed: "abc"
        )
        #expect(software.targetLabel == "Recorded minimum")
        #expect(theme.targetLabel == "Saved baseline")
        #expect(FleetTargetBasis.latestRelease.label == "Latest available")
    }
}
