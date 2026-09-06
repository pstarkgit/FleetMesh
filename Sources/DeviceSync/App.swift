import AppKit
import Observation
import SwiftUI

@main
struct DeviceSyncApp: App {
    @NSApplicationDelegateAdaptor(DeviceSyncAppDelegate.self) private var appDelegate
    @State private var appState = DeviceSyncAppState.shared
    @State private var appearance = FleetMeshAppearanceStore.shared

    init() {
        let arguments = CommandLine.arguments
        if arguments.contains("--version") {
            print("\(FleetMeshIdentity.productName) \(DeviceSyncVersion.current)")
            exit(0)
        }
        if let operation = HeadlessOperation(arguments: arguments) {
            Self.runHeadless(operation: operation)
        }
    }

    var body: some Scene {
        Window(FleetMeshIdentity.productName, id: DeviceSyncWindow.main) {
            RootView(
                store: appState.store,
                navigation: appState.navigation,
                appearance: appearance
            )
                .frame(minWidth: 1040, minHeight: 720)
                .preferredColorScheme(appearance.selection.colorScheme)
                .background(AdaptiveWindowAppearance(selection: appearance.selection))
                .background(DeviceSyncWindowRegistrar(appState: appState))
                .task { await appState.store.start() }
        }
        .defaultSize(width: 1280, height: 820)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Refresh Fleet") {
                    Task { await appState.store.refresh() }
                }
                .keyboardShortcut("r", modifiers: .command)
            }
        }
    }

    private static func runHeadless(operation: HeadlessOperation) -> Never {
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached {
            defer { semaphore.signal() }
            do {
                if operation == .selfCheck {
                    print("\(FleetMeshIdentity.productName) \(DeviceSyncVersion.current): SELF-CHECK OK")
                    return
                }
                if case .migrateDynamoDB(
                    let mode,
                    let profile,
                    let region,
                    let table,
                    let fleetID
                ) = operation {
                    let result = try await FleetDynamoDBMigrationCommand.run(
                        mode: mode,
                        profile: profile,
                        region: region,
                        table: table,
                        fleetID: fleetID
                    )
                    print("migration: \(result.backend.rawValue)")
                    print("manifest: \(result.migration.manifestRevision)")
                    print("devices: \(result.migration.importedDeviceCount)")
                    print("shadow-match: \(result.migration.comparison.isMatch)")
                    return
                }
                let localRepository = LocalStateRepository()
                let state = try localRepository.loadOrCreate()
                let snapshot = await InventoryService().capture(
                    machineID: state.machineID,
                    displayName: state.displayName
                )
                let rootURL = URL(
                    fileURLWithPath: state.fleetRootPath,
                    isDirectory: true
                )
                let fleetAccess = FleetRepositoryAccess()
                try await fleetAccess.configure(
                    state: state,
                    rootURL: rootURL,
                    makeDynamoDBClient: FleetDynamoDBClientFactories.production
                )
                let existing = await fleetAccess.load(rootURL: rootURL)
                let read: FleetReadResult
                switch operation {
                case .adoptBaseline:
                    read = try await fleetAccess.replaceBaseline(
                        FleetManifest(snapshot: snapshot),
                        snapshot: snapshot,
                        rootURL: rootURL
                    )
                case .check:
                    if existing.manifest == nil {
                        read = existing
                    } else {
                        read = try await fleetAccess.publish(
                            snapshot,
                            rootURL: rootURL
                        )
                    }
                case .snapshot:
                    guard existing.manifest != nil else {
                        throw HeadlessOperationError.missingManifest
                    }
                    read = try await fleetAccess.publish(
                        snapshot,
                        rootURL: rootURL
                    )
                case .setManaged(let componentID, let managed):
                    guard let manifest = existing.manifest else {
                        throw HeadlessOperationError.missingManifest
                    }
                    let updated = try manifest.settingManaged(
                        componentID: componentID,
                        managed: managed,
                        observation: snapshot.component(componentID),
                        updatedByMachineID: state.machineID
                    )
                    read = try await fleetAccess.publishAndSave(
                        snapshot,
                        manifest: updated,
                        replacingRevision: manifest.revision,
                        rootURL: rootURL
                    )
                case .selfCheck, .migrateDynamoDB:
                    fatalError("early-return operation reached inventory")
                }
                let authorityDescription: String
                if state.effectiveStorageBackend == .json {
                    authorityDescription = rootURL.path
                } else {
                    authorityDescription = state.effectiveStorageBackend.rawValue
                }
                let productVersionTargets = read.manifest.map {
                    ProductVersionTargetResolver().resolve(
                        manifest: $0,
                        localSnapshot: snapshot
                    )
                } ?? [:]
                let assessment = DriftEngine().assess(
                    snapshot: snapshot,
                    manifest: read.manifest,
                    productVersionTargets: productVersionTargets
                )
                let allAssessments: [MachineAssessment] = read.machines.compactMap { machine -> MachineAssessment? in
                    guard read.manifest?.enrollmentStatus(for: machine.machineID) == .enrolled else {
                        return nil
                    }
                    return DriftEngine().assess(
                        snapshot: machine,
                        manifest: read.manifest,
                        productVersionTargets: productVersionTargets
                    )
                }
                let reportedIDs = Set(read.machines.map(\.machineID))
                let missingEnrolled = read.manifest?.devices?.filter {
                    $0.enrollment == .enrolled && !reportedIDs.contains($0.machineID)
                }.count ?? 0
                let fleetVerdict = FleetHealthEvaluator.verdict(
                    manifest: read.manifest,
                    assessments: allAssessments,
                    issueCount: read.issues.count,
                    missingEnrolledCount: missingEnrolled
                )
                switch operation {
                case .snapshot:
                    print("snapshot: \(authorityDescription)")
                case .adoptBaseline:
                    print("baseline: \(authorityDescription)")
                    print("targets: \(read.manifest?.activeTargets.count ?? 0)")
                case .setManaged(let componentID, let managed):
                    print("scope: \(componentID) \(managed ? "managed" : "unmanaged")")
                    print("baseline: \(authorityDescription)")
                    print("targets: \(read.manifest?.activeTargets.count ?? 0)")
                    print("snapshot: \(authorityDescription)")
                case .check:
                    print("\(FleetMeshIdentity.productName) \(DeviceSyncVersion.current): \(fleetVerdict.label)")
                    print("machine: \(snapshot.name) (\(snapshot.hostName))")
                    print("fleet authority: \(authorityDescription)")
                    print("components: \(snapshot.components.filter { $0.status == .installed }.count) installed, \(snapshot.components.filter { $0.status == .missing }.count) missing")
                    print("fleet: \(read.machines.count) report(s), \(assessment.attentionCount) attention item(s), \(read.issues.count) read issue(s)")
                    if fleetVerdict.headlessExitCode != 0 {
                        exit(fleetVerdict.headlessExitCode)
                    }
                case .selfCheck, .migrateDynamoDB:
                    break
                }
            } catch {
                fputs("\(FleetMeshIdentity.productName) check failed: \(error.localizedDescription)\n", stderr)
                exit(1)
            }
        }
        semaphore.wait()
        exit(0)
    }
}

