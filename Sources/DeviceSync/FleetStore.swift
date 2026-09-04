import AppKit
import Foundation
import Observation

@MainActor
@Observable
final class FleetStore {
    private(set) var localState: LocalDeviceState?
    private(set) var localSnapshot: MachineSnapshot?
    private(set) var manifest: FleetManifest?
    private(set) var assessments: [MachineAssessment] = []
    private(set) var issues: [FleetIssue] = []
    private(set) var isRefreshing = false
    private(set) var isDoctorRunning = false
    private(set) var activeDoctorComponentID: String?
    private(set) var doctorRuns: [String: DoctorRunRecord] = [:]
    private(set) var lastError: String?
    private(set) var lastRefreshAt: Date?

    var selectedMachineID: String?
    var searchText = ""

    private var hasStarted = false

    private let localRepository: LocalStateRepository
    private let inventory: any InventoryCapturing
    private let driftEngine: DriftEngine
    private let bootstrapPlanner: BootstrapPlanner
    private let doctorPlanner: DoctorPlanner
    private let doctorCommandRunner: any DoctorCommandRunning
    private let doctorHomeURL: URL

    init(
        localRepository: LocalStateRepository = LocalStateRepository(),
        inventory: any InventoryCapturing = InventoryService(),
        driftEngine: DriftEngine = DriftEngine(),
        bootstrapPlanner: BootstrapPlanner = BootstrapPlanner(),
        doctorPlanner: DoctorPlanner = DoctorPlanner(),
        doctorCommandRunner: any DoctorCommandRunning = ProcessDoctorCommandRunner(),
        doctorHomeURL: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.localRepository = localRepository
        self.inventory = inventory
        self.driftEngine = driftEngine
        self.bootstrapPlanner = bootstrapPlanner
        self.doctorPlanner = doctorPlanner
        self.doctorCommandRunner = doctorCommandRunner
        self.doctorHomeURL = doctorHomeURL
    }

    var fleetRootURL: URL? {
        localState.map { URL(fileURLWithPath: $0.fleetRootPath, isDirectory: true) }
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
        if assessments.contains(where: { $0.verdict == .critical }) { return .critical }
        if assessments.contains(where: { $0.verdict == .attention }) { return .attention }
        if assessments.isEmpty || manifest == nil { return .unknown }
        return .aligned
    }

    var fleetAttentionCount: Int {
        assessments.reduce(0) { $0 + $1.attentionCount } + issues.count
    }

    var menuBarSummary: MenuBarSummary {
        MenuBarSummary(
            verdict: fleetVerdict,
            machineCount: assessments.count,
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
        guard !isRefreshing && !isDoctorRunning else { return }
        isRefreshing = true
        lastError = nil
        defer { isRefreshing = false }

        do {
            _ = try await scanAndPublish()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func adoptThisMacAsBaseline() async {
        guard let snapshot = localSnapshot, let fleetRootURL else { return }
        do {
            let newManifest = FleetManifest(snapshot: snapshot)
            try FleetRepository(rootURL: fleetRootURL).saveManifest(newManifest)
            await reloadFleet()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func chooseFleetFolder() async {
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
        }
    }

    func revealFleetFolder() {
        guard let fleetRootURL else { return }
        NSWorkspace.shared.open(fleetRootURL)
    }

    func setMachineDisplayName(_ name: String) async {
        do {
            localState = try localRepository.updatingDisplayName(name)
            await refresh()
        } catch {
            lastError = error.localizedDescription
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
        guard !isDoctorRunning && !isRefreshing else { return }
        let startedAt = Date()
        let originalName = selectedAssessment?.drifts
            .first { $0.componentID == componentID }?.name ?? componentID

        isDoctorRunning = true
        activeDoctorComponentID = componentID
        lastError = nil
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
        assessments = machines.map {
            driftEngine.assess(snapshot: $0, manifest: read.manifest)
        }

        if selectedMachineID == nil
            || !assessments.contains(where: { $0.snapshot.machineID == selectedMachineID }) {
            selectedMachineID = currentSnapshot.machineID
        }
    }
}
