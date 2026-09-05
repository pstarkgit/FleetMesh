import AppKit
import Observation
import SwiftUI

enum DeviceSyncStatusItemPlacement {
    // Preserve the pre-FleetMesh identity so AppKit reuses the user's slot.
    static let autosaveName = FleetMeshIdentity.statusItemAutosaveName
    static let preferenceKey = "NSStatusItem Preferred Position \(autosaveName)"
    static let defaultOffsetFromRightEdge = 48

    /// AppKit reads this value when the status item is created. Seed only our
    /// own unset slot, then preserve any placement the user establishes later.
    @discardableResult
    static func prepare(defaults: UserDefaults = .standard) -> Bool {
        guard defaults.object(forKey: preferenceKey) == nil else { return false }
        defaults.set(defaultOffsetFromRightEdge, forKey: preferenceKey)
        return true
    }
}

@MainActor
final class DeviceSyncStatusItemController: NSObject {
    private let store: FleetStore
    private let openSection: (AppSection) -> Void
    private let statusItem: NSStatusItem
    private let popover: NSPopover

    init(store: FleetStore, openSection: @escaping (AppSection) -> Void) {
        self.store = store
        self.openSection = openSection

        // The anonymous status item SwiftUI created could be pushed into this
        // Mac's crowded off-screen overflow. A named AppKit item owns a stable
        // FleetMesh-only slot without changing any other app's placement.
        DeviceSyncStatusItemPlacement.prepare()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.autosaveName = DeviceSyncStatusItemPlacement.autosaveName
        statusItem.isVisible = true

        popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.contentSize = NSSize(width: 350, height: 396)

        super.init()

        popover.contentViewController = NSHostingController(
            rootView: DeviceSyncMenuBarView(
                store: store,
                openSection: { [weak self] section in
                    self?.popover.performClose(nil)
                    self?.openSection(section)
                },
                quit: { NSApp.terminate(nil) }
            )
        )

        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePopover(_:))
            button.sendAction(on: [.leftMouseUp])
            button.identifier = NSUserInterfaceItemIdentifier("devicesync.statusItem")
        }

        updateStatusItem()
        observeStore()
    }

    @objc
    private func togglePopover(_ sender: Any?) {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    private func observeStore() {
        withObservationTracking {
            _ = store.menuBarSummary
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.updateStatusItem()
                self.observeStore()
            }
        }
    }

    private func updateStatusItem() {
        let summary = store.menuBarSummary
        guard let button = statusItem.button else { return }
        let label = "\(FleetMeshIdentity.productName) — \(summary.headline)"
        let image = Self.statusItemImage(summary: summary, label: label)
        button.image = image
        button.imagePosition = .imageOnly
        button.toolTip = "\(label) · \(summary.machineLabel) · \(summary.attentionLabel)"
        button.setAccessibilityLabel(label)
    }

    private static func statusItemImage(summary: MenuBarSummary, label: String) -> NSImage {
        let size = NSSize(width: 19, height: 19)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.labelColor.setStroke()
            NSColor.labelColor.setFill()
            let markRect = rect.insetBy(dx: 1.4, dy: 1.4)
            let links = NSBezierPath(FleetMeshMarkGeometry.links(in: markRect))
            links.lineWidth = 1.35
            links.lineCapStyle = .round
            links.lineJoinStyle = .round
            links.stroke()
            NSBezierPath(FleetMeshMarkGeometry.nodes(in: markRect)).fill()

            let badgeRect = NSRect(x: 12.0, y: 0.8, width: 6.2, height: 6.2)
            NSColor.controlBackgroundColor.setFill()
            NSBezierPath(ovalIn: badgeRect.insetBy(dx: -1, dy: -1)).fill()
            Self.badgeColor(for: summary).setFill()
            NSBezierPath(ovalIn: badgeRect).fill()
            return true
        }
        image.accessibilityDescription = label
        image.isTemplate = false
        return image
    }

    private static func badgeColor(for summary: MenuBarSummary) -> NSColor {
        if summary.isScanning { return .systemBlue }
        if summary.errorMessage != nil { return .systemRed }
        switch summary.verdict {
        case .aligned: return .systemGreen
        case .attention: return .systemOrange
        case .critical: return .systemRed
        case .unknown: return .systemGray
        }
    }
}

private extension NSBezierPath {
    convenience init(_ path: Path) {
        self.init()
        path.cgPath.applyWithBlock { elementPointer in
            let element = elementPointer.pointee
            switch element.type {
            case .moveToPoint:
                move(to: element.points[0])
            case .addLineToPoint:
                line(to: element.points[0])
            case .addQuadCurveToPoint:
                break
            case .addCurveToPoint:
                curve(
                    to: element.points[2],
                    controlPoint1: element.points[0],
                    controlPoint2: element.points[1]
                )
            case .closeSubpath:
                close()
            @unknown default:
                break
            }
        }
    }
}

struct MenuBarSummary: Equatable, Sendable {
    let verdict: FleetVerdict
    let machineCount: Int
    let attentionCount: Int
    let lastScanAt: Date?
    let isScanning: Bool
    let errorMessage: String?

    var headline: String {
        if isScanning { return "Scanning this Mac" }
        if errorMessage != nil { return "Scan failed" }
        return verdict.label
    }

    var statusSymbol: String {
        if isScanning { return "arrow.triangle.2.circlepath" }
        switch verdict {
        case .aligned: return "checkmark.circle.fill"
        case .attention: return "exclamationmark.triangle.fill"
        case .critical: return "xmark.octagon.fill"
        case .unknown: return "questionmark.circle.fill"
        }
    }

