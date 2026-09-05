import AppKit
import Foundation
import Observation

@MainActor
@Observable
final class FleetStore {
    private(set) var localState: LocalDeviceState?
    private(set) var localSnapshot: MachineSnapshot?
    private(set) var manifest: FleetManifest?
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

    init(
        localRepository: LocalStateRepository = LocalStateRepository(),
        inventory: any InventoryCapturing = InventoryService(),
        remoteInventory: any RemoteInventoryCapturing = SSHRemoteInventoryService(),
        driftEngine: DriftEngine = DriftEngine(),
        bootstrapPlanner: BootstrapPlanner = BootstrapPlanner(),
        doctorPlanner: DoctorPlanner = DoctorPlanner(),
        doctorCommandRunner: any DoctorCommandRunning = ProcessDoctorCommandRunner(),
        doctorHomeURL: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.localRepository = localRepository
        self.inventory = inventory
        self.remoteInventory = remoteInventory
        self.driftEngine = driftEngine
        self.bootstrapPlanner = bootstrapPlanner
        self.doctorPlanner = doctorPlanner
        self.doctorCommandRunner = doctorCommandRunner
        self.doctorHomeURL = doctorHomeURL
    }

    var fleetRootURL: URL? {
        localState.map { URL(fileURLWithPath: $0.fleetRootPath, isDirectory: true) }
    }

    var isBusy: Bool {
        isRefreshing || isDoctorRunning || isUpdatingScope || !checkingRemoteDeviceIDs.isEmpty
    }

    var fleetScopeItems: [FleetScopeItem] {
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
        if lastError != nil { return .unknown }
        if !issues.isEmpty { return .unknown }
        if !missingEnrolledDevices.isEmpty { return .unknown }
        if assessments.contains(where: { $0.verdict == .critical }) { return .critical }
        if assessments.contains(where: { $0.verdict == .attention }) { return .attention }
        if assessments.isEmpty || manifest == nil { return .unknown }
        return .aligned
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
    }

    func adoptThisMacAsBaseline() async {
        guard !isBusy, let snapshot = localSnapshot, let fleetRootURL else { return }
        isUpdatingScope = true
        lastError = nil
        lastActionMessage = nil
        defer { isUpdatingScope = false }
        do {
            let newManifest = FleetManifest(snapshot: snapshot)
            try FleetRepository(rootURL: fleetRootURL).saveManifest(newManifest)
            await reloadFleet()
            lastError = nil
            lastActionMessage = "Fleet baseline replaced with this Mac's fresh observed state."
        } catch {
            lastError = error.localizedDescription
            lastActionMessage = nil
        }
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

            let repository = FleetRepository(rootURL: fleetRootURL)
            _ = try repository.publish(snapshot)
            let updatedManifest = try displayedManifest.settingManaged(
                componentID: componentID,
                managed: managed,
                observation: snapshot.component(componentID),
                updatedByMachineID: state.machineID
            )
            try repository.saveManifest(
                updatedManifest,
                replacingRevision: displayedManifest.revision
            )

            let read = repository.load()
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
            try requireManifestForRemoteCheckIn()
            try migrateLegacyManifestBeforeNewDevice()
            localState = try localRepository.addingRemoteDevice(connection)
            selectedMachineID = connection.machineID
            let snapshot = try await remoteInventory.capture(connection: connection)
            guard let fleetRootURL else { return }
            let repository = FleetRepository(rootURL: fleetRootURL)
            _ = try repository.publish(snapshot)
            let read = repository.load()
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
            try requireManifestForRemoteCheckIn()
            try migrateLegacyManifestBeforeNewDevice()
            let snapshot = try await remoteInventory.capture(connection: connection)
            let repository = FleetRepository(rootURL: fleetRootURL)
            _ = try repository.publish(snapshot)
            apply(read: repository.load(), currentSnapshot: try currentLocalSnapshot())
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
            let repository = FleetRepository(rootURL: fleetRootURL)
            try repository.saveManifest(
                updated,
                replacingRevision: displayedManifest.revision
            )
            if device.localConnection != nil {
                localState = try localRepository.updatingRemoteDeviceRole(
                    machineID: machineID,
                    role: role
                )
            }
            apply(read: repository.load(), currentSnapshot: try currentLocalSnapshot())
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
            let repository = FleetRepository(rootURL: fleetRootURL)
            try repository.saveManifest(
                updated,
                replacingRevision: displayedManifest.revision
            )
            apply(read: repository.load(), currentSnapshot: try currentLocalSnapshot())
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
        doctorPlanner.findings(for: assessment, manifest: manifest)
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

            let assessment = driftEngine.assess(snapshot: preflight, manifest: manifest)
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
                target: manifest?.target(componentID)
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

            let postAssessment = driftEngine.assess(snapshot: postflight, manifest: manifest)
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
                    summary: "The product-owned repair exited with status \(commandResult.exitCode). Fresh evidence was published.",
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
        let read = FleetRepository(rootURL: fleetRootURL).load()
        apply(read: read, currentSnapshot: localSnapshot)
    }

