import Foundation
import Testing
@testable import DeviceSync

struct FleetEnrollmentInvitationTests {
    @Test
    func invitationContainsOnlyCredentialFreeFleetSelectors() throws {
        var state = LocalDeviceState(
            machineID: "f9ed225c-40f5-4f9c-b5a6-e70d6e9ce45e",
            fleetRootPath: "/private/fleet",
            displayName: "Controller",
            storageBackend: .dynamodb,
            awsProfile: "fleetmesh-controller",
            awsRegion: "us-west-2",
            dynamoDBTable: "fleetmesh-control-plane",
            fleetID: "primary",
            cachePath: "/private/cache"
        )
        state.remoteDevices = [try RemoteDeviceConnection(
            host: "private-host.example.com",
            displayName: "Private device",
            role: .server
        )]

        let invitation = try FleetEnrollmentInvitation.make(from: state)
        let data = try invitation.encoded()
        let object = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        #expect(Set(object.keys) == [
            "schemaVersion", "createdAt", "region", "table", "fleetID",
            "reporterProfileHint", "suggestedRole",
        ])
        #expect(invitation.reporterProfileHint == "fleetmesh-reporter")
        #expect(invitation.region == "us-west-2")
        #expect(invitation.table == "fleetmesh-control-plane")
        #expect(invitation.fleetID == "primary")
        let decoded = try FleetEnrollmentInvitation.decode(data)
        #expect(decoded.schemaVersion == invitation.schemaVersion)
        #expect(decoded.region == invitation.region)
        #expect(decoded.table == invitation.table)
        #expect(decoded.fleetID == invitation.fleetID)
        #expect(decoded.reporterProfileHint == invitation.reporterProfileHint)
        #expect(decoded.suggestedRole == invitation.suggestedRole)
        #expect(abs(decoded.createdAt.timeIntervalSince(invitation.createdAt)) < 1.0)

        let json = try #require(String(data: data, encoding: .utf8))
        for forbidden in [
            state.machineID, "fleetmesh-controller", "private-host", "/private/",
            "accessKey", "secret", "token", "accountId", "remoteDevices",
        ] {
            #expect(!json.localizedCaseInsensitiveContains(forbidden))
        }
    }

    @Test
    func invitationRejectsUnsupportedSchemaAndInvalidSelectors() throws {
        let invitation = try FleetEnrollmentInvitation(
            region: "us-west-2",
            table: "fleetmesh-control-plane",
            fleetID: "primary"
        )
        var object = try #require(
            JSONSerialization.jsonObject(with: invitation.encoded()) as? [String: Any]
        )
        object["schemaVersion"] = 99
        let future = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: FleetEnrollmentInvitationError.unsupportedSchema(99)) {
            try FleetEnrollmentInvitation.decode(future)
        }
        #expect(throws: FleetEnrollmentInvitationError.invalidSelectors) {
            try FleetEnrollmentInvitation(
                region: "us-west-2",
                table: "bad/table",
                fleetID: "primary"
            )
        }

        object["schemaVersion"] = FleetEnrollmentInvitation.currentSchemaVersion
        object["reporterProfileHint"] = "fleetmesh-controller"
        let elevated = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: FleetEnrollmentInvitationError.invalidSelectors) {
            try FleetEnrollmentInvitation.decode(elevated)
        }
    }

    @Test
    func applyingInvitationPreservesMachineIdentityAndPrivateState() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("fleetmesh-enrollment-state-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = LocalStateRepository(
            stateURL: root.appendingPathComponent("local-state.json"),
            homeURL: root
        )
        let machineID = "f9ed225c-40f5-4f9c-b5a6-e70d6e9ce45e"
        let connection = try RemoteDeviceConnection(
            host: "private-host.example.com",
            displayName: "Private device",
            role: .server
        )
        try repository.save(LocalDeviceState(
            machineID: machineID,
            fleetRootPath: root.appendingPathComponent("legacy-fleet").path,
            displayName: "Old name",
            remoteDevices: [connection],
            hiddenComponentIDs: ["optional-app"]
        ))
        let invitation = try FleetEnrollmentInvitation(
            region: "us-west-2",
            table: "fleetmesh-control-plane",
            fleetID: "primary"
        )

        let updated = try repository.applyingEnrollmentInvitation(
            invitation,
            profile: "fleetmesh-reporter",
            displayName: "New Mac"
        )

        #expect(updated.machineID == machineID)
        #expect(updated.displayName == "New Mac")
        let preservedConnection = try #require(updated.remoteConnections.first)
        #expect(preservedConnection.machineID == connection.machineID)
        #expect(preservedConnection.host == connection.host)
        #expect(preservedConnection.displayName == connection.displayName)
        #expect(preservedConnection.role == connection.role)
        #expect(updated.hiddenComponents == ["optional-app"])
        #expect(updated.effectiveStorageBackend == .dynamodb)
        #expect(updated.awsProfile == "fleetmesh-reporter")
        #expect(updated.awsRegion == "us-west-2")
        #expect(updated.dynamoDBTable == "fleetmesh-control-plane")
        #expect(updated.fleetID == "primary")

        let beforeInvalid = try repository.loadOrCreate()
        #expect(throws: FleetStorageConfigurationError.self) {
            try repository.applyingEnrollmentInvitation(
                invitation,
                profile: "bad/profile",
                displayName: "Should not persist"
            )
        }
        #expect(try repository.loadOrCreate() == beforeInvalid)
        #expect(updated.cachePath == root
            .appendingPathComponent("dynamodb-cache")
            .appendingPathComponent("primary")
            .path)
    }

    @Test
    @MainActor
    func newMacInvitationPublishesPendingWithoutReplacingManifest() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("fleetmesh-enrollment-store-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let stateURL = root.appendingPathComponent("state/local-state.json")
        let repository = LocalStateRepository(stateURL: stateURL, homeURL: root)
        let joining = enrollmentSnapshot(
            machineID: "f9ed225c-40f5-4f9c-b5a6-e70d6e9ce45e",
            name: "Joining Mac"
        )
        try repository.save(LocalDeviceState(
            machineID: joining.machineID,
            fleetRootPath: root.appendingPathComponent("legacy-fleet").path
        ))

        let authority = enrollmentSnapshot(
            machineID: "4a451340-1b16-40bd-bb99-ae107126fa09",
            name: "Controller"
        )
        let manifest = FleetManifest(snapshot: authority)
        let client = InMemoryDynamoDBFleetClient()
        try await client.put(
            DynamoDBFleetItemCodec.manifest(fleetID: "primary", manifest: manifest),
            condition: .none
        )
        try await client.put(
            DynamoDBFleetItemCodec.device(fleetID: "primary", snapshot: authority),
            condition: .none
        )

        let store = FleetStore(
            localRepository: repository,
            inventory: EnrollmentInventory(snapshot: joining),
            doctorHomeURL: root,
            dynamoDBClientFactory: { _ in client }
        )
        await store.start()
        #expect(store.shouldOfferEnrollmentWizard)
        #expect(store.manifest == nil)

        let invitation = try FleetEnrollmentInvitation(
            region: "us-west-2",
            table: "fleetmesh-control-plane",
            fleetID: "primary"
        )
        await store.applyEnrollmentInvitation(
            invitation,
            profile: "fleetmesh-reporter",
            displayName: "Joining Mac"
        )

        #expect(store.manifest?.revision == manifest.revision)
        #expect(store.localDevice?.status == .pending)
        #expect(store.localDeviceNeedsEnrollment)
        #expect(store.lastActionMessage?.contains("Pending") == true)
        #expect(!store.shouldOfferEnrollmentWizard)
        let items = try await client.queryFleet(gsiPartitionKey: "FLEET#primary")
        let reports = try items
            .filter { $0.entityType == .device }
            .map(DynamoDBFleetItemCodec.decodeDevice)
        #expect(reports.contains { $0.machineID == joining.machineID })
        let saved = try repository.loadOrCreate()
        #expect(saved.machineID == joining.machineID)
        #expect(saved.effectiveStorageBackend == .dynamodb)
    }

    @Test
    @MainActor
    func movePreflightsDestinationLeavesOldFleetAndPublishesPending() async throws {
        let fixture = try await EnrollmentMoveFixture.make(includeDestination: true)
        defer { fixture.cleanUp() }
        await fixture.store.start()

        let sameFleet = try FleetEnrollmentInvitation(
            region: "us-west-2",
            table: "fleetmesh-control-plane",
            fleetID: "old-fleet"
        )
        #expect(fixture.store.enrollmentTransition(for: sameFleet) == .alreadyConnected)
        let invitation = try FleetEnrollmentInvitation(
            region: "us-west-2",
            table: "fleetmesh-control-plane",
            fleetID: "new-fleet"
        )
        #expect(fixture.store.enrollmentTransition(for: invitation) == .move(
            currentFleetID: "old-fleet",
            destinationFleetID: "new-fleet"
        ))

        await fixture.store.moveToEnrollmentInvitation(
            invitation,
            profile: "fleetmesh-reporter",
            displayName: "Moving Mac"
        )

        let saved = try fixture.localRepository.loadOrCreate()

        #expect(fixture.store.lastError == nil)
        #expect(saved.machineID == fixture.local.machineID)
        #expect(saved.fleetID == "new-fleet")
        #expect(saved.awsProfile == "fleetmesh-reporter")
        #expect(fixture.store.manifest?.revision == fixture.destinationManifest?.revision)
        #expect(fixture.store.localDevice?.status == .pending)
        #expect(fixture.store.lastActionMessage?.contains("left fleet old-fleet") == true)
        let oldItem = try #require(await fixture.client.get(
            partitionKey: "FLEET#old-fleet",
            sortKey: "STATE"
        ))
        let oldManifest = try DynamoDBFleetItemCodec.decodeManifest(oldItem)
        #expect(oldManifest.enrollmentStatus(for: fixture.local.machineID) == .excluded)
        let movedItem = try #require(await fixture.client.get(
            partitionKey: "DEVICE#\(fixture.local.machineID)",
            sortKey: "STATE"
        ))
        #expect(movedItem.gsiPartitionKey == "FLEET#new-fleet")
    }

    @Test
    @MainActor
    func destinationPreflightFailureLeavesOldFleetAndLocalAuthorityUnchanged() async throws {
        let fixture = try await EnrollmentMoveFixture.make(includeDestination: false)
        defer { fixture.cleanUp() }
        await fixture.store.start()
        let invitation = try FleetEnrollmentInvitation(
            region: "us-west-2",
            table: "fleetmesh-control-plane",
            fleetID: "missing-fleet"
        )

        await fixture.store.moveToEnrollmentInvitation(
            invitation,
            profile: "fleetmesh-reporter",
            displayName: "Moving Mac"
        )

        let saved = try fixture.localRepository.loadOrCreate()
        #expect(saved.fleetID == "old-fleet")
        #expect(fixture.store.localDevice?.status == .enrolled)
        #expect(fixture.store.lastError?.contains("remains in its current fleet") == true)
        let oldItem = try #require(await fixture.client.get(
            partitionKey: "FLEET#old-fleet",
            sortKey: "STATE"
        ))
        let oldManifest = try DynamoDBFleetItemCodec.decodeManifest(oldItem)
        #expect(oldManifest.enrollmentStatus(for: fixture.local.machineID) == .enrolled)
    }

    @Test
    @MainActor
    func oldFleetConflictLeavesLocalAuthorityUnchanged() async throws {
        let fixture = try await EnrollmentMoveFixture.make(includeDestination: true)
        defer { fixture.cleanUp() }
        await fixture.store.start()
        let concurrent = try fixture.oldManifest.settingDeviceEnrollment(
            snapshot: fixture.local,
            enrolled: true,
            role: .server,
            knownSnapshots: [fixture.controller, fixture.local],
            updatedByMachineID: fixture.controller.machineID,
            updatedAt: Date().addingTimeInterval(1)
        )
        try await fixture.client.put(
            DynamoDBFleetItemCodec.manifest(fleetID: "old-fleet", manifest: concurrent),
            condition: .manifestRevision(fixture.oldManifest.revision)
        )
        let invitation = try FleetEnrollmentInvitation(
            region: "us-west-2",
            table: "fleetmesh-control-plane",
            fleetID: "new-fleet"
        )

        await fixture.store.moveToEnrollmentInvitation(
            invitation,
            profile: "fleetmesh-reporter",
            displayName: "Moving Mac"
        )

        #expect(try fixture.localRepository.loadOrCreate().fleetID == "old-fleet")
        #expect(fixture.store.lastError != nil)
        let oldItem = try #require(await fixture.client.get(
            partitionKey: "FLEET#old-fleet",
            sortKey: "STATE"
        ))
        let oldManifest = try DynamoDBFleetItemCodec.decodeManifest(oldItem)
        #expect(oldManifest.revision == concurrent.revision)
        #expect(oldManifest.enrollmentStatus(for: fixture.local.machineID) == .enrolled)
    }
}

