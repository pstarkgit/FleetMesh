#!/bin/bash
# Render the canonical FleetMesh SVG into a complete macOS .icns family.
set -euo pipefail
cd "$(dirname "$0")/.."

SOURCE="Resources/FleetMeshMark.svg"
OUTPUT="Resources/AppIcon.icns"
RENDERER="${RSVG_CONVERT:-/opt/homebrew/bin/rsvg-convert}"

if [ ! -x "$RENDERER" ]; then
    echo "ERROR: rsvg-convert is required at $RENDERER" >&2
    exit 1
fi

ICON_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/fleetmesh-icon.XXXXXX")"
ICONSET="$ICON_ROOT/AppIcon.iconset"
mkdir -p "$ICONSET"

cleanup() {
    rm -rf "$ICON_ROOT"
}
trap cleanup EXIT

render() {
    local pixels="$1"
    local filename="$2"
    "$RENDERER" --width "$pixels" --height "$pixels" "$SOURCE" > "$ICONSET/$filename"
}

render 16 icon_16x16.png
render 32 icon_16x16@2x.png
render 32 icon_32x32.png
render 64 icon_32x32@2x.png
render 128 icon_128x128.png
render 256 icon_128x128@2x.png
render 256 icon_256x256.png
render 512 icon_256x256@2x.png
render 512 icon_512x512.png
render 1024 icon_512x512@2x.png

iconutil -c icns "$ICONSET" -o "$OUTPUT"
echo "Rendered $OUTPUT from $SOURCE"
