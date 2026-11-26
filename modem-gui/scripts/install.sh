#!/bin/sh
# SPDX-License-Identifier: CC0-1.0
# Build the two apps and copy them into the Applications folder.
# Usage: scripts/install.sh               build and install into /Applications
#        scripts/install.sh --uninstall   remove the installed apps
#        DESTINATION=~/Applications scripts/install.sh    another folder
set -eu
cd "$(dirname "$0")/.."

DESTINATION=${DESTINATION:-/Applications}
APPS="QuectelMenu QuectelDebug"

# A running copy keeps the serial port and would be replaced under its feet.
stop_apps() {
    for name in $APPS; do
        pkill -x "$name" 2>/dev/null || true
    done
}

if [ "${1:-}" = --uninstall ]; then
    stop_apps
    for name in $APPS; do
        rm -rf "$DESTINATION/$name.app"
        echo "Removed $DESTINATION/$name.app"
    done
    exit 0
fi

scripts/bundle.sh
stop_apps
mkdir -p "$DESTINATION"
for name in $APPS; do
    rm -rf "$DESTINATION/$name.app"
    ditto "build/$name.app" "$DESTINATION/$name.app"
    echo "Installed $DESTINATION/$name.app"
done
