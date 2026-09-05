import AppKit
import Foundation
import Observation

@MainActor
@Observable
final class FleetStore {
    private(set) var localState: LocalDeviceState?
    private(set) var localSnapshot: MachineSnapshot?
    /// Persisted desired state exactly as read from fleet-manifest.json.
    private(set) var manifest: FleetManifest?
    private(set) var repositoryTargets: [String: RepositoryBuildTarget] = [:]
    private(set) var devices: [FleetDeviceItem] = []
    private(set) var assessments: [MachineAssessment] = []
    private(set) var issues: [FleetIssue] = []
    private(set) var isRefreshing = false
    private(set) var isDoctorRunning = false
    private(set) var isUpdatingScope = false
    private(set) var activeDoctorComponentID: String?
    private(set) var doctorRuns: [String: DoctorRunRecord] = [:]
    private(set) var lastError: String?
    private(set) var lastActionMessage: String?
    private(set) var lastRefreshAt: Date?
    private(set) var checkingRemoteDeviceIDs: Set<String> = []
    private(set) var detectedExistingFleetURL: URL?

    var selectedMachineID: String?
    var searchText = ""

    private var hasStarted = false
    private var knownSnapshots: [String: MachineSnapshot] = [:]

    private let localRepository: LocalStateRepository
    private let inventory: any InventoryCapturing
    private let remoteInventory: any RemoteInventoryCapturing
    private let driftEngine: DriftEngine
    private let bootstrapPlanner: BootstrapPlanner
    private let doctorPlanner: DoctorPlanner
    private let doctorCommandRunner: any DoctorCommandRunning
    private let doctorHomeURL: URL
    private let fleetAccess: FleetRepositoryAccess

    init(
        localRepository: LocalStateRepository = LocalStateRepository(),
        inventory: any InventoryCapturing = InventoryService(),
        remoteInventory: any RemoteInventoryCapturing = SSHRemoteInventoryService(),
        driftEngine: DriftEngine = DriftEngine(),
        bootstrapPlanner: BootstrapPlanner = BootstrapPlanner(),
        doctorPlanner: DoctorPlanner = DoctorPlanner(),
        doctorCommandRunner: any DoctorCommandRunning = ProcessDoctorCommandRunner(),
        doctorHomeURL: URL = FileManager.default.homeDirectoryForCurrentUser,
        fleetAccess: FleetRepositoryAccess = FleetRepositoryAccess()
    ) {
        self.localRepository = localRepository
        self.inventory = inventory
        self.remoteInventory = remoteInventory
        self.driftEngine = driftEngine
        self.bootstrapPlanner = bootstrapPlanner
        self.doctorPlanner = doctorPlanner
        self.doctorCommandRunner = doctorCommandRunner
        self.doctorHomeURL = doctorHomeURL
        self.fleetAccess = fleetAccess
    }

    var fleetRootURL: URL? {
        localState.map { URL(fileURLWithPath: $0.fleetRootPath, isDirectory: true) }
    }

    var isBusy: Bool {
        isRefreshing || isDoctorRunning || isUpdatingScope || !checkingRemoteDeviceIDs.isEmpty
    }

    private var catalogScopeItems: [FleetScopeItem] {
        var observations: [String: ComponentObservation] = [:]
        for observation in localSnapshot?.components ?? []
            where ComponentLifecycle.isActive(observation.id) {
            observations[observation.id] = observation
        }
        var targets: [String: ManifestTarget] = [:]
        for target in manifest?.catalogTargets ?? [] {
            targets[target.id] = target
        }
        return Set(observations.keys).union(targets.keys)
            .map { componentID in
                FleetScopeItem(
                    observation: observations[componentID],
                    target: targets[componentID]
                )
            }
            .sorted { lhs, rhs in
                if lhs.isManaged != rhs.isManaged { return lhs.isManaged }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
    }

    var fleetScopeItems: [FleetScopeItem] {
        let hiddenIDs = localState?.hiddenComponents ?? []
        return catalogScopeItems.filter { item in
            // Shared desired state wins over a local presentation preference.
            item.isManaged || !hiddenIDs.contains(item.id)
        }
    }

    var hiddenFleetScopeItems: [FleetScopeItem] {
        let hiddenIDs = localState?.hiddenComponents ?? []
        return catalogScopeItems.filter { item in
            !item.isManaged && hiddenIDs.contains(item.id)
        }
    }

    var filteredDevices: [FleetDeviceItem] {
        let needle = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return devices }
        return devices.filter { device in
            device.name.localizedCaseInsensitiveContains(needle)
                || device.snapshot?.hostName.localizedCaseInsensitiveContains(needle) == true
                || device.localConnection?.host.localizedCaseInsensitiveContains(needle) == true
                || device.platform.label.localizedCaseInsensitiveContains(needle)
                || device.role.label.localizedCaseInsensitiveContains(needle)
        }
    }

    var selectedDevice: FleetDeviceItem? {
        guard let selectedMachineID else { return devices.first }
        return devices.first { $0.machineID == selectedMachineID }
    }

