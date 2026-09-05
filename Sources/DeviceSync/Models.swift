import Foundation

enum ComponentLifecycle {
    /// Component IDs that older FleetMesh writers may still publish. They are
    /// intentionally ignored rather than shown as optional software forever.
    static let retiredIDs: Set<String> = [
        "meshclaw-themes",
    ]

    static func isActive(_ id: String) -> Bool {
        !retiredIDs.contains(id)
    }

    /// Persisted reports and baselines may carry a historical display name.
    /// Stable IDs remain authoritative; current UI uses the canonical brand.
    static func displayName(for id: String, fallback: String) -> String {
        switch id {
        case FleetMeshIdentity.componentID:
            FleetMeshIdentity.productName
        default:
            fallback
        }
    }
}

enum ComponentKind: String, Codable, CaseIterable, Sendable {
    case application
    case commandLineTool
    case service
    case configuration
    case theme

    var label: String {
        switch self {
        case .application: "App"
        case .commandLineTool: "CLI"
        case .service: "Service"
        case .configuration: "Config"
        case .theme: "Theme"
        }
    }
}

enum ObservationStatus: String, Codable, Sendable {
    case installed
    case missing
    case unknown
}

struct ComponentObservation: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let kind: ComponentKind
    let status: ObservationStatus
    let installedVersion: String?
    let build: String?
    let installedRevision: String?
    let sourceRevision: String?
    let sourceBranch: String?
    let sourceDirty: Bool?
    let configurationFingerprint: String?
    let items: [String]?
    let isRunning: Bool?
    let evidence: String

    init(
        id: String,
        name: String,
        kind: ComponentKind,
        status: ObservationStatus,
        installedVersion: String? = nil,
        build: String? = nil,
        installedRevision: String? = nil,
        sourceRevision: String? = nil,
        sourceBranch: String? = nil,
        sourceDirty: Bool? = nil,
        configurationFingerprint: String? = nil,
        items: [String]? = nil,
        isRunning: Bool? = nil,
        evidence: String
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.status = status
        self.installedVersion = installedVersion
        self.build = build
        self.installedRevision = installedRevision
        self.sourceRevision = sourceRevision
        self.sourceBranch = sourceBranch
        self.sourceDirty = sourceDirty
        self.configurationFingerprint = configurationFingerprint
        self.items = items
        self.isRunning = isRunning
        self.evidence = evidence
    }

    var primaryVersion: String {
        installedVersion ?? installedRevision ?? sourceRevision ?? "Not observed"
    }
}

struct MachineSnapshot: Codable, Identifiable, Hashable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let machineID: String
    let name: String
    let hostName: String
    let modelIdentifier: String
    let architecture: String
    let osVersion: String
    let osBuild: String
    let capturedAt: Date
    let deviceSyncVersion: String
    let components: [ComponentObservation]

    var id: String { machineID }

    init(
        machineID: String,
        name: String,
        hostName: String,
        modelIdentifier: String,
        architecture: String,
        osVersion: String,
        osBuild: String,
        capturedAt: Date = Date(),
        deviceSyncVersion: String = DeviceSyncVersion.current,
        components: [ComponentObservation]
    ) {
        self.schemaVersion = Self.currentSchemaVersion
        self.machineID = machineID
        self.name = name
        self.hostName = hostName
        self.modelIdentifier = modelIdentifier
        self.architecture = architecture
        self.osVersion = osVersion
        self.osBuild = osBuild
        self.capturedAt = capturedAt
        self.deviceSyncVersion = deviceSyncVersion
        self.components = components
    }

    func component(_ id: String) -> ComponentObservation? {
        components.first { $0.id == id }
    }
}

struct ManifestTarget: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let kind: ComponentKind
    let required: Bool
    let expectedVersion: String?
    let expectedInstalledRevision: String?
    let expectedSourceRevision: String?
    let expectedConfigurationFingerprint: String?

    init(observation: ComponentObservation, required: Bool = true) {
        id = observation.id
        name = observation.name
        kind = observation.kind
        self.required = required
        expectedVersion = observation.installedVersion
        expectedInstalledRevision = observation.installedRevision
        expectedSourceRevision = observation.sourceRevision
        expectedConfigurationFingerprint = observation.configurationFingerprint
    }
}

