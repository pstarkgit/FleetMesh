#!/bin/bash
# Build, sign, and transactionally install Device Sync.app.
set -euo pipefail
cd "$(dirname "$0")"

if [ "$(id -u)" -eq 0 ]; then
    echo "ERROR: run ./install.sh as yourself, not as root" >&2
    exit 1
fi

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
swift build -c release

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

FINAL_APP="/Applications/Device Sync.app"
LAUNCH_AGENT="$HOME/Library/LaunchAgents/dev.starkpat.devicesync.snapshot.plist"
SNAPSHOT_LOG_DIR="$HOME/Library/Logs/Device Sync"
STAGE_ROOT="$(mktemp -d "/Applications/.device-sync-install.XXXXXX")"
STAGE_APP="$STAGE_ROOT/Device Sync.app"
BACKUP_APP="$STAGE_ROOT/Device Sync.app.previous"
COMMIT="$(git rev-parse --short HEAD 2>/dev/null || echo dev)"
BUILD_DATE="$(date '+%Y-%m-%d %H:%M')"

cleanup() {
    if [ ! -d "$FINAL_APP" ] && [ -d "$BACKUP_APP" ]; then
        mv "$BACKUP_APP" "$FINAL_APP" 2>/dev/null || true
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
    echo "ERROR: Device Sync processes survived termination; refusing to replace the bundle" >&2
    return 1
}

mkdir -p "$STAGE_APP/Contents/MacOS" "$STAGE_APP/Contents/Resources"
cp .build/release/DeviceSync "$STAGE_APP/Contents/MacOS/DeviceSync"
cp Resources/Info.plist "$STAGE_APP/Contents/Info.plist"
cp CHANGELOG.md "$STAGE_APP/Contents/Resources/CHANGELOG.md"
cp Resources/dev.starkpat.devicesync.snapshot.plist \
    "$STAGE_APP/Contents/Resources/dev.starkpat.devicesync.snapshot.plist"
if [ -f Resources/AppIcon.icns ]; then
    cp Resources/AppIcon.icns "$STAGE_APP/Contents/Resources/AppIcon.icns"
fi

/usr/libexec/PlistBuddy \
    -c "Set :CFBundleShortVersionString $VERSION" \
    -c "Set :CFBundleVersion $VERSION" \
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

if [ -d "$FINAL_APP" ]; then
    stop_device_sync_processes
    mv "$FINAL_APP" "$BACKUP_APP"
fi

mv "$STAGE_APP" "$FINAL_APP"
if ! "$FINAL_APP/Contents/MacOS/DeviceSync" --check; then
    rm -rf "$FINAL_APP"
    if [ -d "$BACKUP_APP" ]; then mv "$BACKUP_APP" "$FINAL_APP"; fi
    echo "ERROR: installed Device Sync failed its check; previous app restored" >&2
    exit 1
fi

rm -rf "$BACKUP_APP"

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
    echo "ERROR: Device Sync did not remain running after launch" >&2
    exit 1
fi

echo "Installed Device Sync $VERSION ($COMMIT) with $SIGNING_LABEL"
