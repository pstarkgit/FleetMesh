# Changelog

## 0.1.10 — 2026-09-05

- Made fleet software posture version-first. Installed version, product-owned
  latest-version evidence, and runtime state determine health; developer branch,
  dirtiness, source revision, and installed/source commit equality do not.
- Added Murmr Voice's signed Sparkle appcast as its authoritative latest-stable
  check. Installed `0.2.36` is aligned when the feed reports `0.2.36`, regardless
  of an unrelated older local checkout.
- Moved software-checkout inspection behind explicit Doctor repair preflight.
  Dirty, changed, or older source still blocks a requested source installer, but
  it no longer creates fleet drift or attention on its own.
- Stopped routine local and Linux software inventory from reading Git checkouts,
  and stripped Doctor-only software checkout fields from shared machine JSON.
- Kept exact configuration and theme fingerprints as explicit baseline state.
  Failed product update checks remain Unknown rather than being reported healthy.

## 0.1.9 — 2026-09-05

- Made managed-software cards clickable. Each card expands in place with its
  one safe next action: guarded Doctor repair or local-checkout review. Healthy
  software has no mutation action.
- Removed manual software promotion. FleetMesh now accepts software newer than
  an older recorded minimum automatically and offers repair only when software
  is behind a verified target or its deployment evidence is inconsistent.
- Let clean product checkouts advertise a newer update target before that build
  is installed, while preventing an older checkout from running an installer
  that could downgrade a newer installed app.
- Preserved dirty checkouts with review-only navigation; FleetMesh does not
  pull, reset, overwrite, or convert local work into desired state.
- Promoted product-installer failure output into the inline result and expanded
  it automatically on failure. Administrator language appears only when the
  captured output proves a permission or authorization failure; FleetMesh does
  not rerun an installer as root when that product forbids it.
- Fixed repository targeting across GitHub merge commits by proving installed
  and source revisions resolve to the same immutable Git tree. Equal versions
  with different trees remain drift.
- Added a persistent `FleetMesh 0.1.9` build identity at the bottom of the
  sidebar, with exact installed commit metadata available through Help and
  accessibility.

## 0.1.8 — 2026-09-05

- Added a first-class new-Mac join journey: FleetMesh validates an existing
  shared manifest, previews this Mac as Pending, requires explicit enrollment,
  and routes successful joins to Bootstrap without installing or repairing
  anything automatically.
- Removed implicit baseline creation from startup, scheduled scans, and
  headless checks. A partially synced OneDrive folder can no longer make a new
  Mac replace fleet authority; creating a fleet remains an explicit baseline
  action.
- Added read-only repository target evidence from each product's committed
  version source (`HEAD`, never working-tree content). A fresh, clean installed
  build on this Mac must prove the same version and revision; synced reports
  never become target authority.
- Kept `fleet-manifest.json` as the explicit scope and configuration authority:
  repository tracking does not rewrite its revision, target list, or theme
  fingerprints during refresh.
- Labeled software cards as `Latest repo` when verified repository evidence is
  available and `Saved baseline` when it is not, so target provenance is visible.

## 0.1.7 — 2026-09-04

- Added the cross-platform device model for macOS and Linux devices, with
  workstation, server, and cloud-desktop roles plus explicit capability tracking
  for GUI, Mac apps, menu bar, launchd, systemd, shell, and config files.
- Upgraded the desired-state manifest to schema v2 with explicit device
  enrollment, removal, role assignment, and per-device Inherit/Required/Excluded
  item policy while preserving snapshot schema v1 through additive platform and
  capability fields.
- Added local-only Linux SSH check-in: endpoints stay in this controller Mac's
  legacy Application Support state, shared JSON receives only redacted evidence,
  and the probe uses a fixed bounded read-only script through the user's existing
  SSH config and agent.
- Kept Doctor local-only and evidence-gated: remote devices can check in, but
  repairs remain explicit local actions backed by product-owned entrypoints and
  postflight snapshots.
- Made Codex Voice observable but outside the managed daily baseline so it does
  not create normal posture, Bootstrap, or Doctor work.
- Reaffirmed Kiro Crew as the active managed agent product and MeshClaw as
  retired compatibility evidence that readers ignore.
- Documented menu-bar/full-app reliability: closing the singleton window keeps
  FleetMesh alive in the menu bar, and Dock/menu actions reopen the same live
  app state.
- Added a persisted System/Light/Dark appearance control shared by the full app
  and menu-bar command center, with a dark Aurora evidence canvas.
- Reworked the 19-point menu-bar mark for crowded real-world bars: a full-size
  white-core Aurora bridge replaces the dim glyph and overlapping status badge.
- Added a reversible local Hide action for unwanted Available discoveries, plus
  a collapsed Hidden items section for restoring them without changing shared
  fleet scope, inventory evidence, or installed software.
- Preserved all legacy compatibility identifiers, including
  `dev.starkpat.devicesync`, `DeviceSync`, `device-sync`,
  `deviceSyncVersion`, the `Device Sync` folders, LaunchAgent label, and
  status-item autosave name.

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
