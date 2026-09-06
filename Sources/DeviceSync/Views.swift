import SwiftUI

struct RootView: View {
    @Bindable var store: FleetStore
    @Bindable var navigation: AppNavigation
    @Bindable var appearance: FleetMeshAppearanceStore

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            ZStack {
                DSTheme.canvas.ignoresSafeArea()
                switch navigation.section {
                case .fleet:
                    FleetView(
                        store: store,
                        onOpenDoctor: { navigation.open(.doctor) },
                        onOpenBootstrap: { navigation.open(.bootstrap) },
                        onOpenSettings: { navigation.open(.settings) }
                    )
                case .devices:
                    DevicesView(store: store)
                case .doctor:
                    DoctorView(store: store)
                case .bootstrap:
                    BootstrapView(store: store)
                case .settings:
                    SettingsView(store: store, appearance: appearance)
                }
            }
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
                    ForEach(store.filteredDevices) { device in
                        Button {
                            navigation.open(.devices)
                            store.selectedMachineID = device.machineID
                        } label: {
                            MachineSidebarRow(
                                device: device,
                                assessment: store.assessments.first {
                                    $0.snapshot.machineID == device.machineID
                                },
                                isCurrent: device.machineID == store.localSnapshot?.machineID
                            )
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("devicesync.device.row.\(device.machineID)")
                    }
                }
            }
            .listStyle(.sidebar)
            .searchable(text: $store.searchText, prompt: "Devices, roles, or apps")

            fleetFooter
            buildFooter
        }
        .background(.ultraThinMaterial)
        .frame(minWidth: 250)
    }

    private var brand: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(DSTheme.auroraFieldGradient)
                FleetMeshMark()
                    .padding(6)
            }
            .frame(width: 42, height: 42)

            VStack(alignment: .leading, spacing: 2) {
                Text(FleetMeshIdentity.productName)
                    .font(.system(size: 17, weight: .bold))
                Text("Device fleet control plane")
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
                Text("\(store.enrolledDevices.count) device\(store.enrolledDevices.count == 1 ? "" : "s") · \(store.fleetAttentionCount) item\(store.fleetAttentionCount == 1 ? "" : "s")")
                    .font(.caption2)
                    .foregroundStyle(DSTheme.inkMuted)
            }
            Spacer()
        }
        .padding(14)
        .overlay(alignment: .top) { Divider() }
    }

    private var buildFooter: some View {
        HStack {
            Text(FleetMeshBuildIdentity.footerLabel)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(DSTheme.inkMuted)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 10)
        .help(FleetMeshBuildIdentity.detail)
        .accessibilityLabel(FleetMeshBuildIdentity.detail)
        .accessibilityIdentifier("fleetmesh.buildIdentity")
    }
}

private struct MachineSidebarRow: View {
    let device: FleetDeviceItem
    let assessment: MachineAssessment?
    let isCurrent: Bool

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: device.platform == .linux ? "server.rack" : "laptopcomputer")
                .foregroundStyle(statusColor)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(device.name)
                        .lineLimit(1)
                    if isCurrent {
                        Text("THIS MAC")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(DSTheme.blue)
                    }
                }
                Text(statusDetail)
                    .font(.caption2)
                    .foregroundStyle(DSTheme.inkMuted)
            }
            Spacer()
            if let assessment, assessment.attentionCount > 0 {
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

    private var statusDetail: String {
        switch device.status {
        case .pending: return "Pending review"
        case .excluded: return "Removed from fleet"
        case .enrolled:
            if !device.hasFreshEvidence { return "Evidence missing" }
            guard let assessment else { return "Evidence incomplete" }
            return assessment.isStale ? "Snapshot stale" : assessment.verdict.label
        }
    }

    private var statusColor: Color {
        switch device.status {
        case .pending: return DSTheme.blue
        case .excluded: return DSTheme.inkMuted
        case .enrolled:
            guard device.hasFreshEvidence, let assessment else { return DSTheme.orange }
            return DSTheme.color(for: assessment.verdict)
        }
    }
}

struct DevicesView: View {
    @Bindable var store: FleetStore
    @State private var showAddDevice = false
    @State private var pendingMembership: PendingDeviceMembership?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header

                if let error = store.lastError {
                    IssueBanner(title: "Device change failed", detail: error, color: DSTheme.red)
                }
                if let message = store.lastActionMessage {
                    ActionBanner(message: message)
                }
                if store.manifest == nil {
                    IssueBanner(
                        title: "Connect fleet authority first",
                        detail: "A valid fleet-manifest.json is required before FleetMesh can add, enroll, or check in another device.",
                        color: DSTheme.orange
                    )
                }

                inventoryStrip

