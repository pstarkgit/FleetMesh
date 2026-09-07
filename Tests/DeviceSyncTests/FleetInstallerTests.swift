import Foundation
import Testing
@testable import DeviceSync

struct FleetInstallerTests {
    @Test
    func installerUsesXcodeSelectAndSupportsCommandLineTools() async throws {
        let root = repositoryRoot()
        let installer = root.appendingPathComponent("install.sh")
        let selected = await ProcessCommandRunner().run(
            executable: URL(fileURLWithPath: "/usr/bin/xcode-select"),
            arguments: ["-p"],
            environment: ["DEVELOPER_DIR": ""],
            timeout: 5
        )
        let probe = await ProcessCommandRunner().run(
            executable: installer,
            arguments: ["--print-developer-dir"],
            environment: ["DEVELOPER_DIR": ""],
            timeout: 10
        )

        #expect(selected.exitCode == 0)
        #expect(probe.exitCode == 0)
        #expect(
            probe.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
                == selected.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        #expect(!probe.standardOutput.contains("/Applications/Xcode.app/Contents/Developer")
            || selected.standardOutput.contains("/Applications/Xcode.app/Contents/Developer"))
    }

    @Test
    func staleDeveloperDirectoryFallsBackToXcodeSelect() async {
        let root = repositoryRoot()
        let result = await ProcessCommandRunner().run(
            executable: root.appendingPathComponent("install.sh"),
            arguments: ["--print-developer-dir"],
            environment: ["DEVELOPER_DIR": "/definitely/missing/Xcode.app/Contents/Developer"],
            timeout: 10
        )

        #expect(result.exitCode == 0)
        #expect(result.standardError.contains("ignoring invalid DEVELOPER_DIR"))
        #expect(!result.standardOutput.contains("definitely/missing"))
    }

    @Test
    func installerTouchesOnlyFleetMeshAndItsOwnLaunchAgent() throws {
        let source = try String(
            contentsOf: repositoryRoot().appendingPathComponent("install.sh"),
            encoding: .utf8
        )

        #expect(source.contains("/Applications/FleetMesh.app"))
        #expect(source.contains("dev.starkpat.devicesync.snapshot"))
        #expect(!source.localizedCaseInsensitiveContains("harness-sync"))
        #expect(!source.localizedCaseInsensitiveContains("bootstrap.sh"))
        #expect(!source.contains("/Applications/Xcode.app/Contents/Developer"))
    }

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