enum HeadlessOperation: Equatable {
    case selfCheck
    case check
    case snapshot
    case adoptBaseline
    case setManaged(componentID: String, managed: Bool)
    case migrateDynamoDB(
        mode: FleetDynamoDBMigrationMode,
        profile: String,
        region: String,
        table: String,
        fleetID: String
    )

    init?(arguments: [String]) {
        if arguments.contains("--self-check") {
            self = .selfCheck
        } else if let index = arguments.firstIndex(of: "--migrate-dynamodb"),
                  arguments.indices.contains(index + 4) {
            self = .migrateDynamoDB(
                mode: arguments.contains("--cutover") ? .cutover : .shadow,
                profile: arguments[index + 1],
                region: arguments[index + 2],
                table: arguments[index + 3],
                fleetID: arguments[index + 4]
            )
        } else if arguments.contains("--check") {
            self = .check
        } else if arguments.contains("--snapshot") {
            self = .snapshot
        } else if arguments.contains("--adopt-baseline") {
            self = .adoptBaseline
        } else if let index = arguments.firstIndex(of: "--add-to-scope"),
                  arguments.indices.contains(index + 1) {
            self = .setManaged(componentID: arguments[index + 1], managed: true)
        } else if let index = arguments.firstIndex(of: "--remove-from-scope"),
                  arguments.indices.contains(index + 1) {
            self = .setManaged(componentID: arguments[index + 1], managed: false)
        } else {
            return nil
        }
    }
}