    var localDevice: FleetDeviceItem? {
        guard let machineID = localSnapshot?.machineID else { return nil }
        return devices.first { $0.machineID == machineID }
    }

    var localDeviceNeedsEnrollment: Bool {
        localDevice?.status == .pending && manifest != nil
    }

    var needsFleetConnection: Bool { manifest == nil }

    var enrolledDevices: [FleetDeviceItem] {
        devices.filter { $0.status == .enrolled }
    }

    var missingEnrolledDevices: [FleetDeviceItem] {
        enrolledDevices.filter { !$0.hasFreshEvidence }
    }

    func isCheckingIn(_ machineID: String) -> Bool {
        checkingRemoteDeviceIDs.contains(machineID)
    }

    func deviceScopeItems(for machineID: String) -> [FleetScopeItem] {
        guard let device = devices.first(where: { $0.machineID == machineID }) else {
            return []
        }
        let snapshot = device.snapshot
        var observations: [String: ComponentObservation] = [:]
        for observation in snapshot?.components ?? []
            where ComponentLifecycle.isActive(observation.id) {
            observations[observation.id] = observation
        }
        var targets: [String: ManifestTarget] = [:]
        for target in manifest?.catalogTargets ?? [] {
            targets[target.id] = target
        }

        return Set(observations.keys).union(targets.keys).map { componentID in
            let target = targets[componentID]
            let selection = manifest?.scopeSelection(
                componentID: componentID,
                machineID: machineID
            ) ?? .inherit
            let applicability = target?.applicability(
                platform: device.platform,
                capabilities: device.capabilities
            ) ?? .applicable
            let inherited = target?.isManagedByDefault == true
            let selectedManaged: Bool
            switch selection {
            case .inherit: selectedManaged = inherited
            case .required: selectedManaged = true
            case .excluded: selectedManaged = false
            }
            return FleetScopeItem(
                observation: observations[componentID],
                target: target,
                scopeSelection: selection,
                isDeviceScope: true,
                effectiveManaged: selectedManaged && applicability.isApplicable,
                applicability: applicability,
                canRequire: applicability.isApplicable
                    && (target != nil
                        || observations[componentID].map(FleetManifest.isEligibleForBaseline) == true)
            )
        }.sorted { lhs, rhs in
            if lhs.isManaged != rhs.isManaged { return lhs.isManaged }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    var filteredAssessments: [MachineAssessment] {
        let needle = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return assessments }
        return assessments.filter { assessment in
            assessment.snapshot.name.localizedCaseInsensitiveContains(needle)
                || assessment.snapshot.hostName.localizedCaseInsensitiveContains(needle)
                || assessment.snapshot.components.contains {
                    $0.name.localizedCaseInsensitiveContains(needle)
                }
        }
    }

    var selectedAssessment: MachineAssessment? {
        guard let selectedMachineID else { return assessments.first }
        return assessments.first { $0.snapshot.machineID == selectedMachineID }
    }

    var fleetVerdict: FleetVerdict {
        FleetHealthEvaluator.verdict(
            manifest: manifest,
            assessments: assessments,
            issueCount: issues.count,
            missingEnrolledCount: missingEnrolledDevices.count,
            hasRuntimeError: lastError != nil
        )
    }

    var fleetAttentionCount: Int {
        assessments.reduce(0) { $0 + $1.attentionCount }
            + missingEnrolledDevices.count
            + issues.count
    }

    var menuBarSummary: MenuBarSummary {
        MenuBarSummary(
            verdict: fleetVerdict,
            machineCount: enrolledDevices.count,
            attentionCount: fleetAttentionCount,
            lastScanAt: lastRefreshAt,
            isScanning: isRefreshing || isDoctorRunning,
            errorMessage: lastError
        )
    }

    func start() async {
        guard !hasStarted else { return }
        hasStarted = true
        await refresh()
    }

    func refresh() async {
        guard !isBusy else { return }
        isRefreshing = true
        lastError = nil
        lastActionMessage = nil
        defer { isRefreshing = false }

        do {
            _ = try await scanAndPublish()
        } catch {
            lastError = error.localizedDescription
        }
        await refreshDetectedExistingFleet()
    }

    func adoptThisMacAsBaseline() async {
        guard !isBusy, let snapshot = localSnapshot, let fleetRootURL else { return }
        isUpdatingScope = true
        lastError = nil
        lastActionMessage = nil
        defer { isUpdatingScope = false }
        do {
            let newManifest = FleetManifest(snapshot: snapshot)
            let read = try await fleetAccess.replaceBaseline(
                newManifest,
                snapshot: snapshot,
                rootURL: fleetRootURL
            )
            apply(read: read, currentSnapshot: snapshot)
            lastError = nil
            lastActionMessage = "Fleet baseline replaced with this Mac's fresh observed state."
        } catch {
            lastError = error.localizedDescription
            lastActionMessage = nil
        }
    }

    func joinThisMac(role: DeviceRole = .workstation) async {
        guard let machineID = localSnapshot?.machineID else {
            lastError = FleetStoreError.localSnapshotUnavailable.localizedDescription
            return
        }
        await setDeviceEnrollment(machineID: machineID, enrolled: true, role: role)
    }

    func connectDetectedFleet() async {
        guard !isBusy, let url = detectedExistingFleetURL else { return }
        await connectExistingFleet(at: url)
    }

    func setComponentManaged(componentID: String, managed: Bool) async {
        guard !isBusy,
              let displayedManifest = manifest,
              let fleetRootURL else { return }

        isUpdatingScope = true
        lastError = nil
        lastActionMessage = nil
        defer { isUpdatingScope = false }

        do {
            let state = try localRepository.loadOrCreate()
            localState = state
            let snapshot = await inventory.capture(
                machineID: state.machineID,
                displayName: state.displayName
            )
            localSnapshot = snapshot

            let updatedManifest = try displayedManifest.settingManaged(
                componentID: componentID,
                managed: managed,
                observation: snapshot.component(componentID),
                updatedByMachineID: state.machineID
            )
            let read = try await fleetAccess.publishAndSave(
                snapshot,
                manifest: updatedManifest,
                replacingRevision: displayedManifest.revision,
                rootURL: fleetRootURL
            )
            apply(read: read, currentSnapshot: snapshot)
            lastRefreshAt = Date()
            let name = FleetScopeItem(
                observation: snapshot.component(componentID),
                target: updatedManifest.target(componentID) ?? displayedManifest.target(componentID)
            ).name
            lastActionMessage = managed
                ? "\(name) is now managed across the fleet."
                : "\(name) was removed from fleet scope. Nothing was uninstalled or deleted."
        } catch {
            lastError = error.localizedDescription
            lastActionMessage = nil
            await reloadFleet()
        }
    }

    func useObservedConfigurationAsBaseline(componentID: String) async {
        guard !isBusy,
              let displayedManifest = manifest,
              let fleetRootURL else { return }
        isUpdatingScope = true
        lastError = nil
        lastActionMessage = nil
        defer { isUpdatingScope = false }

        do {
            let state = try localRepository.loadOrCreate()
            let snapshot = await inventory.capture(
                machineID: state.machineID,
                displayName: state.displayName
            )
            guard let observation = snapshot.component(componentID),
                  observation.sourceDirty != true else {
                throw FleetStoreError.freshObservationUnavailable(componentID)
            }
            let updated = try displayedManifest.settingObservedConfigurationBaseline(
                componentID: componentID,
                observation: observation,
                updatedByMachineID: state.machineID
            )
            let read = try await fleetAccess.publishAndSave(
                snapshot,
                manifest: updated,
                replacingRevision: displayedManifest.revision,
                rootURL: fleetRootURL
            )
            localSnapshot = snapshot
            apply(read: read, currentSnapshot: snapshot)
            lastRefreshAt = Date()
            lastActionMessage = "\(observation.name) now uses the freshly observed configuration as its fleet baseline. No software was installed or repaired."
        } catch {
            lastError = error.localizedDescription
            lastActionMessage = nil
            await reloadFleet()
        }
    }


    func setComponentHidden(componentID: String, hidden: Bool) {
        guard !isBusy else { return }
        guard let item = catalogScopeItems.first(where: { $0.id == componentID }) else {
            lastError = FleetStoreError.unknownCatalogComponent(componentID).localizedDescription
            lastActionMessage = nil
            return
        }
        guard !hidden || !item.isManaged else {
            lastError = FleetStoreError.managedComponentCannotBeHidden(item.name).localizedDescription
            lastActionMessage = nil
            return
        }

        lastError = nil
        do {
            localState = try localRepository.settingComponentHidden(
                componentID: componentID,
                hidden: hidden
            )
            lastActionMessage = hidden
                ? "\(item.name) is hidden from Available items on this Mac. It remains installed and observed."
                : "\(item.name) is visible in Available items again."
        } catch {
            lastError = error.localizedDescription
            lastActionMessage = nil
        }
    }

    func addRemoteDevice(host: String, displayName: String, role: DeviceRole) async {
        guard !isBusy else { return }
        isUpdatingScope = true
        lastError = nil
        lastActionMessage = nil
        defer { isUpdatingScope = false }

        do {
            let connection = try RemoteDeviceConnection(
                host: host,
                displayName: displayName,
                role: role
            )
            localState = try localRepository.loadOrCreate()
            try await requireManifestForRemoteCheckIn()
            localState = try localRepository.addingRemoteDevice(connection)
            selectedMachineID = connection.machineID
            let snapshot = try await remoteInventory.capture(connection: connection)
            guard let fleetRootURL else { return }
            let read = try await fleetAccess.publish(snapshot, rootURL: fleetRootURL)
            apply(read: read, currentSnapshot: try currentLocalSnapshot())
            selectedMachineID = connection.machineID
            lastActionMessage = "\(connection.displayName) checked in and is Pending. Review its evidence, then add it to the fleet."
        } catch {
            lastError = error.localizedDescription
            lastActionMessage = nil
            await reloadFleet()
        }
    }

    func checkInRemoteDevice(machineID: String) async {
        guard !isBusy,
              let connection = localState?.remoteConnections.first(where: {
                  $0.machineID == machineID
              }), let fleetRootURL else { return }

        checkingRemoteDeviceIDs.insert(machineID)
        lastError = nil
        lastActionMessage = nil
        defer { checkingRemoteDeviceIDs.remove(machineID) }

        do {
            try await requireManifestForRemoteCheckIn()
            let snapshot = try await remoteInventory.capture(connection: connection)
            let read = try await fleetAccess.publish(snapshot, rootURL: fleetRootURL)
            apply(read: read, currentSnapshot: try currentLocalSnapshot())
            selectedMachineID = machineID
            lastActionMessage = "\(connection.displayName) published fresh redacted evidence."
        } catch {
            lastError = error.localizedDescription
            lastActionMessage = nil
            await reloadFleet()
        }
    }

    func setDeviceEnrollment(
        machineID: String,
        enrolled: Bool,
        role: DeviceRole
    ) async {
        guard !isBusy,
              let displayedManifest = manifest,
              let fleetRootURL,
              let device = devices.first(where: { $0.machineID == machineID }) else { return }

        isUpdatingScope = true
        lastError = nil
        lastActionMessage = nil
        defer { isUpdatingScope = false }

        do {
            let state = try localRepository.loadOrCreate()
            let currentSnapshot = try currentLocalSnapshot()
            let snapshots = Array(knownSnapshots.values)
            let updated: FleetManifest
            if let snapshot = device.snapshot {
                updated = try displayedManifest.settingDeviceEnrollment(
                    snapshot: snapshot,
                    enrolled: enrolled,
                    role: role,
                    knownSnapshots: snapshots,
                    updatedByMachineID: state.machineID
                )
            } else {
                updated = try displayedManifest.settingExistingDevicePolicy(
                    machineID: machineID,
                    enrolled: enrolled,
                    role: role,
                    updatedByMachineID: state.machineID
                )
            }
            var localStateToRestore: LocalDeviceState?
            if let connection = device.localConnection, connection.role != role {
                let changedState = try localRepository.updatingRemoteDeviceRole(
                    machineID: machineID,
                    role: role
                )
                localStateToRestore = state
                localState = changedState
            }

            let read: FleetReadResult
            do {
                read = try await fleetAccess.save(
                    updated,
                    replacingRevision: displayedManifest.revision,
                    rootURL: fleetRootURL
                )
            } catch {
                if let localStateToRestore {
                    do {
                        try localRepository.save(localStateToRestore)
                        localState = localStateToRestore
                    } catch let rollbackError {
                        throw FleetStoreError.localRoleRollbackFailed(
                            change: error.localizedDescription,
                            rollback: rollbackError.localizedDescription
                        )
                    }
                }
                throw error
            }
            apply(read: read, currentSnapshot: currentSnapshot)
            selectedMachineID = machineID
            lastActionMessage = enrolled
                ? "\(device.name) is now in the fleet. Its applicable defaults now drive drift."
                : "\(device.name) was removed from fleet health. Its report and local connection were preserved."
        } catch {
            lastError = error.localizedDescription
            lastActionMessage = nil
            await reloadFleet()
        }
    }

    func setDeviceRole(machineID: String, role: DeviceRole) async {
        guard !isBusy,
              let device = devices.first(where: { $0.machineID == machineID }) else { return }
        if device.status == .pending {
            guard device.localConnection != nil else {
                lastError = FleetStoreError.pendingDeviceRoleRequiresEnrollment(
                    device.name
                ).localizedDescription
                lastActionMessage = nil
                return
            }
            do {
                localState = try localRepository.updatingRemoteDeviceRole(
                    machineID: machineID,
                    role: role
                )
                await reloadFleet()
                lastActionMessage = "\(device.name) is classified as a \(role.label.lowercased())."
            } catch {
                lastError = error.localizedDescription
            }
            return
        }
        await setDeviceEnrollment(
            machineID: machineID,
            enrolled: device.status == .enrolled,
            role: role
        )
    }

    func setDeviceScope(
        machineID: String,
        componentID: String,
        selection: DeviceScopeSelection
    ) async {
        guard !isBusy,
              let displayedManifest = manifest,
              let fleetRootURL,
              let snapshot = knownSnapshots[machineID] else { return }

        isUpdatingScope = true
        lastError = nil
        lastActionMessage = nil
        defer { isUpdatingScope = false }

        do {
            let state = try localRepository.loadOrCreate()
            let updated = try displayedManifest.settingDeviceScope(
                componentID: componentID,
                selection: selection,
                snapshot: snapshot,
                knownSnapshots: Array(knownSnapshots.values),
                updatedByMachineID: state.machineID
            )
            let read = try await fleetAccess.save(
                updated,
                replacingRevision: displayedManifest.revision,
                rootURL: fleetRootURL
            )
            apply(read: read, currentSnapshot: try currentLocalSnapshot())
            selectedMachineID = machineID
            let name = updated.target(componentID)?.name ?? componentID
            lastActionMessage = "\(name) now uses ‘\(selection.label)’ on \(snapshot.name). No repair command ran."
        } catch {
            lastError = error.localizedDescription
            lastActionMessage = nil
            await reloadFleet()
        }
    }

    func chooseFleetFolder() async {
        guard !isBusy else { return }
        let panel = NSOpenPanel()
        panel.title = "Choose FleetMesh Fleet Folder"
        panel.prompt = "Use Folder"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            localState = try localRepository.updatingFleetRoot(url)
            await refresh()
        } catch {
            lastError = error.localizedDescription
            lastActionMessage = nil
        }
    }

