#!/bin/bash
# Checks a built "BriefBar.app" before anyone uses it: its signature is valid, with the hardened runtime
# and no entitlements; its designated requirement names a certificate rather than code hashes (so Full
# Disk Access survives rebuilds); and on this Mac it runs and sorts the demo data as expected.
#   scripts/check-app.sh [app] [--universal]   (default: build/BriefBar.app)
#   --universal   requires code for both Apple silicon and Intel (CI).
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/BriefBar.app"
UNIVERSAL=false
for arg in "$@"; do
    case "$arg" in
        --universal) UNIVERSAL=true ;;
        -*) echo "Unknown option: $arg" >&2; exit 2 ;;
        *) APP="$arg" ;;
    esac
done
BIN="$APP/Contents/MacOS/BriefBar"
PLIST="$APP/Contents/Info.plist"

fail() {
    echo "$APP: $1" >&2
    exit 1
}
plist() { /usr/libexec/PlistBuddy -c "Print :$1" "$PLIST" 2>/dev/null; }

codesign --verify --deep --strict "$APP" || fail "has an invalid signature."
codesign -dv "$APP" 2>&1 | grep '^CodeDirectory.*flags=.*runtime' >/dev/null || fail "isn't signed with the hardened runtime."
REQUIREMENT="$(codesign -d -r- "$APP" 2>&1 | sed -n 's/^#* *designated => //p')"
if [[ "$REQUIREMENT" == *cdhash* ]]; then
    fail "is signed ad hoc (designated requirement: $REQUIREMENT), so Full Disk Access won't survive the next build. Run 'make signing-identity' and build again."
elif [[ "$REQUIREMENT" != *'identifier "com.asaf.BriefBar"'* || "$REQUIREMENT" != *certificate* ]]; then
    fail "has an unexpected designated requirement: $REQUIREMENT"
fi
# No entitlements: library validation stays on, so nothing but Apple's libraries and the app's own code
# runs with its Full Disk Access.
ENTITLEMENTS="$(codesign -d --entitlements - --xml "$APP" 2>/dev/null | plutil -convert json -o - - 2>/dev/null || true)"
[[ -z "$ENTITLEMENTS" || "$ENTITLEMENTS" == "{}" ]] || fail "has entitlements: $ENTITLEMENTS"
[[ ! -e "$APP/Contents/Frameworks" ]] || fail "embeds frameworks, which it shouldn't need."

ARCHS="$(lipo -archs "$BIN")"
REQUIRED_ARCHS="$(uname -m)"
if $UNIVERSAL; then
    REQUIRED_ARCHS="arm64 x86_64"
fi
for arch in $REQUIRED_ARCHS; do
    [[ " $ARCHS " == *" $arch "* ]] || fail "${BIN#"$APP/"} has no $arch code (only $ARCHS)."
done

[[ "$(plist CFBundleIdentifier)" == com.asaf.BriefBar ]] || fail "has another bundle identifier."
[[ "$(plist LSUIElement)" == true ]] || fail "isn't a menu-bar-only app (LSUIElement)."
[[ "$(plist CFBundleVersion)" == "$(plist CFBundleShortVersionString)" ]] ||
    fail "has a CFBundleVersion that isn't its version."
[[ -f "$APP/Contents/Resources/AppIcon.icns" ]] || fail "has no icon."
# Summaries need macOS 26's FoundationModels; linked weakly, the app still opens on macOS 15. (No
# grep -q in these pipes: with pipefail, its early exit could make a match look like none.)
if otool -l "$BIN" | grep -B2 'FoundationModels.framework' | grep 'cmd LC_LOAD_DYLIB$' >/dev/null; then
    fail "links FoundationModels strongly, so it won't open before macOS 26."
fi

# Running it shows that it launches under the hardened runtime.
"$BIN" --help >/dev/null || fail "doesn't launch."
make -s demo-check PULSE="$BIN"
echo "Checked $APP: valid signature, hardened runtime, no entitlements, $ARCHS, designated requirement: $REQUIREMENT"
