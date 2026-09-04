import SwiftUI

struct RootView: View {
    @Bindable var store: FleetStore
    @Bindable var navigation: AppNavigation

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            ZStack {
                DSTheme.canvas.ignoresSafeArea()
                switch navigation.section {
                case .fleet:
                    FleetView(store: store) {
                        navigation.open(.doctor)
                    }
                case .doctor:
                    DoctorView(store: store)
                case .bootstrap:
                    BootstrapView(store: store)
                case .settings:
                    SettingsView(store: store)
                }
            }
            // The product uses a deliberate light evidence canvas beside the
            // system-adaptive sidebar. Without pinning this subtree, a Mac in
            // dark appearance gives default labels white foregrounds while the
            // canvas remains light, making machine and component names vanish.
            .environment(\.colorScheme, .light)
            .foregroundColor(DSTheme.ink)
        }
        .navigationSplitViewStyle(.balanced)
        .tint(DSTheme.blue)
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            brand

            List(selection: $navigation.section) {
                Section("CONTROL PLANE") {
                    ForEach(AppSection.allCases) { item in
                        Label(item.rawValue, systemImage: item.symbol)
                            .tag(item)
                    }
                }

                Section("MACHINES") {
                    ForEach(store.filteredAssessments) { assessment in
                        Button {
                            navigation.open(.fleet)
                            store.selectedMachineID = assessment.snapshot.machineID
                        } label: {
                            MachineSidebarRow(
                                assessment: assessment,
                                isCurrent: assessment.snapshot.machineID == store.localSnapshot?.machineID
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .listStyle(.sidebar)
            .searchable(text: $store.searchText, prompt: "Machines or apps")

            fleetFooter
        }
        .background(.ultraThinMaterial)
        .frame(minWidth: 250)
    }

    private var brand: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [DSTheme.blue, DSTheme.cyan],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                Image(systemName: "arrow.triangle.2.circlepath.icloud.fill")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 42, height: 42)

            VStack(alignment: .leading, spacing: 2) {
                Text("Device Sync")
                    .font(.system(size: 17, weight: .bold))
                Text("Mac fleet control plane")
                    .font(.caption)
                    .foregroundStyle(DSTheme.inkMuted)
            }
            Spacer()
        }
        .padding(16)
    }

    private var fleetFooter: some View {
        HStack(spacing: 9) {
            Circle()
                .fill(DSTheme.color(for: store.fleetVerdict))
                .frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 1) {
                Text(store.fleetVerdict.label)
                    .font(.caption.weight(.semibold))
                Text("\(store.assessments.count) machine\(store.assessments.count == 1 ? "" : "s") · \(store.fleetAttentionCount) item\(store.fleetAttentionCount == 1 ? "" : "s")")
                    .font(.caption2)
                    .foregroundStyle(DSTheme.inkMuted)
            }
            Spacer()
        }
        .padding(14)
        .overlay(alignment: .top) { Divider() }
    }
}

private struct MachineSidebarRow: View {
    let assessment: MachineAssessment
    let isCurrent: Bool

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "laptopcomputer")
                .foregroundStyle(DSTheme.color(for: assessment.verdict))
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(assessment.snapshot.name)
                        .lineLimit(1)
                    if isCurrent {
                        Text("THIS MAC")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(DSTheme.blue)
                    }
                }
                Text(assessment.isStale ? "Snapshot stale" : assessment.verdict.label)
                    .font(.caption2)
                    .foregroundStyle(DSTheme.inkMuted)
            }
            Spacer()
            if assessment.attentionCount > 0 {
                Text("\(assessment.attentionCount)")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(DSTheme.color(for: assessment.verdict))
                    .clipShape(Capsule())
            }
        }
        .contentShape(Rectangle())
    }
}

struct FleetView: View {
    @Bindable var store: FleetStore
    let onOpenBootstrap: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                fleetHeader
                if let error = store.lastError {
                    IssueBanner(title: "Refresh failed", detail: error, color: DSTheme.red)
                }
                ForEach(store.issues) { issue in
                    IssueBanner(title: issue.title, detail: issue.detail, color: DSTheme.orange)
                }
                metrics