                if let device = store.selectedDevice {
                    deviceDetail(device)
                } else {
                    ContentUnavailableView(
                        "No devices have checked in",
                        systemImage: "server.rack",
                        description: Text("Add a Linux device over SSH, or install FleetMesh on another Mac and point it at this fleet folder.")
                    )
                    .frame(maxWidth: .infinity, minHeight: 360)
                }
            }
            .padding(28)
        }
        .accessibilityIdentifier("devicesync.devices")
        .sheet(isPresented: $showAddDevice) {
            AddDeviceSheet(store: store, isPresented: $showAddDevice)
        }
        .confirmationDialog(
            membershipTitle,
            isPresented: Binding(
                get: { pendingMembership != nil },
                set: { if !$0 { pendingMembership = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let change = pendingMembership {
                Button(change.enrolled ? "Add to fleet" : "Remove from fleet", role: change.enrolled ? nil : .destructive) {
                    pendingMembership = nil
                    Task {
                        await store.setDeviceEnrollment(
                            machineID: change.device.machineID,
                            enrolled: change.enrolled,
                            role: change.device.role
                        )
                    }
                }
            }
            Button("Cancel", role: .cancel) { pendingMembership = nil }
        } message: {
            if let change = pendingMembership {
                Text(change.enrolled
                    ? "FleetMesh will apply compatible fleet defaults to this device. This changes policy only; it does not install or repair anything."
                    : "The device will stop contributing to fleet health, Bootstrap, and Doctor. Its evidence and local connection will be preserved so it can be added again.")
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 18) {
            VStack(alignment: .leading, spacing: 7) {
                Text("FLEET MEMBERSHIP")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .tracking(1.5)
                    .foregroundStyle(DSTheme.cyan)
                Text("Devices & scope")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                Text("Enroll each device deliberately, classify what it can run, and override fleet defaults only where needed.")
                    .font(.system(size: 14))
                    .foregroundStyle(DSTheme.inkSoft)
            }
            Spacer()
            Button {
                showAddDevice = true
            } label: {
                Label("Add device", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .disabled(store.isBusy || store.manifest == nil)
            .accessibilityIdentifier("devicesync.device.add")
        }
    }

    private var inventoryStrip: some View {
        HStack(spacing: 12) {
            DeviceCountCard(
                title: "In fleet",
                value: store.devices.filter { $0.status == .enrolled }.count,
                color: DSTheme.green,
                symbol: "checkmark.circle.fill"
            )
            DeviceCountCard(
                title: "Pending",
                value: store.devices.filter { $0.status == .pending }.count,
                color: DSTheme.blue,
                symbol: "person.badge.clock.fill"
            )
            DeviceCountCard(
                title: "Missing evidence",
                value: store.missingEnrolledDevices.count,
                color: DSTheme.orange,
                symbol: "exclamationmark.arrow.triangle.2.circlepath"
            )
            DeviceCountCard(
                title: "Removed",
                value: store.devices.filter { $0.status == .excluded }.count,
                color: DSTheme.inkMuted,
                symbol: "minus.circle.fill"
            )
        }
    }

    private func deviceDetail(_ device: FleetDeviceItem) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            DeviceHero(device: device, store: store)

            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 16) {
                    membershipCard(device)
                    capabilitiesCard(device)
                }
                .frame(width: 310, alignment: .topLeading)

                scopeCard(device)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
    }

    private func membershipCard(_ device: FleetDeviceItem) -> some View {
        VStack(alignment: .leading, spacing: 13) {
            SectionTitle(
                title: "Membership & role",
                subtitle: "Platform is observed evidence; role is your fleet policy"
            )

            HStack {
                Text("Status")
                    .font(.subheadline)
                Spacer()
                DeviceStatusPill(status: device.status)
            }

            HStack {
                Text("Device role")
                    .font(.subheadline)
                Spacer()
                Picker("Device role", selection: Binding(
                    get: { device.role },
                    set: { role in
                        Task { await store.setDeviceRole(machineID: device.machineID, role: role) }
                    }
                )) {
                    ForEach(DeviceRole.allCases, id: \.self) { role in
                        Text(role.label).tag(role)
                    }
                }
                .labelsHidden()
                .frame(width: 150)
                .disabled(
                    store.isBusy
                        || store.manifest == nil
                        || (device.status == .pending && device.localConnection == nil)
                )
                .accessibilityIdentifier("devicesync.device.role")
            }

            if device.status == .pending && device.localConnection == nil {
                Text("Enroll this independently reporting device before changing its fleet role.")
                    .font(.caption2)
                    .foregroundStyle(DSTheme.inkMuted)
            }

            if let connection = device.localConnection {
                VStack(alignment: .leading, spacing: 4) {
                    Text("PRIVATE SSH ENDPOINT")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(DSTheme.inkMuted)
                    Text(connection.host)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(2)
                    Text("Stored only in local Application Support; never published to fleet JSON.")
                        .font(.caption2)
                        .foregroundStyle(DSTheme.inkMuted)
                }
                .padding(10)
                .background(DSTheme.canvas)
                .clipShape(RoundedRectangle(cornerRadius: 9))

                Button {
                    Task { await store.checkInRemoteDevice(machineID: device.machineID) }
                } label: {
                    Label(
                        store.isCheckingIn(device.machineID) ? "Checking in…" : "Check in over SSH",
                        systemImage: "arrow.triangle.2.circlepath"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(store.isBusy)
                .accessibilityIdentifier("devicesync.device.checkIn")
            } else if device.machineID == store.localSnapshot?.machineID {
                Button {
                    Task { await store.refresh() }
                } label: {
                    Label("Scan this Mac", systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(store.isBusy)
            }

            membershipButton(device)
        }
        .deviceCard()
    }

    @ViewBuilder
    private func membershipButton(_ device: FleetDeviceItem) -> some View {
        switch device.status {
        case .pending:
            Button {
                pendingMembership = PendingDeviceMembership(device: device, enrolled: true)
            } label: {
                Label("Add to fleet", systemImage: "plus.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!device.hasFreshEvidence || store.isBusy || store.manifest == nil)
            .accessibilityIdentifier("devicesync.device.enroll")
        case .enrolled:
            Button("Remove from fleet…", role: .destructive) {
                pendingMembership = PendingDeviceMembership(device: device, enrolled: false)
            }
            .frame(maxWidth: .infinity)
            .disabled(store.isBusy || store.manifest == nil)
            .accessibilityIdentifier("devicesync.device.remove")
        case .excluded:
            Button {
                pendingMembership = PendingDeviceMembership(device: device, enrolled: true)
            } label: {
                Label("Add back to fleet", systemImage: "arrow.uturn.backward.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!device.hasFreshEvidence || store.isBusy || store.manifest == nil)
            .accessibilityIdentifier("devicesync.device.reenroll")
        }
    }

    private func capabilitiesCard(_ device: FleetDeviceItem) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle(
                title: "Capabilities",
                subtitle: "Reported by this device, never inferred from its role"
            )
            if device.capabilities.isEmpty {
                Label("No current capability evidence", systemImage: "questionmark.circle")
                    .font(.caption)
                    .foregroundStyle(DSTheme.orange)
            } else {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 86), spacing: 7)],
                    alignment: .leading,
                    spacing: 7
                ) {
                    ForEach(device.capabilities.sorted { $0.rawValue < $1.rawValue }, id: \.self) { capability in
                        CapabilityChip(capability: capability)
                    }
                }
            }
        }
        .deviceCard()
    }

    private func scopeCard(_ device: FleetDeviceItem) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                SectionTitle(
                    title: "Scope on this device",
                    subtitle: "Inherit fleet defaults, require an exception, or exclude an item"
                )
                Spacer()
                Text("\(store.deviceScopeItems(for: device.machineID).filter(\.isManaged).count) effective")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(DSTheme.blue)
            }

            if device.status != .enrolled {
                IssueBanner(
                    title: device.status == .pending ? "Review before enrollment" : "Outside fleet health",
                    detail: device.status == .pending
                        ? "Add this device to the fleet before assigning item-level scope. Its check-in does not enroll it automatically."
                        : "Add this device back to the fleet before changing its item-level scope.",
                    color: device.status == .pending ? DSTheme.blue : DSTheme.inkMuted
                )
            } else if !device.hasFreshEvidence {
                IssueBanner(
                    title: "Fresh evidence required",
                    detail: "FleetMesh preserves this enrolled device, but will not change its scope while its report is missing.",
                    color: DSTheme.orange
                )
            }

            let items = store.deviceScopeItems(for: device.machineID)
            if items.isEmpty {
                ContentUnavailableView(
                    "No fleet catalog",
                    systemImage: "checklist.unchecked",
                    description: Text("Create or connect a fleet baseline before assigning device scope.")
                )
                .frame(maxWidth: .infinity, minHeight: 170)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        DeviceScopeRow(
                            item: item,
                            enabled: device.status == .enrolled
                                && device.hasFreshEvidence
                                && !store.isBusy
                        ) { selection in
                            Task {
                                await store.setDeviceScope(
                                    machineID: device.machineID,
                                    componentID: item.id,
                                    selection: selection
                                )
                            }
                        }
                        if index < items.count - 1 {
                            Divider().padding(.leading, 44)
                        }
                    }
                }
                .background(DSTheme.canvas)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(DSTheme.line, lineWidth: 1)
                }
            }
        }
        .deviceCard()
    }

    private var membershipTitle: String {
        guard let change = pendingMembership else { return "Change fleet membership?" }
        return change.enrolled
            ? "Add \(change.device.name) to the fleet?"
            : "Remove \(change.device.name) from the fleet?"
    }
}

private struct PendingDeviceMembership {
    let device: FleetDeviceItem
    let enrolled: Bool
}

private struct DeviceCountCard: View {
    let title: String
    let value: Int
    let color: Color
    let symbol: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(color)
            VStack(alignment: .leading, spacing: 1) {
                Text("\(value)")
                    .font(.system(size: 19, weight: .bold, design: .rounded))
                Text(title)
                    .font(.caption)
                    .foregroundStyle(DSTheme.inkMuted)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .deviceCard()
    }
}

