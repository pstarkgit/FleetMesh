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
    private(set) var lastError: String?
    private(set) var lastRefreshAt: Date?

    var selectedMachineID: String?
    var searchText = ""

    private let localRepository: LocalStateRepository
    private let inventory: InventoryService
    private let driftEngine: DriftEngine
    private let bootstrapPlanner: BootstrapPlanner

    init(
        localRepository: LocalStateRepository = LocalStateRepository(),
        inventory: InventoryService = InventoryService(),
        driftEngine: DriftEngine = DriftEngine(),
        bootstrapPlanner: BootstrapPlanner = BootstrapPlanner()
    ) {
        self.localRepository = localRepository
        self.inventory = inventory
        self.driftEngine = driftEngine
        self.bootstrapPlanner = bootstrapPlanner
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
        if !issues.isEmpty { return .unknown }
        if assessments.contains(where: { $0.verdict == .critical }) { return .critical }
        if assessments.contains(where: { $0.verdict == .attention }) { return .attention }
        if assessments.isEmpty || manifest == nil { return .unknown }
        return .aligned
    }

    var fleetAttentionCount: Int {
        assessments.reduce(0) { $0 + $1.attentionCount } + issues.count
    }

    func start() async {
        await refresh()
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        lastError = nil
        defer { isRefreshing = false }

        do {
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
            if read.manifest == nil && !repository.manifestExists {
                let seeded = FleetManifest(snapshot: snapshot)
                try repository.saveManifest(seeded)
                read = repository.load()
            }

            apply(read: read, currentSnapshot: snapshot)
            lastRefreshAt = Date()
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
        panel.title = "Choose Device Sync Fleet Folder"
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

    private func reloadFleet() async {
        guard let fleetRootURL, let localSnapshot else { return }
        let read = FleetRepository(rootURL: fleetRootURL).load()
        apply(read: read, currentSnapshot: localSnapshot)
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