                if let assessment = store.selectedAssessment {
                    machineDetail(assessment)
                } else {
                    emptyFleet
                }
            }
            .padding(28)
        }
    }

    private var fleetHeader: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 7) {
                Text("FLEET POSTURE")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .tracking(1.5)
                    .foregroundStyle(DSTheme.blue)
                Text(store.fleetVerdict.label)
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .foregroundStyle(DSTheme.ink)
                Text(fleetHeadline)
                    .font(.system(size: 14))
                    .foregroundStyle(DSTheme.inkSoft)
            }
            Spacer()
            Button {
                Task { await store.refresh() }
            } label: {
                Label(store.isRefreshing ? "Scanning…" : "Scan this Mac", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.borderedProminent)
            .disabled(store.isRefreshing)
        }
    }

    private var fleetHeadline: String {
        guard store.manifest != nil else {
            return "No verified baseline is available. Device Sync will not infer one from missing evidence."
        }
        switch store.fleetVerdict {
        case .aligned:
            return "Every fresh machine report matches the selected software and theme baseline."
        case .attention:
            return "One or more Macs differ from the baseline or have stale evidence."
        case .critical:
            return "A required app or configuration is missing on at least one Mac."
        case .unknown:
            return "Some fleet evidence could not be read or verified."
        }
    }

    private var metrics: some View {
        HStack(spacing: 12) {
            MetricCard(
                title: "Machines",
                value: "\(store.assessments.count)",
                detail: "publishing snapshots",
                color: DSTheme.blue,
                symbol: "laptopcomputer.and.iphone"
            )
            MetricCard(
                title: "Aligned",
                value: "\(store.assessments.filter { $0.verdict == .aligned }.count)",
                detail: "fresh and matching",
                color: DSTheme.green,
                symbol: "checkmark.seal.fill"
            )
            MetricCard(
                title: "Attention",
                value: "\(store.fleetAttentionCount)",
                detail: "drift, stale, or unknown",
                color: DSTheme.orange,
                symbol: "exclamationmark.triangle.fill"
            )
            MetricCard(
                title: "Baseline",
                value: store.manifest == nil ? "—" : "v1",
                detail: store.manifest.map { relativeDate($0.updatedAt) } ?? "not verified",
                color: DSTheme.purple,
                symbol: "scope"
            )
        }
    }

    private func machineDetail(_ assessment: MachineAssessment) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            MachineHero(
                assessment: assessment,
                isCurrent: assessment.snapshot.machineID == store.localSnapshot?.machineID
            )

            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 12) {
                    SectionTitle(title: "Software & configuration", subtitle: "Observed evidence compared with the fleet baseline")
                    ForEach(assessment.drifts) { drift in
                        DriftRow(
                            drift: drift,
                            observation: assessment.snapshot.component(drift.componentID)
                        )
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .leading, spacing: 12) {
                    SectionTitle(title: "Convergence flow", subtitle: "Review before any machine changes")
                    ConvergenceFlow(assessment: assessment)

                    Button {
                        store.selectedMachineID = assessment.snapshot.machineID
                        onOpenBootstrap()
                    } label: {
                        Label("Open Doctor", systemImage: "stethoscope")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                }
                .frame(width: 300, alignment: .leading)
                .deviceCard()
            }
        }
    }

    private var emptyFleet: some View {
        ContentUnavailableView(
            "No machine evidence",
            systemImage: "laptopcomputer.slash",
            description: Text("Scan this Mac or choose the correct fleet folder.")
        )
        .frame(maxWidth: .infinity, minHeight: 360)
    }
}

private struct MetricCard: View {
    let title: String
    let value: String
    let detail: String
    let color: Color
    let symbol: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 38, height: 38)
                .background(color.opacity(0.11))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(DSTheme.inkMuted)
                Text(value)
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundStyle(DSTheme.ink)
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(DSTheme.inkMuted)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
        .deviceCard()
    }
}