    func chooseExistingFleetFolder() async {
        guard !isBusy else { return }
        let panel = NSOpenPanel()
        panel.title = "Choose Existing FleetMesh Fleet Folder"
        panel.message = "Select the folder that contains fleet-manifest.json. FleetMesh will not create or replace a baseline while joining."
        panel.prompt = "Connect Fleet"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        await connectExistingFleet(at: url)
    }

    private func connectExistingFleet(at url: URL) async {
        guard !isBusy else { return }
        isUpdatingScope = true
        lastError = nil
        lastActionMessage = nil
        defer { isUpdatingScope = false }

        let validation = await fleetAccess.loadManifest(rootURL: url)
        guard validation.manifest != nil else {
            lastError = validation.issue?.detail
                ?? "The selected folder does not contain a readable fleet-manifest.json. Wait for sync to finish or choose the existing shared fleet folder."
            lastActionMessage = nil
            return
        }
        do {
            let snapshot = try currentLocalSnapshot()
            let (read, connectedState) = try await fleetAccess.connect(
                snapshot: snapshot,
                rootURL: url,
                persistLocalRoot: { [localRepository] root in
                    try localRepository.updatingFleetRoot(root)
                }
            )
            localState = connectedState
            apply(read: read, currentSnapshot: snapshot)
            lastActionMessage = "Connected to the existing fleet. Review this Mac, then choose Join this Mac."
        } catch {
            lastError = error.localizedDescription
            lastActionMessage = nil
        }
        await refreshDetectedExistingFleet()
    }

