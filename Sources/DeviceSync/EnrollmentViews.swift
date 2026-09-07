import Foundation
import SwiftUI
import UniformTypeIdentifiers

struct MacEnrollmentInvitationSheet: View {
    @Bindable var store: FleetStore
    @Binding var isPresented: Bool
    @State private var document: FleetEnrollmentInvitationDocument?
    @State private var isExporting = false
    @State private var errorMessage: String?
    @State private var exported = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            enrollmentHeader(
                title: "Invite a new Mac",
                subtitle: "Create a credential-free connection file for the FleetMesh first-run wizard.",
                symbol: "laptopcomputer.and.arrow.down"
            )

            if let errorMessage {
                enrollmentNotice(errorMessage, color: DSTheme.red, symbol: "exclamationmark.triangle.fill")
            }
            if exported {
                enrollmentNotice(
                    "Invitation saved. Transfer it to the new Mac, open FleetMesh, and choose Join existing fleet.",
                    color: DSTheme.green,
                    symbol: "checkmark.circle.fill"
                )
            }

            VStack(alignment: .leading, spacing: 10) {
                enrollmentDetailRow(label: "Authority", value: "DynamoDB")
                enrollmentDetailRow(label: "Region", value: store.localState?.awsRegion ?? "Unavailable")
                enrollmentDetailRow(label: "Table", value: store.localState?.dynamoDBTable ?? "Unavailable")
                enrollmentDetailRow(label: "Fleet", value: store.localState?.fleetID ?? "Unavailable")
                enrollmentDetailRow(
                    label: "Profile hint",
                    value: FleetEnrollmentInvitation.defaultReporterProfileHint
                )
            }
            .padding(14)
            .background(DSTheme.canvas)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            VStack(alignment: .leading, spacing: 7) {
                Label("Contains no AWS credentials, tokens, account ID, or device identity", systemImage: "lock.shield.fill")
                Label("Does not copy controller access or private SSH endpoints", systemImage: "eye.slash.fill")
                Label("The new Mac remains Pending until you approve it here", systemImage: "person.badge.clock.fill")
            }
            .font(.caption)
            .foregroundStyle(DSTheme.inkSoft)

