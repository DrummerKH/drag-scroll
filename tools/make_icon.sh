#!/bin/bash
# Regenerates DragScroll/AppIcon.icns from tools/make_icon.m.
set -euo pipefail
cd "$(dirname "$0")/.."

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

clang -fobjc-arc -fmodules -framework Cocoa tools/make_icon.m -o "$WORK/make_icon"
"$WORK/make_icon" "$WORK/icon_1024.png"

mkdir -p "$WORK/AppIcon.iconset"
gen() { sips -z "$1" "$1" "$WORK/icon_1024.png" --out "$WORK/AppIcon.iconset/$2" >/dev/null; }
gen 16   icon_16x16.png
gen 32   icon_16x16@2x.png
gen 32   icon_32x32.png
gen 64   icon_32x32@2x.png
gen 128  icon_128x128.png
gen 256  icon_128x128@2x.png
gen 256  icon_256x256.png
gen 512  icon_256x256@2x.png
gen 512  icon_512x512.png
cp "$WORK/icon_1024.png" "$WORK/AppIcon.iconset/icon_512x512@2x.png"

iconutil -c icns "$WORK/AppIcon.iconset" -o DragScroll/AppIcon.icns
echo "Wrote DragScroll/AppIcon.icns"