private enum HeadlessOperationError: LocalizedError {
    case missingManifest

    var errorDescription: String? {
        "No readable fleet baseline is available. Connect the existing shared fleet folder, or use --adopt-baseline explicitly to create a new fleet."
    }
}

enum DeviceSyncWindow {
    static let main = "main"
}

@MainActor
@Observable
final class DeviceSyncAppState {
    static let shared = DeviceSyncAppState()

    let store: FleetStore
    let navigation: AppNavigation
    let appearance: FleetMeshAppearanceStore

    private var statusItemController: DeviceSyncStatusItemController?
    private var openMainWindow: (() -> Void)?

    private init() {
        store = FleetStore()
        navigation = AppNavigation()
        appearance = FleetMeshAppearanceStore.shared
    }

    func installStatusItem() {
        guard statusItemController == nil else { return }
        statusItemController = DeviceSyncStatusItemController(
            store: store,
            appearance: appearance,
            openSection: { [weak self] section in self?.show(section) }
        )
    }

    func registerWindowOpener(_ opener: @escaping () -> Void) {
        openMainWindow = opener
    }

    func show(_ section: AppSection) {
        navigation.open(section)
        openMainWindow?()
        NSApp.activate(ignoringOtherApps: true)
        bringMainWindowForward(attemptsRemaining: 12)
    }

    private func bringMainWindowForward(attemptsRemaining: Int) {
        guard attemptsRemaining > 0 else { return }
        if let window = NSApp.windows.first(where: {
            $0.title == FleetMeshIdentity.productName
        }) {
            window.deminiaturize(nil)
            window.makeKeyAndOrderFront(nil)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.bringMainWindowForward(attemptsRemaining: attemptsRemaining - 1)
        }
    }
}

@MainActor
final class DeviceSyncAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        DeviceSyncAppState.shared.appearance.apply()
        DeviceSyncAppState.shared.installStatusItem()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        if !flag {
            DeviceSyncAppState.shared.show(.fleet)
        }
        return true
    }
}

private struct DeviceSyncWindowRegistrar: View {
    let appState: DeviceSyncAppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onAppear {
                appState.registerWindowOpener {
                    openWindow(id: DeviceSyncWindow.main)
                }
            }
        }
}

/// Keeps native AppKit chrome and the SwiftUI canvas on the same persisted
/// System/Light/Dark selection.
private struct AdaptiveWindowAppearance: NSViewRepresentable {
    let selection: FleetMeshAppearance

    func makeNSView(context: Context) -> AdaptiveWindowSentinel {
        AdaptiveWindowSentinel()
    }

    func updateNSView(_ nsView: AdaptiveWindowSentinel, context: Context) {
        nsView.applyAppearance(selection)
    }
}

@MainActor
private final class AdaptiveWindowSentinel: NSView {
    private var selection: FleetMeshAppearance = .system

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyAppearance(selection)
    }

    func applyAppearance(_ selection: FleetMeshAppearance) {
        self.selection = selection
        FleetMeshAppearanceStore.shared.apply(to: window)
    }
}
