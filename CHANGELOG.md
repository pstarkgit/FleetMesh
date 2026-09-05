# Changelog

## 0.1.6 — 2026-09-04

- Added explicit Managed Items controls in Settings so individual apps, tools,
  configurations, and themes can enter or leave fleet scope without replacing
  the entire baseline.
- Kept removed items discoverable as observed evidence while excluding them
  from daily Fleet posture, Bootstrap work, Doctor findings, and attention
  counts; scope changes never uninstall apps or delete source.
- Protected item-level baseline edits with fresh local evidence, atomic writes,
  and manifest-revision checks so a stale Mac cannot overwrite newer scope.
- Added guarded `--add-to-scope` and `--remove-from-scope` operator commands for
  recovery and automation through the same manifest contract as the UI.
- Kept the menu-bar command center alive after the full window closes, made
  Dock/menu-bar reopening resilient to asynchronous SwiftUI window creation,
  and documented the lifecycle directly in the popover.
- Improved timestamps, shared busy states, success/error feedback, managed-only
  Fleet copy, and direct navigation to Managed Items.

## 0.1.5 — 2026-09-04

- Renamed the visible product and installed bundle to FleetMesh while retaining
  all Device Sync fleet, process, launch-agent, bundle, and JSON identities.
- Added the selected Fleet Bridge icon: two machine clusters connected through
  one authority bridge in the shared Aurora emerald-cyan-indigo palette.
- Replaced the generic cloud-sync glyph in the full app and command center with
  the same scalable FleetMesh mark.
- Applied the exact shared Aurora three-stop field to the full-app and menu-bar
  brand tiles so the installed icon and both native surfaces cannot color-drift.
- Made the Settings hierarchy explicit: `fleet-manifest.json` is the shared
  in-scope authority, machine reports are evidence, and local state is a pointer.
- Prevented a first launch without OneDrive from silently seeding a second local
  baseline; initial seeding is now limited to the canonical shared fleet path.

## 0.1.4 — 2026-09-04

- Renamed the customer-facing product and installed app to FleetForge across
  the full app, menu-bar command center, Doctor, Bootstrap, CLI, and docs.
- Added a transactional migration from `/Applications/Device Sync.app` to
  `/Applications/FleetForge.app`, with rollback if the new app fails its check.
- Preserved the existing bundle ID, executable, component ID, state and fleet
  folders, snapshot schema field, LaunchAgent identity, and menu-bar slot so
  enrolled Macs and fleet history continue without reset or duplication.
- Canonicalized the historical `device-sync` display name to FleetForge while
  reading older baselines and reports, without mutating their persisted JSON.

## 0.1.3 — 2026-09-04

- Added a native menu-bar command center alongside the singleton full app,
  with live fleet posture, machine and attention counts, and scan freshness.
- Added one-click local scanning plus direct Fleet and Doctor routing while
  keeping repair review, confirmation, and proof in the full Doctor window.
- Made navigation and menu status share the same observable state, and made a
  failed refresh invalidate an old green posture instead of hiding stale truth.
- Anchored the command center with a named native status item so its popover
  remains reachable on a crowded or Stow-managed menu bar without moving any
  other app's saved item.

## 0.1.2 — 2026-09-04

- Added Doctor: a native diagnosis and guarded-repair surface for local fleet
  drift, with explicit confirmation and hard-coded product-owned entrypoints.
- Added fresh preflight and postflight snapshots so a successful command is
  never reported as a successful repair without observed installed-state proof.
- Blocked remote repair, dirty checkouts, unknown evidence, unapproved source
  revisions, automatic theme replacement, and implicit baseline changes.

## 0.1.1 — 2026-09-04

- Replaced retired MeshClaw theme inventory with Kiro Crew's managed package,
  signed desktop runtime, and recursive native-theme fingerprint.
- Added component lifecycle handling so older MeshClaw evidence is ignored in
  drift, baseline lookup, and baseline counts.

## 0.1.0 — 2026-09-04

- Added the native macOS fleet dashboard with explicit unknown, stale, drift,
  missing, aligned, and local-work states.
- Added read-only inventory for ai-continuum, AuthBar, Stow, Murmr Voice,
  Model Bridge, Codex Desktop/CLI/Voice, harness-sync, and managed theme sets.
- Added the privacy-bounded JSON fleet protocol, first-run baseline seeding,
  per-machine reports, and malformed-report isolation.
- Added reviewed bootstrap plans that delegate to each product's own installer.
- Added a login/six-hour snapshot LaunchAgent, explicit baseline CLI, source vs
  installed drift, optional component visibility, and per-Mac display names.
