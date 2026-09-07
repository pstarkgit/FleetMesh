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

enum DevicePlatform: String, Codable, CaseIterable, Sendable {
    case macOS = "macos"
    case linux
    case unknown

    var label: String {
        switch self {
        case .macOS: "Mac"
        case .linux: "Linux"
        case .unknown: "Unknown platform"
        }
    }
}

enum DeviceRole: String, Codable, CaseIterable, Sendable {
    case workstation
    case server
    case cloudDesktop = "cloud-desktop"

    var label: String {
        switch self {
        case .workstation: "Workstation"
        case .server: "Server"
        case .cloudDesktop: "Cloud desktop"
        }
    }

    static func suggested(for platform: DevicePlatform) -> DeviceRole {
        platform == .linux ? .server : .workstation
    }
}

enum DeviceCapability: String, Codable, CaseIterable, Hashable, Sendable {
    case graphicalSession = "graphical-session"
    case macOSApplications = "macos-applications"
    case menuBar = "menu-bar"
    case launchd
    case systemd
    case shell
    case configurationFiles = "configuration-files"

    var label: String {
        switch self {
        case .graphicalSession: "GUI"
        case .macOSApplications: "Mac apps"
        case .menuBar: "Menu bar"
        case .launchd: "launchd"
        case .systemd: "systemd"
        case .shell: "Shell"
        case .configurationFiles: "Config files"
        }
    }

    static func defaults(for platform: DevicePlatform) -> [DeviceCapability] {
        switch platform {
        case .macOS:
            [.graphicalSession, .macOSApplications, .menuBar, .launchd, .shell, .configurationFiles]
        case .linux:
            [.systemd, .shell, .configurationFiles]
        case .unknown:
            []
        }
    }
}

enum ObservationStatus: String, Codable, Sendable {
    case installed
    case missing
    case unknown
}

enum ProductVersionAuthority: String, Codable, Hashable, Sendable {
    case sparkleAppcast

    var label: String {
        switch self {
        case .sparkleAppcast: "Product update feed"
        }
    }
}

enum ProductVersionCheckStatus: String, Codable, Hashable, Sendable {
    case verified
    case unavailable
}

struct ProductVersionCheck: Codable, Hashable, Sendable {
    let status: ProductVersionCheckStatus
    let authority: ProductVersionAuthority
    let latestVersion: String?

    static func verified(
        version: String,
        authority: ProductVersionAuthority
    ) -> ProductVersionCheck {
        ProductVersionCheck(
            status: .verified,
            authority: authority,
            latestVersion: version
        )
    }

    static func unavailable(
        authority: ProductVersionAuthority
    ) -> ProductVersionCheck {
        ProductVersionCheck(
            status: .unavailable,
            authority: authority,
            latestVersion: nil
        )
    }
}

enum ApplicationInstallationLocation: String, Codable, Hashable, Sendable {
    case systemApplications
    case userApplications
    case runningBundle

    var label: String {
        switch self {
        case .systemApplications: "System Applications"
        case .userApplications: "User Applications"
        case .runningBundle: "Running bundle outside Applications folders"
        }
    }

    func displayPath(appName: String) -> String {
        switch self {
        case .systemApplications: "/Applications/\(appName).app"
        case .userApplications: "~/Applications/\(appName).app"
        case .runningBundle: label
        }
    }
}

