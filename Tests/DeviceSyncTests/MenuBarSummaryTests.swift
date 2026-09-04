import Foundation
import Testing
@testable import DeviceSync

struct MenuBarSummaryTests {
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
        #expect(value.machineLabel == "3 machines")
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