    func revealFleetFolder() {
        guard let fleetRootURL else { return }
        NSWorkspace.shared.open(fleetRootURL)
    }

    func setMachineDisplayName(_ name: String) async {
        guard !isBusy else { return }
        lastError = nil
        lastActionMessage = nil
        do {
            localState = try localRepository.updatingDisplayName(name)
            await refresh()
            lastActionMessage = "This Mac is now named \(localState?.displayName ?? name) in fleet reports."
        } catch {
            lastError = error.localizedDescription
            lastActionMessage = nil
        }
    }

    func bootstrapPlan(for assessment: MachineAssessment) -> [BootstrapStep] {
        bootstrapPlanner.plan(for: assessment)
    }

    func doctorFindings(for assessment: MachineAssessment) -> [DoctorFinding] {
        doctorPlanner.findings(
            for: assessment,
            manifest: manifest,
            repositoryTargets: repositoryTargets
        )
    }

    func doctorRun(for componentID: String) -> DoctorRunRecord? {
        doctorRuns[componentID]
    }

    func repair(componentID: String, targetMachineID: String) async {
        guard !isBusy else { return }
        let startedAt = Date()
        let originalName = selectedAssessment?.drifts
            .first { $0.componentID == componentID }?.name ?? componentID

        isDoctorRunning = true
        activeDoctorComponentID = componentID
        lastError = nil
        lastActionMessage = nil
        doctorRuns[componentID] = DoctorRunRecord(
            componentID: componentID,
            componentName: originalName,
            outcome: .running,
            summary: "Running a fresh safety scan before any change.",
            output: nil,
            startedAt: startedAt,
            finishedAt: nil
        )
        defer {
            isDoctorRunning = false
            activeDoctorComponentID = nil
        }

        do {
            let state = try localRepository.loadOrCreate()
            guard targetMachineID == state.machineID else {
                finishDoctorRun(
                    componentID: componentID,
                    componentName: originalName,
                    outcome: .protected,
                    summary: "Doctor can repair only the Mac on which it is running. Open FleetMesh on the selected Mac to continue.",
                    output: nil,
                    startedAt: startedAt
                )
                return
            }

            let preflight = try await scanForDoctor()
            guard preflight.machineID == targetMachineID else {
                finishDoctorRun(
                    componentID: componentID,
                    componentName: originalName,
                    outcome: .protected,
                    summary: "Doctor can repair only the Mac on which it is running.",
                    output: nil,
                    startedAt: startedAt
                )
                return
            }

            guard let approvedManifest = manifest else {
                finishDoctorRun(
                    componentID: componentID,
                    componentName: originalName,
                    outcome: .protected,
                    summary: "The fleet manifest was unavailable after preflight. No repair command ran.",
                    output: nil,
                    startedAt: startedAt
                )
                return
            }
            let approvedRepositoryTargets = repositoryTargets
            let approvedTarget = approvedManifest.target(componentID).map {
                ResolvedFleetTarget(
                    baseline: $0,
                    repositoryBuild: approvedRepositoryTargets[componentID]
                )
            }

            let assessment = driftEngine.assess(
                snapshot: preflight,
                manifest: approvedManifest,
                repositoryTargets: approvedRepositoryTargets
            )
            guard let drift = assessment.drifts.first(where: { $0.componentID == componentID }) else {
                finishDoctorRun(
                    componentID: componentID,
                    componentName: originalName,
                    outcome: .needsAttention,
                    summary: "The fresh scan did not contain enough managed evidence to choose a repair.",
                    output: nil,
                    startedAt: startedAt
                )
                return
            }

            if drift.state == .aligned {
                finishDoctorRun(
                    componentID: componentID,
                    componentName: drift.name,
                    outcome: .repaired,
                    summary: "Fresh evidence is already aligned; no repair command ran.",
                    output: nil,
                    startedAt: startedAt
                )
                return
            }

            let finding = doctorPlanner.finding(
                for: drift,
                observation: preflight.component(componentID),
                resolvedTarget: approvedTarget
            )
            guard finding.canRepair, let recipe = finding.recipe else {
                finishDoctorRun(
                    componentID: componentID,
                    componentName: drift.name,
                    outcome: finding.disposition == .protected ? .protected : .needsAttention,
                    summary: finding.detail,
                    output: nil,
                    startedAt: startedAt
                )
                return
            }

            guard recipe.componentID == componentID,
                  DoctorCatalog.definition(for: componentID)?.recipe == recipe else {
                finishDoctorRun(
                    componentID: componentID,
                    componentName: drift.name,
                    outcome: .protected,
                    summary: "The requested action did not match Doctor's built-in repair catalog.",
                    output: nil,
                    startedAt: startedAt
                )
                return
            }

            let command = recipe.resolve(homeURL: doctorHomeURL)
            guard FileManager.default.isExecutableFile(atPath: command.executableURL.path) else {
                finishDoctorRun(
                    componentID: componentID,
                    componentName: drift.name,
                    outcome: .failed,
                    summary: "The product-owned repair entrypoint is missing or is not executable.",
                    output: nil,
                    startedAt: startedAt
                )
                return
            }
            if let workingDirectoryURL = command.workingDirectoryURL {
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(
                    atPath: workingDirectoryURL.path,
                    isDirectory: &isDirectory
                ), isDirectory.boolValue else {
                    finishDoctorRun(
                        componentID: componentID,
                        componentName: drift.name,
                        outcome: .failed,
                        summary: "The product checkout required by this repair is unavailable.",
                        output: nil,
                        startedAt: startedAt
                    )
                    return
                }
            }

            // Pin the authority and checkout state immediately before execution.
            // The installer may run for minutes; postflight is still evaluated
            // against these approved values, never mutable store state.
            guard let fleetRootURL else {
                finishDoctorRun(
                    componentID: componentID,
                    componentName: drift.name,
                    outcome: .protected,
                    summary: "The fleet folder became unavailable before execution. No repair command ran.",
                    output: nil,
                    startedAt: startedAt
                )
                return
            }
            let executionPreflight = await inventory.capture(
                machineID: state.machineID,
                displayName: state.displayName
            )
            let executionManifest = await fleetAccess.loadManifest(rootURL: fleetRootURL).manifest
            guard executionManifest?.revision == approvedManifest.revision,
                  executionPreflight.machineID == targetMachineID,
                  DoctorApproval.matchesPinnedSource(
                    approved: preflight.component(componentID),
                    current: executionPreflight.component(componentID),
                    requiresCleanSource: recipe.requiresCleanSource
                  ) else {
                finishDoctorRun(
                    componentID: componentID,
                    componentName: drift.name,
                    outcome: .protected,
                    summary: "Fleet authority or source state changed after preflight. No repair command ran; scan and review again.",
                    output: nil,
                    startedAt: startedAt
                )
                return
            }

            doctorRuns[componentID] = DoctorRunRecord(
                componentID: componentID,
                componentName: drift.name,
                outcome: .running,
                summary: "Running \(finding.title), then FleetMesh will re-scan installed state.",
                output: nil,
                startedAt: startedAt,
                finishedAt: nil
            )
            let commandResult = await doctorCommandRunner.run(command)

            let postflight: MachineSnapshot
            do {
                postflight = try await scanForDoctor()
            } catch {
                finishDoctorRun(
                    componentID: componentID,
                    componentName: drift.name,
                    outcome: .failed,
                    summary: "The repair ran, but the required post-repair scan failed: \(error.localizedDescription)",
                    output: commandResult.combinedOutput,
                    startedAt: startedAt
                )
                return
            }

            let postAssessment = driftEngine.assess(
                snapshot: postflight,
                manifest: approvedManifest,
                repositoryTargets: approvedRepositoryTargets
            )
            let postDrift = postAssessment.drifts.first { $0.componentID == componentID }
            if commandResult.timedOut {
                finishDoctorRun(
                    componentID: componentID,
                    componentName: drift.name,
                    outcome: .failed,
                    summary: "The repair exceeded its time limit. Fresh evidence was published and still requires review.",
                    output: commandResult.combinedOutput,
                    startedAt: startedAt
                )
            } else if commandResult.exitCode != 0 {
                finishDoctorRun(
                    componentID: componentID,
                    componentName: drift.name,
                    outcome: .failed,
                    summary: "\(commandResult.failureSummary) Fresh evidence was published.",
                    output: commandResult.combinedOutput,
                    startedAt: startedAt
                )
            } else if postDrift?.state == .aligned {
                finishDoctorRun(
                    componentID: componentID,
                    componentName: drift.name,
                    outcome: .repaired,
                    summary: "Repair completed and a fresh scan now matches the fleet baseline.",
                    output: commandResult.combinedOutput,
                    startedAt: startedAt
                )
            } else if doctorPlanner.repairedLocalState(
                before: preflight.component(componentID),
                after: postflight.component(componentID)
            ) {
                finishDoctorRun(
                    componentID: componentID,
                    componentName: drift.name,
                    outcome: .repairedNeedsBaselineReview,
                    summary: "The installed app now matches its clean source checkout. The fleet baseline still records the prior build and needs a separate explicit decision.",
                    output: commandResult.combinedOutput,
                    startedAt: startedAt
                )
            } else {
                finishDoctorRun(
                    componentID: componentID,
                    componentName: drift.name,
                    outcome: .needsAttention,
                    summary: postDrift?.summary
                        ?? "The repair exited successfully, but fresh evidence did not prove alignment.",
                    output: commandResult.combinedOutput,
                    startedAt: startedAt
                )
            }
        } catch {
            lastError = error.localizedDescription
            finishDoctorRun(
                componentID: componentID,
                componentName: originalName,
                outcome: .failed,
                summary: "Doctor could not complete its safety scan: \(error.localizedDescription)",
                output: nil,
                startedAt: startedAt
            )
        }
    }

