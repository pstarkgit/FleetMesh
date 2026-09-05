import Darwin
import Foundation

struct SSHRemoteCommandResult: Sendable {
    let exitCode: Int32
    let standardOutput: String
    let standardError: String
    let timedOut: Bool
}

protocol SSHRemoteCommandRunning: Sendable {
    func run(host: String, script: String, timeout: TimeInterval) async -> SSHRemoteCommandResult
}

struct ProcessSSHRemoteCommandRunner: SSHRemoteCommandRunning {
    func run(
        host: String,
        script: String,
        timeout: TimeInterval
    ) async -> SSHRemoteCommandResult {
        await Task.detached(priority: .utility) {
            let captureRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent("fleetmesh-ssh-\(UUID().uuidString)", isDirectory: true)
            let outputURL = captureRoot.appendingPathComponent("stdout")
            let errorURL = captureRoot.appendingPathComponent("stderr")
            do {
                try FileManager.default.createDirectory(
                    at: captureRoot,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
                _ = FileManager.default.createFile(
                    atPath: outputURL.path,
                    contents: nil,
                    attributes: [.posixPermissions: 0o600]
                )
                _ = FileManager.default.createFile(
                    atPath: errorURL.path,
                    contents: nil,
                    attributes: [.posixPermissions: 0o600]
                )
            } catch {
                return SSHRemoteCommandResult(
                    exitCode: -1,
                    standardOutput: "",
                    standardError: error.localizedDescription,
                    timedOut: false
                )
            }
            defer { try? FileManager.default.removeItem(at: captureRoot) }

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            process.arguments = [
                "-T",
                "-o", "BatchMode=yes",
                "-o", "ConnectTimeout=8",
                "-o", "ConnectionAttempts=1",
                "-o", "ServerAliveInterval=5",
                "-o", "ServerAliveCountMax=1",
                "-o", "LogLevel=ERROR",
                host,
                "sh", "-s",
            ]

            let input = Pipe()
            process.standardInput = input

            do {
                let outputHandle = try FileHandle(forWritingTo: outputURL)
                let errorHandle = try FileHandle(forWritingTo: errorURL)
                defer {
                    try? outputHandle.close()
                    try? errorHandle.close()
                }
                process.standardOutput = outputHandle
                process.standardError = errorHandle
                try process.run()
                input.fileHandleForWriting.write(Data(script.utf8))
                try? input.fileHandleForWriting.close()

                let deadline = Date().addingTimeInterval(timeout)
                while process.isRunning && Date() < deadline {
                    try? await Task.sleep(for: .milliseconds(100))
                }

                var timedOut = false
                if process.isRunning {
                    timedOut = true
                    process.terminate()
                    let terminationDeadline = Date().addingTimeInterval(2)
                    while process.isRunning && Date() < terminationDeadline {
                        try? await Task.sleep(for: .milliseconds(100))
                    }
                    if process.isRunning {
                        Darwin.kill(process.processIdentifier, SIGKILL)
                        let killDeadline = Date().addingTimeInterval(1)
                        while process.isRunning && Date() < killDeadline {
                            try? await Task.sleep(for: .milliseconds(100))
                        }
                    }
                }
                try? outputHandle.close()
                try? errorHandle.close()
                return SSHRemoteCommandResult(
                    exitCode: process.isRunning ? -1 : process.terminationStatus,
                    standardOutput: String(
                        data: Self.readPrefix(outputURL, maximumBytes: 262_144),
                        encoding: .utf8
                    ) ?? "",
                    standardError: String(
                        data: Self.readPrefix(errorURL, maximumBytes: 262_144),
                        encoding: .utf8
                    ) ?? "",
                    timedOut: timedOut
                )
            } catch {
                try? input.fileHandleForWriting.close()
                return SSHRemoteCommandResult(
                    exitCode: -1,
                    standardOutput: "",
                    standardError: error.localizedDescription,
                    timedOut: false
                )
            }
        }.value
    }

    private static func readPrefix(
        _ url: URL,
        maximumBytes: Int
    ) -> Data {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return Data() }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: maximumBytes)) ?? Data()
    }
}

protocol RemoteInventoryCapturing: Sendable {
    func capture(connection: RemoteDeviceConnection) async throws -> MachineSnapshot
}

struct SSHRemoteInventoryService: RemoteInventoryCapturing {
    let runner: any SSHRemoteCommandRunning

    init(runner: any SSHRemoteCommandRunning = ProcessSSHRemoteCommandRunner()) {
        self.runner = runner
    }

