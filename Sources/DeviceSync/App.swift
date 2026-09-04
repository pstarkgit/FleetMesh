import AppKit
import Observation
import SwiftUI

@main
struct DeviceSyncApp: App {
    @NSApplicationDelegateAdaptor(DeviceSyncAppDelegate.self) private var appDelegate
    @State private var appState = DeviceSyncAppState.shared

    init() {
        // FleetMesh uses a deliberately light evidence canvas. Pin the
        // AppKit appearance too: setting only SwiftUI's colorScheme left native
        // hosting layers in Aqua Dark, which turned bold primary labels white
        // on the light canvas after a Developer ID install.
        NSApplication.shared.appearance = NSAppearance(named: .aqua)

        let arguments = CommandLine.arguments
        if arguments.contains("--version") {
            print("\(FleetMeshIdentity.productName) \(DeviceSyncVersion.current)")
            exit(0)
        }
        if arguments.contains("--check")
            || arguments.contains("--snapshot")
            || arguments.contains("--adopt-baseline") {
            Self.runHeadless(
                snapshotOnly: arguments.contains("--snapshot"),
                adoptBaseline: arguments.contains("--adopt-baseline")
            )
        }
    }

    var body: some Scene {
        Window(FleetMeshIdentity.productName, id: DeviceSyncWindow.main) {
            RootView(store: appState.store, navigation: appState.navigation)
                .frame(minWidth: 1040, minHeight: 720)
                .preferredColorScheme(.light)
                .background(AquaWindowAppearance())
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

    private static func runHeadless(snapshotOnly: Bool, adoptBaseline: Bool) -> Never {
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached {
            defer { semaphore.signal() }
            do {
                let localRepository = LocalStateRepository()
                let state = try localRepository.loadOrCreate()
                let snapshot = await InventoryService().capture(
                    machineID: state.machineID,
                    displayName: state.displayName
                )
                let repository = FleetRepository(
                    rootURL: URL(fileURLWithPath: state.fleetRootPath, isDirectory: true)
                )
                let url = try repository.publish(snapshot)
                if adoptBaseline
                    || (!snapshotOnly
                        && !repository.manifestExists
                        && LocalStateRepository.maySeedInitialManifest(
                            state: state,
                            homeURL: localRepository.homeURL
                        )) {
                    try repository.saveManifest(FleetManifest(snapshot: snapshot))
                }
                let read = repository.load()
                let assessment = DriftEngine().assess(snapshot: snapshot, manifest: read.manifest)
                if snapshotOnly {
                    print("snapshot: \(url.path)")
                } else if adoptBaseline {
                    print("baseline: \(repository.manifestURL.path)")
                    print("targets: \(read.manifest?.activeTargets.count ?? 0)")
                } else {
                    print("\(FleetMeshIdentity.productName) \(DeviceSyncVersion.current): OK")
                    print("machine: \(snapshot.name) (\(snapshot.hostName))")
                    print("fleet folder: \(repository.rootURL.path)")
                    print("components: \(snapshot.components.filter { $0.status == .installed }.count) installed, \(snapshot.components.filter { $0.status == .missing }.count) missing")
                    print("fleet: \(read.machines.count) report(s), \(assessment.attentionCount) attention item(s), \(read.issues.count) read issue(s)")
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

enum DeviceSyncWindow {
    static let main = "main"
}

@MainActor
@Observable
final class DeviceSyncAppState {
    static let shared = DeviceSyncAppState()

    let store: FleetStore
    let navigation: AppNavigation

    private var statusItemController: DeviceSyncStatusItemController?
    private var openMainWindow: (() -> Void)?

    private init() {
        store = FleetStore()
        navigation = AppNavigation()
    }

    func installStatusItem() {
        guard statusItemController == nil else { return }
        statusItemController = DeviceSyncStatusItemController(
            store: store,
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

        // Opening a SwiftUI scene is asynchronous. Bring the singleton forward
        // on the next run loop and restore it if it was minimized.
        DispatchQueue.main.async {
            guard let window = NSApp.windows.first(where: {
                $0.title == FleetMeshIdentity.productName
            }) else {
                return
            }
            window.deminiaturize(nil)
            window.makeKeyAndOrderFront(nil)
        }
    }
}

@MainActor
private final class DeviceSyncAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        DeviceSyncAppState.shared.installStatusItem()
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

/// Pins the actual AppKit window to Aqua once SwiftUI has created it.
///
/// `preferredColorScheme(.light)` controls SwiftUI's environment but does not
/// reliably change the native `NSWindow`/toolbar appearance when the system is
/// in Dark Mode. That mismatch was visible in acceptance captures: the light
/// canvas rendered correctly while native and nested primary labels stayed
/// white. The window is the authoritative appearance boundary.
private struct AquaWindowAppearance: NSViewRepresentable {
    func makeNSView(context: Context) -> AquaWindowSentinel {
        AquaWindowSentinel()
    }

    func updateNSView(_ nsView: AquaWindowSentinel, context: Context) {
        nsView.applyAppearance()
    }
}

@MainActor
private final class AquaWindowSentinel: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyAppearance()
    }

    func applyAppearance() {
        guard let aqua = NSAppearance(named: .aqua) else { return }
        NSApp.appearance = aqua
        window?.appearance = aqua
        window?.contentView?.appearance = aqua
    }
}
