import Foundation

enum HeadlessFleetReport {
    static func attentionCount(
        assessments: [MachineAssessment],
        missingDeviceNames: [String]
    ) -> Int {
        assessments.reduce(0) { $0 + $1.attentionCount }
            + missingDeviceNames.count
    }

    static func findingLines(
        assessments: [MachineAssessment],
        missingDeviceNames: [String]
    ) -> [String] {
        var lines: [String] = []
        for assessment in assessments.sorted(by: machineOrder) {
            let machineName = singleLine(assessment.snapshot.name)
            if assessment.isStale {
                lines.append(
                    "finding: \(machineName) | report | stale | attention | Device report is older than 24 hours."
                )
            }
            for drift in assessment.managedDrifts
            where drift.state != .aligned && drift.state != .notApplicable {
                let detail = expectedObservedDetail(drift)
                lines.append(
                    "finding: \(machineName) | \(singleLine(drift.componentID)) | \(drift.state.rawValue) | \(severityLabel(drift.severity)) | \(singleLine(drift.summary))\(detail)"
                )
            }
        }
        for name in missingDeviceNames.sorted(by: localizedOrder) {
            lines.append(
                "finding: \(singleLine(name)) | report | missing | critical | Enrolled device has no report."
            )
        }
        return lines
    }

    private static func machineOrder(_ lhs: MachineAssessment, _ rhs: MachineAssessment) -> Bool {
        localizedOrder(lhs.snapshot.name, rhs.snapshot.name)
    }

    private static func localizedOrder(_ lhs: String, _ rhs: String) -> Bool {
        lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending
    }

    private static func expectedObservedDetail(_ drift: ComponentDrift) -> String {
        var fields: [String] = []
        if let expected = drift.expected {
            fields.append("expected: \(singleLine(expected))")
        }
        if let observed = drift.observed {
            fields.append("observed: \(singleLine(observed))")
        }
        return fields.isEmpty ? "" : " | \(fields.joined(separator: " | "))"
    }

    private static func severityLabel(_ severity: DriftSeverity) -> String {
        switch severity {
        case .information: "information"
        case .attention: "attention"
        case .critical: "critical"
        }
    }

    private static func singleLine(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "|", with: "/")
    }
}
