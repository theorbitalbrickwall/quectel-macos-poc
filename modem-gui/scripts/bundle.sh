#!/bin/sh
# SPDX-License-Identifier: CC0-1.0
# Build QuectelMenu.app and QuectelDebug.app into modem-gui/build.
# Usage: scripts/bundle.sh          build both apps
#        scripts/bundle.sh --zip    also pack them into build/QuectelApps.zip
# The apps are signed ad hoc (no Apple developer account) and built for the
# architecture of this Mac only.
set -eu
cd "$(dirname "$0")/.."

VERSION=0.1.0
BUILD=1
OUT=build

swift build -c release
BIN=$(swift build -c release --show-bin-path)

# bundle EXECUTABLE DISPLAY_NAME BUNDLE_ID ICON_STYLE MENU_BAR_ONLY
bundle() {
    app="$OUT/$1.app"
    rm -rf "$app"
    mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
    cp "$BIN/$1" "$app/Contents/MacOS/$1"

    swift scripts/make-icon.swift "$OUT/$1.iconset" "$4"
    iconutil -c icns -o "$app/Contents/Resources/AppIcon.icns" "$OUT/$1.iconset"
    rm -rf "$OUT/$1.iconset"

    cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>$1</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>$3</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>$2</string>
    <key>CFBundleDisplayName</key>
    <string>$2</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>$BUILD</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <$5/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
</dict>
</plist>
PLIST
    plutil -lint "$app/Contents/Info.plist" >/dev/null
    codesign --force --sign - "$app"
    codesign --verify --strict "$app"
    echo "Built $PWD/$app"
}

mkdir -p "$OUT"
bundle QuectelMenu "Quectel Menu" space.linuxgemini.quectel-menu light true
bundle QuectelDebug "Quectel Debug" space.linuxgemini.quectel-debug dark false

if [ "${1:-}" = --zip ]; then
    rm -f "$OUT/QuectelApps.zip"
    (cd "$OUT" && zip -qry QuectelApps.zip QuectelMenu.app QuectelDebug.app)
    echo "Packed $PWD/$OUT/QuectelApps.zip"
fi