private struct MachineHero: View {
    let assessment: MachineAssessment
    let isCurrent: Bool

    var body: some View {
        HStack(spacing: 18) {
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(DSTheme.color(for: assessment.verdict).opacity(0.11))
                Image(systemName: "laptopcomputer")
                    .font(.system(size: 34, weight: .medium))
                    .foregroundStyle(DSTheme.color(for: assessment.verdict))
            }
            .frame(width: 76, height: 68)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(assessment.snapshot.name)
                        .font(.system(size: 23, weight: .bold, design: .rounded))
                        .foregroundColor(DSTheme.ink)
                    if isCurrent {
                        Text("THIS MAC")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(DSTheme.blue)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(DSTheme.blue.opacity(0.1))
                            .clipShape(Capsule())
                    }
                }
                Text("\(assessment.snapshot.modelIdentifier) · \(assessment.snapshot.architecture) · macOS \(assessment.snapshot.osVersion)")
                    .font(.subheadline)
                    .foregroundStyle(DSTheme.inkSoft)
                Text("\(assessment.snapshot.hostName) · captured \(relativeDate(assessment.snapshot.capturedAt))")
                    .font(.caption)
                    .foregroundStyle(assessment.isStale ? DSTheme.orange : DSTheme.inkMuted)
            }
            Spacer()
            VerdictPill(verdict: assessment.verdict, stale: assessment.isStale)
        }
        .deviceCard()
    }
}

private struct VerdictPill: View {
    let verdict: FleetVerdict
    let stale: Bool

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(DSTheme.color(for: verdict))
                .frame(width: 8, height: 8)
            Text(stale ? "Snapshot stale" : verdict.label)
                .font(.caption.weight(.semibold))
        }
        .foregroundStyle(DSTheme.color(for: verdict))
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
        .background(DSTheme.color(for: verdict).opacity(0.1))
        .clipShape(Capsule())
    }
}

private struct DriftRow: View {
    let drift: ComponentDrift
    let observation: ComponentObservation?

    var body: some View {
        HStack(alignment: .top, spacing: 13) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(DSTheme.color(for: drift.state).opacity(0.1))
                Image(systemName: symbol)
                    .foregroundStyle(DSTheme.color(for: drift.state))
            }
            .frame(width: 38, height: 38)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(drift.name)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(DSTheme.ink)
                    Text(drift.kind.label.uppercased())
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(DSTheme.inkMuted)
                    Spacer()
                    Text(drift.state.label)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(DSTheme.color(for: drift.state))
                }
                Text(drift.summary)
                    .font(.caption)
                    .foregroundStyle(DSTheme.inkSoft)

                HStack(spacing: 12) {
                    if let expected = drift.expected {
                        Label("Target \(expected)", systemImage: "scope")
                    }
                    if let observed = drift.observed {
                        Label("Observed \(observed)", systemImage: "eye")
                    }
                    if observation?.isRunning == true {
                        Label("Running", systemImage: "play.fill")
                            .foregroundStyle(DSTheme.green)
                    }
                }
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(DSTheme.inkMuted)
            }
        }
        .deviceCard()
    }

    private var symbol: String {
        switch drift.kind {
        case .application: "app.fill"
        case .commandLineTool: "terminal.fill"
        case .service: "wave.3.right.circle.fill"
        case .configuration: "slider.horizontal.3"
        case .theme: "paintpalette.fill"
        }
    }
}

private struct ConvergenceFlow: View {
    let assessment: MachineAssessment

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            FlowStep(number: 1, title: "Observe", detail: "Read installed evidence", state: .done)
            connector
            FlowStep(number: 2, title: "Compare", detail: "Evaluate the baseline", state: .done)
            connector
            FlowStep(
                number: 3,
                title: "Review",
                detail: assessment.attentionCount == 0 ? "No change required" : "\(assessment.attentionCount) item(s) need a decision",
                state: assessment.attentionCount == 0 ? .done : .active
            )
            connector
            FlowStep(number: 4, title: "Converge", detail: "Use product-owned installers", state: .pending)
            connector
            FlowStep(number: 5, title: "Prove", detail: "Publish a fresh snapshot", state: .pending)
        }
    }

    private var connector: some View {
        Rectangle()
            .fill(DSTheme.line)
            .frame(width: 2, height: 14)
            .padding(.leading, 14)
    }
}

