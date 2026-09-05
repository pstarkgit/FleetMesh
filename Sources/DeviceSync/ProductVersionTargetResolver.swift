import Foundation

/// Resolves software targets only from product-owned version authorities.
/// Developer checkouts, synced reports, and manifest-provided commands never
/// participate. A failed or unavailable check leaves the recorded minimum in
/// force and does not turn missing evidence into a healthy latest-version claim.
struct ProductVersionTargetResolver: Sendable {
    let freshnessInterval: TimeInterval
    let futureSkewTolerance: TimeInterval

    init(
        freshnessInterval: TimeInterval = 24 * 60 * 60,
        futureSkewTolerance: TimeInterval = 5 * 60
    ) {
        self.freshnessInterval = freshnessInterval
        self.futureSkewTolerance = futureSkewTolerance
    }

    func resolve(
        manifest: FleetManifest,
        localSnapshot snapshot: MachineSnapshot,
        now: Date = Date()
    ) -> [String: ProductVersionTarget] {
        let age = now.timeIntervalSince(snapshot.capturedAt)
        guard manifest.enrollmentStatus(for: snapshot.machineID) == .enrolled,
              age >= -futureSkewTolerance,
              age <= freshnessInterval else { return [:] }

        return Dictionary(uniqueKeysWithValues: snapshot.components.compactMap { observation in
            guard let baseline = manifest.target(observation.id),
                  baseline.kind != .configuration,
                  baseline.kind != .theme,
                  let check = observation.productVersionCheck else { return nil }

            if check.status == .verified,
               let rawVersion = check.latestVersion,
               let version = VersionIdentity.normalizedDeclaration(rawVersion),
               isAtLeastRecordedMinimum(
                candidate: version,
                minimum: baseline.expectedVersion
               ) {
                return (observation.id, ProductVersionTarget(
                    status: .verified,
                    version: version,
                    authority: check.authority
                ))
            }
            return (observation.id, ProductVersionTarget(
                status: .unavailable,
                version: nil,
                authority: check.authority
            ))
        })
    }

    private func isAtLeastRecordedMinimum(candidate: String, minimum: String?) -> Bool {
        guard let minimum else { return true }
        guard let comparison = VersionIdentity.compare(candidate, minimum) else { return false }
        return comparison != .orderedAscending
    }
}

struct ResolvedFleetTarget: Sendable {
    let baseline: ManifestTarget
    let productVersion: ProductVersionTarget?

    var id: String { baseline.id }
    var name: String { baseline.name }
    var kind: ComponentKind { baseline.kind }
    var required: Bool { baseline.required }
    var expectedVersion: String? { productVersion?.version ?? baseline.expectedVersion }
    var expectedInstalledRevision: String? {
        kind == .configuration || kind == .theme
            ? baseline.expectedInstalledRevision
            : nil
    }
    var expectedSourceRevision: String? {
        kind == .configuration || kind == .theme
            ? baseline.expectedSourceRevision
            : nil
    }
    var expectedConfigurationFingerprint: String? {
        baseline.expectedConfigurationFingerprint
    }
    var basis: FleetTargetBasis {
        productVersion?.status == .verified ? .latestRelease : .savedBaseline
    }

    var productVersionCheckUnavailable: Bool {
        productVersion?.status == .unavailable
    }

    func applicability(to snapshot: MachineSnapshot) -> ComponentApplicability {
        baseline.applicability(to: snapshot)
    }
}