private struct EnrollmentMoveFixture {
    let root: URL
    let localRepository: LocalStateRepository
    let client: InMemoryDynamoDBFleetClient
    let store: FleetStore
    let local: MachineSnapshot
    let controller: MachineSnapshot
    let oldManifest: FleetManifest
    let destinationManifest: FleetManifest?

    @MainActor
    static func make(includeDestination: Bool) async throws -> EnrollmentMoveFixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("fleetmesh-move-\(UUID().uuidString)")
        let local = enrollmentSnapshot(
            machineID: "f9ed225c-40f5-4f9c-b5a6-e70d6e9ce45e",
            name: "Moving Mac"
        )
        let controller = enrollmentSnapshot(
            machineID: "4a451340-1b16-40bd-bb99-ae107126fa09",
            name: "Old Controller"
        )
        var oldManifest = FleetManifest(snapshot: controller)
        oldManifest = try oldManifest.settingDeviceEnrollment(
            snapshot: local,
            enrolled: true,
            role: .workstation,
            knownSnapshots: [controller, local],
            updatedByMachineID: controller.machineID
        )
        let destinationController = enrollmentSnapshot(
            machineID: "ca22164e-bc61-4c82-8d49-823d23ffcf87",
            name: "New Controller"
        )
        let destinationManifest = includeDestination
            ? FleetManifest(snapshot: destinationController)
            : nil
        let client = InMemoryDynamoDBFleetClient()
        try await client.put(
            DynamoDBFleetItemCodec.manifest(fleetID: "old-fleet", manifest: oldManifest),
            condition: .none
        )
        try await client.put(
            DynamoDBFleetItemCodec.device(fleetID: "old-fleet", snapshot: controller),
            condition: .none
        )
        try await client.put(
            DynamoDBFleetItemCodec.device(fleetID: "old-fleet", snapshot: local),
            condition: .none
        )
        if let destinationManifest {
            try await client.put(
                DynamoDBFleetItemCodec.manifest(
                    fleetID: "new-fleet",
                    manifest: destinationManifest
                ),
                condition: .none
            )
            try await client.put(
                DynamoDBFleetItemCodec.device(
                    fleetID: "new-fleet",
                    snapshot: destinationController
                ),
                condition: .none
            )
        }
        let localRepository = LocalStateRepository(
            stateURL: root.appendingPathComponent("state/local-state.json"),
            homeURL: root
        )
        try localRepository.save(LocalDeviceState(
            machineID: local.machineID,
            fleetRootPath: root.appendingPathComponent("legacy-fleet").path,
            displayName: local.name,
            storageBackend: .dynamodb,
            awsProfile: "fleetmesh-controller",
            awsRegion: "us-west-2",
            dynamoDBTable: "fleetmesh-control-plane",
            fleetID: "old-fleet",
            cachePath: root.appendingPathComponent("old-cache").path
        ))
        let store = FleetStore(
            localRepository: localRepository,
            inventory: EnrollmentInventory(snapshot: local),
            doctorHomeURL: root,
            dynamoDBClientFactory: { _ in client }
        )
        return EnrollmentMoveFixture(
            root: root,
            localRepository: localRepository,
            client: client,
            store: store,
            local: local,
            controller: controller,
            oldManifest: oldManifest,
            destinationManifest: destinationManifest
        )
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: root)
    }
}