struct ComponentObservation: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let kind: ComponentKind
    let status: ObservationStatus
    let installedVersion: String?
    let build: String?
    let installedRevision: String?
    /// Product-owned latest-version evidence. Ordinary fleet posture may use
    /// this value, but never a developer checkout, to advance a software target.
    let productVersionCheck: ProductVersionCheck?
    /// Privacy-safe location class for an installed application. Raw home paths
    /// never enter shared fleet state.
    let installationLocation: ApplicationInstallationLocation?
    /// Developer-checkout evidence is legacy snapshot compatibility and
    /// explicit Doctor-preflight context. Drift evaluation ignores it for
    /// software, and routine scans do not collect or publish it.
    let sourceVersion: String?
    let sourceRevision: String?
    let sourceBranch: String?
    let sourceDirty: Bool?
    let sourceTree: String?
    let installedTree: String?
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
        productVersionCheck: ProductVersionCheck? = nil,
        installationLocation: ApplicationInstallationLocation? = nil,
        sourceVersion: String? = nil,
        sourceRevision: String? = nil,
        sourceBranch: String? = nil,
        sourceDirty: Bool? = nil,
        sourceTree: String? = nil,
        installedTree: String? = nil,
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
        self.productVersionCheck = productVersionCheck
        self.installationLocation = installationLocation
        self.sourceVersion = sourceVersion
        self.sourceRevision = sourceRevision
        self.sourceBranch = sourceBranch
        self.sourceDirty = sourceDirty
        self.sourceTree = sourceTree
        self.installedTree = installedTree
        self.configurationFingerprint = configurationFingerprint
        self.items = items
        self.isRunning = isRunning
        self.evidence = evidence
    }

    var primaryVersion: String {
        if kind == .configuration || kind == .theme {
            return configurationFingerprint ?? sourceRevision ?? "Not observed"
        }
        return installedVersion ?? installedRevision ?? "Not observed"
    }

    func removingSoftwareCheckoutEvidence() -> ComponentObservation {
        if kind == .configuration || kind == .theme {
            return ComponentObservation(
                id: id,
                name: name,
                kind: kind,
                status: status,
                installedVersion: installedVersion,
                build: build,
                installedRevision: installedRevision,
                productVersionCheck: productVersionCheck,
                installationLocation: installationLocation,
                sourceVersion: sourceVersion,
                sourceRevision: sourceRevision,
                sourceTree: sourceTree,
                installedTree: installedTree,
                configurationFingerprint: configurationFingerprint,
                items: items,
                isRunning: isRunning,
                evidence: evidence
            )
        }
        return ComponentObservation(
            id: id,
            name: name,
            kind: kind,
            status: status,
            installedVersion: installedVersion,
            build: build,
            installedRevision: installedRevision,
            productVersionCheck: productVersionCheck,
            installationLocation: installationLocation,
            configurationFingerprint: configurationFingerprint,
            items: items,
            isRunning: isRunning,
            evidence: evidence
        )
    }

    func addingSoftwareCheckoutEvidence(
        version: String?,
        revision: String,
        branch: String?,
        dirty: Bool,
        sourceTree: String,
        installedTree: String?
    ) -> ComponentObservation {
        ComponentObservation(
            id: id,
            name: name,
            kind: kind,
            status: status,
            installedVersion: installedVersion,
            build: build,
            installedRevision: installedRevision,
            productVersionCheck: productVersionCheck,
            installationLocation: installationLocation,
            sourceVersion: version,
            sourceRevision: revision,
            sourceBranch: branch,
            sourceDirty: dirty,
            sourceTree: sourceTree,
            installedTree: installedTree,
            configurationFingerprint: configurationFingerprint,
            items: items,
            isRunning: isRunning,
            evidence: evidence
        )
    }
}

struct MachineSnapshot: Codable, Identifiable, Hashable, Sendable {
    // Platform and capability fields are additive. Keeping the snapshot wire
    // version at v1 lets older FleetMesh readers safely ignore those keys.
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let machineID: String
    let name: String
    let hostName: String
    let modelIdentifier: String
    let architecture: String
    let osVersion: String
    let osBuild: String
    let platform: DevicePlatform?
    let capabilities: [DeviceCapability]?
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
        platform: DevicePlatform = .macOS,
        capabilities: [DeviceCapability]? = nil,
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
        self.platform = platform
        self.capabilities = (capabilities ?? DeviceCapability.defaults(for: platform))
            .sorted { $0.rawValue < $1.rawValue }
        self.capturedAt = capturedAt
        self.deviceSyncVersion = deviceSyncVersion
        self.components = components
    }

    func component(_ id: String) -> ComponentObservation? {
        components.first { $0.id == id }
    }

    func removingSoftwareCheckoutEvidence() -> MachineSnapshot {
        MachineSnapshot(
            machineID: machineID,
            name: name,
            hostName: hostName,
            modelIdentifier: modelIdentifier,
            architecture: architecture,
            osVersion: osVersion,
            osBuild: osBuild,
            platform: effectivePlatform,
            capabilities: Array(effectiveCapabilities),
            capturedAt: capturedAt,
            deviceSyncVersion: deviceSyncVersion,
            components: components.map { $0.removingSoftwareCheckoutEvidence() }
        )
    }

    func replacingComponent(_ replacement: ComponentObservation) -> MachineSnapshot {
        MachineSnapshot(
            machineID: machineID,
            name: name,
            hostName: hostName,
            modelIdentifier: modelIdentifier,
            architecture: architecture,
            osVersion: osVersion,
            osBuild: osBuild,
            platform: effectivePlatform,
            capabilities: Array(effectiveCapabilities),
            capturedAt: capturedAt,
            deviceSyncVersion: deviceSyncVersion,
            components: components.map { $0.id == replacement.id ? replacement : $0 }
        )
    }

    var effectivePlatform: DevicePlatform {
        // Schema-v1 reports were emitted only by the native Mac app.
        platform ?? .macOS
    }

    var effectiveCapabilities: Set<DeviceCapability> {
        Set(capabilities ?? DeviceCapability.defaults(for: effectivePlatform))
    }
}

