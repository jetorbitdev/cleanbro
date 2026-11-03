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

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/CleanBro"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>CleanBro</string>
  <key>CFBundleDisplayName</key><string>CleanBro</string>
  <key>CFBundleIdentifier</key><string>com.jetorbit.cleanbro</string>
  <key>CFBundleExecutable</key><string>CleanBro</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>CFBundleDevelopmentRegion</key><string>id</string>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP" >/dev/null

# Zip untuk dibagikan; ditto menjaga permission & signature bundle
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

echo "✅ $PWD/$APP"
echo "📦 $PWD/$ZIP"
