import Foundation
import Testing
@testable import DeviceSync

struct DevicePolicyModelTests {
    @Test
    func schemaV1SnapshotAndManifestDecodeAndMigrateWithoutChangingMeaning() throws {
        let snapshot = policyMacSnapshot()
        let manifest = FleetManifest(snapshot: snapshot)

        var snapshotJSON = try #require(
            JSONSerialization.jsonObject(with: FleetJSON.encoder.encode(snapshot)) as? [String: Any]
        )
        snapshotJSON.removeValue(forKey: "platform")
        snapshotJSON.removeValue(forKey: "capabilities")
        let legacySnapshot = try FleetJSON.decoder.decode(
            MachineSnapshot.self,
            from: JSONSerialization.data(withJSONObject: snapshotJSON)
        )

        var manifestJSON = try #require(
            JSONSerialization.jsonObject(with: FleetJSON.encoder.encode(manifest)) as? [String: Any]
        )
        manifestJSON["schemaVersion"] = 1
        manifestJSON.removeValue(forKey: "devices")
        manifestJSON["targets"] = try #require(manifestJSON["targets"] as? [[String: Any]]).map { value in
            var target = value
            target.removeValue(forKey: "defaultManaged")
            target.removeValue(forKey: "supportedPlatforms")
            target.removeValue(forKey: "requiredCapabilities")
            return target
        }
        let legacyManifest = try FleetJSON.decoder.decode(
            FleetManifest.self,
            from: JSONSerialization.data(withJSONObject: manifestJSON)
        )
        let migrated = legacyManifest.migratingLegacyDevices([legacySnapshot])

        #expect(legacySnapshot.effectivePlatform == .macOS)
        #expect(legacySnapshot.effectiveCapabilities.contains(.macOSApplications))
        #expect(legacyManifest.schemaVersion == 1)
        #expect(legacyManifest.devices == nil)
        #expect(legacyManifest.target("codex-voice")?.isManagedByDefault == true)
        #expect(migrated.schemaVersion == 2)
        #expect(migrated.devices?.first?.machineID == snapshot.machineID)
        #expect(migrated.devices?.first?.enrollment == .enrolled)
        #expect(migrated.target("authbar")?.supportedPlatforms == [.macOS])
        #expect(migrated.target("codex-voice")?.isManagedByDefault == false)
    }

    @Test
    func linuxCloudDesktopGetsOnlyApplicableInheritedItems() throws {
        let mac = policyMacSnapshot()
        let linux = policyLinuxSnapshot()
        let manifest = try FleetManifest(snapshot: mac).settingDeviceEnrollment(
            snapshot: linux,
            enrolled: true,
            role: .cloudDesktop,
            knownSnapshots: [mac, linux],
            updatedByMachineID: mac.machineID
        )

        let assessment = DriftEngine().assess(snapshot: linux, manifest: manifest)
        let authBar = try #require(assessment.drifts.first { $0.componentID == "authbar" })

        #expect(manifest.devicePolicy(linux.machineID)?.role == .cloudDesktop)
        #expect(linux.effectivePlatform == .linux)
        #expect(authBar.state == .notApplicable)
        #expect(authBar.severity == .information)
        #expect(assessment.attentionCount == 0)
        #expect(DoctorPlanner().findings(for: assessment, manifest: manifest).isEmpty)
        #expect(BootstrapPlanner().plan(for: assessment).allSatisfy {
            $0.componentID != "authbar"
        })
    }

    @Test
    func incompatibleRequiredOverrideFailsWithCapabilityReason() throws {
        let mac = policyMacSnapshot()
        let linux = policyLinuxSnapshot()
        let manifest = try FleetManifest(snapshot: mac).settingDeviceEnrollment(
            snapshot: linux,
            enrolled: true,
            role: .server,
            knownSnapshots: [mac, linux],
            updatedByMachineID: mac.machineID
        )

        #expect(throws: FleetManifestError.self) {
            try manifest.settingDeviceScope(
                componentID: "authbar",
                selection: .required,
                snapshot: linux,
                knownSnapshots: [mac, linux],
                updatedByMachineID: mac.machineID
            )
        }
    }

    @Test
    func pendingAndRemovedDevicesHaveNoScopedTargets() throws {
        let mac = policyMacSnapshot()
        let linux = policyLinuxSnapshot()
        let base = FleetManifest(snapshot: mac)

        #expect(base.enrollmentStatus(for: linux.machineID) == .pending)
        #expect(base.scopedTargets(for: linux).isEmpty)

        let removed = try base.settingDeviceEnrollment(
            snapshot: linux,
            enrolled: false,
            role: .server,
            knownSnapshots: [mac],
            updatedByMachineID: mac.machineID
        )
        #expect(removed.enrollmentStatus(for: linux.machineID) == .excluded)
        #expect(removed.scopedTargets(for: linux).isEmpty)
    }

    @Test
    func sshEndpointIsLocalOnlyAndNeverAppearsInSharedObjects() async throws {
        let host = "dev-dsk-starkpat-1d-19238b71.us-east-1.amazon.com"
        let connection = try RemoteDeviceConnection(
            host: host,
            displayName: "Dev cloud desktop",
            role: .cloudDesktop
        )
        let inventory = SSHRemoteInventoryService(runner: SuccessfulSSHRunner())
        let snapshot = try await inventory.capture(connection: connection)
        let manifest = FleetManifest(snapshot: snapshot)

        let localJSON = try #require(String(
            data: FleetJSON.encoder.encode(connection),
            encoding: .utf8
        ))
        let snapshotJSON = try #require(String(
            data: FleetJSON.encoder.encode(snapshot),
            encoding: .utf8
        ))
        let manifestJSON = try #require(String(
            data: FleetJSON.encoder.encode(manifest),
            encoding: .utf8
        ))

        #expect(localJSON.contains(host))
        #expect(!snapshotJSON.contains(host))
        #expect(!manifestJSON.contains(host))
        #expect(snapshot.hostName == "Private SSH endpoint")
        #expect(snapshot.effectivePlatform == .linux)
        #expect(snapshot.effectiveCapabilities.contains(.systemd))
        #expect(snapshot.component("codex-cli")?.installedVersion == "1.2.3")
    }

    @Test
    func sshDestinationValidationRejectsOptionsAndShellSyntax() throws {
        #expect(throws: RemoteDeviceConnectionError.self) {
            try RemoteDeviceConnection(
                host: "-F/tmp/evil",
                displayName: "Bad",
                role: .server
            )
        }
        #expect(throws: RemoteDeviceConnectionError.self) {
            try RemoteDeviceConnection(
                host: "server;touch /tmp/bad",
                displayName: "Bad",
                role: .server
            )
        }
        #expect(throws: RemoteDeviceConnectionError.self) {
            try RemoteDeviceConnection(
                host: "operator@private-server.example.com",
                displayName: "private-server.example.com",
                role: .server
            )
        }
    }
}