struct FleetScopeItem: Identifiable, Hashable, Sendable {
    let observation: ComponentObservation?
    let target: ManifestTarget?

    var id: String { observation?.id ?? target?.id ?? "unknown" }

    var name: String {
        ComponentLifecycle.displayName(
            for: id,
            fallback: observation?.name ?? target?.name ?? id
        )
    }

    var kind: ComponentKind {
        observation?.kind ?? target?.kind ?? .configuration
    }

    var isManaged: Bool { target != nil }

    var canAdd: Bool {
        observation.map(FleetManifest.isEligibleForBaseline) == true
    }

    var observedSummary: String {
        guard let observation else { return "Not reported by this Mac" }
        switch observation.status {
        case .installed:
            if observation.kind == .theme {
                let count = observation.items?.count ?? 0
                return "\(count) file\(count == 1 ? "" : "s") observed"
            }
            if let version = observation.installedVersion
                ?? observation.installedRevision
                ?? observation.sourceRevision {
                return version
            }
            if let fingerprint = observation.configurationFingerprint {
                return "Fingerprint \(fingerprint.prefix(12))"
            }
            return "Installed"
        case .missing:
            return "Not installed on this Mac"
        case .unknown:
            return "Current state is unknown"
        }
    }
}

struct FleetManifest: Codable, Hashable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let revision: String
    let updatedAt: Date
    let updatedByMachineID: String
    let targets: [ManifestTarget]

    var activeTargets: [ManifestTarget] {
        targets.filter { ComponentLifecycle.isActive($0.id) }
    }

    init(snapshot: MachineSnapshot, updatedAt: Date = Date()) {
        schemaVersion = Self.currentSchemaVersion
        revision = UUID().uuidString.lowercased()
        self.updatedAt = updatedAt
        updatedByMachineID = snapshot.machineID
        targets = snapshot.components
            .filter(Self.isEligibleForBaseline)
            .map { ManifestTarget(observation: $0) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private init(
        schemaVersion: Int,
        revision: String,
        updatedAt: Date,
        updatedByMachineID: String,
        targets: [ManifestTarget]
    ) {
        self.schemaVersion = schemaVersion
        self.revision = revision
        self.updatedAt = updatedAt
        self.updatedByMachineID = updatedByMachineID
        self.targets = targets
    }

    static func isEligibleForBaseline(_ observation: ComponentObservation) -> Bool {
        ComponentLifecycle.isActive(observation.id)
            && (observation.status == .installed
                || (observation.kind == .theme && !(observation.items ?? []).isEmpty))
    }

    func settingManaged(
        componentID: String,
        managed: Bool,
        observation: ComponentObservation?,
        updatedByMachineID: String,
        updatedAt: Date = Date()
    ) throws -> FleetManifest {
        guard ComponentLifecycle.isActive(componentID) else {
            throw FleetManifestError.retiredComponent(componentID)
        }

        let isCurrentlyManaged = targets.contains { $0.id == componentID }
        guard isCurrentlyManaged != managed else {
            throw managed
                ? FleetManifestError.alreadyManaged(componentID)
                : FleetManifestError.alreadyUnmanaged(componentID)
        }

        var updatedTargets = targets.filter { $0.id != componentID }
        if managed {
            guard let observation, observation.id == componentID else {
                throw FleetManifestError.missingObservation(componentID)
            }
            guard Self.isEligibleForBaseline(observation) else {
                throw FleetManifestError.ineligibleObservation(observation.name)
            }
            updatedTargets.append(ManifestTarget(observation: observation))
        }

        return FleetManifest(
            schemaVersion: schemaVersion,
            revision: UUID().uuidString.lowercased(),
            updatedAt: updatedAt,
            updatedByMachineID: updatedByMachineID,
            targets: updatedTargets.sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
        )
    }

    func target(_ id: String) -> ManifestTarget? {
        guard ComponentLifecycle.isActive(id) else { return nil }
        return targets.first { $0.id == id }
    }
}

enum FleetManifestError: LocalizedError {
    case missingObservation(String)
    case ineligibleObservation(String)
    case retiredComponent(String)
    case alreadyManaged(String)
    case alreadyUnmanaged(String)

    var errorDescription: String? {
        switch self {
        case .missingObservation(let componentID):
            "This Mac has not reported enough evidence to add \(componentID) to fleet scope."
        case .ineligibleObservation(let name):
            "\(name) must be installed or configured on this Mac before it can define fleet scope."
        case .retiredComponent(let componentID):
            "\(componentID) is retired and cannot be added to the active fleet baseline."
        case .alreadyManaged(let componentID):
            "\(componentID) is already managed by the fleet baseline."
        case .alreadyUnmanaged(let componentID):
            "\(componentID) is already outside fleet scope."
        }
    }
}

struct FleetIssue: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let detail: String

    init(id: String = UUID().uuidString, title: String, detail: String) {
        self.id = id
        self.title = title
        self.detail = detail
    }
}

