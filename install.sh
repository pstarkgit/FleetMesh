#!/bin/bash
# Build, sign, and transactionally install FleetMesh.app.
set -euo pipefail
cd "$(dirname "$0")"

resolve_developer_dir() {
    local requested="${DEVELOPER_DIR:-}"
    local selected

    if [ -n "$requested" ] && [ -d "$requested" ] \
        && DEVELOPER_DIR="$requested" /usr/bin/xcrun --find swift >/dev/null 2>&1; then
        printf '%s\n' "$requested"
        return 0
    fi

    selected="$(/usr/bin/env -u DEVELOPER_DIR /usr/bin/xcode-select -p 2>/dev/null || true)"
    if [ -n "$selected" ] && [ -d "$selected" ] \
        && DEVELOPER_DIR="$selected" /usr/bin/xcrun --find swift >/dev/null 2>&1; then
        if [ -n "$requested" ] && [ "$requested" != "$selected" ]; then
            echo "WARNING: ignoring invalid DEVELOPER_DIR '$requested'; using '$selected'." >&2
        fi
        printf '%s\n' "$selected"
        return 0
    fi

    echo "ERROR: no valid Apple developer directory was found. Install Xcode or Command Line Tools, then run xcode-select --install." >&2
    return 1
}

DEVELOPER_DIR="$(resolve_developer_dir)"
export DEVELOPER_DIR

if [ "${1:-}" = "--print-developer-dir" ]; then
    printf '%s\n' "$DEVELOPER_DIR"
    exit 0
fi

if [ "${1:-}" != "" ]; then
    echo "ERROR: unsupported argument: $1" >&2
    exit 2
fi

if [ "$(id -u)" -eq 0 ]; then
    echo "ERROR: run ./install.sh as yourself, not as root" >&2
    exit 1
fi

/usr/bin/xcrun swift build -c release

VERSION_FILE="Sources/DeviceSync/DeviceSyncVersion.swift"
VERSION="$(sed -n 's/.*static let current = "\([^"]*\)".*/\1/p' "$VERSION_FILE" | head -1)"
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "ERROR: could not read a semantic version from $VERSION_FILE" >&2
    exit 1
fi

CHANGELOG_HEAD="$(awk '/^## / { print $2; exit }' CHANGELOG.md)"
if [ "$CHANGELOG_HEAD" != "$VERSION" ]; then
    echo "ERROR: CHANGELOG.md starts at '${CHANGELOG_HEAD:-none}', expected $VERSION" >&2
    exit 1
fi

FINAL_APP="/Applications/FleetMesh.app"
FORMER_APP="/Applications/FleetForge.app"
LEGACY_APP="/Applications/Device Sync.app"
LAUNCH_AGENT="$HOME/Library/LaunchAgents/dev.starkpat.devicesync.snapshot.plist"
SNAPSHOT_LOG_DIR="$HOME/Library/Logs/FleetForge"
STAGE_ROOT="$(mktemp -d "/Applications/.device-sync-install.XXXXXX")"
STAGE_APP="$STAGE_ROOT/FleetMesh.app"
BACKUP_FINAL_APP="$STAGE_ROOT/FleetMesh.app.previous"
BACKUP_FORMER_APP="$STAGE_ROOT/FleetForge.app.previous"
BACKUP_LEGACY_APP="$STAGE_ROOT/Device Sync.app.previous"
COMMIT="$(git rev-parse --short HEAD 2>/dev/null || echo dev)"
SOURCE_DIR="$(pwd -P)"
BUILD_DATE="$(date '+%Y-%m-%d %H:%M')"

cleanup() {
    if [ ! -d "$FINAL_APP" ] && [ -d "$BACKUP_FINAL_APP" ]; then
        mv "$BACKUP_FINAL_APP" "$FINAL_APP" 2>/dev/null || true
    fi
    if [ ! -d "$FORMER_APP" ] && [ -d "$BACKUP_FORMER_APP" ]; then
        mv "$BACKUP_FORMER_APP" "$FORMER_APP" 2>/dev/null || true
    fi
    if [ ! -d "$LEGACY_APP" ] && [ -d "$BACKUP_LEGACY_APP" ]; then
        mv "$BACKUP_LEGACY_APP" "$LEGACY_APP" 2>/dev/null || true
    fi
    rm -rf "$STAGE_ROOT"
}
trap cleanup EXIT

device_sync_pids() {
    ps -axo pid=,ucomm= | awk '$2 == "DeviceSync" { print $1 }'
}

device_sync_processes_alive() {
    [ -n "$(device_sync_pids)" ]
}

stop_device_sync_processes() {
    # Stop the scheduled one-shot first so it cannot race the bundle swap.
    launchctl bootout "gui/$(id -u)/dev.starkpat.devicesync.snapshot" \
        2>/dev/null || true

    local pids
    pids="$(device_sync_pids)"
    [ -n "$pids" ] || return 0
    kill $pids 2>/dev/null || true
    for _ in $(seq 1 40); do
        device_sync_processes_alive || return 0
        sleep 0.2
    done
    pids="$(device_sync_pids)"
    [ -z "$pids" ] || kill -9 $pids 2>/dev/null || true
    for _ in $(seq 1 20); do
        device_sync_processes_alive || return 0
        sleep 0.2
    done
    echo "ERROR: FleetMesh processes survived termination; refusing to replace the bundle" >&2
    return 1
}

mkdir -p "$STAGE_APP/Contents/MacOS" "$STAGE_APP/Contents/Resources"
cp .build/release/DeviceSync "$STAGE_APP/Contents/MacOS/DeviceSync"
cp Resources/Info.plist "$STAGE_APP/Contents/Info.plist"
cp CHANGELOG.md "$STAGE_APP/Contents/Resources/CHANGELOG.md"
cp -R Resources/RepairAssets "$STAGE_APP/Contents/Resources/RepairAssets"
cp Resources/dev.starkpat.devicesync.snapshot.plist \
    "$STAGE_APP/Contents/Resources/dev.starkpat.devicesync.snapshot.plist"
if [ -f Resources/AppIcon.icns ]; then
    cp Resources/AppIcon.icns "$STAGE_APP/Contents/Resources/AppIcon.icns"
fi

/usr/libexec/PlistBuddy \
    -c "Set :CFBundleShortVersionString $VERSION" \
    -c "Set :CFBundleVersion $VERSION" \
    -c "Set :DSSourceDir $SOURCE_DIR" \
    -c "Set :DSCommit $COMMIT" \
    -c "Set :DSBuildDate $BUILD_DATE" \
    "$STAGE_APP/Contents/Info.plist"

for key in CFBundleShortVersionString CFBundleVersion; do
    stamped="$(/usr/libexec/PlistBuddy -c "Print :$key" "$STAGE_APP/Contents/Info.plist")"
    if [ "$stamped" != "$VERSION" ]; then
        echo "ERROR: $key stamp is '$stamped', expected '$VERSION'" >&2
        exit 1
    fi
done

IDENTITIES="$(security find-identity -v -p codesigning 2>/dev/null || true)"
DEVELOPER_ID="Developer ID Application: Patrick Stark (P2M5LH6CVA)"
DEVELOPER_ID_HASH="$({
    printf '%s\n' "$IDENTITIES" \
        | awk -v identity="$DEVELOPER_ID" 'index($0, identity) { print $2; exit }'
} || true)"
if [ -n "$DEVELOPER_ID_HASH" ]; then
    codesign --force --deep --options runtime --sign "$DEVELOPER_ID_HASH" "$STAGE_APP"
    SIGNING_LABEL="$DEVELOPER_ID ($DEVELOPER_ID_HASH)"