    private func reloadFleet() async {
        guard let fleetRootURL, let localSnapshot else { return }
        let read = await Task.detached(priority: .utility) {
            FleetRepository(rootURL: fleetRootURL).load()
        }.value
        apply(read: read, currentSnapshot: localSnapshot)
    }

    private func currentLocalSnapshot() throws -> MachineSnapshot {
        guard let localSnapshot else {
            throw FleetStoreError.localSnapshotUnavailable
        }
        return localSnapshot
    }

    private func requireManifestForRemoteCheckIn() async throws {
        guard let fleetRootURL else {
            throw FleetStoreError.missingManifestForRemoteCheckIn
        }
        let read = await fleetAccess.loadManifest(rootURL: fleetRootURL)
        guard read.manifest != nil else {
            throw read.issue != nil
                ? FleetStoreError.unreadableManifestForRemoteCheckIn
                : FleetStoreError.missingManifestForRemoteCheckIn
        }
    }

    private func scanForDoctor() async throws -> MachineSnapshot {
        isRefreshing = true
        defer { isRefreshing = false }
        return try await scanAndPublish()
    }

    private func scanAndPublish(requireManifest: Bool = false) async throws -> MachineSnapshot {
        let state = try localRepository.loadOrCreate()
        localState = state
        let snapshot = await inventory.capture(
            machineID: state.machineID,
            displayName: state.displayName
        )
        localSnapshot = snapshot

        let fleetRoot = URL(fileURLWithPath: state.fleetRootPath, isDirectory: true)
        let read = try await Task.detached(priority: .utility) {
            let repository = FleetRepository(rootURL: fleetRoot)
            let manifestRead = repository.loadManifest()
            var result = FleetReadResult(
                manifest: manifestRead.manifest,
                machines: [],
                issues: manifestRead.issue.map { [$0] } ?? []
            )
            // Missing authority can mean OneDrive has not downloaded the
            // manifest yet. Inventory locally, but publish only after an
            // existing manifest is readable.
            if result.manifest != nil {
                _ = try repository.publish(snapshot)
                result = repository.load()
            } else if requireManifest {
                throw manifestRead.issue == nil
                    ? FleetStoreError.missingManifestForRemoteCheckIn
                    : FleetStoreError.unreadableManifestForRemoteCheckIn
            }

            return result
        }.value

        apply(read: read, currentSnapshot: snapshot)
        lastRefreshAt = Date()
        return snapshot
    }

