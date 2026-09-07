import SwiftUI

struct FleetMeshUpdatesView: View {
    @Bindable var updater: FleetMeshUpdater
    @State private var entries: [FleetMeshReleaseNotes.Entry] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                updateCard
                whatsNew
            }
            .padding(28)
        }
        .accessibilityIdentifier("fleetmesh.updates")
        .onAppear {
            entries = FleetMeshReleaseNotes.loadBundled()
            if case .idle = updater.state {
                Task { await updater.check() }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("UPDATES")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .tracking(1.5)
                .foregroundStyle(DSTheme.cyan)
            Text("Updates & What's New")
                .font(.system(size: 30, weight: .bold, design: .rounded))
            Text("Check the clean attached source for updates and review the release notes bundled with this build.")
                .font(.system(size: 14))
                .foregroundStyle(DSTheme.inkSoft)
        }
    }

    private var updateCard: some View {
        HStack(alignment: .top, spacing: 18) {
            ZStack {
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .fill(DSTheme.auroraFieldGradient.opacity(0.22))
                Image(systemName: updateSymbol)
                    .font(.system(size: 27, weight: .semibold))
                    .foregroundStyle(updateColor)
            }
            .frame(width: 68, height: 64)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text("FleetMesh")
                        .font(.title3.bold())
                    Text(FleetMeshBuildIdentity.version)
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(DSTheme.canvas)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                Text(updateStatus)
                    .font(.subheadline)
                    .foregroundStyle(DSTheme.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
                Text(FleetMeshBuildIdentity.detail)
                    .font(.caption2.monospaced())
                    .foregroundStyle(DSTheme.inkMuted)
                    .textSelection(.enabled)
            }

            Spacer(minLength: 18)
            updateAction
        }
        .padding(18)
        .deviceCard()
    }

    @ViewBuilder
    private var updateAction: some View {
        switch updater.state {
        case .checking, .updating:
            ProgressView().controlSize(.small)
        case .available:
            Button {
                Task { await updater.installAvailableUpdate() }
            } label: {
                Label("Update now", systemImage: "arrow.down.circle.fill")
            }
            .buttonStyle(.borderedProminent)
        default:
            Button {
                Task { await updater.check() }
            } label: {
                Label("Check again", systemImage: "arrow.triangle.2.circlepath")
            }
            .buttonStyle(.bordered)
        }
    }

    private var updateStatus: String {
        switch updater.state {
        case .idle:
            "Not checked yet."
        case .checking:
            "Checking clean origin/main ancestry…"
        case .upToDate:
            "You are up to date."
        case .available(let version):
            "FleetMesh \(version) is available from origin/main."
        case .blocked(let detail):
            detail
        case .updating:
            "Fast-forwarding the clean source and launching the product installer…"
        case .failed(let detail):
            detail
        }
    }

    private var updateSymbol: String {
        switch updater.state {
        case .available: "arrow.down.circle.fill"
        case .upToDate: "checkmark.circle.fill"
        case .failed, .blocked: "exclamationmark.triangle.fill"
        case .checking, .updating: "arrow.triangle.2.circlepath"
        case .idle: "sparkles"
        }
    }

    private var updateColor: Color {
        switch updater.state {
        case .available: DSTheme.cyan
        case .upToDate: DSTheme.green
        case .failed, .blocked: DSTheme.orange
        case .checking, .updating, .idle: DSTheme.blue
        }
    }

    private var whatsNew: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("WHAT'S NEW")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .tracking(1.3)
                        .foregroundStyle(DSTheme.cyan)
                    Text("Release notes")
                        .font(.title2.bold())
                }
                Spacer()
                Text("\(entries.count) release\(entries.count == 1 ? "" : "s")")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(DSTheme.inkMuted)
            }

            if entries.isEmpty {
                ContentUnavailableView(
                    "Release notes unavailable",
                    systemImage: "doc.text.magnifyingglass",
                    description: Text("This build does not contain a readable CHANGELOG.md.")
                )
                .frame(maxWidth: .infinity, minHeight: 180)
            } else {
                VStack(spacing: 12) {
                    ForEach(entries) { entry in
                        releaseCard(entry)
                    }
                }
            }
        }
    }

    private func releaseCard(_ entry: FleetMeshReleaseNotes.Entry) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(alignment: .firstTextBaseline) {
                Text("FleetMesh \(entry.version)")
                    .font(.headline)
                if entry.version == FleetMeshBuildIdentity.version {
                    Text("THIS BUILD")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(DSTheme.green)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(DSTheme.green.opacity(0.1))
                        .clipShape(Capsule())
                }
                Spacer()
                if !entry.date.isEmpty {
                    Text(entry.date)
                        .font(.caption)
                        .foregroundStyle(DSTheme.inkMuted)
                }
            }
            if !entry.title.isEmpty {
                Text(entry.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(DSTheme.inkSoft)
            }
            ForEach(Array(entry.changes.enumerated()), id: \.offset) { _, change in
                HStack(alignment: .top, spacing: 8) {
                    Circle()
                        .fill(DSTheme.cyan)
                        .frame(width: 5, height: 5)
                        .padding(.top, 6)
                    Text(change)
                        .font(.subheadline)
                        .foregroundStyle(DSTheme.inkSoft)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(16)
        .deviceCard()
    }
}
