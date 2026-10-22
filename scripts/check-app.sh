#!/bin/bash
# Checks a built "BriefBar.app" before it ships:
# - BriefBar's signatures are valid. BriefBar itself has the hardened runtime and no entitlements, so library
#   validation is on: it links only Apple's libraries, by their full paths, with no rpath and no Frameworks folder.
#   Its designated requirement names a certificate rather than code hashes, so Full Disk Access survives updates.
# - Its updater (Contents/Helpers/BriefBar Updater.app) has its own bundle identifier and the same signature, with
#   the hardened runtime and exactly one entitlement, which turns off library validation for Sparkle, in its own
#   Frameworks, the only folder it looks in.
# - It's set up for signed updates. On this Mac it launches, starts the updater, which loads its Sparkle, and sorts
#   every source's demo data into the expected groups. (That the updater can't use BriefBar's permissions is
#   checked where it shows, in a copy macOS opens: scripts/test-updater-isolation.sh.)
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
PLIST="$APP/Contents/Info.plist"
UPDATER="$APP/Contents/Helpers/BriefBar Updater.app"
UPDATER_BIN="$UPDATER/Contents/MacOS/BriefBarUpdater"
UPDATER_PLIST="$UPDATER/Contents/Info.plist"
FRAMEWORK="$UPDATER/Contents/Frameworks/Sparkle.framework"

fail() {
    echo "$APP: $1" >&2
    exit 1
}
plist() { /usr/libexec/PlistBuddy -c "Print :$1" "${2:-$PLIST}" 2>/dev/null; }
requirement() { codesign -d -r- "$1" 2>&1 | sed -n 's/^#* *designated => //p'; }
entitlements() { codesign -d --entitlements - --xml "$1" 2>/dev/null | plutil -convert json -o - - 2>/dev/null || true; }
rpaths() { otool -arch "$1" -l "$2" | sed -n 's/^ *path \(.*\) (offset [0-9]*)$/\1/p' | sort -u | tr '\n' ' '; }
# The libraries a binary links, for one architecture, but those that match a pattern. (No grep -q in these pipes:
# with pipefail, its early exit could make a match look like none.)
links_other_than() { otool -arch "$1" -L "$2" | tail -n +2 | awk '{ print $1 }' | grep -v -E "$3" | tr '\n' ' ' || true; }

# Every signature, and each nested one on its own so a failure names it.
codesign --verify --deep --strict "$APP" || fail "has an invalid signature."
for code in "$FRAMEWORK/Versions/B/Autoupdate" "$FRAMEWORK/Versions/B/Updater.app" "$FRAMEWORK" "$UPDATER"; do
    codesign --verify --strict "$code" || fail "${code#"$APP/"} has an invalid signature."
done
for code in "$APP" "$UPDATER"; do
    codesign -dv "$code" 2>&1 | grep '^CodeDirectory.*flags=.*runtime' >/dev/null ||
        fail "${code#"$APP/"} isn't signed with the hardened runtime."
done
REQUIREMENT="$(requirement "$APP")"
UPDATER_REQUIREMENT="$(requirement "$UPDATER")"
if [[ "$REQUIREMENT" == *cdhash* ]]; then
    $ALLOW_AD_HOC || fail "is signed ad hoc (designated requirement: $REQUIREMENT). A release must be signed with a certificate, or each update would cost its users their Full Disk Access (see \"Releasing\" in CONTRIBUTING.md). Pass --allow-ad-hoc to check a build of your own."
    [[ "$UPDATER_REQUIREMENT" == *cdhash* ]] || fail "is signed ad hoc, but its updater isn't: $UPDATER_REQUIREMENT"
elif [[ "$REQUIREMENT" != 'identifier "com.asaf.BriefBar" and '* || "$REQUIREMENT" != *certificate* ]]; then
    fail "has an unexpected designated requirement: $REQUIREMENT"
else
    # The updater is signed with the same certificate: the same requirement, with its own identifier.
    EXPECTED="identifier \"com.asaf.BriefBar.Updater\"${REQUIREMENT#identifier \"com.asaf.BriefBar\"}"
    [[ "$UPDATER_REQUIREMENT" == "$EXPECTED" ]] || fail "has an updater signed with something else: $UPDATER_REQUIREMENT"
fi

