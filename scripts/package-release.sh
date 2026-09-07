#!/bin/bash
# Build one trusted FleetMesh release artifact for all receiving Macs.
set -euo pipefail
cd "$(dirname "$0")/.."

DEVID="Developer ID Application: Patrick Stark (P2M5LH6CVA)"
NOTARY_PROFILE="${FLEETMESH_NOTARY_PROFILE:-AuthBar}"
VERSION="$(sed -n 's/.*static let current = "\([^"]*\)".*/\1/p' Sources/DeviceSync/DeviceSyncVersion.swift | head -1)"
COMMIT="$(git rev-parse HEAD)"
ARCHITECTURE="$(uname -m)"
TAG="v$VERSION"
ARCHIVE="FleetMesh-$VERSION-$ARCHITECTURE.zip"
MANIFEST="FleetMesh-$VERSION-$ARCHITECTURE.json"
SBOM="FleetMesh-$VERSION-$ARCHITECTURE.sbom.json"
DIST="$(pwd -P)/dist/$TAG"
APP="$DIST/FleetMesh.app"

[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "ERROR: invalid version" >&2; exit 1; }
[[ "$COMMIT" =~ ^[0-9a-f]{40}$ ]] || { echo "ERROR: invalid commit" >&2; exit 1; }
[ "$ARCHITECTURE" = "arm64" ] || { echo "ERROR: unsupported release architecture $ARCHITECTURE" >&2; exit 1; }
[ -z "$(git status --porcelain)" ] || { echo "ERROR: release checkout must be clean" >&2; exit 1; }
[ ! -e "$DIST" ] || { echo "ERROR: release output already exists: $DIST" >&2; exit 1; }
mkdir -p "$DIST"
trap 'rm -rf "$DIST"' ERR

IDENTITIES="$(security find-identity -v -p codesigning 2>/dev/null || true)"
DEVID_HASH="$(printf '%s\n' "$IDENTITIES" | awk -v identity="$DEVID" 'index($0, identity) { print $2; exit }')"
[ -n "$DEVID_HASH" ] || { echo "ERROR: Developer ID identity is unavailable" >&2; exit 1; }
xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 || {
    echo "ERROR: notarytool profile '$NOTARY_PROFILE' is unavailable" >&2
    exit 1
}

./install.sh --build-app "$APP"
/usr/bin/codesign --force --deep --options runtime --timestamp --sign "$DEVID_HASH" "$APP"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP"
SIGINFO="$(/usr/bin/codesign -dv --verbose=4 "$APP" 2>&1 || true)"
case "$SIGINFO" in *"Authority=$DEVID"*) ;; *) echo "ERROR: Developer ID authority missing" >&2; exit 1 ;; esac
case "$SIGINFO" in *"TeamIdentifier=P2M5LH6CVA"*) ;; *) echo "ERROR: TeamIdentifier mismatch" >&2; exit 1 ;; esac
case "$SIGINFO" in *"flags=0x10000(runtime)"*) ;; *) echo "ERROR: hardened runtime missing" >&2; exit 1 ;; esac
case "$SIGINFO" in *"Timestamp="*) ;; *) echo "ERROR: secure timestamp missing" >&2; exit 1 ;; esac

SUBMISSION_ZIP="$DIST/.notary-submission.zip"
/usr/bin/ditto -c -k --keepParent "$APP" "$SUBMISSION_ZIP"
xcrun notarytool submit "$SUBMISSION_ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
rm -f "$SUBMISSION_ZIP"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
/usr/sbin/spctl --assess --type execute --verbose=2 "$APP"

/usr/bin/ditto -c -k --keepParent "$APP" "$DIST/$ARCHIVE"
ARCHIVE_SHA="$(/usr/bin/shasum -a 256 "$DIST/$ARCHIVE" | awk '{print $1}')"
ARCHIVE_SIZE="$(/usr/bin/stat -f%z "$DIST/$ARCHIVE")"

/usr/bin/python3 - "$VERSION" "$COMMIT" "$ARCHITECTURE" "$ARCHIVE" "$ARCHIVE_SHA" "$ARCHIVE_SIZE" "$DIST/$SBOM" <<'PY'
import json, pathlib, sys
version, commit, architecture, archive, digest, size, output = sys.argv[1:]
resolved = json.loads(pathlib.Path("Package.resolved").read_text())
components = []
for pin in resolved.get("pins", []):
    state = pin.get("state", {})
    components.append({
        "type": "library",
        "name": pin.get("identity", "unknown"),
        "version": state.get("version") or state.get("revision", "unknown"),
        "purl": f"pkg:github/{pin.get('location','').removeprefix('https://github.com/').removesuffix('.git')}@{state.get('version') or state.get('revision','unknown')}",
    })
sbom = {
    "bomFormat": "CycloneDX",
    "specVersion": "1.5",
    "version": 1,
    "metadata": {"component": {"type": "application", "name": "FleetMesh", "version": version}},
    "components": components,
    "properties": [
        {"name": "fleetmesh:commit", "value": commit},
        {"name": "fleetmesh:architecture", "value": architecture},
        {"name": "fleetmesh:archive", "value": archive},
        {"name": "fleetmesh:archive-sha256", "value": digest},
        {"name": "fleetmesh:archive-size", "value": size},
    ],
}
pathlib.Path(output).write_text(json.dumps(sbom, sort_keys=True, indent=2) + "\n")
PY
SBOM_SHA="$(/usr/bin/shasum -a 256 "$DIST/$SBOM" | awk '{print $1}')"

/usr/bin/python3 - "$VERSION" "$COMMIT" "$ARCHITECTURE" "$ARCHIVE" "$ARCHIVE_SHA" "$ARCHIVE_SIZE" "$SBOM" "$SBOM_SHA" "$DIST/$MANIFEST" <<'PY'
import json, pathlib, sys
version, commit, architecture, archive, digest, size, sbom, sbom_digest, output = sys.argv[1:]
manifest = {
    "schemaVersion": 1,
    "product": "FleetMesh",
    "version": version,
    "commit": commit,
    "architecture": architecture,
    "bundleIdentifier": "dev.starkpat.devicesync",
    "teamIdentifier": "P2M5LH6CVA",
    "archiveName": archive,
    "archiveSHA256": digest,
    "archiveSize": int(size),
}
pathlib.Path(output).write_text(json.dumps(manifest, sort_keys=True, indent=2) + "\n")
PY

VERIFY="$DIST/verify"
mkdir "$VERIFY"
/usr/bin/ditto -x -k "$DIST/$ARCHIVE" "$VERIFY"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$VERIFY/FleetMesh.app"
xcrun stapler validate "$VERIFY/FleetMesh.app"
/usr/sbin/spctl --assess --type execute --verbose=2 "$VERIFY/FleetMesh.app"
[ "$(/usr/libexec/PlistBuddy -c 'Print :DSCommit' "$VERIFY/FleetMesh.app/Contents/Info.plist")" = "$COMMIT" ]
[ "$(/usr/libexec/PlistBuddy -c 'Print :DSArchitecture' "$VERIFY/FleetMesh.app/Contents/Info.plist")" = "$ARCHITECTURE" ]
rm -rf "$VERIFY" "$APP"
trap - ERR

echo "Release ready: $DIST"
echo "  $ARCHIVE ($ARCHIVE_SIZE bytes, sha256 $ARCHIVE_SHA)"
echo "  $MANIFEST"
echo "  $SBOM (sha256 $SBOM_SHA)"