            HStack {
                Button("Close", role: .cancel) { isPresented = false }
                Spacer()
                Button {
                    prepareExport()
                } label: {
                    Label("Save invitation…", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!store.canCreateEnrollmentInvitation || store.isBusy)
            }
        }
        .padding(24)
        .frame(width: 540)
        .foregroundStyle(DSTheme.ink)
        .fileExporter(
            isPresented: $isExporting,
            document: document,
            contentType: .fleetMeshInvitation,
            defaultFilename: document?.invitation.suggestedFilename ?? "FleetMesh-invitation"
        ) { result in
            switch result {
            case .success:
                exported = true
                errorMessage = nil
            case .failure(let error):
                errorMessage = error.localizedDescription
            }
            document = nil
        }
    }

    private func prepareExport() {
        do {
            document = FleetEnrollmentInvitationDocument(
                invitation: try store.makeEnrollmentInvitation()
            )
            errorMessage = nil
            exported = false
            isExporting = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct FleetEnrollmentWizardView: View {
    @Bindable var store: FleetStore
    @Binding var isPresented: Bool
    let initialInvitationURL: URL?
    let onInvitationConsumed: () -> Void
    @State private var invitation: FleetEnrollmentInvitation?
    @State private var profile = FleetEnrollmentInvitation.defaultReporterProfileHint
    @State private var machineName = ""
    @State private var isImporting = false
    @State private var confirmMove = false
    @State private var importError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if connectedPending {
                successContent
            } else {
                enrollmentHeader(
                    title: invitation == nil ? "Join an existing fleet" : "Review connection",
                    subtitle: invitation == nil
                        ? "Import the credential-free invitation created by your FleetMesh controller."
                        : "Confirm this Mac's local profile and name, then publish Pending evidence.",
                    symbol: invitation == nil ? "link.badge.plus" : "checkmark.shield"
                )

                if let error = importError ?? store.lastError {
                    enrollmentNotice(error, color: DSTheme.red, symbol: "exclamationmark.triangle.fill")
                }

                if let invitation {
                    reviewContent(invitation)
                } else {
                    importContent
                }
            }
        }
        .padding(26)
        .frame(width: 590)
        .foregroundStyle(DSTheme.ink)
        .interactiveDismissDisabled(store.isBusy)
        .fileImporter(
            isPresented: $isImporting,
            allowedContentTypes: [.fleetMeshInvitation, .json],
            allowsMultipleSelection: false
        ) { result in
            importInvitation(result)
        }
        .confirmationDialog(
            moveConfirmationTitle,
            isPresented: $confirmMove,
            titleVisibility: .visible
        ) {
            Button("Move this Mac") {
                guard let invitation else { return }
                Task {
                    await store.moveToEnrollmentInvitation(
                        invitation,
                        profile: profile,
                        displayName: machineName
                    )
                }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text(moveConfirmationDetail)
        }
        .onAppear {
            if machineName.isEmpty {
                machineName = store.localState?.displayName
                    ?? store.localSnapshot?.name
                    ?? Host.current().localizedName
                    ?? "New Mac"
            }
            if let initialInvitationURL, invitation == nil {
                loadInvitation(from: initialInvitationURL)
                onInvitationConsumed()
            }
        }
        .onChange(of: initialInvitationURL) { _, newURL in
            if let newURL {
                loadInvitation(from: newURL)
                onInvitationConsumed()
            }
        }
    }

    private var importContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                Label("The invitation configures only non-secret fleet selectors", systemImage: "doc.badge.gearshape")
                Label("AWS access stays in a temporary local role session", systemImage: "key.horizontal")
                Label("This Mac cannot enroll itself or replace the baseline", systemImage: "hand.raised.fill")
            }
            .font(.subheadline)
            .foregroundStyle(DSTheme.inkSoft)

            Button {
                isImporting = true
            } label: {
                Label("Choose FleetMesh invitation…", systemImage: "doc.badge.plus")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            HStack {
                Button("Not now", role: .cancel) { isPresented = false }
                Spacer()
                Text("No fleet state changes until Connect")
                    .font(.caption)
                    .foregroundStyle(DSTheme.inkMuted)
            }
        }
    }

    private func reviewContent(_ invitation: FleetEnrollmentInvitation) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 9) {
                enrollmentDetailRow(label: "Region", value: invitation.region)
                enrollmentDetailRow(label: "Table", value: invitation.table)
                enrollmentDetailRow(label: "Fleet", value: invitation.fleetID)
                enrollmentDetailRow(label: "Approval role", value: invitation.suggestedRole.label)
            }
            .padding(14)
            .background(DSTheme.canvas)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            switch store.enrollmentTransition(for: invitation) {
            case .join:
                EmptyView()
            case .move(let currentFleetID, let destinationFleetID):
                enrollmentNotice(
                    "This Mac currently belongs to fleet \(currentFleetID). FleetMesh will verify \(destinationFleetID), remove this Mac from the old fleet, then publish it as Pending to the new fleet.",
                    color: DSTheme.orange,
                    symbol: "arrow.triangle.swap"
                )
            case .alreadyConnected:
                enrollmentNotice(
                    "This invitation points to the fleet this Mac already uses. Nothing needs to move.",
                    color: DSTheme.blue,
                    symbol: "checkmark.circle.fill"
                )
            }

            Form {
                TextField("Reporter profile", text: $profile)
                    .textContentType(.username)
                TextField("Name for this Mac", text: $machineName)
            }
            .formStyle(.grouped)

            Text("The profile must already resolve temporary least-privilege credentials on this Mac. FleetMesh never writes, copies, or exports AWS credentials.")
                .font(.caption)
                .foregroundStyle(DSTheme.inkMuted)

            HStack {
                Button("Choose another…") {
                    self.invitation = nil
                    importError = nil
                }
                .disabled(store.isBusy)
                Button("Cancel", role: .cancel) { isPresented = false }
                    .disabled(store.isBusy)
                Spacer()
                if store.isBusy {
                    ProgressView().controlSize(.small)
                }
                Button {
                    switch store.enrollmentTransition(for: invitation) {
                    case .join:
                        Task {
                            await store.applyEnrollmentInvitation(
                                invitation,
                                profile: profile,
                                displayName: machineName
                            )
                        }
                    case .move:
                        confirmMove = true
                    case .alreadyConnected:
                        break
                    }
                } label: {
                    Label(primaryActionLabel(for: invitation), systemImage: primaryActionSymbol(for: invitation))
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    store.isBusy
                        || store.enrollmentTransition(for: invitation) == .alreadyConnected
                        || profile.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || machineName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )
            }
        }
    }

    private func primaryActionLabel(for invitation: FleetEnrollmentInvitation) -> String {
        switch store.enrollmentTransition(for: invitation) {
        case .join: "Connect this Mac"
        case .move: "Move this Mac"
        case .alreadyConnected: "Already connected"
        }
    }

    private func primaryActionSymbol(for invitation: FleetEnrollmentInvitation) -> String {
        switch store.enrollmentTransition(for: invitation) {
        case .join: "link.badge.plus"
        case .move: "arrow.triangle.swap"
        case .alreadyConnected: "checkmark.circle.fill"
        }
    }

    private var moveConfirmationTitle: String {
        guard let invitation,
              case .move(_, let destinationFleetID) = store.enrollmentTransition(
                for: invitation
              ) else { return "Move this Mac to a new fleet?" }
        return "Move this Mac to fleet \(destinationFleetID)?"
    }

    private var moveConfirmationDetail: String {
        guard let invitation,
              case .move(let currentFleetID, let destinationFleetID) = store.enrollmentTransition(
                for: invitation
              ) else { return "FleetMesh will not change anything without a valid destination." }
        return "FleetMesh will first verify fleet \(destinationFleetID) without changing local authority. It will then mark this Mac Removed from fleet \(currentFleetID), switch authority, and publish Pending evidence. If destination verification or old-fleet departure fails, this Mac stays in its current fleet."
    }

    private var successContent: some View {
        VStack(alignment: .leading, spacing: 20) {
            enrollmentHeader(
                title: "Connected and Pending",
                subtitle: "This Mac published fresh redacted evidence without changing fleet policy.",
                symbol: "checkmark.circle.fill"
            )
            enrollmentNotice(
                "On the existing controller Mac, open Devices, select this Pending Mac, choose Workstation, and approve Add to fleet.",
                color: DSTheme.green,
                symbol: "person.badge.clock.fill"
            )
            VStack(alignment: .leading, spacing: 7) {
                Label("Unique machine identity preserved locally", systemImage: "checkmark.circle")
                Label("Destination DynamoDB authority verified", systemImage: "checkmark.circle")
                Label("Destination membership remains Pending", systemImage: "checkmark.circle")
            }
            .font(.subheadline)
            .foregroundStyle(DSTheme.inkSoft)
            HStack {
                Spacer()
                Button("Done") { isPresented = false }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    private var connectedPending: Bool {
        store.manifest != nil
            && store.localState?.effectiveStorageBackend == .dynamodb
            && store.localDevice?.status == .pending
    }

    private func importInvitation(_ result: Result<[URL], Error>) {
        do {
            guard let url = try result.get().first else {
                throw FleetEnrollmentInvitationError.unreadableFile
            }
            loadInvitation(from: url)
        } catch {
            invitation = nil
            importError = error.localizedDescription
        }
    }

    private func loadInvitation(from url: URL) {
        do {
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            let decoded = try FleetEnrollmentInvitation.decode(Data(contentsOf: url))
            invitation = decoded
            profile = decoded.reporterProfileHint
            importError = nil
        } catch {
            invitation = nil
            importError = error.localizedDescription
        }
    }
}

private func enrollmentHeader(title: String, subtitle: String, symbol: String) -> some View {
    HStack(alignment: .top, spacing: 14) {
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(DSTheme.auroraFieldGradient)
            Image(systemName: symbol)
                .font(.system(size: 23, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(width: 54, height: 54)
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.title2.bold())
            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(DSTheme.inkSoft)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private func enrollmentDetailRow(label: String, value: String) -> some View {
    HStack {
        Text(label)
            .font(.caption.weight(.semibold))
            .foregroundStyle(DSTheme.inkMuted)
        Spacer()
        Text(value)
            .font(.system(size: 12, design: .monospaced))
            .textSelection(.enabled)
    }
}

private func enrollmentNotice(_ message: String, color: Color, symbol: String) -> some View {
    HStack(alignment: .top, spacing: 10) {
        Image(systemName: symbol).foregroundStyle(color)
        Text(message)
            .font(.subheadline)
            .foregroundStyle(DSTheme.inkSoft)
            .fixedSize(horizontal: false, vertical: true)
        Spacer()
    }
    .padding(12)
    .background(color.opacity(0.08))
    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
}