struct DevicePolicyStoreTests {
    @Test
    @MainActor
    func startupMigratesLegacyManifestWithoutAutoEnrollingExtraReports() async throws {
        let extra = policyLinuxSnapshot(
            machineID: "9c694b70-14b7-48f6-83e1-cd23603ac157",
            name: "Unreviewed Linux report"
        )
        let fixture = try DeviceStoreFixture(
            pendingSnapshots: [extra],
            legacyManifest: true
        )
        defer { fixture.cleanUp() }

        await fixture.store.start()

        let persisted = try #require(
            FleetRepository(rootURL: fixture.fleetURL).load().manifest
        )
        #expect(persisted.schemaVersion == FleetManifest.currentSchemaVersion)
        #expect(persisted.enrollmentStatus(for: fixture.localSnapshot.machineID) == .enrolled)
        #expect(persisted.enrollmentStatus(for: extra.machineID) == .pending)
        #expect(persisted.devices?.map(\.machineID) == [fixture.localSnapshot.machineID])
        #expect(persisted.target("codex-voice")?.isManagedByDefault == false)
        #expect(fixture.store.enrolledDevices.map(\.machineID) == [fixture.localSnapshot.machineID])
        #expect(fixture.store.devices.first { $0.machineID == extra.machineID }?.status == .pending)
        #expect(!fixture.store.assessments.contains {
            $0.snapshot.machineID == extra.machineID
        })
    }

    @Test
    @MainActor
    func remoteCheckInStaysPendingUntilExplicitEnrollmentAndRunsNoRepair() async throws {
        let fixture = try DeviceStoreFixture()
        defer { fixture.cleanUp() }

        await fixture.store.start()
        await fixture.store.addRemoteDevice(
            host: "dev-dsk-starkpat-1d-19238b71.us-east-1.amazon.com",
            displayName: "Dev cloud desktop",
            role: .cloudDesktop
        )

        let pending = try #require(fixture.store.devices.first {
            $0.name == "Dev cloud desktop"
        })
        #expect(pending.status == .pending)
        #expect(pending.platform == .linux)
        #expect(fixture.store.assessments.count == 1)
        #expect(fixture.store.enrolledDevices.count == 1)
        #expect(await fixture.doctorRunner.callCount() == 0)

        await fixture.store.setDeviceEnrollment(
            machineID: pending.machineID,
            enrolled: true,
            role: .cloudDesktop
        )

        let enrolled = try #require(fixture.store.devices.first {
            $0.machineID == pending.machineID
        })
        #expect(enrolled.status == .enrolled)
        #expect(fixture.store.enrolledDevices.count == 2)
        #expect(fixture.store.assessments.contains {
            $0.snapshot.machineID == pending.machineID
        })

        await fixture.store.setDeviceScope(
            machineID: pending.machineID,
            componentID: "codex-cli",
            selection: .excluded
        )

        #expect(
            fixture.store.manifest?.scopeSelection(
                componentID: "codex-cli",
                machineID: pending.machineID
            ) == .excluded
        )
        #expect(await fixture.doctorRunner.callCount() == 0)
    }

    @Test
    @MainActor
    func enrolledDeviceWithMissingReportRemainsVisibleAndMakesFleetUnknown() async throws {
        let fixture = try DeviceStoreFixture(includeMissingEnrolledPolicy: true)
        defer { fixture.cleanUp() }

        await fixture.store.start()

        let missingID = DeviceStoreFixture.missingMachineID
        let missing = try #require(fixture.store.devices.first {
            $0.machineID == missingID
        })
        #expect(missing.status == .enrolled)
        #expect(!missing.hasFreshEvidence)
        #expect(fixture.store.missingEnrolledDevices.map(\.machineID).contains(missingID))
        #expect(fixture.store.fleetVerdict == .unknown)
        #expect(fixture.store.fleetAttentionCount >= 1)
    }

    @Test
    @MainActor
    func staleDevicePolicyWriteCannotOverwriteNewerManifest() async throws {
        let fixture = try DeviceStoreFixture()
        defer { fixture.cleanUp() }
        await fixture.store.start()

        let displayed = try #require(fixture.store.manifest)
        let repository = FleetRepository(rootURL: fixture.fleetURL)
        let newer = try displayed.settingManaged(
            componentID: "authbar",
            managed: false,
            observation: fixture.localSnapshot.component("authbar"),
            updatedByMachineID: fixture.localSnapshot.machineID
        )
        try repository.saveManifest(newer, replacingRevision: displayed.revision)

        await fixture.store.setDeviceRole(
            machineID: fixture.localSnapshot.machineID,
            role: .server
        )

        #expect(fixture.store.lastError?.contains("Another Mac changed") == true)
        #expect(repository.load().manifest?.revision == newer.revision)
        #expect(await fixture.doctorRunner.callCount() == 0)
    }

    @Test
    @MainActor
    func missingManifestBlocksRemoteOnboardingAndDoesNotStoreEndpoint() async throws {
        let fixture = try DeviceStoreFixture(includeManifest: false)
        defer { fixture.cleanUp() }
        await fixture.store.start()

        #expect(fixture.store.manifest == nil)
        #expect(fixture.store.enrolledDevices.isEmpty)
        #expect(fixture.store.selectedDevice?.status == .pending)

        await fixture.store.addRemoteDevice(
            host: "dev-dsk-starkpat-1d-19238b71.us-east-1.amazon.com",
            displayName: "Blocked cloud desktop",
            role: .cloudDesktop
        )

        #expect(fixture.store.lastError?.contains("valid fleet baseline") == true)
        #expect(fixture.store.localState?.remoteConnections.isEmpty == true)
        #expect(!fixture.store.devices.contains { $0.name == "Blocked cloud desktop" })
    }

    @Test
    @MainActor
    func pendingNativeDeviceRoleCannotCreateAnImplicitPolicy() async throws {
        let pending = policyMacSnapshot(
            machineID: "0f558bb2-c67f-4536-b699-5bb81e2a8777",
            name: "Pending native Mac"
        )
        let fixture = try DeviceStoreFixture(pendingSnapshots: [pending])
        defer { fixture.cleanUp() }
        await fixture.store.start()
        let revision = try #require(fixture.store.manifest?.revision)

        await fixture.store.setDeviceRole(machineID: pending.machineID, role: .server)

        #expect(fixture.store.lastError?.contains("Add Pending native Mac") == true)
        #expect(fixture.store.manifest?.revision == revision)
        #expect(fixture.store.manifest?.devicePolicy(pending.machineID) == nil)
        #expect(fixture.store.devices.first { $0.machineID == pending.machineID }?.status == .pending)
    }

    @Test
    @MainActor
    func failedInitialSSHProbeKeepsLocalConnectionForRetryWithoutEnrollment() async throws {
        let fixture = try DeviceStoreFixture(remoteInventory: FailingPolicyRemoteInventory())
        defer { fixture.cleanUp() }
        await fixture.store.start()

        await fixture.store.addRemoteDevice(
            host: "retry-host",
            displayName: "Retry Linux",
            role: .server
        )

        let retry = try #require(fixture.store.devices.first { $0.name == "Retry Linux" })
        #expect(retry.status == .pending)
        #expect(retry.snapshot == nil)
        #expect(retry.localConnection?.host == "retry-host")
        #expect(fixture.store.lastError?.contains("test SSH failure") == true)
        #expect(fixture.store.manifest?.devicePolicy(retry.machineID) == nil)
    }
}

