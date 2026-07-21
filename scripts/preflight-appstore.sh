#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

APP="build/Eqlume-AppStore.app"

./build.sh appstore

test -d "$APP"
test ! -e "$APP/Contents/Resources/DiscogsEffNet.mlmodelc"
test ! -e "$APP/Contents/Resources/discogs_styles.txt"

codesign --verify --deep --strict "$APP"

ENTITLEMENTS=$(codesign -d --entitlements - "$APP" 2>/dev/null)
[[ "$ENTITLEMENTS" == *"com.apple.security.app-sandbox"* ]]
[[ "$ENTITLEMENTS" == *"com.apple.security.network.client"* ]]
[[ "$ENTITLEMENTS" != *"com.apple.security.get-task-allow"* ]]

INFO="$APP/Contents/Info.plist"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$INFO")" == "com.gokturkgocen.Eqlume" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :LSApplicationCategoryType' "$INFO")" == "public.app-category.utilities" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :ITSAppUsesNonExemptEncryption' "$INFO")" == "false" ]]

echo "App Store preflight passed: $APP"
