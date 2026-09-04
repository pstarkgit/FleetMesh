# Changelog

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
