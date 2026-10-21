#!/bin/bash
# Checks a built "BriefBar.app" before it ships: its signatures are valid, with the hardened runtime and only
# the entitlement it needs; its designated requirement names a certificate rather than code hashes (so Full
# Disk Access survives updates); it embeds Sparkle (the updater), loads it, and looks for libraries only in its
# own Frameworks and Apple's Swift folder; it's set up for signed updates; and on this Mac it runs and sorts
# every source's demo data into the expected groups.
#   scripts/check-app.sh [app] [--universal] [--release] [--allow-ad-hoc]   (default: build/BriefBar.app)
#   --universal     requires code for both Apple silicon and Intel (releases and CI).
#   --release       also requires the update signing key in Info.plist (scripts/make-release-keys.sh).
#   --allow-ad-hoc  accepts an ad-hoc signature, for a build of your own.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/BriefBar.app"
UNIVERSAL=false
RELEASE=false
ALLOW_AD_HOC=false
for arg in "$@"; do
    case "$arg" in
        --universal) UNIVERSAL=true ;;
        --release) RELEASE=true ;;
        --allow-ad-hoc) ALLOW_AD_HOC=true ;;
        -*) echo "Unknown option: $arg" >&2; exit 2 ;;
        *) APP="$arg" ;;
    esac
done
BIN="$APP/Contents/MacOS/BriefBar"
FRAMEWORK="$APP/Contents/Frameworks/Sparkle.framework"
PLIST="$APP/Contents/Info.plist"

fail() {
    echo "$APP: $1" >&2
    exit 1
}
plist() { /usr/libexec/PlistBuddy -c "Print :$1" "$PLIST" 2>/dev/null; }

# Every signature, and each nested one on its own so a failure names it.
codesign --verify --deep --strict "$APP" || fail "has an invalid signature."
for code in "$FRAMEWORK/Versions/B/Autoupdate" "$FRAMEWORK/Versions/B/Updater.app" "$FRAMEWORK"; do
    codesign --verify --strict "$code" || fail "${code#"$APP/"} has an invalid signature."
done
codesign -dv "$APP" 2>&1 | grep '^CodeDirectory.*flags=.*runtime' >/dev/null || fail "isn't signed with the hardened runtime."
REQUIREMENT="$(codesign -d -r- "$APP" 2>&1 | sed -n 's/^#* *designated => //p')"
if [[ "$REQUIREMENT" == *cdhash* ]]; then
    $ALLOW_AD_HOC || fail "is signed ad hoc (designated requirement: $REQUIREMENT). A release must be signed with a certificate, or each update would cost its users their Full Disk Access (see \"Releasing\" in CONTRIBUTING.md). Pass --allow-ad-hoc to check a build of your own."
elif [[ "$REQUIREMENT" != *'identifier "com.asaf.BriefBar"'* || "$REQUIREMENT" != *certificate* ]]; then
    fail "has an unexpected designated requirement: $REQUIREMENT"
fi
# Only the entitlement that lets the hardened runtime load Sparkle (see Resources/BriefBar.entitlements).
ENTITLEMENTS="$(codesign -d --entitlements - --xml "$APP" 2>/dev/null | plutil -convert json -o - - 2>/dev/null || true)"
[[ "$ENTITLEMENTS" == '{"com.apple.security.cs.disable-library-validation":true}' ]] ||
    fail "has unexpected entitlements: ${ENTITLEMENTS:-none}"

# Sparkle, with its symlinks and without the XPC services, loaded through the app's Frameworks only.
[[ -L "$FRAMEWORK/Versions/Current" && -L "$FRAMEWORK/Sparkle" ]] || fail "has no Sparkle.framework, or it lost its symlinks."
[[ ! -e "$FRAMEWORK/Versions/B/XPCServices" ]] || fail "still has Sparkle's XPC services."
[[ -f "$APP/Contents/Resources/Sparkle-LICENSE.txt" ]] || fail "doesn't include Sparkle's license."
otool -L "$BIN" | grep '@rpath/Sparkle.framework/' >/dev/null || fail "doesn't link Sparkle."
ARCHS="$(lipo -archs "$BIN")"
REQUIRED_ARCHS="$(uname -m)"
if $UNIVERSAL; then
    REQUIRED_ARCHS="arm64 x86_64"