    private func refreshDetectedExistingFleet() async {
        let canonical = LocalStateRepository.canonicalSharedFleetURL(
            homeURL: localRepository.homeURL
        )
        guard canonical.standardizedFileURL != fleetRootURL?.standardizedFileURL else {
            detectedExistingFleetURL = nil
            return
        }
        let manifest = await Task.detached(priority: .utility) {
            FleetRepository(rootURL: canonical).loadManifest().manifest
        }.value
        detectedExistingFleetURL = manifest == nil ? nil : canonical
    }

    private func finishDoctorRun(
        componentID: String,
        componentName: String,
        outcome: DoctorRunOutcome,
        summary: String,
        output: String?,
        startedAt: Date
    ) {
        doctorRuns[componentID] = DoctorRunRecord(
            componentID: componentID,
            componentName: componentName,
            outcome: outcome,
            summary: summary,
            output: output,
            startedAt: startedAt,
            finishedAt: Date()
        )
    }

    private func apply(read: FleetReadResult, currentSnapshot: MachineSnapshot) {
        manifest = read.manifest
        issues = read.issues

        var machines = read.machines.filter { $0.machineID != currentSnapshot.machineID }
        machines.append(currentSnapshot)
        machines.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        knownSnapshots = [:]
        for machine in machines {
            knownSnapshots[machine.machineID] = machine
        }

        if let persistedManifest = read.manifest {
            repositoryTargets = RepositoryTargetResolver().resolve(
                manifest: persistedManifest,
                localSnapshot: currentSnapshot
            )
        } else {
            repositoryTargets = [:]
        }

        var resolvedIssues = read.issues
        var policies: [String: FleetDevicePolicy] = [:]
        for policy in read.manifest?.devices ?? [] {
            if policies[policy.machineID] != nil {
                resolvedIssues.append(FleetIssue(
                    id: "duplicate-device-policy-\(policy.machineID.lowercased())",
                    title: "Duplicate device policy ignored",
                    detail: "The manifest contains more than one policy for the same privacy-preserving device ID. FleetMesh used the first policy and left fleet health incomplete."
                ))
                continue
            }
            policies[policy.machineID] = policy
        }
        var connections: [String: RemoteDeviceConnection] = [:]
        for connection in localState?.remoteConnections ?? [] {
            if connections[connection.machineID] != nil {
                resolvedIssues.append(FleetIssue(
                    id: "duplicate-local-connection-\(connection.machineID.lowercased())",
                    title: "Duplicate local device connection ignored",
                    detail: "Local controller state contains more than one connection for the same privacy-preserving device ID. FleetMesh used the first connection."
                ))
                continue
            }
            connections[connection.machineID] = connection
        }
        issues = resolvedIssues
        let machineIDs = Set(knownSnapshots.keys)
            .union(policies.keys)
            .union(connections.keys)
        devices = machineIDs.map { machineID in
            FleetDeviceItem(
                machineID: machineID,
                snapshot: knownSnapshots[machineID],
                policy: policies[machineID],
                localConnection: connections[machineID],
                status: read.manifest.map { $0.enrollmentStatus(for: machineID) } ?? .pending
            )
        }.sorted { lhs, rhs in
            if lhs.status != rhs.status {
                let rank: [DeviceEnrollmentStatus: Int] = [
                    .pending: 0, .enrolled: 1, .excluded: 2,
                ]
                return rank[lhs.status, default: 9] < rank[rhs.status, default: 9]
            }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
        assessments = devices.compactMap { device in
            guard device.status == .enrolled, let snapshot = device.snapshot else { return nil }
            return driftEngine.assess(
                snapshot: snapshot,
                manifest: read.manifest,
                repositoryTargets: repositoryTargets
            )
        }

        if selectedMachineID == nil
            || !devices.contains(where: { $0.machineID == selectedMachineID }) {
            selectedMachineID = currentSnapshot.machineID
        }
    }

    private func resolvedTarget(_ componentID: String) -> ResolvedFleetTarget? {
        manifest?.target(componentID).map {
            ResolvedFleetTarget(
                baseline: $0,
                repositoryBuild: repositoryTargets[componentID]
            )
        }
    }
}

private enum FleetStoreError: LocalizedError {
    case localSnapshotUnavailable
    case missingManifestForRemoteCheckIn
    case unreadableManifestForRemoteCheckIn
    case pendingDeviceRoleRequiresEnrollment(String)
    case managedComponentCannotBeHidden(String)
    case unknownCatalogComponent(String)
    case fleetConnectionLost
    case localRoleRollbackFailed(change: String, rollback: String)
    case freshObservationUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .localSnapshotUnavailable:
            "Scan this Mac before changing device policy."
        case .missingManifestForRemoteCheckIn:
            "Connect or create a valid fleet baseline before adding or checking in a remote device."
        case .unreadableManifestForRemoteCheckIn:
            "The fleet baseline could not be read. Resolve that fleet issue before checking in a remote device."
        case .pendingDeviceRoleRequiresEnrollment(let name):
            "Add \(name) to the fleet before changing its role on this controller."
        case .managedComponentCannotBeHidden(let name):
            "Remove \(name) from fleet scope before hiding it from this Mac's Available list."
        case .unknownCatalogComponent(let componentID):
            "\(componentID) is no longer present in the FleetMesh catalog."
        case .fleetConnectionLost:
            "The fleet manifest changed or disappeared while connecting. FleetMesh restored the previous fleet folder; wait for sync to finish and try again."
        case .localRoleRollbackFailed(let change, let rollback):
            "The fleet policy change failed (\(change)), and FleetMesh could not restore the controller's previous device role (\(rollback)). Reopen FleetMesh and reconcile the role before checking in this device again."
        case .freshObservationUnavailable(let componentID):
            "A fresh clean observation for \(componentID) was unavailable, so FleetMesh did not change the baseline."
        }
    }
}
