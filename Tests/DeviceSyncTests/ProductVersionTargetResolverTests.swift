import Foundation
import Testing
@testable import DeviceSync

struct ProductVersionTargetResolverTests {
    @Test
    func productVersionCheckAdvancesTargetWithoutMutatingManifest() throws {
        let machineID = "b41f9f4f-0fce-4792-a3c6-c93a73fcb4cd"
        let baseline = targetSnapshot(
            machineID: machineID,
            installedVersion: "0.10.5"
        )
        let manifest = FleetManifest(snapshot: baseline)
        let current = targetSnapshot(
            machineID: machineID,
            installedVersion: "0.10.5",
            productCheck: .verified(version: "0.11.3", authority: .sparkleAppcast),
            capturedAt: Date(timeIntervalSince1970: 2_000)
        )

        let targets = ProductVersionTargetResolver().resolve(
            manifest: manifest,
            localSnapshot: current,
            now: Date(timeIntervalSince1970: 2_010)
        )

        #expect(manifest.target("authbar")?.expectedVersion == "0.10.5")
        #expect(targets["authbar"]?.status == .verified)
        #expect(targets["authbar"]?.version == "0.11.3")
        #expect(targets["authbar"]?.authority == .sparkleAppcast)
        let json = try #require(String(
            data: FleetJSON.encoder.encode(manifest),
            encoding: .utf8
        ))
        #expect(!json.contains("0.11.3"))
    }

    @Test
    func checkoutEvidenceCannotBecomeVersionAuthority() {
        let machineID = "b41f9f4f-0fce-4792-a3c6-c93a73fcb4cd"
        let manifest = FleetManifest(snapshot: targetSnapshot(
            machineID: machineID,
            installedVersion: "1.0.0"
        ))
        let checkoutOnly = ComponentObservation(
            id: "authbar",
            name: "AuthBar",
            kind: .application,
            status: .installed,
            installedVersion: "1.0.0",
            installedRevision: "aaaaaaaaaaaa",
            sourceVersion: "9.9.9",
            sourceRevision: "bbbbbbbbbbbb",
            sourceDirty: false,
            evidence: "Developer checkout"
        )
        let current = targetSnapshot(
            machineID: machineID,
            installedVersion: "1.0.0"
        ).replacingComponents([checkoutOnly])

        #expect(ProductVersionTargetResolver().resolve(
            manifest: manifest,
            localSnapshot: current,
            now: Date(timeIntervalSince1970: 1_010)
        ).isEmpty)
    }

    @Test
    func failedMalformedAndRegressedChecksRemainUnverified() {
        let machineID = "b41f9f4f-0fce-4792-a3c6-c93a73fcb4cd"
        let manifest = FleetManifest(snapshot: targetSnapshot(
            machineID: machineID,
            installedVersion: "2.0.0"
        ))
        let checks: [ProductVersionCheck] = [
            .unavailable(authority: .sparkleAppcast),
            ProductVersionCheck(
                status: .verified,
                authority: .sparkleAppcast,
                latestVersion: "next"
            ),
            .verified(version: "1.9.0", authority: .sparkleAppcast),
        ]

        for check in checks {
            let snapshot = targetSnapshot(
                machineID: machineID,
                installedVersion: "2.0.0",
                productCheck: check
            )
            let target = ProductVersionTargetResolver().resolve(
                manifest: manifest,
                localSnapshot: snapshot,
                now: Date(timeIntervalSince1970: 1_010)
            )["authbar"]
            #expect(target?.status == .unavailable)
            #expect(target?.version == nil)
        }
    }

    @Test
    func staleFutureAndPendingEvidenceCannotSetFleetVersionTarget() throws {
        let machineID = "b41f9f4f-0fce-4792-a3c6-c93a73fcb4cd"
        let baseline = targetSnapshot(
            machineID: machineID,
            installedVersion: "1.0.0",
            capturedAt: Date(timeIntervalSince1970: 1_000)
        )
        let manifest = FleetManifest(snapshot: baseline)
        let stale = targetSnapshot(
            machineID: machineID,
            installedVersion: "1.0.0",
            productCheck: .verified(version: "2.0.0", authority: .sparkleAppcast),
            capturedAt: Date(timeIntervalSince1970: 1_000)
        )
        let future = targetSnapshot(
            machineID: machineID,
            installedVersion: "1.0.0",
            productCheck: .verified(version: "2.0.0", authority: .sparkleAppcast),
            capturedAt: Date(timeIntervalSince1970: 10_000)
        )
        let pending = targetSnapshot(
            machineID: "9c694b70-14b7-48f6-83e1-cd23603ac157",
            installedVersion: "1.0.0",
            productCheck: .verified(version: "2.0.0", authority: .sparkleAppcast)
        )

        #expect(ProductVersionTargetResolver(freshnessInterval: 60).resolve(
            manifest: manifest,
            localSnapshot: stale,
            now: Date(timeIntervalSince1970: 2_000)
        ).isEmpty)
        #expect(ProductVersionTargetResolver().resolve(
            manifest: manifest,
            localSnapshot: future,
            now: Date(timeIntervalSince1970: 1_000)
        ).isEmpty)
        #expect(ProductVersionTargetResolver().resolve(
            manifest: manifest,
            localSnapshot: pending,
            now: Date(timeIntervalSince1970: 1_010)
        ).isEmpty)
    }

    @Test
    func parsesSparkleElementAndAttributeVersionsAndChoosesNewest() {
        let appcast = Data(#"""
        <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
          <channel>
            <item><sparkle:shortVersionString>0.2.36</sparkle:shortVersionString></item>
            <item><enclosure sparkle:shortVersionString="0.2.40" /></item>
            <item><sparkle:shortVersionString>next</sparkle:shortVersionString></item>
          </channel>
        </rss>
        """#.utf8)

        #expect(InventoryService.parseSparkleAppcast(appcast) == "0.2.40")
        #expect(InventoryService.parseSparkleAppcast(Data("<rss/>".utf8)) == nil)
        #expect(InventoryService.parseSparkleAppcast(Data(repeating: 0, count: 262_145)) == nil)
    }

    @Test
    func sourceVersionParsingRemainsDoctorOnly() {
        let swift = Data(#"enum Version { static let current = "0.11.3" }"#.utf8)
        let cargo = Data(#"""
        [package]
        name = "app"
        version = "0.4.33"
        """#.utf8)
        let package = Data(#"{"name":"model-bridge","version":"0.2.12"}"#.utf8)

        #expect(InventoryService.parseSourceVersion(data: swift, format: .swiftStaticCurrent) == "0.11.3")
        #expect(InventoryService.parseSourceVersion(data: cargo, format: .cargoPackage) == "0.4.33")
        #expect(InventoryService.parseSourceVersion(data: package, format: .packageJSON) == "0.2.12")
    }
}

private func targetSnapshot(
    machineID: String,
    installedVersion: String,
    productCheck: ProductVersionCheck? = nil,
    capturedAt: Date = Date(timeIntervalSince1970: 1_000)
) -> MachineSnapshot {
    MachineSnapshot(
        machineID: machineID,
        name: "Target Mac",
        hostName: "target-mac",
        modelIdentifier: "Mac17,6",
        architecture: "arm64",
        osVersion: "26.6",
        osBuild: "25G83",
        capturedAt: capturedAt,
        components: [
            ComponentObservation(
                id: "authbar",
                name: "AuthBar",
                kind: .application,
                status: .installed,
                installedVersion: installedVersion,
                productVersionCheck: productCheck,
                evidence: "Test product-version evidence"
            ),
        ]
    )
}

private extension MachineSnapshot {
    func replacingComponents(_ components: [ComponentObservation]) -> MachineSnapshot {
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
            components: components
        )
    }
}