struct ManifestTarget: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let kind: ComponentKind
    let required: Bool
    let defaultManaged: Bool?
    let expectedVersion: String?
    let expectedInstalledRevision: String?
    let expectedSourceRevision: String?
    let expectedConfigurationFingerprint: String?
    let supportedPlatforms: [DevicePlatform]?
    let requiredCapabilities: [DeviceCapability]?

    init(
        observation: ComponentObservation,
        required: Bool = true,
        defaultManaged: Bool = true,
        platform: DevicePlatform = .macOS
    ) {
        id = observation.id
        name = observation.name
        kind = observation.kind
        self.required = required
        self.defaultManaged = defaultManaged
        expectedVersion = observation.installedVersion
        let exactConfiguration = observation.kind == .configuration || observation.kind == .theme
        expectedInstalledRevision = exactConfiguration ? observation.installedRevision : nil
        expectedSourceRevision = exactConfiguration ? observation.sourceRevision : nil
        expectedConfigurationFingerprint = observation.configurationFingerprint
        supportedPlatforms = Self.supportedPlatforms(
            for: observation.id,
            observedOn: platform
        )
        requiredCapabilities = []
    }

    var isManagedByDefault: Bool { defaultManaged ?? true }

    func applicability(to snapshot: MachineSnapshot) -> ComponentApplicability {
        applicability(
            platform: snapshot.effectivePlatform,
            capabilities: snapshot.effectiveCapabilities
        )
    }

    func applicability(
        platform: DevicePlatform,
        capabilities: Set<DeviceCapability>
    ) -> ComponentApplicability {
        // Product support is code-owned metadata. It corrects older manifests
        // that persisted a Mac-only value before a managed product gained a
        // verified Linux installation path. Per-device Excluded remains the
        // explicit policy control for a supported product that is not desired.
        let platforms = Self.knownSupportedPlatforms(for: id)
            ?? supportedPlatforms
            ?? Self.supportedPlatforms(for: id, observedOn: .macOS)
        guard platforms.contains(platform) else {
            return ComponentApplicability(
                isApplicable: false,
                reason: "\(name) supports \(platforms.map(\.label).joined(separator: ", ")), not \(platform.label)."
            )
        }

        let required = Set(requiredCapabilities ?? []).union(Self.capabilityRequirements(
            for: id,
            kind: kind,
            platform: platform
        ))
        let missing = required.subtracting(capabilities)
            .sorted { $0.rawValue < $1.rawValue }
        guard missing.isEmpty else {
            return ComponentApplicability(
                isApplicable: false,
                reason: "This device does not report: \(missing.map(\.label).joined(separator: ", "))."
            )
        }
        return .applicable
    }

    func normalizedForCurrentSchema() -> ManifestTarget {
        ManifestTarget(
            id: id,
            name: name,
            kind: kind,
            required: required,
            defaultManaged: isManagedByDefault,
            expectedVersion: expectedVersion,
            expectedInstalledRevision: expectedInstalledRevision,
            expectedSourceRevision: expectedSourceRevision,
            expectedConfigurationFingerprint: expectedConfigurationFingerprint,
            supportedPlatforms: Self.knownSupportedPlatforms(for: id)
                ?? supportedPlatforms
                ?? Self.supportedPlatforms(for: id, observedOn: .macOS),
            requiredCapabilities: requiredCapabilities ?? []
        )
    }

    func settingDefaultManaged(_ managed: Bool) -> ManifestTarget {
        let normalized = normalizedForCurrentSchema()
        return ManifestTarget(
            id: normalized.id,
            name: normalized.name,
            kind: normalized.kind,
            required: normalized.required,
            defaultManaged: managed,
            expectedVersion: normalized.expectedVersion,
            expectedInstalledRevision: normalized.expectedInstalledRevision,
            expectedSourceRevision: normalized.expectedSourceRevision,
            expectedConfigurationFingerprint: normalized.expectedConfigurationFingerprint,
            supportedPlatforms: normalized.supportedPlatforms,
            requiredCapabilities: normalized.requiredCapabilities
        )
    }

    func replacingConfigurationFingerprint(_ fingerprint: String) throws -> ManifestTarget {
        let normalized = normalizedForCurrentSchema()
        guard kind == .configuration || kind == .theme else {
            throw FleetManifestError.softwareBaselineIsAutomatic(name)
        }
        guard !fingerprint.isEmpty else {
            throw FleetManifestError.missingObservation(id)
        }
        return ManifestTarget(
            id: normalized.id,
            name: normalized.name,
            kind: normalized.kind,
            required: normalized.required,
            defaultManaged: normalized.defaultManaged,
            expectedVersion: normalized.expectedVersion,
            expectedInstalledRevision: normalized.expectedInstalledRevision,
            expectedSourceRevision: normalized.expectedSourceRevision,
            expectedConfigurationFingerprint: fingerprint,
            supportedPlatforms: normalized.supportedPlatforms,
            requiredCapabilities: normalized.requiredCapabilities
        )
    }

    private init(
        id: String,
        name: String,
        kind: ComponentKind,
        required: Bool,
        defaultManaged: Bool?,
        expectedVersion: String?,
        expectedInstalledRevision: String?,
        expectedSourceRevision: String?,
        expectedConfigurationFingerprint: String?,
        supportedPlatforms: [DevicePlatform]?,
        requiredCapabilities: [DeviceCapability]?
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.required = required
        self.defaultManaged = defaultManaged
        self.expectedVersion = expectedVersion
        self.expectedInstalledRevision = expectedInstalledRevision
        self.expectedSourceRevision = expectedSourceRevision
        self.expectedConfigurationFingerprint = expectedConfigurationFingerprint
        self.supportedPlatforms = supportedPlatforms
        self.requiredCapabilities = requiredCapabilities
    }

    private static func capabilityRequirements(
        for componentID: String,
        kind: ComponentKind,
        platform: DevicePlatform
    ) -> [DeviceCapability] {
        if componentID == "kiro-crew", platform == .linux {
            // KiroCrew is a managed desktop app on macOS and a headless
            // toolbox-owned gateway service on Linux.
            return [.shell, .systemd]
        }
        switch kind {
        case .application:
            return platform == .macOS
                ? [.graphicalSession, .macOSApplications]
                : [.graphicalSession]
        case .commandLineTool:
            return [.shell]
        case .service:
            return platform == .macOS ? [.launchd] : [.systemd]
        case .configuration, .theme:
            return [.configurationFiles]
        }
    }

    private static func knownSupportedPlatforms(
        for componentID: String
    ) -> [DevicePlatform]? {
        switch componentID {
        case "harness-sync":
            [.macOS]
        case "ai-continuum", "codex-cli", "kiro-crew", "kiro-crew-themes":
            [.macOS, .linux]
        default:
            nil
        }
    }

    private static func supportedPlatforms(
        for componentID: String,
        observedOn platform: DevicePlatform
    ) -> [DevicePlatform] {
        knownSupportedPlatforms(for: componentID) ?? [platform]
    }
}