private struct DeviceStoreFixture {
    static let localMachineID = "b41f9f4f-0fce-4792-a3c6-c93a73fcb4cd"
    static let missingMachineID = "1124cc67-05e0-47d7-b104-63d6c0a2eafb"

    let rootURL: URL
    let fleetURL: URL
    let localSnapshot: MachineSnapshot
    let doctorRunner: PolicyRecordingDoctorRunner
    let store: FleetStore

    @MainActor
    init(
        includeMissingEnrolledPolicy: Bool = false,
        includeManifest: Bool = true,
        pendingSnapshots: [MachineSnapshot] = [],
        legacyManifest: Bool = false,
        remoteInventory: any RemoteInventoryCapturing = PolicyRemoteInventory()
    ) throws {
        rootURL = policyTemporaryDirectory()
        fleetURL = rootURL.appendingPathComponent("fleet", isDirectory: true)
        let homeURL = rootURL.appendingPathComponent("home", isDirectory: true)
        let localRepository = LocalStateRepository(
            stateURL: rootURL.appendingPathComponent("state/local-state.json"),
            homeURL: homeURL
        )
        try localRepository.save(LocalDeviceState(
            machineID: Self.localMachineID,
            fleetRootPath: fleetURL.path,
            displayName: "Policy Mac"
        ))

        localSnapshot = policyMacSnapshot(machineID: Self.localMachineID)
        var manifest = FleetManifest(snapshot: localSnapshot)
        if includeMissingEnrolledPolicy {
            let missing = policyLinuxSnapshot(machineID: Self.missingMachineID)
            manifest = try manifest.settingDeviceEnrollment(
                snapshot: missing,
                enrolled: true,
                role: .server,
                knownSnapshots: [localSnapshot, missing],
                updatedByMachineID: localSnapshot.machineID
            )
        }
        let fleetRepository = FleetRepository(rootURL: fleetURL)
        if includeManifest {
            try fleetRepository.saveManifest(manifest)
            if legacyManifest {
                var object = try #require(
                    JSONSerialization.jsonObject(
                        with: FleetJSON.encoder.encode(manifest)
                    ) as? [String: Any]
                )
                object["schemaVersion"] = 1
                object.removeValue(forKey: "devices")
                object["targets"] = try #require(
                    object["targets"] as? [[String: Any]]
                ).map { value in
                    var target = value
                    target.removeValue(forKey: "defaultManaged")
                    target.removeValue(forKey: "supportedPlatforms")
                    target.removeValue(forKey: "requiredCapabilities")
                    return target
                }
                try JSONSerialization.data(withJSONObject: object).write(
                    to: fleetRepository.manifestURL,
                    options: .atomic
                )
            }
        }
        for pendingSnapshot in pendingSnapshots {
            _ = try fleetRepository.publish(pendingSnapshot)
        }

        doctorRunner = PolicyRecordingDoctorRunner()
        store = FleetStore(
            localRepository: localRepository,
            inventory: PolicyLocalInventory(snapshot: localSnapshot),
            remoteInventory: remoteInventory,
            doctorCommandRunner: doctorRunner,
            doctorHomeURL: homeURL
        )
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: rootURL)
    }
}

