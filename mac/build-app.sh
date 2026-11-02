#!/bin/bash
# Builds "Transform To.app" (Apple Silicon + Intel) and a zip of it into mac/dist/.
# Needs Xcode (free from the App Store) or at least the Command Line Tools:  xcode-select --install
set -euo pipefail
cd "$(dirname "$0")"

APP="dist/Transform To.app"
rm -rf dist
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# Universal binary when the full Xcode is installed; plain native build with only the Command Line Tools.
if swift build -c release --arch arm64 --arch x86_64 >/dev/null 2>&1; then
  BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/TransformTo"
else
  swift build -c release
  BIN="$(swift build -c release --show-bin-path)/TransformTo"
fi
cp "$BIN" "$APP/Contents/MacOS/TransformTo"
cp Info.plist "$APP/Contents/Info.plist"

# App icon from the shared 1024 px PNG.
ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
  sips -z $size $size ../assets/icon-1024.png --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  sips -z $((size * 2)) $((size * 2)) ../assets/icon-1024.png --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

# Ad-hoc signature: free, no Apple Developer account needed. Enough to run on Apple Silicon.
codesign --force --deep --sign - "$APP"

(cd dist && ditto -c -k --keepParent "Transform To.app" "TransformTo-mac.zip")
echo "Built mac/$APP and mac/dist/TransformTo-mac.zip"
echo "Install: drag \"Transform To.app\" into /Applications and open it once."
