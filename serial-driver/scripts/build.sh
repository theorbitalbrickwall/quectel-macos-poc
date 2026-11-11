#!/bin/sh
# SPDX-License-Identifier: CC0-1.0 AND MIT
# Contains code from idy/ch348-macos, Copyright (c) 2026 idy, under the MIT
# licence: see serial-driver/LICENSE-ch348-macos.
# Usage: scripts/build.sh --unsigned          compile check only, not loadable
#        DEVELOPMENT_TEAM=XXXXXXXXXX scripts/build.sh    development-signed build
set -eu
cd "$(dirname "$0")/.."
xcodegen generate
if [ "${1:-}" = --unsigned ]; then
    exec xcodebuild -project QuectelSerial.xcodeproj -scheme QuectelSerial \
        -configuration Debug -derivedDataPath build \
        -destination 'generic/platform=macOS' \
        ONLY_ACTIVE_ARCH=NO CODE_SIGNING_ALLOWED=NO build
fi
: "${DEVELOPMENT_TEAM:?set DEVELOPMENT_TEAM to your Apple developer team ID}"
exec xcodebuild -project QuectelSerial.xcodeproj -scheme QuectelSerial \
    -configuration Release -derivedDataPath build \
    -destination 'platform=macOS,name=My Mac' \
    -allowProvisioningUpdates -allowProvisioningDeviceRegistration \
    DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" build