private enum FlowState { case done, active, pending }

private struct FlowStep: View {
    let number: Int
    let title: String
    let detail: String
    let state: FlowState

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(color.opacity(state == .pending ? 0.08 : 1))
                if state == .done {
                    Image(systemName: "checkmark")
                        .font(.caption.bold())
                        .foregroundStyle(.white)
                } else {
                    Text("\(number)")
                        .font(.caption.bold())
                        .foregroundStyle(state == .pending ? DSTheme.inkMuted : .white)
                }
            }
            .frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.caption.weight(.semibold))
                    .foregroundColor(DSTheme.ink)
                Text(detail).font(.caption2).foregroundStyle(DSTheme.inkMuted)
            }
        }
    }

    private var color: Color {
        switch state {
        case .done: DSTheme.green
        case .active: DSTheme.orange
        case .pending: DSTheme.inkMuted
        }
    }
}

struct DoctorView: View {
    @Bindable var store: FleetStore
    @State private var pendingRepair: DoctorFinding?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                doctorHeader
                if let error = store.lastError {
                    IssueBanner(title: "Doctor evidence failed", detail: error, color: DSTheme.red)
                }

                if let assessment = store.selectedAssessment {
                    let findings = store.doctorFindings(for: assessment)
                    MachineHero(
                        assessment: assessment,
                        isCurrent: assessment.snapshot.machineID == store.localSnapshot?.machineID
                    )
                    DoctorPipeline(isRunning: store.isDoctorRunning)
                    DoctorSummary(findings: findings)

                    if assessment.snapshot.machineID != store.localSnapshot?.machineID {
                        IssueBanner(
                            title: "Open Doctor on this Mac",
                            detail: "This report is read-only here. Device Sync never repairs another Mac remotely.",
                            color: DSTheme.purple
                        )
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        SectionTitle(
                            title: "Diagnosis",
                            subtitle: "Every repair re-scans before changing anything and publishes fresh proof afterward"
                        )

                        if assessment.isStale {
                            DoctorStaleCard()
                        } else if findings.isEmpty {
                            DoctorAlignedCard()
                        } else {
                            ForEach(findings) { finding in
                                DoctorFindingRow(
                                    finding: finding,
                                    run: store.doctorRun(for: finding.id),
                                    isActive: store.activeDoctorComponentID == finding.id,
                                    isLocalMachine: assessment.snapshot.machineID == store.localSnapshot?.machineID,
                                    doctorBusy: store.isDoctorRunning || store.isRefreshing
                                ) {
                                    pendingRepair = finding
                                }
                            }
                        }
                    }
                } else {
                    ContentUnavailableView(
                        "No machine to diagnose",
                        systemImage: "stethoscope",
                        description: Text("Scan this Mac or choose a machine report.")
                    )
                    .frame(maxWidth: .infinity, minHeight: 360)
                }
            }
            .padding(28)
        }
        .confirmationDialog(
            pendingRepair.map { "Run \($0.title)?" } ?? "Run product repair?",
            isPresented: Binding(
                get: { pendingRepair != nil },
                set: { if !$0 { pendingRepair = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Run product-owned repair") {
                guard let finding = pendingRepair,
                      let machineID = store.selectedAssessment?.snapshot.machineID else { return }
                pendingRepair = nil
                Task {
                    await store.repair(
                        componentID: finding.id,
                        targetMachineID: machineID
                    )
                }
            }
            Button("Cancel", role: .cancel) { pendingRepair = nil }
        } message: {
            if let finding = pendingRepair, let recipe = finding.recipe {
                Text("Device Sync will run \(recipe.displayCommand), then re-scan and publish the observed result. The fleet baseline will not change.")
            }
        }
    }

    private var doctorHeader: some View {
        HStack(alignment: .top, spacing: 18) {
            VStack(alignment: .leading, spacing: 7) {
                Text("GUARDED REPAIR")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .tracking(1.5)
                    .foregroundStyle(DSTheme.purple)
                Text("Doctor")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .foregroundStyle(DSTheme.ink)
                Text("Diagnose drift, run only product-owned repairs, and require fresh installed-state proof.")
                    .font(.system(size: 14))
                    .foregroundStyle(DSTheme.inkSoft)
            }
            Spacer()
            Button {
                Task { await store.refresh() }
            } label: {
                Label(store.isRefreshing ? "Scanning…" : "Scan this Mac", systemImage: "stethoscope")
            }
            .buttonStyle(.borderedProminent)
            .disabled(store.isRefreshing || store.isDoctorRunning)
        }
    }
}

