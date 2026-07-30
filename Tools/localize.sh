#!/bin/sh
#
# Refresh Localizable.xcstrings from the strings actually present in the source.
#
# Xcode's IDE does this on every build. `xcodebuild` does not — it emits the
# per-file .stringsdata and then never merges them back — so a repo driven from
# the command line needs this step run by hand or the catalogue silently stops
# matching the code.
#
# Run it after adding or rewording anything the user reads. New keys arrive with
# no pt-PT value and Xcode marks them NEW; removed ones are marked stale rather
# than deleted, so a translation is never thrown away by a refactor.
#
#     Tools/localize.sh
#
set -eu

cd "$(dirname "$0")/.."

# CONFIGURATION_TEMP_DIR, not OBJROOT. OBJROOT holds every configuration ever
# built here — a Release or device build from last week leaves its .stringsdata
# sitting there, and syncing against those resurrects keys whose call sites have
# since been rewritten. It also holds ReparaCore's, whose strings belong to that
# package's own .lproj and must not land in the app's catalogue.
SCOPE=$(
    xcodebuild -project Repara.xcodeproj -scheme Repara \
        -destination 'generic/platform=iOS Simulator' \
        -showBuildSettings 2>/dev/null |
        awk -F' = ' '/ CONFIGURATION_TEMP_DIR = /{print $2; exit}'
)

echo "Building so the .stringsdata is current…"
xcodebuild -project Repara.xcodeproj -scheme Repara \
    -destination 'generic/platform=iOS Simulator' build >/dev/null

# ScreenshotMode is deliberately left out. It is canned demo content for the
# App Store screenshot harness, it is compiled out of release builds entirely,
# and folding its ~390 strings into the catalogue would treble the translation
# surface to localise screens no user ever reaches. If you ever want per-language
# store screenshots, drop the -not clause.
STRINGSDATA=$(
    find "$SCOPE" -name '*.stringsdata' \
        -not -name 'ScreenshotMode.stringsdata' |
        sed 's/^/--stringsdata /'
)

if [ -z "$STRINGSDATA" ]; then
    echo "No .stringsdata found under $SCOPE — did the build actually run?" >&2
    exit 1
fi

# shellcheck disable=SC2086
xcrun xcstringstool sync Repara/Localizable.xcstrings $STRINGSDATA

python3 - <<'PY'
import json
catalogue = json.load(open("Repara/Localizable.xcstrings"))
strings = catalogue["strings"]
missing = [
    key for key, entry in strings.items()
    if entry.get("shouldTranslate", True)
    and "pt-PT" not in entry.get("localizations", {})
]
print(f"{len(strings)} keys in the catalogue, {len(missing)} without pt-PT.")
for key in missing[:40]:
    print("  •", key[:96])
if len(missing) > 40:
    print(f"  …and {len(missing) - 40} more")
PY