fi
for arch in $REQUIRED_ARCHS; do
    if [[ " $ARCHS " != *" $arch "* ]]; then
        fail "${BIN#"$APP/"} has no $arch code (only $ARCHS)."
    fi
    [[ " $(lipo -archs "$FRAMEWORK/Versions/B/Sparkle") " == *" $arch "* ]] || fail "Sparkle has no $arch code."
    RPATHS="$(otool -arch "$arch" -l "$BIN" | sed -n 's/^ *path \(.*\) (offset [0-9]*)$/\1/p' | sort -u | tr '\n' ' ')"
    [[ "$RPATHS" == "/usr/lib/swift @executable_path/../Frameworks " || "$RPATHS" == "@executable_path/../Frameworks /usr/lib/swift " ]] ||
        fail "${BIN#"$APP/"} ($arch) looks for libraries in other folders than its Frameworks and Apple's Swift folder: $RPATHS"
done

# Signed updates only, from the feed in the latest GitHub release; Sparkle compares CFBundleVersion.
[[ "$(plist SUFeedURL)" == https://github.com/mnsn/brief-bar/releases/latest/download/appcast.xml ]] ||
    fail "has another SUFeedURL: $(plist SUFeedURL)"
KEY_BYTES="$(plist SUPublicEDKey | base64 -d 2>/dev/null | wc -c | tr -d ' ')"
if [[ "$KEY_BYTES" != 32 ]]; then
    if $RELEASE || [[ -n "$(plist SUPublicEDKey)" ]]; then
        fail "has no valid SUPublicEDKey. Run scripts/make-release-keys.sh (see \"Releasing\" in CONTRIBUTING.md)."
    fi
    echo "warning: $APP has no SUPublicEDKey yet, so it won't check for updates." >&2
fi
[[ "$(plist SURequireSignedFeed)" == true && "$(plist SUVerifyUpdateBeforeExtraction)" == true ]] ||
    fail "doesn't require signed updates and appcasts."
[[ "$(plist SUSignedFeedFailureExpirationInterval)" == 0 ]] || fail "would accept an unsigned appcast after a while."
for key in SUEnableSystemProfiling SUEnableDownloaderService SUEnableInstallerLauncherService; do
    [[ -z "$(plist "$key")" ]] || fail "sets $key."
done
[[ "$(plist CFBundleIdentifier)" == com.asaf.BriefBar ]] || fail "has another bundle identifier."
[[ "$(plist LSUIElement)" == true ]] || fail "isn't a menu-bar-only app (LSUIElement)."
[[ "$(plist CFBundleVersion)" == "$(plist CFBundleShortVersionString)" ]] ||
    fail "has a CFBundleVersion that isn't its version."
[[ -f "$APP/Contents/Resources/AppIcon.icns" ]] || fail "has no icon."
# Summaries need macOS 26's FoundationModels; linked weakly, the app still opens on macOS 15. (No grep -q in
# these pipes: with pipefail, its early exit could make a match look like none.)
if otool -l "$BIN" | grep -B2 'FoundationModels.framework' | grep 'cmd LC_LOAD_DYLIB$' >/dev/null; then
    fail "links FoundationModels strongly, so it won't open before macOS 26."
fi

# Running it shows that it launches, with Sparkle loaded under the hardened runtime.
"$BIN" --help >/dev/null || fail "doesn't launch (or can't load Sparkle)."
make -s demo-check BRIEFBAR="$BIN"
echo "Checked $APP: valid signatures, hardened runtime, $ARCHS, Sparkle embedded and loaded, designated requirement: $REQUIREMENT"