struct ComponentApplicability: Hashable, Sendable {
    static let applicable = ComponentApplicability(isApplicable: true, reason: "Supported on this device.")

    let isApplicable: Bool
    let reason: String
}

enum DeviceEnrollment: String, Codable, Sendable {
    case enrolled
    case excluded
}

enum DeviceEnrollmentStatus: String, Sendable {
    case pending
    case enrolled
    case excluded

    var label: String {
        switch self {
        case .pending: "Pending"
        case .enrolled: "In fleet"
        case .excluded: "Removed"
        }
    }
}

enum DeviceScopeSelection: String, Codable, CaseIterable, Sendable {
    case inherit
    case required
    case excluded

    var label: String {
        switch self {
        case .inherit: "Inherit fleet default"
        case .required: "Required on this device"
        case .excluded: "Excluded from this device"
        }
    }
}

struct DeviceComponentOverride: Codable, Identifiable, Hashable, Sendable {
    let componentID: String
    let selection: DeviceScopeSelection

    var id: String { componentID }
}

struct FleetDevicePolicy: Codable, Identifiable, Hashable, Sendable {
    let machineID: String
    let displayName: String
    let role: DeviceRole
    let enrollment: DeviceEnrollment
    let overrides: [DeviceComponentOverride]
    let platform: DevicePlatform?
    let capabilities: [DeviceCapability]?

    var id: String { machineID }

    init(
        snapshot: MachineSnapshot,
        role: DeviceRole? = nil,
        enrollment: DeviceEnrollment = .enrolled,
        overrides: [DeviceComponentOverride] = []
    ) {
        machineID = snapshot.machineID
        displayName = snapshot.name
        self.role = role ?? DeviceRole.suggested(for: snapshot.effectivePlatform)
        self.enrollment = enrollment
        self.overrides = overrides.sorted { $0.componentID < $1.componentID }
        platform = snapshot.effectivePlatform
        capabilities = snapshot.effectiveCapabilities.sorted { $0.rawValue < $1.rawValue }
    }

    init(
        machineID: String,
        displayName: String,
        role: DeviceRole,
        enrollment: DeviceEnrollment,
        overrides: [DeviceComponentOverride],
        platform: DevicePlatform?,
        capabilities: [DeviceCapability]?
    ) {
        self.machineID = machineID
        self.displayName = displayName
        self.role = role
        self.enrollment = enrollment
        self.overrides = overrides.sorted { $0.componentID < $1.componentID }
        self.platform = platform
        self.capabilities = capabilities?.sorted { $0.rawValue < $1.rawValue }
    }

