#!/bin/bash
# Builds "F1 25 Mod Launcher.app" into ./build (needs Xcode or the Xcode Command Line Tools).
# Run the engine tests with:  ./build.sh test
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build

ENGINE="Sources/Core.swift Sources/ERP.swift Sources/Zstd.swift Sources/Textures.swift Sources/GameIndex.swift"

if [[ "${1:-}" == "test" ]]; then
  swiftc -O -swift-version 5 $ENGINE Tests/main.swift -o build/core-tests
  exec build/core-tests "$(mktemp -d)" "${@:2}"
fi

APP="build/F1 25 Mod Launcher.app"
rm -rf "$APP" build/icon
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" build/icon/AppIcon.iconset

echo "Compiling…"
for arch in arm64 x86_64; do
  swiftc -O -swift-version 5 -parse-as-library -target "$arch-apple-macos14.0" \
    $ENGINE Sources/App.swift -o "build/F1ModLauncher-$arch"
done
lipo -create build/F1ModLauncher-arm64 build/F1ModLauncher-x86_64 -output "$APP/Contents/MacOS/F1ModLauncher"
rm build/F1ModLauncher-arm64 build/F1ModLauncher-x86_64

echo "Drawing the icon…"
swiftc -O Tools/make_icon.swift -o build/icon/make_icon
build/icon/make_icon build/icon/icon_1024.png
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" build/icon/icon_1024.png --out "build/icon/AppIcon.iconset/icon_${size}x${size}.png" >/dev/null
  sips -z $((size * 2)) $((size * 2)) build/icon/icon_1024.png --out "build/icon/AppIcon.iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns build/icon/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"

cp Resources/Info.plist "$APP/Contents/Info.plist"
cp LICENSE "$APP/Contents/Resources/LICENSE.txt"
codesign --force --sign - "$APP" >/dev/null
echo "Built $APP"
