#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

PROFILE="${PROVISIONING_PROFILE:-}"
SIGN_ID="${SIGN_ID:-Apple Distribution}"
APP="build/Eqlume-AppStore.app"
PKG="build/Eqlume-1.0.pkg"

if [[ -z "$PROFILE" || ! -f "$PROFILE" ]]; then
    echo "Set PROVISIONING_PROFILE to the downloaded Mac App Store provisioning profile."
    exit 1
fi

if ! security find-identity -v -p codesigning | grep -Fq "$SIGN_ID"; then
    echo "Signing identity not found: $SIGN_ID"
    exit 1
fi

SIGN_ID="$SIGN_ID" ./build.sh appstore
cp "$PROFILE" "$APP/Contents/embedded.provisionprofile"
codesign --force --deep --strict --options runtime --sign "$SIGN_ID" --entitlements Eqlume.appstore.entitlements "$APP"
codesign --verify --deep --strict "$APP"

INSTALLER_ID="${INSTALLER_ID:-3rd Party Mac Developer Installer}"
if ! security find-identity -v | grep -Fq "$INSTALLER_ID"; then
    echo "Installer identity not found: $INSTALLER_ID"
    exit 1
fi

productbuild --component "$APP" /Applications --sign "$INSTALLER_ID" "$PKG"
echo "Created upload package: $PKG"
