# Fleet protocol

## Verdict

FleetMesh stores a small JSON control plane in the legacy `Device Sync` fleet
folder. Manifest schema v2 is desired state. Machine snapshot schema v1 remains
the evidence format, with additive platform/capability fields that older readers
can ignore.

```text
Device Sync/
├── fleet-manifest.json
└── machines/
    ├── <random-machine-id>.json
    └── ...
```

All writes use atomic replacement. Readers validate schema versions, decode each
machine independently, tolerate older writers, surface malformed files as
issues, and never treat partial cloud availability as a healthy empty fleet.

## Manifest schema v2

`fleet-manifest.json` is the desired-state authority. It contains:

- `schemaVersion: 2`
- `revision`, `updatedAt`, and `updatedByMachineID`
- `targets[]`: active and available component defaults, desired versions,
  revisions, fingerprints, platform applicability, and default managed state
- `devices[]`: explicit device policies

Device policy records contain:

- random `machineID`
- redacted display name
- platform: `macos`, `linux`, or `unknown`
- role: `workstation`, `server`, or `cloud-desktop`
- capabilities: `graphical-session`, `macos-applications`, `menu-bar`,
  `launchd`, `systemd`, `shell`, and/or `configuration-files`
- enrollment: Pending when absent from the manifest, In fleet when enrolled, or
  Removed when explicitly excluded
- per-device component overrides: `inherit`, `required`, or `excluded`

`inherit` follows the fleet default. `required` brings an item into scope for
that device even when it is not managed by default. `excluded` keeps the item
out of posture, Bootstrap, and Doctor for that device. Incompatible inherited
items are not applicable rather than unhealthy.

Manifest changes are explicit desired-state actions. Enrolling or removing a
device, changing its role, changing fleet defaults, and setting per-device
scope all assign a new revision and must compare against the currently displayed
revision before replacing the file. A stale writer fails closed and reloads.

## Snapshot schema v1 with additive device fields

Each device owns exactly one `machines/<random-machine-id>.json` snapshot. The
stable ID is a random UUID stored in local Application Support; it is not
derived from serial number, hardware UUID, account, hostname, or SSH endpoint.

Snapshot schema v1 remains the shared evidence contract. FleetMesh 0.1.7 adds
platform and capabilities as optional/additive fields. Device role remains in
manifest policy. Older readers can
ignore them. New readers must treat missing fields as unknown or legacy evidence,
not as proof that a device is healthy or Mac-only.

Snapshots may contain:

- human-readable redacted machine name and local hostname where safe
- platform, capabilities, OS family/version/build, model identifier, and
  architecture
- installed product version/build/revision, product-owned latest-version check,
  and configuration fingerprint
- theme filenames and aggregate SHA-256 fingerprint
- observation status: installed, missing, or unknown
- snapshot freshness and FleetMesh `deviceSyncVersion`

Snapshots deliberately remain observations. They do not enroll a device, change
scope, update desired versions, or repair anything.

## Local-only SSH endpoints

FleetMesh can add a Linux device by SSH from a controller Mac. The destination
host or SSH config alias is controller-private state stored only in the legacy
local Application Support file. It is not synced and is never written to
`fleet-manifest.json` or `machines/*.json`.

The SSH probe uses `/usr/bin/ssh`, existing SSH config/agent trust, strict
destination validation, an 18-second bound, and a fixed read-only script. The
same probe powers explicit check-in from Devices and **Diagnose <device>** from
Doctor. It reports bounded platform capabilities plus allowlisted component
evidence, including KiroCrew runtime/version and relative KiroCrew theme names
with a content fingerprint. The shared fleet protocol never carries executable
commands, and FleetMesh never repairs a remote machine over SSH.

## Redaction rules

Allowed in shared JSON:

- random machine IDs
- redacted display names and safe local host labels
- platform, capabilities, OS version/build, model identifier, architecture
- managed component IDs, installed versions/revisions, product update-check
  results, status, and fingerprints
- theme filenames plus aggregate SHA-256 fingerprints

Forbidden in shared JSON:

- serial number, platform UUID, provisioning UDID, MAC address
- username, account name, absolute home path, or absolute source path
- SSH endpoint, SSH alias, SSH username, key path, or known-host material
- credentials, cookies, OAuth material, tokens, certificates, or Keychain data
- raw settings, prompts, transcripts, logs, databases, sockets, or theme contents
- live SQLite, WAL, shm, or ai-continuum database copies
- developer source branch, source revision, worktree dirtiness, or Git tree hashes

Software checkout evidence is Doctor-local only. Routine local and remote scans
do not read software worktrees, and `machines/*.json` writers strip those legacy
fields before publication. Configuration products may still publish their own
bounded fingerprint/revision when that checkout or linked tree is the configured
artifact itself.

Missing or unreadable evidence is encoded as unknown/missing and surfaced. It is
never converted to green health.

## Component lifecycle

Component IDs have lifecycle semantics. Readers ignore retired IDs such as
`meshclaw-themes`; active replacements use current IDs such as `kiro-crew`
and `kiro-crew-themes` so historical MeshClaw evidence is never represented as
current Kiro Crew state.

Codex Voice remains observable if installed, but it is outside the managed daily
baseline. Its presence should not create Bootstrap work, Doctor action, or fleet
drift unless a user explicitly changes scope.

The `device-sync` component ID and `deviceSyncVersion` snapshot key remain
stable after the FleetMesh rename so older and newer writers describe the same
component and decode the same fleet history.
