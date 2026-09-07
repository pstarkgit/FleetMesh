#!/bin/bash
# Signed FleetMesh resource. Installs only a previously verified prebuilt app.
set -euo pipefail

if [ "$#" -ne 7 ]; then
    echo "ERROR: expected staged app, version, commit, architecture, parent PID, and work root" >&2
    exit 2
fi

APP="$1"
EXPECTED_VERSION="$2"
EXPECTED_COMMIT="$3"
EXPECTED_ARCH="$4"
PARENT_PID="$5"
WORK_ROOT="$6"
# Seventh argument is reserved for the release schema version.
EXPECTED_SCHEMA="$7"
FINAL_APP="/Applications/FleetMesh.app"
TEAM_ID="P2M5LH6CVA"
BUNDLE_ID="dev.starkpat.devicesync"
REPOSITORY="https://github.com/pstarkgit/FleetMesh"
LAUNCH_AGENT="$HOME/Library/LaunchAgents/dev.starkpat.devicesync.snapshot.plist"
LOG_DIR="$HOME/Library/Logs/FleetForge"

fail() { echo "ERROR: $*" >&2; exit 1; }

[ "$(id -u)" -ne 0 ] || fail "run the update as the signed-in user, not root"
[[ "$EXPECTED_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "invalid expected version"
[[ "$EXPECTED_COMMIT" =~ ^[0-9a-f]{40}$ ]] || fail "invalid expected commit"
[ "$EXPECTED_ARCH" = "arm64" ] || fail "unsupported architecture"
[[ "$PARENT_PID" =~ ^[0-9]+$ ]] || fail "invalid parent PID"
[ "$EXPECTED_SCHEMA" = "1" ] || fail "unsupported release schema"

CACHE_ROOT="$HOME/Library/Caches/FleetMesh/Updates"
case "$WORK_ROOT" in
    "$CACHE_ROOT"/*) ;;
    *) fail "work root is outside FleetMesh's private update cache" ;;
esac
[ "$APP" = "$WORK_ROOT/extracted/FleetMesh.app" ] || fail "staged app path does not match the verified extraction root"
[ -d "$APP" ] || fail "staged FleetMesh.app is missing"
[ ! -L "$APP" ] || fail "staged FleetMesh.app cannot be a symlink"

verify_app() {
    local candidate="$1"
    /usr/bin/codesign --verify --deep --strict --verbose=2 "$candidate"
    local signature
    signature="$(/usr/bin/codesign -dv --verbose=4 "$candidate" 2>&1 || true)"
    case "$signature" in *"Authority=Developer ID Application: Patrick Stark (P2M5LH6CVA)"*) ;; *) fail "untrusted Developer ID authority" ;; esac
    case "$signature" in *"TeamIdentifier=$TEAM_ID"*) ;; *) fail "untrusted TeamIdentifier" ;; esac
    case "$signature" in *"flags=0x10000(runtime)"*) ;; *) fail "hardened runtime is missing" ;; esac
    case "$signature" in *"Timestamp="*) ;; *) fail "secure signing timestamp is missing" ;; esac
    /usr/sbin/spctl --assess --type execute --verbose=2 "$candidate"
    /usr/bin/xcrun stapler validate "$candidate"

    local plist="$candidate/Contents/Info.plist"
    [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$plist")" = "$BUNDLE_ID" ] || fail "bundle identifier mismatch"
    [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist")" = "$EXPECTED_VERSION" ] || fail "version mismatch"
    [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$plist")" = "$EXPECTED_VERSION" ] || fail "build version mismatch"
    [ "$(/usr/libexec/PlistBuddy -c 'Print :DSCommit' "$plist")" = "$EXPECTED_COMMIT" ] || fail "commit mismatch"
    [ "$(/usr/libexec/PlistBuddy -c 'Print :DSArchitecture' "$plist")" = "$EXPECTED_ARCH" ] || fail "architecture stamp mismatch"
    [ "$(/usr/libexec/PlistBuddy -c 'Print :DSReleaseRepository' "$plist")" = "$REPOSITORY" ] || fail "repository provenance mismatch"
    [ "$(/usr/bin/lipo -archs "$candidate/Contents/MacOS/DeviceSync")" = "$EXPECTED_ARCH" ] || fail "binary architecture mismatch"
}

mkdir -p "$LOG_DIR"
chmod 700 "$LOG_DIR"
exec >>"$LOG_DIR/update.log" 2>&1
chmod 600 "$LOG_DIR/update.log"
echo "FleetMesh prebuilt install started $(date -u '+%Y-%m-%dT%H:%M:%SZ') version=$EXPECTED_VERSION commit=$EXPECTED_COMMIT"

verify_app "$APP"

# The old app requests normal termination immediately after spawning this helper.
for _ in $(seq 1 200); do
    if ! kill -0 "$PARENT_PID" 2>/dev/null; then break; fi
    sleep 0.1
done
if kill -0 "$PARENT_PID" 2>/dev/null; then
    fail "the prior FleetMesh process did not exit; no bundle was changed"
fi

launchctl bootout "gui/$(id -u)/dev.starkpat.devicesync.snapshot" 2>/dev/null || true
INSTALL_ROOT="$(mktemp -d /Applications/.fleetmesh-prebuilt.XXXXXX)"
BACKUP_APP="$INSTALL_ROOT/FleetMesh.app.previous"
installed=false
rollback() {
    if [ "$installed" = true ] && [ -d "$FINAL_APP" ]; then
        rm -rf "$FINAL_APP"
    fi
    if [ -d "$BACKUP_APP" ] && [ ! -d "$FINAL_APP" ]; then
        mv "$BACKUP_APP" "$FINAL_APP" || true
    fi
    rm -rf "$INSTALL_ROOT"
}
trap rollback EXIT

if [ -d "$FINAL_APP" ]; then
    mv "$FINAL_APP" "$BACKUP_APP"
fi
mv "$APP" "$FINAL_APP"
installed=true

verify_app "$FINAL_APP"
if ! "$FINAL_APP/Contents/MacOS/DeviceSync" --self-check; then
    fail "new app failed self-check; restoring the previous bundle"
fi

mkdir -p "$HOME/Library/LaunchAgents" "$LOG_DIR"
cp "$FINAL_APP/Contents/Resources/dev.starkpat.devicesync.snapshot.plist" "$LAUNCH_AGENT"
/usr/libexec/PlistBuddy -c "Set :StandardOutPath $LOG_DIR/snapshot.out.log" "$LAUNCH_AGENT"
/usr/libexec/PlistBuddy -c "Set :StandardErrorPath $LOG_DIR/snapshot.err.log" "$LAUNCH_AGENT"
launchctl bootstrap "gui/$(id -u)" "$LAUNCH_AGENT" 2>/dev/null || \
    launchctl kickstart -k "gui/$(id -u)/dev.starkpat.devicesync.snapshot" 2>/dev/null || true

rm -rf "$BACKUP_APP"
installed=false
rm -rf "$INSTALL_ROOT"
trap - EXIT
rm -rf "$WORK_ROOT"
/usr/bin/open "$FINAL_APP"
echo "FleetMesh $EXPECTED_VERSION prebuilt install completed"
