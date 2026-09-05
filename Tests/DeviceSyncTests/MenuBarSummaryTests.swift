import AppKit
import Foundation
import Testing
@testable import DeviceSync

struct MenuBarSummaryTests {
    @Test
    func fleetHealthExitCodesDistinguishPostureFromSelfCheck() {
        #expect(FleetVerdict.aligned.headlessExitCode == 0)
        #expect(FleetVerdict.attention.headlessExitCode == 2)
        #expect(FleetVerdict.critical.headlessExitCode == 3)
        #expect(FleetVerdict.unknown.headlessExitCode == 4)
    }
    @Test
    func verdictsMapToDistinctStatusSymbols() {
        #expect(summary(.aligned).statusSymbol == "checkmark.circle.fill")
        #expect(summary(.attention).statusSymbol == "exclamationmark.triangle.fill")
        #expect(summary(.critical).statusSymbol == "xmark.octagon.fill")
        #expect(summary(.unknown).statusSymbol == "questionmark.circle.fill")
    }

    @Test
    func scanningStateTakesPrecedenceOverFleetVerdict() {
        let value = MenuBarSummary(
            verdict: .critical,
            machineCount: 3,
            attentionCount: 4,
            lastScanAt: Date(timeIntervalSince1970: 100),
            isScanning: true,
            errorMessage: nil
        )

        #expect(value.headline == "Scanning this Mac")
        #expect(value.statusSymbol == "arrow.triangle.2.circlepath")
        #expect(value.machineLabel == "3 devices")
        #expect(value.attentionLabel == "4 attention items")
    }

    @Test
    func failedScanNeverPresentsOldGreenHeadline() {
        let value = MenuBarSummary(
            verdict: .aligned,
            machineCount: 1,
            attentionCount: 0,
            lastScanAt: Date(timeIntervalSince1970: 100),
            isScanning: false,
            errorMessage: "Fleet folder unavailable"
        )

        #expect(value.headline == "Scan failed")
        #expect(value.detail.contains("did not produce fresh evidence"))
    }

    @Test
    @MainActor
    func emptyStoreStartsAsUnknownRatherThanHealthy() {
        let value = FleetStore().menuBarSummary

        #expect(value.verdict == .unknown)
        #expect(value.machineCount == 0)
        #expect(value.lastScanAt == nil)
    }

    @Test
    @MainActor
    func sharedNavigationCanRouteMenuBarToDoctor() {
        let navigation = AppNavigation()

        navigation.open(.doctor)

        #expect(navigation.section == .doctor)
    }

    @Test
    @MainActor
    func sharedNavigationCanRouteMenuBarToDevices() {
        let navigation = AppNavigation()

        navigation.open(.devices)

        #expect(navigation.section == .devices)
    }

    @Test
    func statusItemPlacementSeedsOnlyItsOwnUnsetSlot() throws {
        #expect(DeviceSyncStatusItemPlacement.autosaveName == "DeviceSync")
        let suiteName = "dev.starkpat.devicesync.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let unrelatedKey = "NSStatusItem Preferred Position AnotherApp"
        defaults.set(777, forKey: unrelatedKey)

        #expect(DeviceSyncStatusItemPlacement.prepare(defaults: defaults))
        #expect(
            defaults.integer(forKey: DeviceSyncStatusItemPlacement.preferenceKey)
                == DeviceSyncStatusItemPlacement.defaultOffsetFromRightEdge
        )
        #expect(defaults.integer(forKey: unrelatedKey) == 777)

        defaults.set(333, forKey: DeviceSyncStatusItemPlacement.preferenceKey)
        #expect(!DeviceSyncStatusItemPlacement.prepare(defaults: defaults))
        #expect(defaults.integer(forKey: DeviceSyncStatusItemPlacement.preferenceKey) == 333)
        #expect(defaults.integer(forKey: unrelatedKey) == 777)
    }

    @Test
    @MainActor
    func appearanceDefaultsToSystemAndPersistsDarkSelection() throws {
        let suiteName = "dev.starkpat.devicesync.appearance-tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer {
            NSApp?.appearance = nil
            defaults.removePersistentDomain(forName: suiteName)
        }

        let initial = FleetMeshAppearanceStore(defaults: defaults)
        #expect(initial.selection == .system)

        initial.select(.dark)

        #expect(defaults.string(forKey: FleetMeshAppearanceStore.defaultsKey) == "dark")
        #expect(FleetMeshAppearanceStore(defaults: defaults).selection == .dark)

        initial.select(.system)
    }

    @Test
    @MainActor
    func menuBarIconUsesFullBrightAuroraBridgeWithoutOrangeBadge() throws {
        let image = FleetMeshStatusIcon.image(label: "FleetMesh test icon")
        #expect(image.size == NSSize(width: 19, height: 19))
        #expect(!image.isTemplate)

        let width = 38
        let height = 38
        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        let context = try #require(NSGraphicsContext(bitmapImageRep: bitmap))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        image.draw(
            in: NSRect(x: 0, y: 0, width: width, height: height),
            from: .zero,
            operation: .copy,
            fraction: 1
        )
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()

        var visible = 0
        var brightAurora = 0
        var whiteCore = 0
        var orange = 0
        var minX = width
        var maxX = 0
        var minY = height
        var maxY = 0

        for y in 0..<height {
            for x in 0..<width {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else {
                    continue
                }
                let red = Int((color.redComponent * 255).rounded())
                let green = Int((color.greenComponent * 255).rounded())
                let blue = Int((color.blueComponent * 255).rounded())
                let alpha = Int((color.alphaComponent * 255).rounded())
                guard alpha >= 24 else { continue }

                visible += 1
                minX = min(minX, x)
                maxX = max(maxX, x)
                minY = min(minY, y)
                maxY = max(maxY, y)
                if green >= 135 && blue >= 125 { brightAurora += 1 }
                if red >= 215 && green >= 215 && blue >= 215 { whiteCore += 1 }
                if red >= 175 && green >= 75 && green <= 190 && blue <= 85 {
                    orange += 1
                }
            }
        }

        #expect(visible >= 350)
        #expect(brightAurora >= 180)
        #expect(whiteCore >= 35)
        #expect(maxX - minX >= 32)
        #expect(maxY - minY >= 31)
        #expect(orange <= 3)
    }

    @Test
    func freshTimestampsReadNaturally() {
        let now = Date(timeIntervalSince1970: 1_000)

        #expect(FleetDateFormatting.relative(now, now: now) == "just now")
        #expect(FleetDateFormatting.relative(now.addingTimeInterval(-30), now: now) == "just now")
        #expect(FleetDateFormatting.relative(now.addingTimeInterval(-120), now: now).contains("2"))
    }

    @Test
    @MainActor
    func closingLastWindowDoesNotTerminateMenuBarApp() {
        let delegate = DeviceSyncAppDelegate()

        #expect(!delegate.applicationShouldTerminateAfterLastWindowClosed(NSApplication.shared))
    }

    private func summary(_ verdict: FleetVerdict) -> MenuBarSummary {
        MenuBarSummary(
            verdict: verdict,
            machineCount: 1,
            attentionCount: 0,
            lastScanAt: nil,
            isScanning: false,
            errorMessage: nil
        )
    }
}