    func scopeSelection(for componentID: String) -> DeviceScopeSelection {
        overrides.first { $0.componentID == componentID }?.selection ?? .inherit
    }
}

struct FleetDeviceItem: Identifiable, Hashable, Sendable {
    let machineID: String
    let snapshot: MachineSnapshot?
    let policy: FleetDevicePolicy?
    let localConnection: RemoteDeviceConnection?
    let status: DeviceEnrollmentStatus

    var id: String { machineID }
    var name: String {
        snapshot?.name ?? policy?.displayName ?? localConnection?.displayName ?? "Unknown device"
    }
    var platform: DevicePlatform {
        snapshot?.effectivePlatform ?? policy?.platform ?? (localConnection == nil ? .unknown : .linux)
    }
    var capabilities: Set<DeviceCapability> {
        snapshot?.effectiveCapabilities ?? Set(policy?.capabilities ?? [])
    }
    var role: DeviceRole {
        policy?.role ?? localConnection?.role ?? DeviceRole.suggested(for: platform)
    }
    var hasFreshEvidence: Bool { snapshot != nil }
    var isControllerManaged: Bool { localConnection != nil }
}

struct FleetScopeItem: Identifiable, Hashable, Sendable {
    let observation: ComponentObservation?
    let target: ManifestTarget?
    let scopeSelection: DeviceScopeSelection
    let isDeviceScope: Bool
    let effectiveManaged: Bool
    let applicability: ComponentApplicability
    let canRequire: Bool

    init(
        observation: ComponentObservation?,
        target: ManifestTarget?,
        scopeSelection: DeviceScopeSelection? = nil,
        isDeviceScope: Bool = false,
        effectiveManaged: Bool? = nil,
        applicability: ComponentApplicability = .applicable,
        canRequire: Bool? = nil
    ) {
        self.observation = observation
        self.target = target
        self.scopeSelection = scopeSelection
            ?? ((target?.isManagedByDefault == true) ? .required : .excluded)
        self.isDeviceScope = isDeviceScope
        self.effectiveManaged = effectiveManaged ?? (target?.isManagedByDefault == true)
        self.applicability = applicability
        self.canRequire = canRequire
            ?? (target != nil || observation.map(FleetManifest.isEligibleForBaseline) == true)
    }

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

    var isManaged: Bool { effectiveManaged }

    var canAdd: Bool {
        canRequire
    }

    var scopeLabel: String {
        if isDeviceScope && !applicability.isApplicable && scopeSelection != .excluded {
            return "Not applicable"
        }
        if isDeviceScope { return scopeSelection.label }
        return effectiveManaged ? "Managed" : "Available"
    }

    var observedSummary: String {
        guard let observation else { return "Not reported by this device" }
        switch observation.status {
        case .installed:
            if observation.kind == .theme {
                let count = observation.items?.count ?? 0
                return "\(count) file\(count == 1 ? "" : "s") observed"
            }
            if let version = observation.installedVersion
                ?? observation.installedRevision {
                return version
            }
            if let fingerprint = observation.configurationFingerprint {
                return "Fingerprint \(fingerprint.prefix(12))"
            }
            return "Installed"
        case .missing:
            return "Not installed on this device"
        case .unknown:
            return "Current state is unknown"
        }
    }
}

struct FleetManifest: Codable, Hashable, Sendable {
    static let currentSchemaVersion = 2

    let schemaVersion: Int
    let revision: String
    let updatedAt: Date
    let updatedByMachineID: String
    let targets: [ManifestTarget]
    let devices: [FleetDevicePolicy]?

    var activeTargets: [ManifestTarget] {
        targets.filter {
            ComponentLifecycle.isActive($0.id) && $0.isManagedByDefault
        }
    }

    var catalogTargets: [ManifestTarget] {
        targets.filter { ComponentLifecycle.isActive($0.id) }
    }

    var needsDevicePolicyMigration: Bool {
        schemaVersion < Self.currentSchemaVersion || devices == nil
    }