private struct DoctorPipeline: View {
    let isRunning: Bool

    var body: some View {
        HStack(spacing: 10) {
            stage(number: 1, title: "Diagnose", detail: "Fresh evidence", color: DSTheme.blue)
            arrow
            stage(number: 2, title: "Guard", detail: "Protect local work", color: DSTheme.purple)
            arrow
            stage(number: 3, title: "Repair", detail: "Owned installer", color: DSTheme.orange)
            arrow
            stage(number: 4, title: "Prove", detail: "Fresh snapshot", color: DSTheme.green)
        }
        .deviceCard()
        .overlay(alignment: .topTrailing) {
            if isRunning {
                HStack(spacing: 7) {
                    ProgressView().controlSize(.small)
                    Text("Doctor running")
                        .font(.caption.weight(.semibold))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(.white)
                .clipShape(Capsule())
                .padding(12)
            }
        }
    }

    private func stage(
        number: Int,
        title: String,
        detail: String,
        color: Color
    ) -> some View {
        HStack(spacing: 10) {
            Text("\(number)")
                .font(.caption.bold())
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(color)
                .clipShape(Circle())
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(DSTheme.ink)
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(DSTheme.inkMuted)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var arrow: some View {
        Image(systemName: "chevron.right")
            .font(.caption.bold())
            .foregroundStyle(DSTheme.inkMuted)
    }
}

private struct DoctorSummary: View {
    let findings: [DoctorFinding]

    var body: some View {
        HStack(spacing: 12) {
            DoctorCountCard(
                title: "Repairable",
                value: count(.repairable),
                detail: "explicit product repair",
                symbol: "wrench.and.screwdriver.fill",
                color: DSTheme.orange
            )
            DoctorCountCard(
                title: "Protected",
                value: count(.protected),
                detail: "local work preserved",
                symbol: "hand.raised.fill",
                color: DSTheme.purple
            )
            DoctorCountCard(
                title: "Decisions",
                value: count(.manual),
                detail: "operator choice needed",
                symbol: "person.crop.circle.badge.questionmark",
                color: DSTheme.blue
            )
        }
    }

    private func count(_ disposition: DoctorDisposition) -> Int {
        findings.filter { $0.disposition == disposition }.count
    }
}

private struct DoctorCountCard: View {
    let title: String
    let value: Int
    let detail: String
    let symbol: String
    let color: Color

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 38, height: 38)
                .background(color.opacity(0.11))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.caption).foregroundStyle(DSTheme.inkMuted)
                Text("\(value)")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundStyle(DSTheme.ink)
                Text(detail).font(.caption2).foregroundStyle(DSTheme.inkMuted)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .deviceCard()
    }
}

private struct DoctorFindingRow: View {
    let finding: DoctorFinding
    let run: DoctorRunRecord?
    let isActive: Bool
    let isLocalMachine: Bool
    let doctorBusy: Bool
    let onRepair: () -> Void

