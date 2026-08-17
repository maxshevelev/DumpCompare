#!/bin/bash
# Renders the app icon master and slices it into the asset catalog.
# Usage: Design/render-appicon.sh   (from the repository root)
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
set="$root/DumpCompareApp/Assets.xcassets/AppIcon.appiconset"
master="$(mktemp -t appicon).png"
trap 'rm -f "$master"' EXIT

swift "$root/Design/AppIcon.swift" "$master"

# Every size is downsampled from the 1024 master rather than drawn at its own
# size: sips' resampling is smoother than the type rendering at 16 pt would be.
render() { sips -Z "$1" --out "$set/$2" "$master" >/dev/null; }
render 16   icon_16x16.png
render 32   icon_16x16@2x.png
render 32   icon_32x32.png
render 64   icon_32x32@2x.png
render 128  icon_128x128.png
render 256  icon_128x128@2x.png
render 256  icon_256x256.png
render 512  icon_256x256@2x.png
render 512  icon_512x512.png
cp "$master" "$set/icon_512x512@2x.png"

echo "wrote 10 images into ${set#$root/}"
