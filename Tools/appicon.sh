#!/bin/zsh
#
# Regenerate the app icon from `ReparaMark` — the same view the launch screen
# draws, so the icon on the home screen and the mark inside the app cannot
# drift apart.
#
#   Tools/appicon.sh [device-udid]
#
# Defaults to the booted simulator. Renders 1024×1024 at scale 1, opaque, and
# full-bleed: iOS applies the rounded mask itself.

set -euo pipefail

BUNDLE_ID="com.ardennl.Repara"
SCHEME="Repara"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT="$ROOT/Repara.xcodeproj"
OUT="$ROOT/Repara/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png"
DEVICE="${1:-booted}"

if [[ "$DEVICE" == "booted" ]]; then
  UDID="$(xcrun simctl list devices | grep -m1 '(Booted)' | grep -oE '[0-9A-F-]{36}')"
  [[ -n "$UDID" ]] || { echo "No booted simulator. Boot one, or pass a udid."; exit 1; }
else
  UDID="$DEVICE"
fi

echo "▸ Building…"
xcodebuild -project "$PROJECT" -scheme "$SCHEME" \
  -destination "id=$UDID" -configuration Debug build -quiet

# -sdk iphonesimulator matters: without it this resolves to Debug-iphoneos and
# installs a device build onto a simulator, which fails confusingly.
APP="$(xcodebuild -project "$PROJECT" -scheme "$SCHEME" \
  -configuration Debug -sdk iphonesimulator -showBuildSettings 2>/dev/null \
  | awk '/ BUILT_PRODUCTS_DIR /{d=$3} / FULL_PRODUCT_NAME /{n=$3} END{print d"/"n}')"

echo "▸ Installing $APP"
xcrun simctl install "$UDID" "$APP"

xcrun simctl terminate "$UDID" "$BUNDLE_ID" 2>/dev/null || true
xcrun simctl launch "$UDID" "$BUNDLE_ID" --render-app-icon >/dev/null
sleep 4

CONTAINER="$(xcrun simctl get_app_container "$UDID" "$BUNDLE_ID" data)"
SRC="$CONTAINER/Documents/AppIcon-1024.png"
[[ -f "$SRC" ]] || { echo "No icon written — see IconExport.swift"; exit 1; }

cp "$SRC" "$OUT"
xcrun simctl terminate "$UDID" "$BUNDLE_ID" 2>/dev/null || true

echo "▸ Done — $(sips -g pixelWidth -g pixelHeight "$OUT" | tail -2 | tr -d ' \n')  $OUT"
