import SwiftUI

private enum AppSection: String, CaseIterable, Identifiable {
    case fleet = "Fleet"
    case bootstrap = "Bootstrap"
    case settings = "Settings"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .fleet: "macbook.and.iphone"
        case .bootstrap: "sparkles.rectangle.stack"
        case .settings: "gearshape"
        }
    }
}

struct RootView: View {
    @Bindable var store: FleetStore
    @State private var section: AppSection = .fleet

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            ZStack {
                DSTheme.canvas.ignoresSafeArea()
                switch section {
                case .fleet:
                    FleetView(store: store) {
                        section = .bootstrap
                    }
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
        }
        .navigationSplitViewStyle(.balanced)
        .tint(DSTheme.blue)
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            brand

            List(selection: $section) {
                Section("CONTROL PLANE") {
                    ForEach(AppSection.allCases) { item in
                        Label(item.rawValue, systemImage: item.symbol)
                            .tag(item)
                    }
                }

                Section("MACHINES") {
                    ForEach(store.filteredAssessments) { assessment in
                        Button {
                            section = .fleet
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
                        Label("Open bootstrap plan", systemImage: "list.bullet.rectangle.portrait")
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
                        .foregroundStyle(DSTheme.ink)
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
                        .foregroundStyle(DSTheme.ink)
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
                    .foregroundStyle(DSTheme.ink)
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
                    .foregroundStyle(DSTheme.ink)
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
                            Text(store.manifest.map { "Updated \(relativeDate($0.updatedAt)) · \($0.targets.count) targets" } ?? "Create one from a verified Mac.")
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
                .foregroundStyle(DSTheme.ink)
            Text(subtitle).font(.caption).foregroundStyle(DSTheme.inkMuted)
        }
    }
}

private func relativeDate(_ date: Date) -> String {
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .full
    return formatter.localizedString(for: date, relativeTo: Date())
}
