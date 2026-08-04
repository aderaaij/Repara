#!/bin/zsh
#
# Regenerate docs/screenshots/ from the simulator.
#
# One launch per screen, each against the stubbed portal in ScreenshotMode —
# no network, no account, no photograph of anybody's front door, and no route
# in the stub that could file a report. See Repara/Support/ScreenshotMode.swift.
#
#   Tools/screenshots.sh [device-udid]
#
# Defaults to the booted simulator.

set -euo pipefail

BUNDLE_ID="com.ardennl.Repara"
SCHEME="Repara"
OUT="$(cd "$(dirname "$0")/.." && pwd)/docs/screenshots"
DEVICE="${1:-booted}"

# Praça do Comércio — a public square, the same reference point the projection
# self-check uses, chosen so the fixtures identify nobody.
LAT=38.70757
LNG=-9.1364

# scene:filename:scroll — scroll is in points, 0 for the top, 5000 for "as far
# as it goes". Review and Settings are both several screens long, so the
# sections worth documenting need a scrolled shot as well as a top one.
# Order is the order somebody meets these screens.
SCENES=(
  "launch:01-launch:0"
  "welcome:02-welcome:0"
  "sign-in:03-sign-in:0"
  "types:04-what-you-can-report:0"
  "capture-empty:05-capture-no-photo:0"
  "capture:06-capture:0"
  "drafting:07-drafting:0"
  "type-picker:08-type-picker:0"
  "review:09-review:0"
  "review:10-review-text-and-submit:5000"
  # The caution cards sit directly under the verdict card now, so these three
  # are top-of-screen shots. They needed 820 pt of scroll when Review was a
  # `Form` and the warnings were its fifth and sixth sections.
  "review-booked:11-review-booked:0"
  "review-booked-far:11b-review-booked-further-off:0"
  "review-checking:12-review-checking-collections:0"
  "review-failed:13-review-collection-check-failed:0"
  "dry-run:14-dry-run:0"
  "filed:15-filed:0"
  "reports-mine:16-my-reports:0"
  "my-report:16a-my-report:0"
  "occurrence-compare:16b-occurrence-compare:0"
  "browse-empty:17-browse-before-searching:0"
  "browse-results:18-browse-results:0"
  "browse-nothing:19-browse-nothing-open:0"
  "browse-filtered:20-browse-filtered:0"
  "settings:21-settings:0"
  "settings:22-settings-models-and-submission:700"
  "settings-gemini:23-settings-gemini:0"
)

PROJECT="$(cd "$(dirname "$0")/.." && pwd)/Repara.xcodeproj"

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

# Pre-grant location so the permission alert never lands on top of a screenshot,
# and pin the status bar so twenty launches do not produce twenty clocks.
xcrun simctl privacy "$UDID" grant location "$BUNDLE_ID" 2>/dev/null || true
xcrun simctl location "$UDID" set "$LAT,$LNG" 2>/dev/null || true
xcrun simctl status_bar "$UDID" override \
  --time "09:41" --batteryState charged --batteryLevel 100 \
  --cellularMode active --cellularBars 4 --wifiMode active --wifiBars 3 \
  --operatorName "" 2>/dev/null || true

mkdir -p "$OUT"

for entry in "${SCENES[@]}"; do
  scene="${entry%%:*}"
  rest="${entry#*:}"
  name="${rest%%:*}"
  scroll="${rest##*:}"

  xcrun simctl terminate "$UDID" "$BUNDLE_ID" 2>/dev/null || true
  xcrun simctl launch "$UDID" "$BUNDLE_ID" \
    --screenshot-scene "$scene" --screenshot-scroll "$scroll" >/dev/null

  # Long enough for the stubbed lookups and the two debounces in resolve().
  sleep 8

  xcrun simctl io "$UDID" screenshot --type=png "$OUT/$name.png" >/dev/null 2>&1
  echo "  ✓ $name.png"
done

xcrun simctl terminate "$UDID" "$BUNDLE_ID" 2>/dev/null || true
xcrun simctl status_bar "$UDID" clear 2>/dev/null || true

echo "▸ Done — $(ls -1 "$OUT"/*.png | wc -l | tr -d ' ') screenshots in docs/screenshots/"
