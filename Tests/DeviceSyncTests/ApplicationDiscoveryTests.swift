import Foundation
import Testing
@testable import DeviceSync

struct ApplicationDiscoveryTests {
    @Test
    func processInventoryRecoversAppBundlePathsWithSpaces() throws {
        let output = """
        Murmur /Users/example/Build Products/Murmr Voice.app/Contents/MacOS/Murmur
        AuthBar /Applications/AuthBar.app/Contents/MacOS/AuthBar
        helper /usr/libexec/helper
        """

        let inventory = InventoryService.parseRunningProcesses(output)

        #expect(inventory.names.contains("Murmur"))
        #expect(inventory.applicationBundles["Murmur"]?.first?.path ==
            "/Users/example/Build Products/Murmr Voice.app")
        #expect(inventory.applicationBundles["AuthBar"]?.first?.path ==
            "/Applications/AuthBar.app")
        #expect(inventory.applicationBundles["helper"] == nil)
    }

    @Test
    func runningBundleFallbackRequiresMatchingProductIdentity() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("fleetmesh-running-app-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let matching = root.appendingPathComponent(
            "Build Products/Murmr Voice.app",
            isDirectory: true
        )
        try makeBundle(at: matching, identifier: "ai.murmr.labs.voice")
        let wrong = root.appendingPathComponent(
            "Other/Murmr Voice.app",
            isDirectory: true
        )
        try makeBundle(at: wrong, identifier: "example.unrelated")
        let definition = AppProbeDefinition(
            id: "murmr-voice",
            name: "Murmr Voice",
            bundleIdentifiers: ["ai.murmr.labs.voice"],
            preferredPaths: [],
            sourceRelativePath: nil,
            commitKeys: [],
            processNames: ["Murmur"]
        )
        let service = InventoryService(homeURL: root)

        let rejected = service.locateApplication(
            definition,
            applicationsByBundleID: [:],
            runningApplicationBundles: ["Murmur": [wrong]]
        )
        #expect(rejected == nil)

        let recovered = service.locateApplication(
            definition,
            applicationsByBundleID: [:],
            runningApplicationBundles: ["Murmur": [matching]]
        )
        #expect(recovered == matching.standardizedFileURL)
        #expect(service.installationLocation(for: matching) == .runningBundle)
        #expect(
            InventoryService.applicationEvidence(
                managedVersion: nil,
                installationLocation: .runningBundle
            ).contains("matching running bundle")
        )
    }

    @Test
    func applicationLocationsExposeNoRawHomePath() {
        let home = URL(fileURLWithPath: "/Users/private-user", isDirectory: true)
        let service = InventoryService(homeURL: home)

        #expect(service.installationLocation(
            for: URL(fileURLWithPath: "/Applications/Murmr Voice.app")
        ) == .systemApplications)
        #expect(service.installationLocation(
            for: home.appendingPathComponent("Applications/Murmr Voice.app")
        ) == .userApplications)
        let other = service.installationLocation(
            for: home.appendingPathComponent("code/Murmur/dist/Murmr Voice.app")
        )
        #expect(other == .runningBundle)
        #expect(!other.displayPath(appName: "Murmr Voice").contains("private-user"))
    }

    private func makeBundle(at url: URL, identifier: String) throws {
        let contents = url.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(
            at: contents.appendingPathComponent("MacOS", isDirectory: true),
            withIntermediateDirectories: true
        )
        let plist: [String: Any] = [
            "CFBundleIdentifier": identifier,
            "CFBundleExecutable": "Murmur",
            "CFBundleName": "Murmr Voice",
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": "0.2.36",
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        )
        try data.write(to: contents.appendingPathComponent("Info.plist"))
    }
}
