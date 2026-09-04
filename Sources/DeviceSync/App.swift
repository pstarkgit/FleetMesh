import AppKit
import SwiftUI

@main
struct DeviceSyncApp: App {
    @State private var store = FleetStore()

    init() {
        let arguments = CommandLine.arguments
        if arguments.contains("--version") {
            print(DeviceSyncVersion.current)
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
        WindowGroup {
            RootView(store: store)
                .frame(minWidth: 1040, minHeight: 720)
                .task { await store.start() }
        }
        .defaultSize(width: 1280, height: 820)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Refresh Fleet") {
                    Task { await store.refresh() }
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
                if adoptBaseline || (!snapshotOnly && !repository.manifestExists) {
                    try repository.saveManifest(FleetManifest(snapshot: snapshot))
                }
                let read = repository.load()
                let assessment = DriftEngine().assess(snapshot: snapshot, manifest: read.manifest)
                if snapshotOnly {
                    print("snapshot: \(url.path)")
                } else if adoptBaseline {
                    print("baseline: \(repository.manifestURL.path)")
                    print("targets: \(read.manifest?.targets.count ?? 0)")
                } else {
                    print("Device Sync \(DeviceSyncVersion.current): OK")
                    print("machine: \(snapshot.name) (\(snapshot.hostName))")
                    print("fleet folder: \(repository.rootURL.path)")
                    print("components: \(snapshot.components.filter { $0.status == .installed }.count) installed, \(snapshot.components.filter { $0.status == .missing }.count) missing")
                    print("fleet: \(read.machines.count) report(s), \(assessment.attentionCount) attention item(s), \(read.issues.count) read issue(s)")
                }
            } catch {
                fputs("Device Sync check failed: \(error.localizedDescription)\n", stderr)
                exit(1)
            }
        }
        semaphore.wait()
        exit(0)
    }
}