enum DriftState: String, Codable, Sendable {
    case aligned
    case different
    case missing
    case unknown
    case localChanges
    case notManaged

    var label: String {
        switch self {
        case .aligned: "Aligned"
        case .different: "Drift"
        case .missing: "Missing"
        case .unknown: "Unknown"
        case .localChanges: "Local work"
        case .notManaged: "Not in baseline"
        }
    }
}

enum DriftSeverity: Int, Codable, Comparable, Sendable {
    case information = 0
    case attention = 1
    case critical = 2

    static func < (lhs: DriftSeverity, rhs: DriftSeverity) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

struct ComponentDrift: Identifiable, Hashable, Sendable {
    let componentID: String
    let name: String
    let kind: ComponentKind
    let state: DriftState
    let severity: DriftSeverity
    let summary: String
    let expected: String?
    let observed: String?

    var id: String { "\(componentID)-\(state.rawValue)-\(summary)" }
}

enum FleetVerdict: String, Sendable {
    case aligned
    case attention
    case critical
    case unknown

    var label: String {
        switch self {
        case .aligned: "Fleet aligned"
        case .attention: "Attention needed"
        case .critical: "Action required"
        case .unknown: "Evidence incomplete"
        }
    }
}

struct MachineAssessment: Identifiable, Hashable, Sendable {
    let snapshot: MachineSnapshot
    let drifts: [ComponentDrift]
    let isStale: Bool

    var id: String { snapshot.machineID }

    var managedDrifts: [ComponentDrift] {
        drifts.filter { $0.state != .notManaged }
    }

    var verdict: FleetVerdict {
        if drifts.contains(where: { $0.severity == .critical }) { return .critical }
        if isStale || drifts.contains(where: { $0.severity == .attention }) { return .attention }
        if drifts.contains(where: { $0.state == .unknown }) { return .unknown }
        return .aligned
    }

    var attentionCount: Int {
        managedDrifts.filter { $0.state != .aligned }.count
            + (isStale ? 1 : 0)
    }
}

enum FleetDateFormatting {
    static func relative(_ date: Date, now: Date = Date()) -> String {
        let interval = date.timeIntervalSince(now)
        guard abs(interval) >= 60 else { return "just now" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: now)
    }
}

enum BootstrapPhase: String, CaseIterable, Sendable {
    case foundation = "Foundation"
    case applications = "Applications"
    case configuration = "Configuration"
    case validation = "Validation"
}

struct BootstrapStep: Identifiable, Hashable, Sendable {
    let id: String
    let phase: BootstrapPhase
    let componentID: String?
    let title: String
    let detail: String
    let command: String?
    let requiresReview: Bool

    init(
        id: String,
        phase: BootstrapPhase,
        componentID: String? = nil,
        title: String,
        detail: String,
        command: String? = nil,
        requiresReview: Bool = true
    ) {
        self.id = id
        self.phase = phase
        self.componentID = componentID
        self.title = title
        self.detail = detail
        self.command = command
        self.requiresReview = requiresReview
    }
}
