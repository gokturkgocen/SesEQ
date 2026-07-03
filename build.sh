#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="SesEQ"
BUILD_DIR="./build"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

cp Info.plist "$APP_BUNDLE/Contents/Info.plist"

# Bundle ML resources: CoreML model, mel filterbank, style labels, self-test vectors.
RES="$APP_BUNDLE/Contents/Resources"
[ -f Resources/AppIcon.icns ]            && cp Resources/AppIcon.icns "$RES/"
[ -d Resources/DiscogsEffNet.mlmodelc ]  && cp -R Resources/DiscogsEffNet.mlmodelc "$RES/"
[ -f Resources/mel_filterbank_96x257.f32 ] && cp Resources/mel_filterbank_96x257.f32 "$RES/"
[ -f Resources/discogs_styles.txt ]      && cp Resources/discogs_styles.txt "$RES/"
[ -f Resources/selftest_input.f32 ]      && cp Resources/selftest_input.f32 "$RES/"
[ -f Resources/selftest_mel.f32 ]        && cp Resources/selftest_mel.f32 "$RES/"

SDK_PATH=$(xcrun --sdk macosx --show-sdk-path)

swiftc \
    -O \
    -target arm64-apple-macos26.0 \
    -sdk "$SDK_PATH" \
    -framework Cocoa \
    -framework AVFoundation \
    -framework AVFAudio \
    -framework AudioToolbox \
    -framework CoreAudio \
    -framework CoreML \
    -framework Accelerate \
    -framework SwiftUI \
    -o "$APP_BUNDLE/Contents/MacOS/$APP_NAME" \
    Sources/*.swift

# Sign the app. Prefer a real "Apple Development" identity (keeps TCC permissions stable
# across rebuilds); if none exists, fall back to ad-hoc signing so anyone can build without
# an Apple Developer account. Override with: SIGN_ID="Your Identity" ./build.sh
SIGN_ID="${SIGN_ID:-Apple Development}"
if codesign --force --sign "$SIGN_ID" --entitlements SesEQ.entitlements --options runtime "$APP_BUNDLE" 2>/dev/null \
   || codesign --force --sign "$SIGN_ID" --entitlements SesEQ.entitlements "$APP_BUNDLE" 2>/dev/null; then
    echo "Signed with: $SIGN_ID"
else
    echo "No '$SIGN_ID' identity found — using ad-hoc signing."
    codesign --force --sign - --entitlements SesEQ.entitlements "$APP_BUNDLE"
fi

xattr -rc "$APP_BUNDLE" 2>/dev/null || true

echo "Built: $APP_BUNDLE"

if [[ "${1:-}" == "install" ]]; then
    rm -rf "/Applications/$APP_NAME.app"
    cp -R "$APP_BUNDLE" "/Applications/"
    # Remove the build copy so Spotlight/Launchpad only ever show the installed app
    # (otherwise two "SesEQ" entries get indexed).
    rm -rf "$APP_BUNDLE"
    echo "Installed to /Applications/$APP_NAME.app"
fi
