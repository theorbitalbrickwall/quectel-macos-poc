#!/bin/sh
# SPDX-License-Identifier: CC0-1.0
# Build QuectelMenu.app and QuectelDebug.app into modem-gui/build.
# Usage: scripts/bundle.sh          build both apps
#        scripts/bundle.sh --dmg    also pack them into build/QuectelApps.dmg,
#                                   a disk image with a link to Applications
#        DEVELOPMENT_TEAM=XXXXXXXXXX scripts/bundle.sh --dmg
#                                   sign with a certificate of that team
#        SIGN_IDENTITY="Developer ID Application: ..." scripts/bundle.sh
#                                   sign with exactly this certificate
#        NOTARY_PROFILE=name ...    with --dmg: also notarise the apps and
#                                   the disk image, with a profile from
#                                   `notarytool store-credentials`
#        NOTARY_KEY=AuthKey.p8 NOTARY_KEY_ID=... NOTARY_ISSUER=... ...
#                                   the same with an App Store Connect API
#                                   key instead of a profile
#        VERSION=1.2.3 BUILD=45 ... version numbers of the apps
#        ARCHS="arm64 x86_64" ...   universal apps (needs Xcode, not only the
#                                   command line tools)
# Without a team or identity the apps are signed ad hoc (no Apple developer
# account). Without ARCHS they are built for the architecture of this Mac.
set -eu
cd "$(dirname "$0")/.."

VERSION=${VERSION:-0.1.0}
BUILD=${BUILD:-1}
OUT=build

# How notarytool logs in: a keychain profile or an App Store Connect API key.
if [ -n "${NOTARY_PROFILE:-}" ]; then
    NOTARY=profile
elif [ -n "${NOTARY_KEY:-}" ]; then
    : "${NOTARY_KEY_ID:?NOTARY_KEY also needs NOTARY_KEY_ID}"
    : "${NOTARY_ISSUER:?NOTARY_KEY also needs NOTARY_ISSUER}"
    NOTARY=key
else
    NOTARY=
fi

# The code signing certificates in the keychain, one "HASH NAME" per line.
identities() {
    security find-identity -v -p codesigning |
        sed -n 's/^ *[0-9]*) \([0-9A-F]\{40\}\) "\(.*\)"$/\1 \2/p'
}

# Print the hash of the first certificate of the team whose name starts with
# $1. The team is the OU field of the certificate; the text in brackets in
# the name is the team only for Developer ID certificates.
team_identity() {
    identities | while read -r hash name; do
        case "$name" in "$1"*) ;; *) continue ;; esac
        if security find-certificate -c "$name" -p | openssl x509 -noout -subject |
            grep -Eq "OU ?= ?$DEVELOPMENT_TEAM([,/]|\$)"; then
            echo "$hash"
            break
        fi
    done
}

IDENTITY=${SIGN_IDENTITY:-}
if [ -z "$IDENTITY" ] && [ -n "${DEVELOPMENT_TEAM:-}" ]; then
    IDENTITY=$(team_identity "Developer ID Application")
    [ -n "$IDENTITY" ] || IDENTITY=$(team_identity "Apple Development")
    if [ -z "$IDENTITY" ]; then
        echo "No code signing certificate of team $DEVELOPMENT_TEAM in the keychain." >&2
        exit 1
    fi
fi
if [ -n "$IDENTITY" ]; then
    echo "Signing with $(identities | grep -F "$IDENTITY" | head -1)"
else
    echo "Signing ad hoc"
fi

# sign FILE: with the certificate (hardened runtime, timestamp) or ad hoc.
sign() {
    if [ -n "$IDENTITY" ]; then
        codesign --force --options runtime --timestamp --sign "$IDENTITY" "$1"
    else
        codesign --force --sign - "$1"
    fi
}

# notarytool SUBCOMMAND ARGS...: run it with the login chosen above.
notarytool() {
    if [ "$NOTARY" = profile ]; then
        xcrun notarytool "$@" --keychain-profile "$NOTARY_PROFILE"
    else
        xcrun notarytool "$@" --key "$NOTARY_KEY" --key-id "$NOTARY_KEY_ID" \
            --issuer "$NOTARY_ISSUER"
    fi
}

# notarise FILE: send a zip or disk image to Apple and wait for the verdict.
# On a refusal, print Apple's list of what is wrong with it.
notarise() {
    result=$(notarytool submit "$1" --wait) || { echo "$result"; exit 1; }
    echo "$result"
    if ! echo "$result" | grep -q "status: Accepted"; then
        id=$(echo "$result" | sed -n 's/^ *id: //p' | head -1)
        [ -z "$id" ] || notarytool log "$id" || true
        echo "Apple did not notarise $1." >&2
        exit 1
    fi
}

ARCH_FLAGS=
for arch in ${ARCHS:-}; do
    ARCH_FLAGS="$ARCH_FLAGS --arch $arch"
done
# shellcheck disable=SC2086
swift build -c release $ARCH_FLAGS
# shellcheck disable=SC2086
BIN=$(swift build -c release $ARCH_FLAGS --show-bin-path)

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
    <key>CFBundleSupportedPlatforms</key>
    <array>
        <string>MacOSX</string>
    </array>
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
    sign "$app"
    codesign --verify --strict "$app"
    echo "Built $PWD/$app"
}

mkdir -p "$OUT"
bundle QuectelMenu "Quectel Menu" space.linuxgemini.quectel-menu light true
bundle QuectelDebug "Quectel Debug" space.linuxgemini.quectel-debug dark false

if [ "${1:-}" = --dmg ]; then
    dmg="$OUT/QuectelApps.dmg"
    stage="$OUT/dmg"
    rm -rf "$stage" "$dmg"
    if [ -n "$NOTARY" ]; then
        # The apps get their own ticket, so that a copy taken out of the
        # disk image opens on a Mac that is offline.
        zip="$OUT/QuectelApps.zip"
        mkdir -p "$stage"
        ditto "$OUT/QuectelMenu.app" "$stage/QuectelMenu.app"
        ditto "$OUT/QuectelDebug.app" "$stage/QuectelDebug.app"
        ditto -c -k "$stage" "$zip"
        rm -rf "$stage"
        notarise "$zip"
        rm -f "$zip"
        xcrun stapler staple "$OUT/QuectelMenu.app"
        xcrun stapler staple "$OUT/QuectelDebug.app"
    fi
    mkdir -p "$stage"
    ditto "$OUT/QuectelMenu.app" "$stage/QuectelMenu.app"
    ditto "$OUT/QuectelDebug.app" "$stage/QuectelDebug.app"
    ln -s /Applications "$stage/Applications"
    hdiutil create -quiet -volname "Quectel Apps" -srcfolder "$stage" -format UDZO "$dmg"
    rm -rf "$stage"
    if [ -n "$IDENTITY" ]; then
        codesign --force --timestamp --sign "$IDENTITY" "$dmg"
    fi
    if [ -n "$NOTARY" ]; then
        notarise "$dmg"
        xcrun stapler staple "$dmg"
    fi
    echo "Packed $PWD/$dmg"
fi