private struct DeviceHero: View {
    let device: FleetDeviceItem
    @Bindable var store: FleetStore

    var body: some View {
        HStack(spacing: 18) {
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(DSTheme.auroraGradient.opacity(0.18))
                Image(systemName: device.platform == .linux ? "server.rack" : "laptopcomputer")
                    .font(.system(size: 32, weight: .medium))
                    .foregroundStyle(DSTheme.cyan)
            }
            .frame(width: 76, height: 68)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(device.name)
                        .font(.system(size: 23, weight: .bold, design: .rounded))
                    if device.machineID == store.localSnapshot?.machineID {
                        Text("THIS MAC")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(DSTheme.blue)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(DSTheme.blue.opacity(0.1))
                            .clipShape(Capsule())
                    }
                }
                Text("\(device.platform.label) · \(device.role.label)")
                    .font(.subheadline)
                    .foregroundStyle(DSTheme.inkSoft)
                if let snapshot = device.snapshot {
                    Text("\(snapshot.architecture) · OS \(snapshot.osVersion) · captured \(relativeDate(snapshot.capturedAt))")
                        .font(.caption)
                        .foregroundStyle(DSTheme.inkMuted)
                } else {
                    Text("No readable check-in is currently available")
                        .font(.caption)
                        .foregroundStyle(DSTheme.orange)
                }
            }
            Spacer()
            DeviceStatusPill(status: device.status)
        }
        .deviceCard()
    }
}

private struct DeviceStatusPill: View {
    let status: DeviceEnrollmentStatus

    var body: some View {
        HStack(spacing: 7) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(status.label).font(.caption.weight(.semibold))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
        .background(color.opacity(0.1))
        .clipShape(Capsule())
    }

    private var color: Color {
        switch status {
        case .pending: DSTheme.blue
        case .enrolled: DSTheme.green
        case .excluded: DSTheme.inkMuted
        }
    }
}

private struct CapabilityChip: View {
    let capability: DeviceCapability

    var body: some View {
        Label(capability.label, systemImage: "checkmark")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(DSTheme.inkSoft)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(DSTheme.cyan.opacity(0.09))
            .clipShape(Capsule())
    }
}

private struct DeviceScopeRow: View {
    let item: FleetScopeItem
    let enabled: Bool
    let update: (DeviceScopeSelection) -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: item.applicability.isApplicable ? "checklist" : "nosign")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(item.applicability.isApplicable ? DSTheme.green : DSTheme.inkMuted)
                .frame(width: 32, height: 32)
                .background((item.applicability.isApplicable ? DSTheme.green : DSTheme.inkMuted).opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 7) {
                    Text(item.name).font(.subheadline.weight(.semibold))
                    Text(item.kind.label.uppercased())
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(DSTheme.inkMuted)
                }
                Text(item.applicability.isApplicable ? item.observedSummary : item.applicability.reason)
                    .font(.caption)
                    .foregroundStyle(item.applicability.isApplicable ? DSTheme.inkMuted : DSTheme.orange)
                    .lineLimit(2)
            }
            Spacer()
            Text(item.scopeLabel)
                .font(.caption.weight(.semibold))
                .foregroundStyle(item.isManaged ? DSTheme.green : DSTheme.inkMuted)
            Menu {
                Button {
                    update(.inherit)
                } label: {
                    scopeLabel(.inherit, selected: item.scopeSelection == .inherit)
                }
                Button {
                    update(.required)
                } label: {
                    scopeLabel(.required, selected: item.scopeSelection == .required)
                }
                .disabled(!item.canRequire)
                Button {
                    update(.excluded)
                } label: {
                    scopeLabel(.excluded, selected: item.scopeSelection == .excluded)
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 16, weight: .medium))
            }
            .menuStyle(.borderlessButton)
            .disabled(!enabled)
            .accessibilityIdentifier("devicesync.device.scope.\(item.id)")
        }
        .padding(12)
    }

    private func scopeLabel(_ selection: DeviceScopeSelection, selected: Bool) -> some View {
        Label(selection.label, systemImage: selected ? "checkmark" : "circle")
    }
}

private struct AddDeviceSheet: View {
    @Bindable var store: FleetStore
    @Binding var isPresented: Bool
    @State private var host = ""
    @State private var displayName = ""
    @State private var role: DeviceRole = .cloudDesktop

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 13).fill(DSTheme.auroraGradient)
                    Image(systemName: "server.rack")
                        .font(.system(size: 23, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .frame(width: 52, height: 52)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Add a Linux device")
                        .font(.title2.bold())
                    Text("Use a host already reachable through your SSH config or agent.")
                        .font(.subheadline)
                        .foregroundStyle(DSTheme.inkSoft)
                }
            }

            Form {
                TextField("SSH host or config alias", text: $host, prompt: Text("dev-dsk-…amazon.com"))
                    .textContentType(.URL)
                TextField("Fleet display name", text: $displayName, prompt: Text("Dev cloud desktop"))
                Picker("Device role", selection: $role) {
                    ForEach(DeviceRole.allCases, id: \.self) { role in
                        Text(role.label).tag(role)
                    }
                }
            }
            .formStyle(.grouped)

            VStack(alignment: .leading, spacing: 6) {
                Label("Runs a fixed, bounded, read-only SSH probe", systemImage: "checkmark.shield.fill")
                Label("Publishes only a random ID and redacted evidence", systemImage: "eye.slash.fill")
                Label("Does not enroll, install, update, or repair the device", systemImage: "hand.raised.fill")
            }
            .font(.caption)
            .foregroundStyle(DSTheme.inkSoft)

            HStack {
                Button("Cancel", role: .cancel) { isPresented = false }
                Spacer()
                Button("Check in device") {
                    let submittedHost = host
                    let submittedName = displayName
                    let submittedRole = role
                    isPresented = false
                    Task {
                        await store.addRemoteDevice(
                            host: submittedHost,
                            displayName: submittedName,
                            role: submittedRole
                        )
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || store.isBusy
                )
            }
        }
        .padding(24)
        .frame(width: 510)
        .foregroundStyle(DSTheme.ink)
    }
}