    var detail: String {
        if isScanning {
            return "Refreshing installed apps, revisions, and themes."
        }
        if errorMessage != nil {
            return "The last attempt did not produce fresh evidence."
        }
        switch verdict {
        case .aligned:
            return "Fresh fleet evidence matches the selected baseline."
        case .attention:
            return "One or more Macs have drift, stale evidence, or a decision."
        case .critical:
            return "A required app or configuration is missing."
        case .unknown:
            return "Some fleet evidence is missing or could not be verified."
        }
    }

    var machineLabel: String {
        "\(machineCount) machine\(machineCount == 1 ? "" : "s")"
    }

    var attentionLabel: String {
        "\(attentionCount) attention item\(attentionCount == 1 ? "" : "s")"
    }
}

struct DeviceSyncMenuBarView: View {
    @Bindable var store: FleetStore
    let openSection: (AppSection) -> Void
    let quit: () -> Void

    private var summary: MenuBarSummary { store.menuBarSummary }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            posture
            actions
            Divider()
            footer
        }
        .frame(width: 350)
        .background(DSTheme.canvas)
        .environment(\.colorScheme, .light)
        .task { await store.start() }
        .accessibilityIdentifier("devicesync.menu")
    }

    private var header: some View {
        HStack(spacing: 11) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(DSTheme.auroraGradient)
                FleetMeshMark()
                    .padding(6)
            }
            .frame(width: 38, height: 38)

            VStack(alignment: .leading, spacing: 1) {
                Text(FleetMeshIdentity.productName)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(DSTheme.ink)
                Text("Mac fleet control plane")
                    .font(.caption)
                    .foregroundStyle(DSTheme.inkMuted)
            }
            Spacer()
            Text("v\(DeviceSyncVersion.current)")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(DSTheme.inkMuted)
        }
        .padding(16)
    }

    private var posture: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    Circle()
                        .fill(DSTheme.color(for: summary.verdict).opacity(0.12))
                    if summary.isScanning {
                        ProgressView()
                            .controlSize(.small)
                            .tint(DSTheme.color(for: summary.verdict))
                    } else {
                        Image(systemName: summary.statusSymbol)
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(DSTheme.color(for: summary.verdict))
                    }
                }
                .frame(width: 44, height: 44)

                VStack(alignment: .leading, spacing: 3) {
                    Text(summary.headline)
                        .font(.system(size: 17, weight: .bold, design: .rounded))
                        .foregroundStyle(DSTheme.ink)
                        .accessibilityIdentifier("devicesync.menu.status")
                    Text(summary.detail)
                        .font(.caption)
                        .foregroundStyle(DSTheme.inkSoft)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack(spacing: 10) {
                MenuMetric(
                    symbol: "laptopcomputer",
                    value: "\(summary.machineCount)",
                    label: "Machines",
                    color: DSTheme.blue
                )
                MenuMetric(
                    symbol: "exclamationmark.triangle.fill",
                    value: "\(summary.attentionCount)",
                    label: "Attention",
                    color: summary.attentionCount == 0 ? DSTheme.green : DSTheme.orange
                )
            }

            HStack(spacing: 7) {
                Image(systemName: "clock")
                if let lastScanAt = summary.lastScanAt {
                    Text("Last scan ") + Text(lastScanAt, style: .relative)
                } else {
                    Text("No successful scan yet")
                }
            }
            .font(.caption)
            .foregroundStyle(DSTheme.inkMuted)

            if let error = summary.errorMessage {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundStyle(DSTheme.red)
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(DSTheme.inkSoft)
                        .lineLimit(3)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(DSTheme.red.opacity(0.07))
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            }
        }
        .padding(16)
    }

    private var actions: some View {
        VStack(spacing: 10) {
            Button {
                Task { await store.refresh() }
            } label: {
                Label(summary.isScanning ? "Scanning…" : "Scan this Mac", systemImage: "arrow.clockwise")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(store.isRefreshing || store.isDoctorRunning)
            .accessibilityIdentifier("devicesync.menu.scan")

            HStack(spacing: 10) {
                Button {
                    openSection(.fleet)
                } label: {
                    Label("Open Fleet", systemImage: AppSection.fleet.symbol)
                        .frame(maxWidth: .infinity)
                }
                .accessibilityIdentifier("devicesync.menu.openFleet")

                Button {
                    openSection(.doctor)
                } label: {
                    Label("Open Doctor", systemImage: AppSection.doctor.symbol)
                        .frame(maxWidth: .infinity)
                }
                .accessibilityIdentifier("devicesync.menu.openDoctor")
            }
            .buttonStyle(.bordered)

            Text("Repairs open in the full Doctor for evidence, confirmation, and post-repair proof.")
                .font(.caption2)
                .foregroundStyle(DSTheme.inkMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
    }

    private var footer: some View {
        HStack {
            Text(store.localSnapshot?.name ?? "This Mac")
                .lineLimit(1)
            Spacer()
            Button("Quit \(FleetMeshIdentity.productName)") { quit() }
                .buttonStyle(.plain)
                .foregroundStyle(DSTheme.inkSoft)
                .accessibilityIdentifier("devicesync.menu.quit")
        }
        .font(.caption)
        .foregroundStyle(DSTheme.inkMuted)
        .padding(14)
    }
}

private struct MenuMetric: View {
    let symbol: String
    let value: String
    let label: String
    let color: Color

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: symbol)
                .foregroundStyle(color)
            VStack(alignment: .leading, spacing: 0) {
                Text(value)
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundStyle(DSTheme.ink)
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(DSTheme.inkMuted)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity)
        .background(.white.opacity(0.86))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(DSTheme.line, lineWidth: 1)
        }
    }
}