    @State private var showOutput = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 13) {
                ZStack {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(dispositionColor.opacity(0.11))
                    if isActive {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: dispositionSymbol)
                            .foregroundStyle(dispositionColor)
                    }
                }
                .frame(width: 42, height: 42)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(finding.drift.name)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(DSTheme.ink)
                        Text(finding.disposition.label.uppercased())
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundStyle(dispositionColor)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(dispositionColor.opacity(0.1))
                            .clipShape(Capsule())
                    }
                    Text(finding.title)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(DSTheme.ink)
                    Text(finding.detail)
                        .font(.caption)
                        .foregroundStyle(DSTheme.inkSoft)
                }
                Spacer()

                if finding.canRepair {
                    Button(isActive ? "Repairing…" : "Repair…") { onRepair() }
                        .buttonStyle(.borderedProminent)
                        .tint(DSTheme.orange)
                        .disabled(doctorBusy || !isLocalMachine)
                        .accessibilityIdentifier("doctor.repair.\(finding.id)")
                }
            }

            if let recipe = finding.recipe {
                HStack(spacing: 8) {
                    Image(systemName: "terminal")
                    Text(recipe.displayCommand)
                        .lineLimit(1)
                        .textSelection(.enabled)
                    Spacer()
                    Text("Built into Device Sync")
                        .foregroundStyle(DSTheme.inkMuted)
                }
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(DSTheme.inkSoft)
                .padding(10)
                .background(DSTheme.canvas)
                .clipShape(RoundedRectangle(cornerRadius: 9))
            }

            if let run {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: runSymbol(run.outcome))
                        .foregroundStyle(runColor(run.outcome))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(run.outcome.label)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(runColor(run.outcome))
                        Text(run.summary)
                            .font(.caption)
                            .foregroundStyle(DSTheme.inkSoft)
                    }
                    Spacer()
                }
                .padding(10)
                .background(runColor(run.outcome).opacity(0.07))
                .clipShape(RoundedRectangle(cornerRadius: 9))

                if let output = run.output, !output.isEmpty {
                    DisclosureGroup("Repair output", isExpanded: $showOutput) {
                        ScrollView(.horizontal) {
                            Text(output)
                                .font(.system(size: 10, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.top, 8)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(DSTheme.inkSoft)
                }
            }
        }
        .deviceCard()
    }

    private var dispositionColor: Color {
        switch finding.disposition {
        case .repairable: DSTheme.orange
        case .protected: DSTheme.purple
        case .manual: DSTheme.blue
        }
    }

    private var dispositionSymbol: String {
        switch finding.disposition {
        case .repairable: "wrench.and.screwdriver.fill"
        case .protected: "hand.raised.fill"
        case .manual: "person.crop.circle.badge.questionmark"
        }
    }

    private func runColor(_ outcome: DoctorRunOutcome) -> Color {
        switch outcome {
        case .running: DSTheme.blue
        case .repaired: DSTheme.green
        case .repairedNeedsBaselineReview: DSTheme.blue
        case .needsAttention: DSTheme.orange
        case .protected: DSTheme.purple
        case .failed: DSTheme.red
        }
    }

    private func runSymbol(_ outcome: DoctorRunOutcome) -> String {
        switch outcome {
        case .running: "clock.arrow.circlepath"
        case .repaired: "checkmark.seal.fill"
        case .repairedNeedsBaselineReview: "checkmark.circle.badge.questionmark.fill"
        case .needsAttention: "exclamationmark.triangle.fill"
        case .protected: "hand.raised.fill"
        case .failed: "xmark.octagon.fill"
        }
    }
}

private struct DoctorAlignedCard: View {
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 26))
                .foregroundStyle(DSTheme.green)
            VStack(alignment: .leading, spacing: 3) {
                Text("No repair needed")
                    .font(.headline)
                    .foregroundStyle(DSTheme.ink)
                Text("Fresh observed state matches the selected fleet baseline.")
                    .font(.caption)
                    .foregroundStyle(DSTheme.inkSoft)
            }
            Spacer()
        }
        .deviceCard()
    }
}

