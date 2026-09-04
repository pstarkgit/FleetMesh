import Foundation
import Testing
@testable import DeviceSync

struct BootstrapPlannerTests {
    @Test
    func dirtySourceProducesReviewStepWithoutCommand() {
        let snapshot = MachineSnapshot(
            machineID: "8e9d5e0d-4e5c-4f26-895b-e87249833e12",
            name: "Mac",
            hostName: "mac",
            modelIdentifier: "Mac17,6",
            architecture: "arm64",
            osVersion: "26.6",
            osBuild: "25G83",
            components: []
        )
        let drift = ComponentDrift(
            componentID: "authbar",
            name: "AuthBar",
            kind: .application,
            state: .localChanges,
            severity: .attention,
            summary: "Local work",
            expected: "1.0",
            observed: "1.0"
        )
        let assessment = MachineAssessment(snapshot: snapshot, drifts: [drift], isStale: false)

        let plan = BootstrapPlanner().plan(for: assessment)
        let review = plan.first { $0.id == "review-authbar" }

        #expect(review != nil)
        #expect(review?.command == nil)
        #expect(review?.requiresReview == true)
    }

    @Test
    func missingAppDelegatesToOwnedInstaller() {
        let snapshot = MachineSnapshot(
            machineID: "aa38f9a4-3b39-431b-a152-f06a4a5b438e",
            name: "Mac",
            hostName: "mac",
            modelIdentifier: "Mac17,6",
            architecture: "arm64",
            osVersion: "26.6",
            osBuild: "25G83",
            components: []
        )
        let drift = ComponentDrift(
            componentID: "stow",
            name: "Stow",
            kind: .application,
            state: .missing,
            severity: .critical,
            summary: "Missing",
            expected: "0.1.37",
            observed: nil
        )
        let assessment = MachineAssessment(snapshot: snapshot, drifts: [drift], isStale: false)

        let plan = BootstrapPlanner().plan(for: assessment)
        let install = plan.first { $0.id == "converge-stow" }

        #expect(install?.command == "~/code/Stow/install.sh")
        #expect(install?.requiresReview == true)
    }

    @Test
    func componentOutsideBaselineDoesNotCreateConvergenceWork() {
        let snapshot = MachineSnapshot(
            machineID: "e79c3404-0648-45f0-b565-41cfb22b71b8",
            name: "Mac",
            hostName: "mac",
            modelIdentifier: "Mac17,6",
            architecture: "arm64",
            osVersion: "26.6",
            osBuild: "25G83",
            components: []
        )
        let drift = ComponentDrift(
            componentID: "kiro-crew-themes",
            name: "Kiro Crew themes",
            kind: .theme,
            state: .notManaged,
            severity: .information,
            summary: "Optional",
            expected: nil,
            observed: "Missing"
        )
        let assessment = MachineAssessment(snapshot: snapshot, drifts: [drift], isStale: false)

        let plan = BootstrapPlanner().plan(for: assessment)

        #expect(!plan.contains { $0.componentID == "kiro-crew-themes" })
    }
}
