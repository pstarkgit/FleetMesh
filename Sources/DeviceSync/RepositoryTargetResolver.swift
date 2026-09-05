import Foundation

/// Resolves software targets only from this Mac's direct inventory. The
/// resolver never reads synced reports, mutates a checkout, contacts a remote,
/// or changes the saved manifest. A repository identity is usable only when a
/// fresh, clean checkout declares a valid version at least as new as the saved
/// minimum. When that version is already installed, the installed/source build
/// must also prove the same revision or immutable Git tree.
struct RepositoryTargetResolver: Sendable {
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
    ) -> [String: RepositoryBuildTarget] {
        let age = now.timeIntervalSince(snapshot.capturedAt)
        guard manifest.enrollmentStatus(for: snapshot.machineID) == .enrolled,
              age >= -futureSkewTolerance,
              age <= freshnessInterval else { return [:] }

        return Dictionary(uniqueKeysWithValues: snapshot.components.compactMap { observation in
            guard let target = manifest.target(observation.id),
                  target.kind != .configuration,
                  target.kind != .theme,
                  observation.status == .installed,
                  observation.sourceDirty == false,
                  let installedVersion = observation.installedVersion,
                  let rawSourceVersion = observation.sourceVersion,
                  let sourceVersion = VersionIdentity.normalizedDeclaration(rawSourceVersion),
                  let sourceRevision = validRevision(observation.sourceRevision),
                  isAtLeastSavedTarget(
                    candidate: sourceVersion,
                    saved: target.expectedVersion
                  ) else { return nil }

            let comparison = VersionIdentity.compare(sourceVersion, installedVersion)
            let installedRevision: String?
            switch comparison {
            case .orderedDescending:
                // A clean, committed checkout may advertise the next build
                // before it is installed. Doctor still requires this exact
                // pinned source at execution and proves the installed result.
                guard validFullObjectID(observation.sourceTree) != nil else { return nil }
                installedRevision = nil
            case .orderedSame:
                guard let validatedInstalled = validRevision(observation.installedRevision),
                      RevisionIdentity.provesSameBuild(observation) else { return nil }
                installedRevision = validatedInstalled
            case .orderedAscending, .none:
                // An older checkout must never become authority for a newer
                // installed app; this prevents downgrade repairs.
                return nil
            }

            return (observation.id, RepositoryBuildTarget(
                version: sourceVersion,
                installedRevision: installedRevision,
                sourceRevision: sourceRevision
            ))
        })
    }

    private func isAtLeastSavedTarget(candidate: String, saved: String?) -> Bool {
        guard let saved else { return true }
        guard let comparison = VersionIdentity.compare(candidate, saved) else { return false }
        return comparison != .orderedAscending
    }

    private func validRevision(_ value: String?) -> String? {
        guard let value,
              (7...40).contains(value.count),
              value.unicodeScalars.allSatisfy(
                CharacterSet(charactersIn: "0123456789abcdefABCDEF").contains
              ) else { return nil }
        return value.lowercased()
    }

    private func validFullObjectID(_ value: String?) -> String? {
        guard let value,
              value.count == 40,
              value.unicodeScalars.allSatisfy(
                CharacterSet(charactersIn: "0123456789abcdefABCDEF").contains
              ) else { return nil }
        return value.lowercased()
    }

}

struct ResolvedFleetTarget: Sendable {
    let baseline: ManifestTarget
    let repositoryBuild: RepositoryBuildTarget?

    var id: String { baseline.id }
    var name: String { baseline.name }
    var kind: ComponentKind { baseline.kind }
    var required: Bool { baseline.required }
    var expectedVersion: String? { repositoryBuild?.version ?? baseline.expectedVersion }
    var expectedInstalledRevision: String? {
        guard let repositoryBuild else { return baseline.expectedInstalledRevision }
        return repositoryBuild.installedRevision
    }
    var expectedSourceRevision: String? {
        repositoryBuild?.sourceRevision ?? baseline.expectedSourceRevision
    }
    var expectedConfigurationFingerprint: String? {
        baseline.expectedConfigurationFingerprint
    }
    var basis: FleetTargetBasis {
        repositoryBuild == nil ? .savedBaseline : .latestRepository
    }

    func applicability(to snapshot: MachineSnapshot) -> ComponentApplicability {
        baseline.applicability(to: snapshot)
    }
}