    func capture(connection: RemoteDeviceConnection) async throws -> MachineSnapshot {
        _ = try RemoteDeviceConnection.validate(host: connection.host)
        let result = await runner.run(
            host: connection.host,
            script: Self.probeScript,
            timeout: 18
        )
        if result.timedOut {
            throw RemoteInventoryError.timedOut(connection.displayName)
        }
        guard result.exitCode == 0 else {
            throw RemoteInventoryError.sshFailed(
                connection.displayName,
                Self.safeErrorSummary(result.standardError)
            )
        }
        return try Self.decode(result.standardOutput, connection: connection)
    }

    private static func decode(
        _ output: String,
        connection: RemoteDeviceConnection
    ) throws -> MachineSnapshot {
        let lines = output.split(separator: "\n", omittingEmptySubsequences: true)
        guard lines.first == "FLEETMESH_REMOTE_V1" else {
            throw RemoteInventoryError.invalidResponse(connection.displayName)
        }

        var values: [String: String] = [:]
        for line in lines.dropFirst() {
            let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2,
                  let data = Data(base64Encoded: String(parts[1])),
                  let value = String(data: data, encoding: .utf8) else { continue }
            values[String(parts[0])] = value
        }

        guard values["platform"] == "linux",
              let architecture = values["architecture"], !architecture.isEmpty,
              let osVersion = values["osVersion"], !osVersion.isEmpty,
              let osBuild = values["osBuild"], !osBuild.isEmpty else {
            throw RemoteInventoryError.invalidResponse(connection.displayName)
        }

        let capabilities = (values["capabilities"] ?? "")
            .split(separator: ",")
            .compactMap { DeviceCapability(rawValue: String($0)) }

        let components = [
            component(
                id: "ai-continuum",
                name: "ai-continuum",
                kind: .service,
                values: values
            ),
            component(
                id: "codex-cli",
                name: "Codex CLI",
                kind: .commandLineTool,
                values: values
            ),
            component(
                id: "harness-sync",
                name: "Harness Sync",
                kind: .configuration,
                values: values
            ),
        ]

        return MachineSnapshot(
            machineID: connection.machineID,
            name: connection.displayName,
            // The SSH endpoint is controller-private. A stable generic value
            // keeps the shared report useful without publishing its DNS name.
            hostName: "Private SSH endpoint",
            modelIdentifier: "Linux \(connection.role.label.lowercased())",
            architecture: architecture,
            osVersion: osVersion,
            osBuild: osBuild,
            platform: .linux,
            capabilities: capabilities,
            components: components
        )
    }

    private static func component(
        id: String,
        name: String,
        kind: ComponentKind,
        values: [String: String]
    ) -> ComponentObservation {
        let prefix = "component.\(id)."
        let status = ObservationStatus(rawValue: values[prefix + "status"] ?? "unknown") ?? .unknown
        return ComponentObservation(
            id: id,
            name: name,
            kind: kind,
            status: status,
            installedVersion: normalizedVersion(values[prefix + "version"]),
            sourceRevision: kind == .configuration
                ? values[prefix + "sourceRevision"]?.nilIfBlank
                : nil,
            sourceBranch: kind == .configuration
                ? values[prefix + "sourceBranch"]?.nilIfBlank
                : nil,
            sourceDirty: kind == .configuration
                ? bool(values[prefix + "sourceDirty"])
                : nil,
            configurationFingerprint: id == "harness-sync"
                ? values[prefix + "sourceRevision"]?.nilIfBlank
                : nil,
            isRunning: bool(values[prefix + "running"]),
            evidence: status == .installed
                ? "Read-only evidence returned by FleetMesh's fixed SSH probe."
                : "FleetMesh's fixed SSH probe did not find this component."
        )
    }

    private static func bool(_ value: String?) -> Bool? {
        switch value {
        case "true": true
        case "false": false
        default: nil
        }
    }

    private static func normalizedVersion(_ value: String?) -> String? {
        guard let value = value?.nilIfBlank else { return nil }
        return VersionIdentity.extract(from: value, fallbackLimit: 80)
    }

    private static func safeErrorSummary(_ error: String) -> String {
        let summary = error
            .split(whereSeparator: \Character.isNewline)
            .last
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let summary, !summary.isEmpty else {
            return "SSH exited without a usable error."
        }
        return String(summary.prefix(240))
    }

