# AGENTS.md — Device Sync

## Product contract

Device Sync is Patrick's native macOS fleet control plane. It answers three
questions with evidence:

1. What is installed and configured on each Mac?
2. How does each Mac differ from the explicitly chosen fleet baseline?
3. What reviewed action would converge a new or drifting Mac?

The app may inventory and publish a redacted machine snapshot autonomously.
Installing, updating, restoring configuration, changing the fleet baseline,
or replacing a theme always requires an explicit user action.

## Ownership boundaries

- Device Sync owns the desired-state manifest, redacted machine snapshots,
  drift calculation, and bootstrap orchestration UI.
- Each managed product owns its own installer, updater, runtime state, and
  health semantics. Invoke those entrypoints; do not duplicate them here.
- `~/harness-sync` owns recurring Claude/OMP configuration linking. Device
  Sync reports and orchestrates it but never rewrites the files it owns.
- Kiro Crew is the active managed agent product and Builder Toolbox owns its
  installation/update lifecycle. MeshClaw is retired; never treat its old
  state or component IDs as current Kiro Crew evidence.
- ai-continuum owns its SQLite databases. Never copy live SQLite, WAL, socket,
  credentials, tokens, cookies, or Keychain material into the fleet folder.
- BrainVault/StarkBrain is durable knowledge, not the live fleet-state store.

## Fleet protocol

- Shared state is small, atomic, human-readable JSON only.
- `fleet-manifest.json` is desired state and changes only through an explicit
  baseline action (except first-run seeding when no manifest exists).
- `machines/<random-local-id>.json` is one writer per machine and contains no
  serial number, hardware UUID, username, home path, secrets, or raw config.
- Missing or unreadable evidence is `unknown`/`missing`, never healthy.
- Readers must tolerate an older writer, malformed files, and partial cloud
  availability without hiding the issue.

## Engineering conventions

- Swift 6 strict concurrency and macOS 14 minimum.
- Keep inventory probes read-only and bounded. Do not invoke billable APIs.
- Preserve source checkout state; never pull, install, commit, push, or publish
  managed repositories as a side effect of refresh.
- Use stable IDs in persisted JSON and add migrations before changing meaning.
- Validate with `swift test`, a release build, the installed app's `--check`,
  the running process, and the generated snapshot/manifest.