    init(snapshot: MachineSnapshot, updatedAt: Date = Date()) {
        schemaVersion = Self.currentSchemaVersion
        revision = UUID().uuidString.lowercased()
        self.updatedAt = updatedAt
        updatedByMachineID = snapshot.machineID
        targets = snapshot.components
            .filter(Self.isEligibleForBaseline)
            .map {
                ManifestTarget(
                    observation: $0,
                    defaultManaged: $0.id != "codex-voice",
                    platform: snapshot.effectivePlatform
                )
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        devices = [FleetDevicePolicy(snapshot: snapshot)]
    }

    private init(
        schemaVersion: Int,
        revision: String,
        updatedAt: Date,
        updatedByMachineID: String,
        targets: [ManifestTarget],
        devices: [FleetDevicePolicy]?
    ) {
        self.schemaVersion = schemaVersion
        self.revision = revision
        self.updatedAt = updatedAt
        self.updatedByMachineID = updatedByMachineID
        self.targets = targets
        self.devices = devices
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

        let isCurrentlyManaged = target(componentID)?.isManagedByDefault == true
        guard isCurrentlyManaged != managed else {
            throw managed
                ? FleetManifestError.alreadyManaged(componentID)
                : FleetManifestError.alreadyUnmanaged(componentID)
        }

        var updatedTargets = targets
        if let index = updatedTargets.firstIndex(where: { $0.id == componentID }) {
            updatedTargets[index] = updatedTargets[index].settingDefaultManaged(managed)
        } else if managed {
            guard let observation, observation.id == componentID else {
                throw FleetManifestError.missingObservation(componentID)
            }
            guard Self.isEligibleForBaseline(observation) else {
                throw FleetManifestError.ineligibleObservation(observation.name)
            }
            updatedTargets.append(ManifestTarget(observation: observation))
        }

        return replacing(
            targets: updatedTargets,
            devices: devices,
            updatedByMachineID: updatedByMachineID,
            updatedAt: updatedAt
        )
    }

    func settingObservedConfigurationBaseline(
        componentID: String,
        observation: ComponentObservation,
        updatedByMachineID: String,
        updatedAt: Date = Date()
    ) throws -> FleetManifest {
        guard let index = targets.firstIndex(where: { $0.id == componentID }),
              observation.id == componentID,
              let fingerprint = observation.configurationFingerprint else {
            throw FleetManifestError.missingObservation(componentID)
        }
        var updatedTargets = targets
        updatedTargets[index] = try updatedTargets[index]
            .replacingConfigurationFingerprint(fingerprint)
        guard updatedTargets[index] != targets[index] else {
            throw FleetManifestError.baselineAlreadyMatches(observation.name)
        }
        return replacing(
            targets: updatedTargets,
            devices: devices,
            updatedByMachineID: updatedByMachineID,
            updatedAt: updatedAt
        )
    }


    func enrollmentStatus(for machineID: String) -> DeviceEnrollmentStatus {
        guard let devices else {
            return machineID == updatedByMachineID ? .enrolled : .pending
        }
        guard let device = devices.first(where: { $0.machineID == machineID }) else {
            return .pending
        }
        return device.enrollment == .enrolled ? .enrolled : .excluded
    }

    func devicePolicy(_ machineID: String) -> FleetDevicePolicy? {
        devices?.first { $0.machineID == machineID }
    }

    func scopeSelection(componentID: String, machineID: String) -> DeviceScopeSelection {
        devicePolicy(machineID)?.scopeSelection(for: componentID) ?? .inherit
    }

    func scopedTargets(for snapshot: MachineSnapshot) -> [ManifestTarget] {
        guard enrollmentStatus(for: snapshot.machineID) == .enrolled else { return [] }
        return catalogTargets.filter { target in
            switch scopeSelection(componentID: target.id, machineID: snapshot.machineID) {
            case .required: true
            case .excluded: false
            case .inherit: target.isManagedByDefault
            }
        }
    }

    func migratingLegacyDevices(
        _ snapshots: [MachineSnapshot],
        updatedByMachineID: String? = nil,
        updatedAt: Date? = nil,
        preserveRevision: Bool = true
    ) -> FleetManifest {
        let migratedDevices: [FleetDevicePolicy]?
        if let devices {
            migratedDevices = devices
        } else {
            migratedDevices = snapshots
                .filter { $0.machineID == self.updatedByMachineID }
                .prefix(1)
                .map { FleetDevicePolicy(snapshot: $0) }
                .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        }
        return FleetManifest(
            schemaVersion: Self.currentSchemaVersion,
            revision: preserveRevision ? revision : UUID().uuidString.lowercased(),
            updatedAt: updatedAt ?? self.updatedAt,
            updatedByMachineID: updatedByMachineID ?? self.updatedByMachineID,
            targets: targets.map { target in
                let normalized = target.normalizedForCurrentSchema()
                guard schemaVersion < Self.currentSchemaVersion,
                      normalized.id == "codex-voice" else {
                    return normalized
                }
                return normalized.settingDefaultManaged(false)
            },
            devices: migratedDevices
        )
    }

    func settingDeviceEnrollment(
        snapshot: MachineSnapshot,
        enrolled: Bool,
        role: DeviceRole,
        knownSnapshots: [MachineSnapshot],
        updatedByMachineID: String,
        updatedAt: Date = Date()
    ) throws -> FleetManifest {
        let requiredMigration = needsDevicePolicyMigration
        let migrated = migratingLegacyDevices(knownSnapshots)
        var policies = migrated.devices ?? []
        let existingIndex = policies.firstIndex { $0.machineID == snapshot.machineID }
        let desiredEnrollment: DeviceEnrollment = enrolled ? .enrolled : .excluded
        if let existingIndex {
            let existing = policies[existingIndex]
            guard requiredMigration
                || existing.enrollment != desiredEnrollment
                || existing.role != role else {
                throw FleetManifestError.devicePolicyUnchanged(snapshot.name)
            }
            policies[existingIndex] = FleetDevicePolicy(
                snapshot: snapshot,
                role: role,
                enrollment: desiredEnrollment,
                overrides: existing.overrides
            )
        } else {
            policies.append(FleetDevicePolicy(
                snapshot: snapshot,
                role: role,
                enrollment: desiredEnrollment
            ))
        }
        return migrated.replacing(
            targets: migrated.targets,
            devices: policies,
            updatedByMachineID: updatedByMachineID,
            updatedAt: updatedAt
        )
    }

    func settingExistingDevicePolicy(
        machineID: String,
        enrolled: Bool,
        role: DeviceRole,
        updatedByMachineID: String,
        updatedAt: Date = Date()
    ) throws -> FleetManifest {
        guard var policies = devices,
              let index = policies.firstIndex(where: { $0.machineID == machineID }) else {
            throw FleetManifestError.deviceNotEnrolled("This device")
        }
        let existing = policies[index]
        let desiredEnrollment: DeviceEnrollment = enrolled ? .enrolled : .excluded
        guard existing.enrollment != desiredEnrollment || existing.role != role else {
            throw FleetManifestError.devicePolicyUnchanged(existing.displayName)
        }
        policies[index] = FleetDevicePolicy(
            machineID: existing.machineID,
            displayName: existing.displayName,
            role: role,
            enrollment: desiredEnrollment,
            overrides: existing.overrides,
            platform: existing.platform,
            capabilities: existing.capabilities
        )
        return replacing(
            targets: targets,
            devices: policies,
            updatedByMachineID: updatedByMachineID,
            updatedAt: updatedAt
        )
    }

    func settingDeviceScope(
        componentID: String,
        selection: DeviceScopeSelection,
        snapshot: MachineSnapshot,
        knownSnapshots: [MachineSnapshot],
        updatedByMachineID: String,
        updatedAt: Date = Date()
    ) throws -> FleetManifest {
        guard ComponentLifecycle.isActive(componentID) else {
            throw FleetManifestError.retiredComponent(componentID)
        }
        let migrated = migratingLegacyDevices(knownSnapshots)
        guard let policyIndex = migrated.devices?.firstIndex(where: {
            $0.machineID == snapshot.machineID && $0.enrollment == .enrolled
        }), var policies = migrated.devices else {
            throw FleetManifestError.deviceNotEnrolled(snapshot.name)
        }
        let policy = policies[policyIndex]
        guard policy.scopeSelection(for: componentID) != selection else {
            throw FleetManifestError.deviceScopeUnchanged(componentID)
        }

        var updatedTargets = migrated.targets
        var resolvedTarget = migrated.target(componentID)
        if selection == .required && resolvedTarget == nil {
            guard let observation = snapshot.component(componentID) else {
                throw FleetManifestError.missingObservation(componentID)
            }
            guard Self.isEligibleForBaseline(observation) else {
                throw FleetManifestError.ineligibleObservation(observation.name)
            }
            let added = ManifestTarget(
                observation: observation,
                defaultManaged: false,
                platform: snapshot.effectivePlatform
            )
            updatedTargets.append(added)
            resolvedTarget = added
        }
        if selection == .required, let resolvedTarget {
            let applicability = resolvedTarget.applicability(to: snapshot)
            guard applicability.isApplicable else {
                throw FleetManifestError.incompatibleDevice(
                    component: resolvedTarget.name,
                    device: snapshot.name,
                    reason: applicability.reason
                )
            }
        }

        var overrides = policy.overrides.filter { $0.componentID != componentID }
        if selection != .inherit {
            overrides.append(DeviceComponentOverride(
                componentID: componentID,
                selection: selection
            ))
        }
        policies[policyIndex] = FleetDevicePolicy(
            snapshot: snapshot,
            role: policy.role,
            enrollment: policy.enrollment,
            overrides: overrides
        )
        return migrated.replacing(
            targets: updatedTargets,
            devices: policies,
            updatedByMachineID: updatedByMachineID,
            updatedAt: updatedAt
        )
    }

    private func replacing(
        targets: [ManifestTarget],
        devices: [FleetDevicePolicy]?,
        updatedByMachineID: String,
        updatedAt: Date
    ) -> FleetManifest {
        FleetManifest(
            schemaVersion: Self.currentSchemaVersion,
            revision: UUID().uuidString.lowercased(),
            updatedAt: updatedAt,
            updatedByMachineID: updatedByMachineID,
            targets: targets.sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            },
            devices: devices?.sorted {
                $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
            }
        )
    }