private actor PolicyLocalInventory: InventoryCapturing {
    let snapshot: MachineSnapshot

    init(snapshot: MachineSnapshot) {
        self.snapshot = snapshot
    }

    func capture(machineID: String, displayName: String?) async -> MachineSnapshot {
        snapshot
    }
}

private struct PolicyRemoteInventory: RemoteInventoryCapturing {
    func capture(connection: RemoteDeviceConnection) async throws -> MachineSnapshot {
        policyLinuxSnapshot(
            machineID: connection.machineID,
            name: connection.displayName
        )
    }
}

private struct FailingPolicyRemoteInventory: RemoteInventoryCapturing {
    func capture(connection: RemoteDeviceConnection) async throws -> MachineSnapshot {
        throw PolicyRemoteInventoryError.testFailure
    }
}

private enum PolicyRemoteInventoryError: LocalizedError {
    case testFailure

    var errorDescription: String? { "test SSH failure" }
}

private actor PolicyRecordingDoctorRunner: DoctorCommandRunning {
    private var calls = 0

    func run(_ command: DoctorResolvedCommand) async -> DoctorCommandResult {
        calls += 1
        return DoctorCommandResult(
            exitCode: 0,
            standardOutputTail: "",
            standardErrorTail: "",
            timedOut: false,
            duration: 0
        )
    }

    func callCount() -> Int { calls }
}

