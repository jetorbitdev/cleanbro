#!/bin/zsh
# Builds CleanBro.app (release) into ./build
set -euo pipefail
cd "$(dirname "$0")"

# Universal binary: jalan di Apple Silicon dan Intel
ARCHS=(--arch arm64 --arch x86_64)
swift build -c release $ARCHS
BIN="$(swift build -c release $ARCHS --show-bin-path)/CleanBro"
APP="build/CleanBro.app"
ZIP="build/CleanBro.zip"
# Bisa di-override dari CI, mis. VERSION=1.2.0 BUILD_NUMBER=42 ./build.sh
VERSION="${VERSION:-1.0}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/CleanBro"
cp Icon/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>CleanBro</string>
  <key>CFBundleDisplayName</key><string>CleanBro</string>
  <key>CFBundleIdentifier</key><string>com.jetorbit.cleanbro</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleExecutable</key><string>CleanBro</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>CFBundleDevelopmentRegion</key><string>id</string>
</dict>
</plist>
PLIST

# Buang xattr lokal (mis. com.apple.provenance) sebelum sign
xattr -cr "$APP"
codesign --force --sign - "$APP" >/dev/null

# Zip untuk dibagikan; ditto menjaga permission & signature bundle.
# --norsrc/--noextattr: jangan ikutkan file ._* (AppleDouble) yang merusak
# signature kalau zip diekstrak dengan tool selain Archive Utility.
rm -f "$ZIP"
ditto -c -k --norsrc --noextattr --keepParent "$APP" "$ZIP"

echo "✅ $PWD/$APP"
echo "📦 $PWD/$ZIP"
