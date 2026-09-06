import Foundation
import Testing
@testable import DeviceSync

struct ShadowFleetRepositoryBackendTests {
    @Test
    func shadowReadsCompareAndWritesStayAuthorityOnly() async throws {
        let authorityRoot = shadowTemporaryDirectory()
        let shadowRoot = shadowTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: authorityRoot)
            try? FileManager.default.removeItem(at: shadowRoot)
        }
        let first = shadowBackendSnapshot(version: "1.0.0", capturedOffset: 0)
        let changed = shadowBackendSnapshot(version: "2.0.0", capturedOffset: 60)
        let manifest = FleetManifest(
            snapshot: first,
            updatedAt: Date(timeIntervalSince1970: 1_788_000_000)
        )
        let authority = JSONFleetRepositoryBackend(rootURL: authorityRoot)
        let shadow = JSONFleetRepositoryBackend(rootURL: shadowRoot)
        _ = try await authority.replaceBaseline(manifest, snapshot: first)
        _ = try await shadow.replaceBaseline(manifest, snapshot: first)
        let backend = ShadowFleetRepositoryBackend(
            authority: authority,
            shadow: shadow
        )

        let initial = await backend.load()
        #expect(initial.machines.first?.component("example-app")?.installedVersion == "1.0.0")
        #expect(await backend.lastComparison()?.isMatch == true)

        _ = try await backend.publish(changed)
        let authorityAfter = await authority.load()
        let shadowAfter = await shadow.load()
        #expect(authorityAfter.machines.first?.component("example-app")?.installedVersion == "2.0.0")
        #expect(shadowAfter.machines.first?.component("example-app")?.installedVersion == "1.0.0")

        _ = await backend.load()
        #expect(await backend.lastComparison()?.mismatchedDeviceIDs == [first.machineID])
        #expect(await backend.lastComparisonError() == nil)
    }
}

private func shadowBackendSnapshot(
    version: String,
    capturedOffset: TimeInterval
) -> MachineSnapshot {
    MachineSnapshot(
        machineID: "77f61618-c556-438c-a2af-101ca6cedae9",
        name: "Shadow backend fixture",
        hostName: "redacted-host",
        modelIdentifier: "Mac17,6",
        architecture: "arm64",
        osVersion: "26.6",
        osBuild: "25G83",
        platform: .macOS,
        capturedAt: Date(timeIntervalSince1970: 1_788_000_000 + capturedOffset),
        components: [
            ComponentObservation(
                id: "example-app",
                name: "Example App",
                kind: .application,
                status: .installed,
                installedVersion: version,
                evidence: "Installed"
            ),
        ]
    )
}

private func shadowTemporaryDirectory() -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(
            "fleetmesh-shadow-tests-\(UUID().uuidString)",
            isDirectory: true
        )
    try! FileManager.default.createDirectory(
        at: root,
        withIntermediateDirectories: true
    )
    return root
}
