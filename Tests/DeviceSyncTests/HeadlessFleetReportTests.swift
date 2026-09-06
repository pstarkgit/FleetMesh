import Foundation
import Testing

@testable import DeviceSync

struct HeadlessFleetReportTests {
    @Test
    func reportsManagedDriftStalenessAndMissingDevicesDeterministically() {
        let attention = ComponentDrift(
            componentID: "example-app",
            name: "Example App",
            kind: .application,
            state: .different,
            severity: .attention,
            summary: "Needs\nan update",
            expected: "2.0.0",
            observed: "1.0.0"
        )
        let critical = ComponentDrift(
            componentID: "required/config",
            name: "Required Config",
            kind: .configuration,
            state: .missing,
            severity: .critical,
            summary: "Required | configuration is missing.",
            expected: "expected",
            observed: nil
        )
        let healthy = ComponentDrift(
            componentID: "healthy",
            name: "Healthy",
            kind: .application,
            state: .aligned,
            severity: .information,
            summary: "Aligned",
            expected: "1",
            observed: "1"
        )
        let beta = MachineAssessment(
            snapshot: snapshot(name: "Beta"),
            drifts: [critical, healthy],
            isStale: true
        )
        let alpha = MachineAssessment(
            snapshot: snapshot(name: "Alpha"),
            drifts: [attention],
            isStale: false
        )

        let missing = ["Zulu", "Offline\nMac"]
        #expect(
            HeadlessFleetReport.attentionCount(
                assessments: [beta, alpha],
                missingDeviceNames: missing
            ) == 5
        )
        #expect(
            HeadlessFleetReport.findingLines(
                assessments: [beta, alpha],
                missingDeviceNames: missing
            ) == [
                "finding: Alpha | example-app | different | attention | Needs an update | expected: 2.0.0 | observed: 1.0.0",
                "finding: Beta | report | stale | attention | Device report is older than 24 hours.",
                "finding: Beta | required/config | missing | critical | Required / configuration is missing. | expected: expected",
                "finding: Offline Mac | report | missing | critical | Enrolled device has no report.",
                "finding: Zulu | report | missing | critical | Enrolled device has no report.",
            ]
        )
    }

    private func snapshot(name: String) -> MachineSnapshot {
        MachineSnapshot(
            machineID: UUID().uuidString.lowercased(),
            name: name,
            hostName: name.lowercased(),
            modelIdentifier: "fixture",
            architecture: "arm64",
            osVersion: "26.0",
            osBuild: "fixture",
            capturedAt: Date(),
            components: []
        )
    }
}