    func target(_ id: String) -> ManifestTarget? {
        guard ComponentLifecycle.isActive(id) else { return nil }
        return targets.first { $0.id == id }
    }

}

struct ProductVersionTarget: Hashable, Sendable {
    let status: ProductVersionCheckStatus
    let version: String?
    let authority: ProductVersionAuthority
}

enum FleetTargetBasis: String, Sendable {
    case latestRelease
    case savedBaseline

    var label: String {
        switch self {
        case .latestRelease: "Latest available"
        case .savedBaseline: "Saved baseline"
        }
    }
}

enum FleetManifestError: LocalizedError {
    case missingObservation(String)
    case ineligibleObservation(String)
    case retiredComponent(String)
    case alreadyManaged(String)
    case alreadyUnmanaged(String)
    case deviceNotEnrolled(String)
    case devicePolicyUnchanged(String)
    case deviceScopeUnchanged(String)
    case incompatibleDevice(component: String, device: String, reason: String)
    case softwareBaselineIsAutomatic(String)
    case baselineAlreadyMatches(String)

    var errorDescription: String? {
        switch self {
        case .missingObservation(let componentID):
            "This device has not reported enough evidence to add \(componentID) to fleet scope."
        case .ineligibleObservation(let name):
            "\(name) must be installed or configured on this device before it can define fleet scope."
        case .retiredComponent(let componentID):
            "\(componentID) is retired and cannot be added to the active fleet baseline."
        case .alreadyManaged(let componentID):
            "\(componentID) is already managed by the fleet baseline."
        case .alreadyUnmanaged(let componentID):
            "\(componentID) is already outside fleet scope."
        case .deviceNotEnrolled(let name):
            "Add \(name) to the fleet before assigning managed items."
        case .devicePolicyUnchanged(let name):
            "\(name) already has that fleet membership and device type."
        case .deviceScopeUnchanged(let componentID):
            "\(componentID) already has that scope setting on this device."
        case .incompatibleDevice(let component, let device, let reason):
            "\(component) cannot be required on \(device). \(reason)"
        case .softwareBaselineIsAutomatic(let name):
            "\(name) follows the latest verified software version automatically."
        case .baselineAlreadyMatches(let name):
            "The saved baseline for \(name) already matches this observation."
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
    case notApplicable

    var label: String {
        switch self {
        case .aligned: "Aligned"
        case .different: "Drift"
        case .missing: "Missing"
        case .unknown: "Unknown"
        case .localChanges: "Local work"
        case .notManaged: "Not in baseline"
        case .notApplicable: "Not applicable"
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
    let targetBasis: FleetTargetBasis

    init(
        componentID: String,
        name: String,
        kind: ComponentKind,
        state: DriftState,
        severity: DriftSeverity,
        summary: String,
        expected: String?,
        observed: String?,
        targetBasis: FleetTargetBasis = .savedBaseline
    ) {
        self.componentID = componentID
        self.name = name
        self.kind = kind
        self.state = state
        self.severity = severity
        self.summary = summary
        self.expected = expected
        self.observed = observed
        self.targetBasis = targetBasis
    }

    var id: String { "\(componentID)-\(state.rawValue)-\(summary)" }

    var targetLabel: String {
        switch targetBasis {
        case .latestRelease:
            "Latest available"
        case .savedBaseline:
            kind == .configuration || kind == .theme
                ? "Saved baseline"
                : "Recorded minimum"
        }
    }
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

    var headlessExitCode: Int32 {
        switch self {
        case .aligned: 0
        case .attention: 2
        case .critical: 3
        case .unknown: 4
        }
    }
}

enum FleetHealthEvaluator {
    static func verdict(
        manifest: FleetManifest?,
        assessments: [MachineAssessment],
        issueCount: Int,
        missingEnrolledCount: Int,
        hasRuntimeError: Bool = false
    ) -> FleetVerdict {
        if hasRuntimeError || manifest == nil || issueCount > 0 || missingEnrolledCount > 0 {
            return .unknown
        }
        if assessments.contains(where: { $0.verdict == .critical }) { return .critical }
        if assessments.contains(where: { $0.verdict == .attention }) { return .attention }
        if assessments.isEmpty { return .unknown }
        return .aligned
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
        managedDrifts.filter { $0.state != .aligned && $0.state != .notApplicable }.count
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