else
    codesign --force --deep --sign - "$STAGE_APP"
    SIGNING_LABEL="ad-hoc"
fi
codesign --verify --deep --strict "$STAGE_APP"

if [ -d "$FINAL_APP" ] || [ -d "$FORMER_APP" ] || [ -d "$LEGACY_APP" ]; then
    stop_device_sync_processes
fi
if [ -d "$FINAL_APP" ]; then
    mv "$FINAL_APP" "$BACKUP_FINAL_APP"
fi
if [ -d "$FORMER_APP" ]; then
    mv "$FORMER_APP" "$BACKUP_FORMER_APP"
fi
if [ -d "$LEGACY_APP" ]; then
    mv "$LEGACY_APP" "$BACKUP_LEGACY_APP"
fi

mv "$STAGE_APP" "$FINAL_APP"
if ! "$FINAL_APP/Contents/MacOS/DeviceSync" --self-check; then
    rm -rf "$FINAL_APP"
    if [ -d "$BACKUP_FINAL_APP" ]; then mv "$BACKUP_FINAL_APP" "$FINAL_APP"; fi
    if [ -d "$BACKUP_FORMER_APP" ]; then mv "$BACKUP_FORMER_APP" "$FORMER_APP"; fi
    if [ -d "$BACKUP_LEGACY_APP" ]; then mv "$BACKUP_LEGACY_APP" "$LEGACY_APP"; fi
    echo "ERROR: installed FleetMesh failed its check; previous app restored" >&2
    exit 1
fi

rm -rf "$BACKUP_FINAL_APP" "$BACKUP_FORMER_APP" "$BACKUP_LEGACY_APP"

mkdir -p "$HOME/Library/LaunchAgents" "$SNAPSHOT_LOG_DIR"
SNAPSHOT_STDOUT="$SNAPSHOT_LOG_DIR/snapshot.out.log"
SNAPSHOT_STDERR="$SNAPSHOT_LOG_DIR/snapshot.err.log"
cp "$FINAL_APP/Contents/Resources/dev.starkpat.devicesync.snapshot.plist" "$LAUNCH_AGENT"
/usr/libexec/PlistBuddy \
    -c "Set :StandardOutPath $SNAPSHOT_STDOUT" \
    -c "Set :StandardErrorPath $SNAPSHOT_STDERR" \
    "$LAUNCH_AGENT"
chmod 600 "$LAUNCH_AGENT"
launchctl bootstrap "gui/$(id -u)" "$LAUNCH_AGENT"

open -n "$FINAL_APP"
sleep 2
if ! ps -axo ucomm= | awk '{$1=$1} $0 == "DeviceSync" { found=1 } END { exit !found }'; then
    echo "ERROR: FleetMesh did not remain running after launch" >&2
    exit 1
fi

echo "Installed FleetMesh $VERSION ($COMMIT) with $SIGNING_LABEL"
