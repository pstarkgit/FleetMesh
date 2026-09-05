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
    private let appearance: FleetMeshAppearanceStore
    private let openSection: (AppSection) -> Void
    private let statusItem: NSStatusItem
    private let popover: NSPopover

    init(
        store: FleetStore,
        appearance: FleetMeshAppearanceStore,
        openSection: @escaping (AppSection) -> Void
    ) {
        self.store = store
        self.appearance = appearance
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
        popover.contentSize = NSSize(width: 350, height: 446)

        super.init()

        popover.contentViewController = NSHostingController(
            rootView: DeviceSyncMenuBarView(
                store: store,
                appearance: appearance,
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
            button.imageScaling = .scaleProportionallyDown
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
        let image = FleetMeshStatusIcon.image(label: label)
        button.image = image
        button.imagePosition = .imageOnly
        button.toolTip = "\(label) · \(summary.machineLabel) · \(summary.attentionLabel)"
        button.setAccessibilityLabel(label)
    }

}

enum FleetMeshStatusIcon {
    static func image(label: String) -> NSImage {
        let size = NSSize(width: 19, height: 19)
        let image = NSImage(size: size, flipped: false) { rect in
            let markRect = rect.insetBy(dx: 1.1, dy: 1.1)
            let left = clusterPath(in: markRect, leading: true)
            let bridge = bridgePath(in: markRect)
            let right = clusterPath(in: markRect, leading: false)
            let complete = NSBezierPath()
            complete.append(left)
            complete.append(bridge)
            complete.append(right)
            complete.lineCapStyle = .round
            complete.lineJoinStyle = .round

            let emerald = NSColor(
                calibratedRed: 0.12,
                green: 0.95,
                blue: 0.67,
                alpha: 1
            )
            let cyan = NSColor(
                calibratedRed: 0.13,
                green: 0.87,
                blue: 1,
                alpha: 1
            )
            let indigo = NSColor(
                calibratedRed: 0.67,
                green: 0.49,
                blue: 1,
                alpha: 1
            )

            // Use the full square for a bright Aurora silhouette. Fleet health
            // stays in the tooltip and popover instead of obscuring the mark.
            if let context = NSGraphicsContext.current?.cgContext {
                context.saveGState()
                context.setShadow(
                    offset: .zero,
                    blur: 4.0,
                    color: cyan.cgColor
                )
                complete.lineWidth = 4.2
                cyan.setStroke()
                complete.stroke()
                cyan.setFill()
                endpointNodes(in: markRect, radius: 2.55).forEach { nodeRect in
                    NSBezierPath(ovalIn: nodeRect).fill()
                }
                context.restoreGState()
            }

            left.lineWidth = 3.2
            emerald.setStroke()
            left.stroke()
            bridge.lineWidth = 3.3
            cyan.setStroke()
            bridge.stroke()
            right.lineWidth = 3.2
            indigo.setStroke()
            right.stroke()

            complete.lineWidth = 1.25
            NSColor.white.setStroke()
            complete.stroke()

            for (index, nodeRect) in endpointNodes(in: markRect, radius: 2.25).enumerated() {
                (index < 2 ? emerald : indigo).setFill()
                NSBezierPath(ovalIn: nodeRect).fill()
                NSColor.white.setFill()
                NSBezierPath(ovalIn: nodeRect.insetBy(dx: 1.2, dy: 1.2)).fill()
            }
            return true
        }
        image.accessibilityDescription = label
        image.isTemplate = false
        return image
    }

    private static func clusterPath(in rect: NSRect, leading: Bool) -> NSBezierPath {
        let outerX = leading
            ? rect.minX + rect.width * 0.08
            : rect.maxX - rect.width * 0.08
        let innerX = leading
            ? rect.minX + rect.width * 0.42
            : rect.maxX - rect.width * 0.42
        let path = NSBezierPath()
        path.move(to: NSPoint(x: outerX, y: rect.maxY - rect.height * 0.08))
        path.line(to: NSPoint(x: innerX, y: rect.midY))
        path.line(to: NSPoint(x: outerX, y: rect.minY + rect.height * 0.08))
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        return path
    }

    private static func bridgePath(in rect: NSRect) -> NSBezierPath {
        let path = NSBezierPath()
        path.move(to: NSPoint(x: rect.minX + rect.width * 0.42, y: rect.midY))
        path.line(to: NSPoint(x: rect.maxX - rect.width * 0.42, y: rect.midY))
        path.lineCapStyle = .round
        return path
    }

    private static func endpointNodes(in rect: NSRect, radius: CGFloat) -> [NSRect] {
        let centers = [
            NSPoint(x: rect.minX + rect.width * 0.08, y: rect.maxY - rect.height * 0.08),
            NSPoint(x: rect.minX + rect.width * 0.08, y: rect.minY + rect.height * 0.08),
            NSPoint(x: rect.maxX - rect.width * 0.08, y: rect.maxY - rect.height * 0.08),
            NSPoint(x: rect.maxX - rect.width * 0.08, y: rect.minY + rect.height * 0.08),
        ]
        return centers.map { center in
            NSRect(
                x: center.x - radius,
                y: center.y - radius,
                width: radius * 2,
                height: radius * 2
            )
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
            return "One or more devices have drift, stale evidence, or a decision."
        case .critical:
            return "A required app or configuration is missing."
        case .unknown:
            return "Some fleet evidence is missing or could not be verified."
        }
    }

    var machineLabel: String {
        "\(machineCount) device\(machineCount == 1 ? "" : "s")"
    }

    var attentionLabel: String {
        "\(attentionCount) attention item\(attentionCount == 1 ? "" : "s")"
    }
}

struct DeviceSyncMenuBarView: View {
    @Bindable var store: FleetStore
    @Bindable var appearance: FleetMeshAppearanceStore
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
        .preferredColorScheme(appearance.selection.colorScheme)
        .task { await store.start() }
        .accessibilityIdentifier("devicesync.menu")
    }

    private var header: some View {
        HStack(spacing: 11) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(DSTheme.auroraFieldGradient)
                FleetMeshMark()
                    .padding(6)
            }
            .frame(width: 38, height: 38)

            VStack(alignment: .leading, spacing: 1) {
                Text(FleetMeshIdentity.productName)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(DSTheme.ink)
                Text("Device fleet control plane")
                    .font(.caption)
                    .foregroundStyle(DSTheme.inkMuted)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                Text("v\(DeviceSyncVersion.current)")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(DSTheme.inkMuted)
                Menu {
                    ForEach(FleetMeshAppearance.allCases) { option in
                        Button {
                            appearance.select(option)
                        } label: {
                            Label(
                                option.label,
                                systemImage: appearance.selection == option
                                    ? "checkmark"
                                    : option.symbol
                            )
                        }
                    }
                } label: {
                    Image(systemName: appearance.selection.symbol)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(DSTheme.cyan)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .accessibilityLabel("Appearance: \(appearance.selection.label)")
                .accessibilityIdentifier("fleetmesh.menu.appearance")
            }
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
                    symbol: "server.rack",
                    value: "\(summary.machineCount)",
                    label: "Devices",
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
                    Text("Last scan \(FleetDateFormatting.relative(lastScanAt))")
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
            .disabled(store.isBusy)
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

            Button {
                openSection(.devices)
            } label: {
                Label("Manage devices", systemImage: AppSection.devices.symbol)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("devicesync.menu.manageDevices")

            Text("Close the window anytime—FleetMesh stays here. Repairs open in the full Doctor for review and proof.")
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
        .background(DSTheme.card)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(DSTheme.line, lineWidth: 1)
        }
    }
}