private actor EnrollmentInventory: InventoryCapturing {
    let snapshot: MachineSnapshot
    private var captures = 0

    init(snapshot: MachineSnapshot) {
        self.snapshot = snapshot
    }

    func capture(machineID: String, displayName: String?) async -> MachineSnapshot {
        captures += 1
        return MachineSnapshot(
            machineID: snapshot.machineID,
            name: snapshot.name,
            hostName: snapshot.hostName,
            modelIdentifier: snapshot.modelIdentifier,
            architecture: snapshot.architecture,
            osVersion: snapshot.osVersion,
            osBuild: snapshot.osBuild,
            platform: snapshot.effectivePlatform,
            capabilities: Array(snapshot.effectiveCapabilities),
            capturedAt: snapshot.capturedAt.addingTimeInterval(Double(captures)),
            deviceSyncVersion: snapshot.deviceSyncVersion,
            components: snapshot.components
        )
    }
}

private func enrollmentSnapshot(machineID: String, name: String) -> MachineSnapshot {
    MachineSnapshot(
        machineID: machineID,
        name: name,
        hostName: name.lowercased().replacingOccurrences(of: " ", with: "-"),
        modelIdentifier: "Mac17,6",
        architecture: "arm64",
        osVersion: "26.6.2",
        osBuild: "25G83",
        components: [
            ComponentObservation(
                id: "authbar",
                name: "AuthBar",
                kind: .application,
                status: .installed,
                installedVersion: "0.11.4",
                evidence: "Installed"
            )
        ]
    )
}