private struct DoctorStaleCard: View {
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "clock.badge.exclamationmark.fill")
                .font(.system(size: 26))
                .foregroundStyle(DSTheme.orange)
            VStack(alignment: .leading, spacing: 3) {
                Text("Fresh evidence required")
                    .font(.headline)
                    .foregroundStyle(DSTheme.ink)
                Text("This report is stale. Open Device Sync on that Mac and scan before choosing or verifying a repair.")
                    .font(.caption)
                    .foregroundStyle(DSTheme.inkSoft)
            }
            Spacer()
        }
        .deviceCard()
    }
}

struct BootstrapView: View {
    @Bindable var store: FleetStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("NEW MAC & DRIFT RECOVERY")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .tracking(1.5)
                        .foregroundStyle(DSTheme.purple)
                    Text("Bootstrap with guardrails")
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                        .foregroundStyle(DSTheme.ink)
                    Text("The plan delegates to each product's installer and stops where local work or manual identity is involved.")
                        .foregroundStyle(DSTheme.inkSoft)
                }

                if let assessment = store.selectedAssessment {
                    MachineHero(
                        assessment: assessment,
                        isCurrent: assessment.snapshot.machineID == store.localSnapshot?.machineID
                    )
                    plan(for: assessment)
                } else {
                    ContentUnavailableView("Choose a machine", systemImage: "laptopcomputer")
                }
            }
            .padding(28)
        }
    }

    private func plan(for assessment: MachineAssessment) -> some View {
        let steps = store.bootstrapPlan(for: assessment)
        return VStack(alignment: .leading, spacing: 18) {
            ForEach(BootstrapPhase.allCases, id: \.self) { phase in
                let phaseSteps = steps.filter { $0.phase == phase }
                if !phaseSteps.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        SectionTitle(
                            title: phase.rawValue,
                            subtitle: phaseSubtitle(phase)
                        )
                        ForEach(phaseSteps) { step in
                            BootstrapStepRow(step: step)
                        }
                    }
                }
            }
        }
    }

    private func phaseSubtitle(_ phase: BootstrapPhase) -> String {
        switch phase {
        case .foundation: "Establish shared evidence before touching software"
        case .applications: "Install or update through component-owned workflows"
        case .configuration: "Converge only reviewed, non-secret configuration"
        case .validation: "Require fresh installed-state proof"
        }
    }
}

private struct BootstrapStepRow: View {
    let step: BootstrapStep
    @State private var copied = false

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: step.requiresReview ? "hand.raised.fill" : "checkmark.circle.fill")
                .font(.system(size: 19))
                .foregroundStyle(step.requiresReview ? DSTheme.orange : DSTheme.green)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 5) {
                Text(step.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(DSTheme.ink)
                Text(step.detail)
                    .font(.caption)
                    .foregroundStyle(DSTheme.inkSoft)
                if let command = step.command {
                    HStack {
                        Text(command)
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                            .lineLimit(2)
                        Spacer()
                        Button(copied ? "Copied" : "Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(command, forType: .string)
                            copied = true
                        }
                        .buttonStyle(.borderless)
                    }
                    .padding(9)
                    .background(DSTheme.canvas)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }
        }
        .deviceCard()
    }
}