# BriefBar has no entitlements, so library validation is on: it loads only libraries Apple signed.
APP_ENTITLEMENTS="$(entitlements "$APP")"
[[ -z "$APP_ENTITLEMENTS" || "$APP_ENTITLEMENTS" == "{}" ]] || fail "has entitlements: $APP_ENTITLEMENTS"
[[ ! -e "$APP/Contents/Frameworks" ]] || fail "has a Frameworks folder: Sparkle belongs in the updater."
# The updater has only the one that lets it load Sparkle (see Resources/BriefBarUpdater.entitlements).
UPDATER_ENTITLEMENTS="$(entitlements "$UPDATER")"
[[ "$UPDATER_ENTITLEMENTS" == '{"com.apple.security.cs.disable-library-validation":true}' ]] ||
    fail "has an updater with unexpected entitlements: ${UPDATER_ENTITLEMENTS:-none}"

# The updater: an identity of its own, BriefBar's version, and no update settings of its own (Sparkle reads
# BriefBar's).
[[ "$(plist CFBundleIdentifier "$UPDATER_PLIST")" == com.asaf.BriefBar.Updater ]] ||
    fail "has an updater with another bundle identifier: $(plist CFBundleIdentifier "$UPDATER_PLIST")"
[[ "$(plist LSUIElement "$UPDATER_PLIST")" == true ]] || fail "has an updater with a Dock icon (LSUIElement)."
for key in CFBundleShortVersionString CFBundleVersion; do
    [[ "$(plist "$key" "$UPDATER_PLIST")" == "$(plist "$key")" ]] || fail "has an updater with another $key."
done
for key in SUFeedURL SUPublicEDKey; do
    [[ -z "$(plist "$key" "$UPDATER_PLIST")" ]] || fail "has an updater that sets $key: Sparkle reads BriefBar's."
done

# Sparkle, with its symlinks and without the XPC services, in the updater's Frameworks.
[[ -L "$FRAMEWORK/Versions/Current" && -L "$FRAMEWORK/Sparkle" ]] || fail "has no Sparkle.framework in its updater, or it lost its symlinks."
[[ ! -e "$FRAMEWORK/Versions/B/XPCServices" ]] || fail "still has Sparkle's XPC services."
[[ -f "$UPDATER/Contents/Resources/Sparkle-LICENSE.txt" ]] || fail "doesn't include Sparkle's license."
ARCHS="$(lipo -archs "$BIN")"
REQUIRED_ARCHS="$(uname -m)"
if $UNIVERSAL; then
    REQUIRED_ARCHS="arm64 x86_64"
fi
for arch in $REQUIRED_ARCHS; do
    for binary in "$BIN" "$UPDATER_BIN" "$FRAMEWORK/Versions/B/Sparkle"; do
        [[ " $(lipo -archs "$binary") " == *" $arch "* ]] || fail "${binary#"$APP/"} has no $arch code."
    done
    OTHERS="$(links_other_than "$arch" "$BIN" '^/(usr/lib|System/Library)/')"
    [[ -z "$OTHERS" ]] || fail "${BIN#"$APP/"} ($arch) links libraries that aren't Apple's: $OTHERS"
    [[ -z "$(rpaths "$arch" "$BIN")" ]] || fail "${BIN#"$APP/"} ($arch) looks for libraries in $(rpaths "$arch" "$BIN")"
    OTHERS="$(links_other_than "$arch" "$UPDATER_BIN" '^/(usr/lib|System/Library)/|^@rpath/Sparkle\.framework/')"
    [[ -z "$OTHERS" ]] || fail "${UPDATER_BIN#"$APP/"} ($arch) links libraries other than Apple's and Sparkle: $OTHERS"
    otool -arch "$arch" -L "$UPDATER_BIN" | grep '@rpath/Sparkle.framework/' >/dev/null ||
        fail "${UPDATER_BIN#"$APP/"} ($arch) doesn't link Sparkle."
    [[ "$(rpaths "$arch" "$UPDATER_BIN")" == "@executable_path/../Frameworks " ]] ||
        fail "${UPDATER_BIN#"$APP/"} ($arch) looks for libraries in other folders than its Frameworks: $(rpaths "$arch" "$UPDATER_BIN")"
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
# Summaries need macOS 26's FoundationModels; linked weakly, the app still opens on macOS 15.
if otool -l "$BIN" | grep -B2 'FoundationModels.framework' | grep 'cmd LC_LOAD_DYLIB$' >/dev/null; then
    fail "links FoundationModels strongly, so it won't open before macOS 26."
fi

# Running it shows that it launches with library validation on, and starts its updater, which loads its own
# Sparkle with library validation off.
"$BIN" --help >/dev/null || fail "doesn't launch."
CHECK="$("$BIN" --check-updater 2>&1)" || fail "doesn't start its updater as it should:
$CHECK"
make -s demo-check BRIEFBAR="$BIN"
echo "Checked $APP: valid signatures, hardened runtime, $ARCHS, no entitlements and only Apple's libraries, Sparkle in its updater (one entitlement, started and loaded), designated requirement: $REQUIREMENT"