struct FleetView: View {
    @Bindable var store: FleetStore
    let onOpenDoctor: () -> Void
    let onOpenBootstrap: () -> Void
    let onOpenSettings: () -> Void
    @State private var joinRole: DeviceRole = .workstation
    @State private var confirmJoin = false
    @State private var expandedComponentID: String?
    @State private var pendingInlineRepair: DoctorFinding?
    @State private var pendingConfigurationBaseline: ComponentObservation?

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
                if store.needsFleetConnection || store.localDeviceNeedsEnrollment {
                    joinThisMacCard
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
        .confirmationDialog(
            "Join this Mac to the fleet?",
            isPresented: $confirmJoin,
            titleVisibility: .visible
        ) {
            Button("Join this Mac") {
                Task {
                    await store.joinThisMac(role: joinRole)
                    if store.localDevice?.status == .enrolled {
                        onOpenBootstrap()
                    }
                }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("FleetMesh will enroll this Mac as a \(joinRole.label.lowercased()) and apply only compatible fleet defaults. No app will be installed or repaired by joining.")
        }
        .confirmationDialog(
            pendingInlineRepair.map { "Run \($0.title)?" } ?? "Run product repair?",
            isPresented: Binding(
                get: { pendingInlineRepair != nil },
                set: { if !$0 { pendingInlineRepair = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Run product-owned repair") {
                guard let finding = pendingInlineRepair,
                      let machineID = store.selectedAssessment?.snapshot.machineID else { return }
                pendingInlineRepair = nil
                Task {
                    await store.repair(componentID: finding.id, targetMachineID: machineID)
                }
            }
            Button("Cancel", role: .cancel) { pendingInlineRepair = nil }
        } message: {
            if let finding = pendingInlineRepair, let recipe = finding.recipe {
                Text("FleetMesh will run \(recipe.displayCommand) as you, then re-scan and publish proof. The fleet baseline will not change. If the product requires administrator approval, its supported installer must request it explicitly.")
            }
        }
        .confirmationDialog(
            pendingConfigurationBaseline.map { "Use observed \($0.name) configuration?" }
                ?? "Change configuration baseline?",
            isPresented: Binding(
                get: { pendingConfigurationBaseline != nil },
                set: { if !$0 { pendingConfigurationBaseline = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Use observed configuration as baseline") {
                guard let observation = pendingConfigurationBaseline else { return }
                pendingConfigurationBaseline = nil
                Task {
                    await store.useObservedConfigurationAsBaseline(componentID: observation.id)
                }
            }
            Button("Cancel", role: .cancel) { pendingConfigurationBaseline = nil }
        } message: {
            if let observation = pendingConfigurationBaseline {
                Text("This changes the exact fleet-wide configuration or theme fingerprint for \(observation.name). FleetMesh will scan again first and will not install software.")
            }
        }
    }

    private var joinThisMacCard: some View {
        HStack(alignment: .top, spacing: 18) {
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(DSTheme.auroraFieldGradient.opacity(0.22))
                Image(systemName: store.needsFleetConnection
                    ? "externaldrive.badge.questionmark"
                    : "laptopcomputer.and.arrow.down")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(DSTheme.cyan)
            }
            .frame(width: 68, height: 64)

            VStack(alignment: .leading, spacing: 7) {
                Text(store.needsFleetConnection ? "CONNECT AN EXISTING FLEET" : "THIS MAC IS READY TO JOIN")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .tracking(1.2)
                    .foregroundStyle(DSTheme.cyan)
                Text(store.needsFleetConnection ? "Find your fleet authority" : "Join this Mac to FleetMesh")
                    .font(.title2.weight(.bold))
                Text(joinCardDetail)
                    .font(.subheadline)
                    .foregroundStyle(DSTheme.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 8) {
                    Label("No baseline replacement", systemImage: "lock.shield.fill")
                    Label("No automatic installs", systemImage: "hand.raised.fill")
                }
                .font(.caption2.weight(.semibold))
                .foregroundStyle(DSTheme.inkMuted)
            }

            Spacer(minLength: 20)

            VStack(alignment: .trailing, spacing: 10) {
                if store.needsFleetConnection {
                    if store.localState?.effectiveStorageBackend == .json {
                        if store.detectedExistingFleetURL != nil {
                            Button {
                                Task { await store.connectDetectedFleet() }
                            } label: {
                                Label("Connect detected fleet", systemImage: "link.badge.plus")
                                    .frame(minWidth: 180)
                            }
                            .buttonStyle(.borderedProminent)
                        }
                        Button {
                            Task { await store.chooseExistingFleetFolder() }
                        } label: {
                            Label("Choose existing fleet…", systemImage: "folder")
                                .frame(minWidth: 180)
                        }
                        .buttonStyle(.bordered)

                        Button("Create a new fleet instead…") { onOpenSettings() }
                            .buttonStyle(.plain)
                            .font(.caption)
                            .foregroundStyle(DSTheme.inkMuted)
                    } else {
                        Button {
                            Task { await store.refresh() }
                        } label: {
                            Label("Refresh cloud authority", systemImage: "arrow.clockwise")
                                .frame(minWidth: 180)
                        }
                        .buttonStyle(.borderedProminent)

                        Button("Review storage settings") { onOpenSettings() }
                            .buttonStyle(.plain)
                            .font(.caption)
                            .foregroundStyle(DSTheme.inkMuted)
                    }
                } else {
                    Picker("Device role", selection: $joinRole) {
                        ForEach(DeviceRole.allCases, id: \.self) { role in
                            Text(role.label).tag(role)
                        }
                    }
                    .frame(width: 190)

                    Button {
                        confirmJoin = true
                    } label: {
                        Label("Join this Mac", systemImage: "plus.circle.fill")
                            .frame(minWidth: 180)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(store.isBusy || store.localDevice?.hasFreshEvidence != true)
                    .accessibilityIdentifier("fleetmesh.joinThisMac")
                }
            }
        }
        .padding(18)
        .background(DSTheme.canvas)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(DSTheme.cyan.opacity(0.35), lineWidth: 1)
        }
    }

    private var joinCardDetail: String {
        if store.needsFleetConnection {
            if store.localState?.effectiveStorageBackend == .json {
                return "Wait for OneDrive to finish syncing, then connect the folder that already contains fleet-manifest.json. A new Mac never creates or replaces fleet authority during a scan."
            }
            return "DynamoDB authority is configured locally but no readable fleet manifest is available. Refresh after restoring least-privilege AWS access; FleetMesh will not create or replace cloud authority during a scan."
        }
        let targetCount = store.manifest?.activeTargets.count ?? 0
        let deviceCount = store.enrolledDevices.count
        return "Fleet authority is verified. Review this Mac, then enroll it explicitly alongside \(deviceCount) existing device\(deviceCount == 1 ? "" : "s") with \(targetCount) managed default\(targetCount == 1 ? "" : "s")."
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
            .disabled(store.isBusy)
        }
    }

    private var fleetHeadline: String {
        guard store.manifest != nil else {
            return "No verified baseline is available. FleetMesh will not infer one from missing evidence."
        }
        switch store.fleetVerdict {
        case .aligned:
            return "Every fresh machine report matches the selected software and theme baseline."
        case .attention:
            return "One or more devices differ from the baseline or have stale evidence."
        case .critical:
            return "A required app or configuration is missing on at least one device."
        case .unknown:
            return "Some fleet evidence could not be read or verified."
        }
    }

    private var metrics: some View {
        HStack(spacing: 12) {
            MetricCard(
                title: "Devices",
                value: "\(store.enrolledDevices.count)",
                detail: "in fleet",
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
                value: store.manifest.map { "v\($0.schemaVersion)" } ?? "—",
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
                    SectionTitle(title: "Managed software & configuration", subtitle: "Only items explicitly included in the fleet baseline")
                    if assessment.managedDrifts.isEmpty {
                        ContentUnavailableView(
                            "No managed items",
                            systemImage: "checklist.unchecked",
                            description: Text("Add apps, tools, or themes from Settings → Fleet defaults.")
                        )
                        .frame(maxWidth: .infinity, minHeight: 180)
                        .deviceCard()
                    } else {
                        ForEach(assessment.managedDrifts) { drift in
                            DriftRow(
                                drift: drift,
                                observation: assessment.snapshot.component(drift.componentID),
                                finding: store.doctorFindings(for: assessment).first {
                                    $0.id == drift.componentID
                                },
                                run: store.doctorRun(for: drift.componentID),
                                expanded: expandedComponentID == drift.componentID,
                                isLocalMachine: assessment.snapshot.machineID == store.localSnapshot?.machineID,
                                isBusy: store.isBusy,
                                onToggle: {
                                    expandedComponentID = expandedComponentID == drift.componentID
                                        ? nil : drift.componentID
                                },
                                onRepair: { finding in pendingInlineRepair = finding },
                                onUseObservedBaseline: { observation in
                                    pendingConfigurationBaseline = observation
                                },
                                onReviewCheckout: { observation in
                                    guard let path = FleetComponentPaths.sourceCheckout(
                                        componentID: observation.id,
                                        homeURL: FileManager.default.homeDirectoryForCurrentUser
                                    ) else { return }
                                    NSWorkspace.shared.activateFileViewerSelecting([path])
                                }
                            )
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .leading, spacing: 12) {
                    SectionTitle(title: "Convergence flow", subtitle: "Review before any machine changes")
                    ConvergenceFlow(assessment: assessment)

                    Button {
                        store.selectedMachineID = assessment.snapshot.machineID
                        onOpenDoctor()
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
                Image(systemName: assessment.snapshot.effectivePlatform == .linux
                    ? "server.rack"
                    : "laptopcomputer")
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
                Text("\(assessment.snapshot.modelIdentifier) · \(assessment.snapshot.architecture) · \(assessment.snapshot.effectivePlatform.label) \(assessment.snapshot.osVersion)")
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
    let finding: DoctorFinding?
    let run: DoctorRunRecord?
    let expanded: Bool
    let isLocalMachine: Bool
    let isBusy: Bool
    let onToggle: () -> Void
    let onRepair: (DoctorFinding) -> Void
    let onUseObservedBaseline: (ComponentObservation) -> Void
    let onReviewCheckout: (ComponentObservation) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: onToggle) {
                rowContent
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("fleetmesh.managedItem.\(drift.componentID)")
            .accessibilityHint(expanded ? "Collapse actions" : "Show actions and details")

            if expanded {
                Divider().padding(.vertical, 12)
                InlineRemediationPanel(
                    drift: drift,
                    observation: observation,
                    finding: finding,
                    run: run,
                    isLocalMachine: isLocalMachine,
                    isBusy: isBusy,
                    onRepair: onRepair,
                    onUseObservedBaseline: onUseObservedBaseline,
                    onReviewCheckout: onReviewCheckout
                )
            }
        }
        .deviceCard()
    }

    private var rowContent: some View {
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
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(DSTheme.inkMuted)
                }
                Text(drift.summary)
                    .font(.caption)
                    .foregroundStyle(DSTheme.inkSoft)

                HStack(spacing: 12) {
                    if let expected = drift.expected {
                        Label("\(drift.targetLabel) \(expected)", systemImage: "scope")
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

private struct InlineRemediationPanel: View {
    let drift: ComponentDrift
    let observation: ComponentObservation?
    let finding: DoctorFinding?
    let run: DoctorRunRecord?
    let isLocalMachine: Bool
    let isBusy: Bool
    let onRepair: (DoctorFinding) -> Void
    let onUseObservedBaseline: (ComponentObservation) -> Void
    let onReviewCheckout: (ComponentObservation) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: actionSymbol)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(actionColor)
                    .frame(width: 36, height: 36)
                    .background(actionColor.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 9))

                VStack(alignment: .leading, spacing: 3) {
                    Text(actionTitle)
                        .font(.subheadline.weight(.semibold))
                    Text(actionDetail)
                        .font(.caption)
                        .foregroundStyle(DSTheme.inkSoft)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                actionButton
            }

            if let run {
                VStack(alignment: .leading, spacing: 5) {
                    Text(run.outcome.label)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(run.outcome == .failed ? DSTheme.red : DSTheme.inkSoft)
                    Text(run.summary)
                        .font(.caption)
                        .foregroundStyle(DSTheme.inkSoft)
                    if let output = run.output, !output.isEmpty {
                        ScrollView(.horizontal) {
                            Text(output)
                                .font(.system(size: 10, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(9)
                        .background(DSTheme.canvas)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .accessibilityIdentifier("fleetmesh.repairOutput.\(drift.componentID)")
                    }
                }
                .padding(10)
                .background((run.outcome == .failed ? DSTheme.red : DSTheme.blue).opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 9))
            }
        }
    }

    @ViewBuilder
    private var actionButton: some View {
        switch action {
        case .repair:
            if let finding {
            Button("Repair…") { onRepair(finding) }
                .buttonStyle(.borderedProminent)
                .tint(DSTheme.orange)
                .disabled(isBusy || !isLocalMachine)
                .accessibilityIdentifier("fleetmesh.inlineRepair.\(drift.componentID)")
            }
        case .reviewCheckout:
            if let observation {
                Button("Review local checkout") { onReviewCheckout(observation) }
                    .buttonStyle(.bordered)
                    .disabled(!isLocalMachine)
                    .accessibilityIdentifier("fleetmesh.reviewCheckout.\(drift.componentID)")
            }
        case .useObservedBaseline:
            if let observation {
                Button("Use observed as baseline…") {
                    onUseObservedBaseline(observation)
                }
                .buttonStyle(.borderedProminent)
                .tint(DSTheme.blue)
                .disabled(isBusy || !isLocalMachine)
                .accessibilityIdentifier("fleetmesh.useObservedBaseline.\(drift.componentID)")
            }
        case .none:
            EmptyView()
        }
    }

    private var action: InlineRemediationAction {
        InlineRemediationPolicy.action(
            drift: drift,
            observation: observation,
            finding: finding
        )
    }

    private var actionTitle: String {
        if let finding { return finding.title }
        if drift.state == .aligned { return "No action needed" }
        return "Review observed state"
    }

    private var actionDetail: String {
        if let finding { return finding.detail }
        if drift.state == .aligned { return "Fresh evidence already matches the selected target." }
        return "Choose whether this observation should become explicit fleet-wide desired state."
    }

    private var actionSymbol: String {
        if finding?.canRepair == true { return "wrench.and.screwdriver.fill" }
        if drift.state == .localChanges { return "hand.raised.fill" }
        if action == .useObservedBaseline { return "scope" }
        return "info.circle.fill"
    }

    private var actionColor: Color {
        if finding?.canRepair == true { return DSTheme.orange }
        if drift.state == .localChanges { return DSTheme.purple }
        if action == .useObservedBaseline { return DSTheme.blue }
        return DSTheme.green
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
    @State private var pendingConfigurationBaseline: ComponentObservation?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                doctorHeader
                if let error = store.lastError {
                    IssueBanner(title: "Doctor evidence failed", detail: error, color: DSTheme.red)
                }
                if store.isLaunchingCodexResolution {
                    DoctorCodexProgressBanner()
                }
                if let taskID = store.completedCodexResolutionTaskID {
                    DoctorCodexResultBanner(
                        taskID: taskID,
                        summary: store.completedCodexResolutionSummary
                    )
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
                        let hasLocalConnection = store.selectedDevice?.localConnection != nil
                        IssueBanner(
                            title: hasLocalConnection
                                ? "Remote diagnosis is read-only"
                                : "Published report is read-only here",
                            detail: hasLocalConnection
                                ? "Diagnose runs FleetMesh's fixed, bounded SSH probe and publishes fresh redacted evidence. Remote repairs remain disabled."
                                : "This Mac has no private SSH connection for the selected device. Diagnose it from the controller that added it; remote repairs remain disabled.",
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
                                    observation: assessment.snapshot.component(finding.id),
                                    run: store.doctorRun(for: finding.id),
                                    isActive: store.activeDoctorComponentID == finding.id,
                                    isCodexResolving: store.isLaunchingCodexResolution,
                                    isLocalMachine: assessment.snapshot.machineID == store.localSnapshot?.machineID,
                                    doctorBusy: store.isBusy,
                                    canResolveCheckout: store.canResolveCheckoutWithCodex(finding),
                                    canReviewCheckout: store.canReviewCheckout(componentID: finding.id)
                                ) {
                                    pendingRepair = finding
                                } onResolveWithCodex: {
                                    Task { await store.resolveCheckoutWithCodex(finding) }
                                } onReviewCheckout: {
                                    store.revealCheckout(componentID: finding.id)
                                } onUseObservedBaseline: { observation in
                                    pendingConfigurationBaseline = observation
                                } onScanAgain: {
                                    Task { await store.diagnoseSelectedMachine() }
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
                Text("FleetMesh will run \(recipe.displayCommand), then re-scan and publish the observed result. The fleet baseline will not change.")
            }
        }
        .confirmationDialog(
            pendingConfigurationBaseline.map { "Use observed \($0.name) configuration?" }
                ?? "Change configuration baseline?",
            isPresented: Binding(
                get: { pendingConfigurationBaseline != nil },
                set: { if !$0 { pendingConfigurationBaseline = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Use observed configuration as baseline") {
                guard let observation = pendingConfigurationBaseline else { return }
                pendingConfigurationBaseline = nil
                Task {
                    await store.useObservedConfigurationAsBaseline(componentID: observation.id)
                }
            }
            Button("Cancel", role: .cancel) { pendingConfigurationBaseline = nil }
        } message: {
            if let observation = pendingConfigurationBaseline {
                Text("This changes the exact fleet-wide configuration or theme fingerprint for \(observation.name). FleetMesh will scan again first and will not run bootstrap or install software.")
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
                Task { await store.diagnoseSelectedMachine() }
            } label: {
                Label(
                    store.isDiagnosingSelectedMachine
                        ? "Diagnosing…"
                        : store.selectedMachineDiagnosisLabel,
                    systemImage: "stethoscope"
                )
            }
            .buttonStyle(.borderedProminent)
            .disabled(store.isBusy || !store.canDiagnoseSelectedMachine)
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
                .background(DSTheme.card)
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
    let observation: ComponentObservation?
    let run: DoctorRunRecord?
    let isActive: Bool
    let isCodexResolving: Bool
    let isLocalMachine: Bool
    let doctorBusy: Bool
    let canResolveCheckout: Bool
    let canReviewCheckout: Bool
    let onRepair: () -> Void
    let onResolveWithCodex: () -> Void
    let onReviewCheckout: () -> Void
    let onUseObservedBaseline: (ComponentObservation) -> Void
    let onScanAgain: () -> Void

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

            if finding.needsCheckoutResolution {
                VStack(alignment: .leading, spacing: 9) {
                    Text("Recommended resolution")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(DSTheme.purple)
                    Text("Commit intentional local work first. Do not rebaseline FleetMesh just to make a dirty checkout disappear. After the checkout is clean, scan again; baseline review is separate if the committed configuration changed.")
                        .font(.caption)
                        .foregroundStyle(DSTheme.inkSoft)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        Button(isCodexResolving ? "Codex working…" : "Resolve with Codex", action: onResolveWithCodex)
                            .buttonStyle(.borderedProminent)
                            .tint(DSTheme.purple)
                            .disabled(doctorBusy || !isLocalMachine || !canResolveCheckout)
                            .accessibilityIdentifier("doctor.resolveWithCodex.\(finding.id)")
                        Button("Review changes", action: onReviewCheckout)
                            .buttonStyle(.bordered)
                            .disabled(doctorBusy || !isLocalMachine || !canReviewCheckout)
                            .accessibilityIdentifier("doctor.reviewCheckout.\(finding.id)")
                        Button("Scan again", action: onScanAgain)
                            .buttonStyle(.bordered)
                            .disabled(doctorBusy || !isLocalMachine)
                            .accessibilityIdentifier("doctor.scanAgain.\(finding.id)")
                    }
                }
                .padding(11)
                .background(DSTheme.purple.opacity(0.07))
                .clipShape(RoundedRectangle(cornerRadius: 9))
            }

            if finding.needsBaselineDecision, let observation {
                VStack(alignment: .leading, spacing: 9) {
                    Text("Committed configuration decision")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(DSTheme.blue)
                    Text("The checkout is clean and committed. Review the exact fingerprint change, then adopt it only if it should become fleet-wide desired state. Bootstrap is not a repair for this difference.")
                        .font(.caption)
                        .foregroundStyle(DSTheme.inkSoft)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        Button("Use observed as baseline…") {
                            onUseObservedBaseline(observation)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(DSTheme.blue)
                        .disabled(doctorBusy || !isLocalMachine)
                        .accessibilityIdentifier("doctor.useObservedBaseline.\(finding.id)")
                        Button("Review changes", action: onReviewCheckout)
                            .buttonStyle(.bordered)
                            .disabled(doctorBusy || !isLocalMachine || !canReviewCheckout)
                            .accessibilityIdentifier("doctor.reviewCheckout.\(finding.id)")
                        Button("Scan again", action: onScanAgain)
                            .buttonStyle(.bordered)
                            .disabled(doctorBusy || !isLocalMachine)
                            .accessibilityIdentifier("doctor.scanAgain.\(finding.id)")
                    }
                }
                .padding(11)
                .background(DSTheme.blue.opacity(0.07))
                .clipShape(RoundedRectangle(cornerRadius: 9))
            }

            if finding.canRepair, let recipe = finding.recipe {
                HStack(spacing: 8) {
                    Image(systemName: "terminal")
                    Text(recipe.displayCommand)
                        .lineLimit(1)
                        .textSelection(.enabled)
                    Spacer()
                    Text("Built into FleetMesh")
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
        .onChange(of: run?.finishedAt) { _, _ in
            if run?.outcome == .failed { showOutput = true }
        }
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

private struct DoctorCodexProgressBanner: View {
    var body: some View {
        HStack(spacing: 12) {
            ProgressView().controlSize(.small)
            VStack(alignment: .leading, spacing: 3) {
                Text("Codex is resolving Harness Sync")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(DSTheme.ink)
                Text("FleetMesh is keeping the agent in the background so you can continue working. It will not switch apps or change the fleet baseline.")
                    .font(.caption)
                    .foregroundStyle(DSTheme.inkSoft)
            }
            Spacer()
        }
        .padding(14)
        .background(DSTheme.purple.opacity(0.09))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .accessibilityIdentifier("doctor.codexProgress")
    }
}

private struct DoctorCodexResultBanner: View {
    let taskID: String
    let summary: String?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(DSTheme.green)
            VStack(alignment: .leading, spacing: 3) {
                Text("Codex resolution finished")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(DSTheme.ink)
                Text("Task \(taskID). The task is saved in Codex; FleetMesh keeps the result here so it does not need access to another app. Scan again after review. Baseline adoption remains separate.")
                    .font(.caption)
                    .foregroundStyle(DSTheme.inkSoft)
                    .textSelection(.enabled)
                if let summary, !summary.isEmpty {
                    DisclosureGroup("Resolution summary") {
                        Text(summary)
                            .font(.caption)
                            .foregroundStyle(DSTheme.inkSoft)
                            .textSelection(.enabled)
                            .padding(.top, 6)
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(DSTheme.ink)
                    .accessibilityIdentifier("doctor.codexResultSummary")
                }
            }
            Spacer()
        }
        .padding(14)
        .background(DSTheme.green.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 12))
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
                Text("This report is stale. Open FleetMesh on that Mac and scan before choosing or verifying a repair.")
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
    @Bindable var appearance: FleetMeshAppearanceStore
    @State private var confirmBaseline = false
    @State private var machineNameDraft = ""
    @State private var pendingScopeChange: PendingScopeChange?
    @State private var showHiddenItems = false

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

                if let error = store.lastError {
                    IssueBanner(title: "Settings change failed", detail: error, color: DSTheme.red)
                }

                VStack(alignment: .leading, spacing: 14) {
                    SectionTitle(
                        title: "Appearance",
                        subtitle: "Follow macOS or choose a dedicated Light or Dark Aurora canvas"
                    )
                    Picker(
                        "Appearance",
                        selection: Binding(
                            get: { appearance.selection },
                            set: { appearance.select($0) }
                        )
                    ) {
                        ForEach(FleetMeshAppearance.allCases) { option in
                            Label(option.label, systemImage: option.symbol).tag(option)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .accessibilityIdentifier("fleetmesh.appearance")
                    Text(appearance.selection == .system
                        ? "System follows the current macOS appearance automatically."
                        : "FleetMesh will stay \(appearance.selection.label.lowercased()) even when macOS changes.")
                        .font(.caption)
                        .foregroundStyle(DSTheme.inkMuted)
                }
                .deviceCard()

                VStack(alignment: .leading, spacing: 14) {
                    SectionTitle(title: "This Mac", subtitle: "Human-readable fleet name; the stable ID remains a random local UUID")
                    HStack {
                        TextField("e.g. Patrick's MacBook Pro", text: $machineNameDraft)
                            .textFieldStyle(.roundedBorder)
                        Button("Save name") {
                            Task { await store.setMachineDisplayName(machineNameDraft) }
                        }
                        .disabled(
                            store.isBusy
                                || machineNameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        )
                    }
                    Text("Host: \(store.localSnapshot?.hostName ?? "Not scanned")")
                        .font(.caption)
                        .foregroundStyle(DSTheme.inkMuted)
                }
                .deviceCard()

                VStack(alignment: .leading, spacing: 14) {
                    SectionTitle(
                        title: "Fleet authority",
                        subtitle: "Local JSON, verified shadow comparison, or DynamoDB control plane"
                    )
                    if store.localState?.effectiveStorageBackend == .json {
                        Text(store.fleetRootURL?.path ?? "Not configured")
                            .font(.system(size: 12, design: .monospaced))
                            .textSelection(.enabled)
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(DSTheme.canvas)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                        HStack {
                            Button("Choose folder…") { Task { await store.chooseFleetFolder() } }
                                .disabled(store.isBusy)
                            Button("Reveal in Finder") { store.revealFleetFolder() }
                                .disabled(store.fleetRootURL == nil || store.isBusy)
                        }
                        VStack(alignment: .leading, spacing: 7) {
                            Label("fleet-manifest.json — in-scope products and desired state", systemImage: "scope")
                            Label("machines/<machine-id>.json — observed evidence from each device", systemImage: "laptopcomputer.and.arrow.down")
                            Label("local-state.json — this Mac's anonymous ID and fleet pointer", systemImage: "internaldrive")
                        }
                        .font(.caption)
                        .foregroundStyle(DSTheme.inkSoft)
                    } else {
                        let backend = store.localState?.effectiveStorageBackend ?? .json
                        let table = store.localState?.dynamoDBTable ?? "Unconfigured table"
                        let region = store.localState?.awsRegion ?? "Unconfigured Region"
                        let fleetID = store.localState?.fleetID ?? "Unconfigured fleet"
                        Text("\(table) · \(region) · fleet \(fleetID)")
                            .font(.system(size: 12, design: .monospaced))
                            .textSelection(.enabled)
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(DSTheme.canvas)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                        VStack(alignment: .leading, spacing: 7) {
                            if backend == .shadow {
                                Label("JSON remains authoritative; DynamoDB is compared read-only", systemImage: "rectangle.on.rectangle")
                            } else {
                                Label("DynamoDB is authoritative; a private JSON cache provides visible stale fallback", systemImage: "cloud")
                            }
                            Label("AWS credentials come from the selected local profile and never enter fleet data", systemImage: "key")
                            Label("SSH endpoints and controller settings remain only in local-state.json", systemImage: "lock.shield")
                        }
                        .font(.caption)
                        .foregroundStyle(DSTheme.inkSoft)
                        Button("Refresh authority") { Task { await store.refresh() } }
                            .disabled(store.isBusy)
                    }
                }
                .deviceCard()

                VStack(alignment: .leading, spacing: 14) {
                    SectionTitle(title: "In-scope manifest", subtitle: "Defaults, versions, and fingerprints for compatible fleet devices")
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(store.manifest.map { "Fleet protocol v\($0.schemaVersion)" } ?? "No baseline")
                                .font(.headline)
                            Text(store.manifest.map { "Updated \(relativeDate($0.updatedAt)) · \($0.activeTargets.count) targets" } ?? "Create one from a verified Mac.")
                                .font(.caption)
                                .foregroundStyle(DSTheme.inkMuted)
                        }
                        Spacer()
                        Button("Use this Mac as baseline", role: .destructive) {
                            confirmBaseline = true
                        }
                        .disabled(store.localSnapshot == nil || store.isBusy)
                    }
                    Text(store.localState?.effectiveStorageBackend == .json
                        ? "New Macs must connect the shared fleet folder before their first scan. Linux devices check in over a local-only SSH connection. Do not replace the baseline unless you intend to change fleet-wide defaults."
                        : "New Macs must have the same local DynamoDB identifiers and least-privilege AWS access before their first scan. Linux devices still check in through a controller's local-only SSH connection. Do not replace the baseline unless you intend to change fleet-wide defaults.")
                        .font(.caption)
                        .foregroundStyle(DSTheme.inkSoft)
                }
                .deviceCard()

                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .top) {
                        SectionTitle(
                            title: "Fleet defaults",
                            subtitle: "Choose what compatible devices inherit for comparison and Bootstrap"
                        )
                        Spacer()
                        if store.isUpdatingScope {
                            ProgressView()
                                .controlSize(.small)
                        } else if let manifest = store.manifest {
                            Text("\(manifest.activeTargets.count) managed")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(DSTheme.blue)
                        }
                    }

                    Text("Remove changes fleet scope. Hide only cleans up this Mac's Available list. Neither action uninstalls the app, deletes source, or erases observed evidence.")
                        .font(.caption)
                        .foregroundStyle(DSTheme.inkSoft)

                    if store.manifest == nil {
                        ContentUnavailableView(
                            "No fleet baseline",
                            systemImage: "scope",
                            description: Text("Connect the shared fleet folder or create a verified baseline before changing scope.")
                        )
                        .frame(maxWidth: .infinity, minHeight: 150)
                    } else {
                        VStack(spacing: 0) {
                            ForEach(Array(store.fleetScopeItems.enumerated()), id: \.element.id) { index, item in
                                ManagedItemRow(
                                    item: item,
                                    isBusy: store.isBusy,
                                    hide: {
                                        store.setComponentHidden(
                                            componentID: item.id,
                                            hidden: true
                                        )
                                    }
                                ) {
                                    pendingScopeChange = PendingScopeChange(
                                        item: item,
                                        managed: !item.isManaged
                                    )
                                }
                                if index < store.fleetScopeItems.count - 1 {
                                    Divider().padding(.leading, 44)
                                }
                            }
                        }
                        .background(DSTheme.canvas)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(DSTheme.line, lineWidth: 1)
                        }

                        if !store.hiddenFleetScopeItems.isEmpty {
                            DisclosureGroup(isExpanded: $showHiddenItems) {
                                VStack(alignment: .leading, spacing: 0) {
                                    Text("Hidden only from this Available list on this Mac. FleetMesh still inventories these items, and shared fleet state is unchanged.")
                                        .font(.caption)
                                        .foregroundStyle(DSTheme.inkMuted)
                                        .padding(.horizontal, 12)
                                        .padding(.bottom, 8)
                                    ForEach(
                                        Array(store.hiddenFleetScopeItems.enumerated()),
                                        id: \.element.id
                                    ) { index, item in
                                        HiddenManagedItemRow(
                                            item: item,
                                            isBusy: store.isBusy
                                        ) {
                                            store.setComponentHidden(
                                                componentID: item.id,
                                                hidden: false
                                            )
                                        }
                                        if index < store.hiddenFleetScopeItems.count - 1 {
                                            Divider().padding(.leading, 44)
                                        }
                                    }
                                }
                                .padding(.top, 10)
                            } label: {
                                HStack(spacing: 8) {
                                    Label("Hidden items", systemImage: "eye.slash")
                                        .font(.subheadline.weight(.semibold))
                                    Spacer()
                                    Text("\(store.hiddenFleetScopeItems.count)")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(DSTheme.inkMuted)
                                }
                            }
                            .padding(12)
                            .background(DSTheme.canvas)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .stroke(DSTheme.line, lineWidth: 1)
                            }
                        }
                    }
                }
                .deviceCard()

                if let message = store.lastActionMessage {
                    ActionBanner(message: message)
                }

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
        .confirmationDialog(
            scopeConfirmationTitle,
            isPresented: Binding(
                get: { pendingScopeChange != nil },
                set: { if !$0 { pendingScopeChange = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let change = pendingScopeChange {
                Button(change.managed ? "Add to fleet scope" : "Remove from fleet scope", role: change.managed ? nil : .destructive) {
                    pendingScopeChange = nil
                    Task {
                        await store.setComponentManaged(
                            componentID: change.item.id,
                            managed: change.managed
                        )
                    }
                }
            }
            Button("Cancel", role: .cancel) { pendingScopeChange = nil }
        } message: {
            if let change = pendingScopeChange {
                Text(change.managed
                    ? "FleetMesh will use this Mac's fresh observed state as the desired version or fingerprint for \(change.item.name). No software will be installed."
                    : "FleetMesh will stop comparing, bootstrapping, and repairing \(change.item.name) across the fleet. The app and source checkout will remain untouched.")
            }
        }
        .onAppear { synchronizeMachineName() }
        .onChange(of: store.localSnapshot?.name) { _, _ in synchronizeMachineName() }
    }

    private func synchronizeMachineName() {
        guard machineNameDraft.isEmpty else { return }
        machineNameDraft = store.localState?.displayName ?? store.localSnapshot?.name ?? ""
    }

    private var scopeConfirmationTitle: String {
        guard let change = pendingScopeChange else { return "Change fleet scope?" }
        return change.managed
            ? "Add \(change.item.name) to fleet scope?"
            : "Remove \(change.item.name) from fleet scope?"
    }
}

private struct PendingScopeChange {
    let item: FleetScopeItem
    let managed: Bool
}

private struct ManagedItemRow: View {
    let item: FleetScopeItem
    let isBusy: Bool
    let hide: () -> Void
    let changeScope: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(item.isManaged ? DSTheme.green : DSTheme.inkMuted)
                .frame(width: 32, height: 32)
                .background((item.isManaged ? DSTheme.green : DSTheme.inkMuted).opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 7) {
                    Text(item.name)
                        .font(.subheadline.weight(.semibold))
                    Text(item.kind.label.uppercased())
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(DSTheme.inkMuted)
                }
                Text(item.observedSummary)
                    .font(.caption)
                    .foregroundStyle(DSTheme.inkMuted)
            }
            Spacer()
            Text(item.isManaged ? "Managed" : "Available")
                .font(.caption.weight(.semibold))
                .foregroundStyle(item.isManaged ? DSTheme.green : DSTheme.inkMuted)
            if !item.isManaged {
                Button(action: hide) {
                    Label("Hide", systemImage: "eye.slash")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(DSTheme.inkMuted)
                .disabled(isBusy)
                .accessibilityLabel("Hide \(item.name) from Available items on this Mac")
            }
            Button(item.isManaged ? "Remove" : "Add", action: changeScope)
                .buttonStyle(.bordered)
                .disabled(isBusy || (!item.isManaged && !item.canAdd))
                .accessibilityLabel("\(item.isManaged ? "Remove" : "Add") \(item.name) \(item.isManaged ? "from" : "to") fleet scope")
        }
        .padding(12)
    }

    private var symbol: String {
        switch item.kind {
        case .application: "app.fill"
        case .commandLineTool: "terminal.fill"
        case .service: "wave.3.right.circle.fill"
        case .configuration: "slider.horizontal.3"
        case .theme: "paintpalette.fill"
        }
    }
}

private struct HiddenManagedItemRow: View {
    let item: FleetScopeItem
    let isBusy: Bool
    let show: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "eye.slash.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(DSTheme.inkMuted)
                .frame(width: 32, height: 32)
                .background(DSTheme.inkMuted.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 7) {
                    Text(item.name)
                        .font(.subheadline.weight(.semibold))
                    Text(item.kind.label.uppercased())
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(DSTheme.inkMuted)
                }
                Text(item.observedSummary)
                    .font(.caption)
                    .foregroundStyle(DSTheme.inkMuted)
            }
            Spacer()
            Text("Hidden locally")
                .font(.caption.weight(.semibold))
                .foregroundStyle(DSTheme.inkMuted)
            Button("Show", action: show)
                .buttonStyle(.bordered)
                .disabled(isBusy)
                .accessibilityLabel("Show \(item.name) in Available items")
        }
        .padding(12)
    }
}

private struct ActionBanner: View {
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(DSTheme.green)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(DSTheme.inkSoft)
            Spacer()
        }
        .padding(13)
        .background(DSTheme.green.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 12).stroke(DSTheme.green.opacity(0.22)) }
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
    FleetDateFormatting.relative(date)
}