struct SettingsView: View {
    @Bindable var store: FleetStore
    @State private var confirmBaseline = false
    @State private var machineNameDraft = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("FLEET AUTHORITY")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .tracking(1.5)
                        .foregroundStyle(DSTheme.blue)
                    Text("Settings & boundaries")
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                    Text("Choose where snapshots meet, and change desired state only through an explicit baseline action.")
                        .foregroundStyle(DSTheme.inkSoft)
                }

                VStack(alignment: .leading, spacing: 14) {
                    SectionTitle(title: "This Mac", subtitle: "Human-readable fleet name; the stable ID remains a random local UUID")
                    HStack {
                        TextField("e.g. Patrick's MacBook Pro", text: $machineNameDraft)
                            .textFieldStyle(.roundedBorder)
                        Button("Save name") {
                            Task { await store.setMachineDisplayName(machineNameDraft) }
                        }
                        .disabled(machineNameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    Text("Host: \(store.localSnapshot?.hostName ?? "Not scanned")")
                        .font(.caption)
                        .foregroundStyle(DSTheme.inkMuted)
                }
                .deviceCard()

                VStack(alignment: .leading, spacing: 14) {
                    SectionTitle(title: "Fleet folder", subtitle: "Atomic JSON only — never runtime databases or secrets")
                    Text(store.fleetRootURL?.path ?? "Not configured")
                        .font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(DSTheme.canvas)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    HStack {
                        Button("Choose folder…") { Task { await store.chooseFleetFolder() } }
                        Button("Reveal in Finder") { store.revealFleetFolder() }
                            .disabled(store.fleetRootURL == nil)
                    }
                }
                .deviceCard()

                VStack(alignment: .leading, spacing: 14) {
                    SectionTitle(title: "Desired-state baseline", subtitle: "Reference versions and theme fingerprints for every Mac")
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(store.manifest == nil ? "No baseline" : "Fleet protocol v\(store.manifest?.schemaVersion ?? 1)")
                                .font(.headline)
                            Text(store.manifest.map { "Updated \(relativeDate($0.updatedAt)) · \($0.activeTargets.count) targets" } ?? "Create one from a verified Mac.")
                                .font(.caption)
                                .foregroundStyle(DSTheme.inkMuted)
                        }
                        Spacer()
                        Button("Use this Mac as baseline", role: .destructive) {
                            confirmBaseline = true
                        }
                        .disabled(store.localSnapshot == nil)
                    }
                }
                .deviceCard()

                VStack(alignment: .leading, spacing: 12) {
                    SectionTitle(title: "Privacy contract", subtitle: "What leaves this Mac in a fleet snapshot")
                    PrivacyRow(symbol: "checkmark.shield.fill", color: DSTheme.green, text: "Versions, revisions, theme filenames, hashes, model, OS, and snapshot time")
                    PrivacyRow(symbol: "xmark.shield.fill", color: DSTheme.red, text: "No serial, hardware UUID, username, paths, tokens, cookies, Keychain data, logs, or raw config")
                    PrivacyRow(symbol: "externaldrive.badge.xmark", color: DSTheme.orange, text: "ai-continuum SQLite and WAL files always remain on local storage")
                }
                .deviceCard()
            }
            .padding(28)
        }
        .confirmationDialog(
            "Replace the fleet baseline with this Mac?",
            isPresented: $confirmBaseline,
            titleVisibility: .visible
        ) {
            Button("Replace baseline", role: .destructive) {
                Task { await store.adoptThisMacAsBaseline() }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Every machine will be compared with the versions and configuration fingerprints observed on this Mac. No software will be installed by this action.")
        }
        .onAppear { synchronizeMachineName() }
        .onChange(of: store.localSnapshot?.name) { _, _ in synchronizeMachineName() }
    }

    private func synchronizeMachineName() {
        guard machineNameDraft.isEmpty else { return }
        machineNameDraft = store.localState?.displayName ?? store.localSnapshot?.name ?? ""
    }
}

private struct PrivacyRow: View {
    let symbol: String
    let color: Color
    let text: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).foregroundStyle(color).frame(width: 22)
            Text(text).font(.subheadline).foregroundStyle(DSTheme.inkSoft)
        }
    }
}

private struct IssueBanner: View {
    let title: String
    let detail: String
    let color: Color

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(color)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(DSTheme.inkSoft)
            }
            Spacer()
        }
        .padding(13)
        .background(color.opacity(0.09))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).stroke(color.opacity(0.25)) }
    }
}

private struct SectionTitle: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 17, weight: .bold))
                .foregroundColor(DSTheme.ink)
            Text(subtitle).font(.caption).foregroundStyle(DSTheme.inkMuted)
        }
    }
}

private func relativeDate(_ date: Date) -> String {
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .full
    return formatter.localizedString(for: date, relativeTo: Date())
}