    private func currentLocalSnapshot() throws -> MachineSnapshot {
        guard let localSnapshot else {
            throw FleetStoreError.localSnapshotUnavailable
        }
        return localSnapshot
    }

    private func migrateLegacyManifestBeforeNewDevice() throws {
        guard let fleetRootURL else { return }
        let repository = FleetRepository(rootURL: fleetRootURL)
        let read = repository.load()
        guard let current = read.manifest, current.needsDevicePolicyMigration else { return }
        let state = try localRepository.loadOrCreate()
        var snapshots = read.machines
        if let localSnapshot, !snapshots.contains(where: {
            $0.machineID == localSnapshot.machineID
        }) {
            snapshots.append(localSnapshot)
        }
        let migrated = current.migratingLegacyDevices(
            snapshots,
            updatedByMachineID: state.machineID,
            updatedAt: Date(),
            preserveRevision: false
        )
        try repository.saveManifest(migrated, replacingRevision: current.revision)
        manifest = migrated
    }

    private func requireManifestForRemoteCheckIn() throws {
        guard let fleetRootURL else {
            throw FleetStoreError.missingManifestForRemoteCheckIn
        }
        let repository = FleetRepository(rootURL: fleetRootURL)
        let read = repository.load()
        guard read.manifest != nil else {
            throw repository.manifestExists
                ? FleetStoreError.unreadableManifestForRemoteCheckIn
                : FleetStoreError.missingManifestForRemoteCheckIn
        }
    }

    private func scanForDoctor() async throws -> MachineSnapshot {
        isRefreshing = true
        defer { isRefreshing = false }
        return try await scanAndPublish()
    }

    private func scanAndPublish() async throws -> MachineSnapshot {
        let state = try localRepository.loadOrCreate()
        localState = state
        let snapshot = await inventory.capture(
            machineID: state.machineID,
            displayName: state.displayName
        )
        localSnapshot = snapshot

        let repository = FleetRepository(
            rootURL: URL(fileURLWithPath: state.fleetRootPath, isDirectory: true)
        )
        _ = try repository.publish(snapshot)

        var read = repository.load()
        if read.manifest == nil
            && !repository.manifestExists
            && LocalStateRepository.maySeedInitialManifest(
                state: state,
                homeURL: localRepository.homeURL
            ) {
            let seeded = FleetManifest(snapshot: snapshot)
            try repository.saveManifest(seeded)
            read = repository.load()
        }

        if let current = read.manifest, current.needsDevicePolicyMigration {
            let migrated = current.migratingLegacyDevices(
                read.machines,
                updatedByMachineID: state.machineID,
                updatedAt: Date(),
                preserveRevision: false
            )
            try repository.saveManifest(
                migrated,
                replacingRevision: current.revision
            )
            read = repository.load()
        }

        apply(read: read, currentSnapshot: snapshot)
        lastRefreshAt = Date()
        return snapshot
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
            return driftEngine.assess(snapshot: snapshot, manifest: read.manifest)
        }

        if selectedMachineID == nil
            || !devices.contains(where: { $0.machineID == selectedMachineID }) {
            selectedMachineID = currentSnapshot.machineID
        }
    }
}

private enum FleetStoreError: LocalizedError {
    case localSnapshotUnavailable
    case missingManifestForRemoteCheckIn
    case unreadableManifestForRemoteCheckIn
    case pendingDeviceRoleRequiresEnrollment(String)

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
        }
    }
}