    // No manifest or machine-report value enters this script. It is a fixed,
    // read-only probe and emits only bounded, base64-encoded scalar evidence.
    private static let probeScript = #"""
set -u

b64() {
  printf '%s' "$1" | base64 | tr -d '\n'
}
emit() {
  printf '%s\t%s\n' "$1" "$(b64 "$2")"
}
clean() {
  printf '%s' "$1" | tr '\t\r\n|' '    ' | cut -c1-240
}
find_executable() {
  for candidate in "$@"; do
    if [ -x "$candidate" ]; then
      printf '%s' "$candidate"
      return 0
    fi
  done
  return 1
}
git_state() {
  key="$1"
  checkout="$2"
  if [ -d "$checkout/.git" ] && command -v git >/dev/null 2>&1; then
    git_read() { GIT_OPTIONAL_LOCKS=0 GIT_TERMINAL_PROMPT=0 git "$@"; }
    revision_full="$(git_read -C "$checkout" rev-parse HEAD 2>/dev/null)" || return 0
    branch="$(git_read -C "$checkout" branch --show-current 2>/dev/null || true)"
    status="$(git_read -C "$checkout" status --porcelain 2>/dev/null)" || return 0
    dirty=false
    [ -z "$status" ] || dirty=true
    final_revision="$(git_read -C "$checkout" rev-parse HEAD 2>/dev/null)" || return 0
    [ "$final_revision" = "$revision_full" ] || return 0
    emit "component.$key.sourceRevision" "$(clean "$(printf '%s' "$revision_full" | cut -c1-12)")"
    emit "component.$key.sourceBranch" "$(clean "$branch")"
    emit "component.$key.sourceDirty" "$dirty"
  fi
}

printf 'FLEETMESH_REMOTE_V1\n'
emit platform linux
emit architecture "$(clean "$(uname -m 2>/dev/null || printf unknown)")"
os_version="$(sed -n 's/^VERSION_ID=//p' /etc/os-release 2>/dev/null | head -1 | tr -d '\"' || true)"
[ -n "$os_version" ] || os_version=unknown
emit osVersion "$(clean "$os_version")"
emit osBuild "$(clean "$(uname -r 2>/dev/null || printf unknown)")"

capabilities="shell,configuration-files"
if [ -d /run/systemd/system ]; then
  capabilities="$capabilities,systemd"
  if command -v systemctl >/dev/null 2>&1 && [ "$(systemctl get-default 2>/dev/null || true)" = graphical.target ]; then
    capabilities="$capabilities,graphical-session"
  fi
fi
emit capabilities "$capabilities"

aic="$(find_executable "$HOME/.local/bin/ai-continuum-ctl" /usr/local/bin/ai-continuum-ctl 2>/dev/null || true)"
if [ -n "$aic" ]; then
  emit component.ai-continuum.status installed
  emit component.ai-continuum.version "$(clean "$($aic --version 2>&1 | head -1 || true)")"
  if pgrep -x ai-continuum-daemon >/dev/null 2>&1; then
    emit component.ai-continuum.running true
  else
    emit component.ai-continuum.running false
  fi
else
  emit component.ai-continuum.status missing
  emit component.ai-continuum.running false
fi
codex="$(find_executable "$HOME/.toolbox/bin/codex" "$HOME/.local/bin/codex" /usr/local/bin/codex 2>/dev/null || true)"
if [ -n "$codex" ]; then
  emit component.codex-cli.status installed
  emit component.codex-cli.version "$(clean "$($codex --version 2>&1 | head -1 || true)")"
else
  emit component.codex-cli.status missing
fi

harness=""
for checkout in "$HOME/harness-sync" "$HOME/code/harness-sync"; do
  if [ -d "$checkout/.git" ]; then harness="$checkout"; break; fi
done
if [ -n "$harness" ]; then
  emit component.harness-sync.status installed
  git_state harness-sync "$harness"
else
  emit component.harness-sync.status missing
fi
"""#
}

enum RemoteInventoryError: LocalizedError {
    case timedOut(String)
    case sshFailed(String, String)
    case invalidResponse(String)

    var errorDescription: String? {
        switch self {
        case .timedOut(let name):
            "\(name) did not complete its read-only SSH check-in within 18 seconds."
        case .sshFailed(let name, let detail):
            "Could not check in \(name). \(detail) FleetMesh uses your existing SSH config and agent; connect once in Terminal first if host trust or authentication is required."
        case .invalidResponse(let name):
            "\(name) returned an incomplete FleetMesh check-in. No fleet policy was changed."
        }
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