private struct SuccessfulSSHRunner: SSHRemoteCommandRunning {
    func run(host: String, script: String, timeout: TimeInterval) async -> SSHRemoteCommandResult {
        let fields = [
            ("platform", "linux"),
            ("architecture", "x86_64"),
            ("osVersion", "2023"),
            ("osBuild", "6.1.0-test"),
            ("capabilities", "configuration-files,shell,systemd"),
            ("component.ai-continuum.status", "installed"),
            ("component.ai-continuum.version", "ai-continuum 2.0.0"),
            ("component.ai-continuum.running", "true"),
            ("component.codex-cli.status", "installed"),
            ("component.codex-cli.version", "codex-cli 1.2.3"),
            ("component.harness-sync.status", "missing"),
        ]
        let output = (["FLEETMESH_REMOTE_V1"] + fields.map { key, value in
            "\(key)\t\(Data(value.utf8).base64EncodedString())"
        }).joined(separator: "\n")
        return SSHRemoteCommandResult(
            exitCode: 0,
            standardOutput: output,
            standardError: "",
            timedOut: false
        )
    }
}

private func policyMacSnapshot(
    machineID: String = "3df64ff0-e900-4cc0-bc85-e76f13ed1a04",
    name: String = "Policy Mac"
) -> MachineSnapshot {
    MachineSnapshot(
        machineID: machineID,
        name: name,
        hostName: "policy-mac",
        modelIdentifier: "Mac17,6",
        architecture: "arm64",
        osVersion: "26.6",
        osBuild: "25G83",
        platform: .macOS,
        components: [
            ComponentObservation(
                id: "authbar",
                name: "AuthBar",
                kind: .application,
                status: .installed,
                installedVersion: "1.0.0",
                evidence: "Test"
            ),
            ComponentObservation(
                id: "ai-continuum",
                name: "ai-continuum",
                kind: .service,
                status: .installed,
                installedVersion: "2.0.0",
                evidence: "Test"
            ),
            ComponentObservation(
                id: "codex-cli",
                name: "Codex CLI",
                kind: .commandLineTool,
                status: .installed,
                installedVersion: "1.2.3",
                evidence: "Test"
            ),
            ComponentObservation(
                id: "codex-voice",
                name: "Codex Voice",
                kind: .application,
                status: .installed,
                installedVersion: "0.1.0",
                evidence: "Observed but unmanaged"
            ),
        ]
    )
}

private func policyLinuxSnapshot(
    machineID: String = "44f61618-c556-438c-a2af-101ca6cedae9",
    name: String = "Linux device"
) -> MachineSnapshot {
    MachineSnapshot(
        machineID: machineID,
        name: name,
        hostName: "Private SSH endpoint",
        modelIdentifier: "Linux server",
        architecture: "x86_64",
        osVersion: "2023",
        osBuild: "6.1.0",
        platform: .linux,
        capabilities: [.configurationFiles, .shell, .systemd],
        components: [
            ComponentObservation(
                id: "ai-continuum",
                name: "ai-continuum",
                kind: .service,
                status: .installed,
                installedVersion: "2.0.0",
                evidence: "Test"
            ),
            ComponentObservation(
                id: "codex-cli",
                name: "Codex CLI",
                kind: .commandLineTool,
                status: .installed,
                installedVersion: "1.2.3",
                evidence: "Test"
            ),
        ]
    )
}

private func policyTemporaryDirectory() -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("fleetmesh-policy-tests-\(UUID().uuidString)", isDirectory: true)
    try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}
