#!/bin/bash
# Builds "BriefBar.app" into ./build, for Apple silicon only, with its updater inside it
# (Contents/Helpers/BriefBar Updater.app, which holds Sparkle) and its plugin for Copilot
# (Contents/Resources/CopilotPlugin), signed ad hoc: macOS ties Full Disk Access to that exact build, so each new one
# needs the access again (see the note at the end). If you made the optional
# "BriefBar Signing" certificate (scripts/make-signing-identity.sh), it's signed with exactly that certificate
# instead, by its SHA-1 (scripts/signing.sh), and keeps the access across rebuilds; never with one whose key some
# app may use without asking, or that can be exported. Every check that fails stops the build.
#   --install     also copies it to ~/Applications and (re)launches it.
#   --ad-hoc      signs it ad hoc even when the certificate exists.
# BRIEFBAR_SIGNING_IDENTITY names another certificate. BRIEFBAR_SIGNING_KEYCHAIN is a keychain of its own that
# holds it, whose key codesign may use without asking (scripts/ci-signing-identity.sh), and must.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/signing.sh

APP_NAME="BriefBar"
EXECUTABLE="BriefBar"
APP="build/$APP_NAME.app"
UPDATER="$APP/Contents/Helpers/BriefBar Updater.app"
UPDATER_EXECUTABLE="BriefBarUpdater"
IDENTITY="${BRIEFBAR_SIGNING_IDENTITY:-BriefBar Signing}"
KEYCHAIN="${BRIEFBAR_SIGNING_KEYCHAIN:-}"
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' Resources/Info.plist)"

INSTALL=false
AD_HOC=false
for arg in "$@"; do
    case "$arg" in
        --install) INSTALL=true ;;
        --ad-hoc) AD_HOC=true ;;
        *) echo "Unknown option: $arg" >&2; exit 2 ;;
    esac
done

# The certificate named exactly $IDENTITY, by its SHA-1; ad hoc when there's none, unless a keychain of its own
# was named, which must hold it.
HASH=""
if ! $AD_HOC; then
    STATUS=0
    FOUND="$(mktemp)"
    trap 'rm -f "$FOUND"' EXIT
    HASH="$(signing_identity "$IDENTITY" ${KEYCHAIN:+"$KEYCHAIN"} 2>"$FOUND")" || STATUS=$?
    if [[ $STATUS -eq 1 && -z "$KEYCHAIN" ]]; then
        AD_HOC=true
    elif [[ $STATUS -ne 0 ]]; then
        cat "$FOUND" >&2
        echo "error: not signing with \"$IDENTITY\"${KEYCHAIN:+ from $KEYCHAIN (BRIEFBAR_SIGNING_KEYCHAIN)}. Or build with --ad-hoc." >&2
        exit 1
    fi
fi
# Your own key, unless it's in a keychain of its own, like CI's.
if ! $AD_HOC && [[ -z "$KEYCHAIN" ]] && ! require_safe_key "$HASH" "$IDENTITY"; then
    echo "error: not signing with \"$IDENTITY\". Or build with --ad-hoc." >&2
    exit 1
fi

BUILD_FLAGS=(-c release --arch arm64)
swift build "${BUILD_FLAGS[@]}" --product "$EXECUTABLE"
swift build "${BUILD_FLAGS[@]}" --product "$UPDATER_EXECUTABLE"
BIN_DIR="$(swift build "${BUILD_FLAGS[@]}" --show-bin-path)"

# The build copies Sparkle.framework, which the updater uses, next to the executables.
SPARKLE=""
for candidate in "$BIN_DIR/Sparkle.framework" "$BIN_DIR/PackageFrameworks/Sparkle.framework"; do
    if [[ -d "$candidate" ]]; then
        SPARKLE="$candidate"
        break
    fi
done
if [[ -z "$SPARKLE" ]]; then
    echo "Sparkle.framework isn't in $BIN_DIR." >&2
    exit 1
fi
# Sparkle's license covers the code it bundles too. The updater ships the copy in its Resources.
SPARKLE_LICENSE=".build/artifacts/sparkle/Sparkle/LICENSE"
if ! cmp -s Resources/Sparkle-LICENSE.txt "$SPARKLE_LICENSE"; then
    echo "Resources/Sparkle-LICENSE.txt differs from $SPARKLE_LICENSE. Copy the new license over it." >&2
    exit 1
fi

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
for plist in Resources/Info.plist Resources/BriefBarUpdater-Info.plist; do
    if /usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$plist" >/dev/null 2>&1; then
        echo "$plist sets CFBundleVersion. Remove it: the build sets it to BriefBar's CFBundleShortVersionString." >&2
        exit 1
    fi
done
if [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' Resources/BriefBarUpdater-Info.plist)" != "$BUNDLE_ID.Updater" ]]; then
    echo "Resources/BriefBarUpdater-Info.plist must name the updater $BUNDLE_ID.Updater: it only updates the app it's in." >&2
    exit 1
fi

# Removes every rpath from a binary but the ones given. BriefBar links only Apple's libraries, by their full
# paths, so it keeps none; the updater keeps its own Frameworks, for Sparkle. Any other folder, such as the
# toolchain's or the build's, would be a place to put a look-alike library for them to load.
keep_only_rpaths() {
    local binary="$1" rpath
    shift
    while IFS= read -r rpath; do
        [[ " $* " == *" $rpath "* ]] || install_name_tool -delete_rpath "$rpath" "$binary"
    done < <(otool -l "$binary" | sed -n 's/^ *path \(.*\) (offset [0-9]*)$/\1/p' | sort -u)
}

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" \
    "$UPDATER/Contents/MacOS" "$UPDATER/Contents/Resources" "$UPDATER/Contents/Frameworks"
cp "$BIN_DIR/$EXECUTABLE" "$APP/Contents/MacOS/$EXECUTABLE"
keep_only_rpaths "$APP/Contents/MacOS/$EXECUTABLE"
cp "$BIN_DIR/$UPDATER_EXECUTABLE" "$UPDATER/Contents/MacOS/$UPDATER_EXECUTABLE"
keep_only_rpaths "$UPDATER/Contents/MacOS/$UPDATER_EXECUTABLE" @executable_path/../Frameworks
cp Resources/Info.plist "$APP/Contents/Info.plist"
# Sparkle offers an update when its CFBundleVersion is higher than the running app's, so it's the version
# itself (scripts/package.sh checks that each release's version is higher). The updater has the same.
/usr/libexec/PlistBuddy -c "Add :CFBundleVersion string $VERSION" "$APP/Contents/Info.plist"
cp Resources/BriefBarUpdater-Info.plist "$UPDATER/Contents/Info.plist"
for key in CFBundleShortVersionString CFBundleVersion; do
    /usr/libexec/PlistBuddy -c "Add :$key string $VERSION" "$UPDATER/Contents/Info.plist"
done
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp Resources/AppIcon.icns "$UPDATER/Contents/Resources/AppIcon.icns"
cp Resources/Sparkle-LICENSE.txt "$UPDATER/Contents/Resources/Sparkle-LICENSE.txt"
# BriefBar's plugin for Copilot: a marketplace that the Copilot CLI loads in place, from here, once you install it in
# Settings › Agents, so it updates with the app. It's at BriefBar's version.
PLUGIN="$APP/Contents/Resources/CopilotPlugin"
cp -R Resources/CopilotPlugin "$PLUGIN"
find "$PLUGIN" -name .DS_Store -delete
plutil -replace version -string "$VERSION" "$PLUGIN/briefbar/plugin.json"
plutil -replace plugins.0.version -string "$VERSION" "$PLUGIN/marketplace.json"

# ditto keeps the framework's symlinks. An app outside the sandbox doesn't use Sparkle's XPC services, so leave
# them out: less code shipped, and less to attack.
FRAMEWORK="$UPDATER/Contents/Frameworks/Sparkle.framework"
ditto "$SPARKLE" "$FRAMEWORK"
rm -rf "$FRAMEWORK/XPCServices" "$FRAMEWORK/Versions/Current/XPCServices"

if $AD_HOC; then
    ./scripts/sign-app.sh "$APP"
else
    if [[ -z "$KEYCHAIN" ]]; then
        echo "Signing with \"$IDENTITY\": macOS asks for your login password so that codesign can use its key," >&2
        echo "twice: for the updater, then the app. Choose Allow, never Always Allow." >&2
    fi
    if ! ./scripts/sign-app.sh "$APP" "$HASH" "$KEYCHAIN"; then
        echo "error: couldn't sign with \"$IDENTITY\" ($HASH). When macOS asks whether codesign may use its key," >&2
        echo "       enter your login password and choose Allow (never Always Allow), or build with --ad-hoc." >&2
        exit 1
    fi
    # Your own key: Always Allow, just now, would let anything running as you sign with it from now on.
    if [[ -z "$KEYCHAIN" ]] && ! require_safe_key "$HASH" "$IDENTITY"; then
        rm -rf "$APP"
        echo "error: deleted the build: make a new certificate, or delete it to build ad hoc, and build again." >&2
        exit 1
    fi
fi
REQUIREMENT="$(codesign -d -r- "$APP" 2>&1 | sed -n 's/^#* *designated => //p')"
echo "Built $APP (version $VERSION, $(lipo -archs "$APP/Contents/MacOS/$EXECUTABLE"))"
echo "Designated requirement: $REQUIREMENT"

if $INSTALL; then
    DEST="$HOME/Applications"
    mkdir -p "$DEST"

    # Quit a running copy so the new build takes over.
    pids="$(pgrep -f "/$APP_NAME.app/Contents/MacOS/$EXECUTABLE" || true)"
    if [[ -n "$pids" ]]; then
        kill $pids 2>/dev/null || true
        for _ in {1..50}; do
            pgrep -f "/$APP_NAME.app/Contents/MacOS/$EXECUTABLE" >/dev/null || break
            sleep 0.1
        done
    fi

    rm -rf "$DEST/$APP_NAME.app"
    cp -R "$APP" "$DEST/"
    open "$DEST/$APP_NAME.app"
    echo "Installed and launched $DEST/$APP_NAME.app"
fi
if $AD_HOC; then
    # Full Disk Access keeps the requirement of the build that was allowed, even when it's turned off and on, so
    # the entry has to go before this build can be allowed.
    echo "note: signed ad hoc, so macOS ties Full Disk Access, which Teams needs, to this exact build, and turning" >&2
    echo "      BriefBar off and on in the list keeps the old build's. To allow this one, run" >&2
    echo "      tccutil reset SystemPolicyAllFiles $BUNDLE_ID" >&2
    echo "      (or remove BriefBar with − in Privacy & Security › Full Disk Access), and add it again with +." >&2
    echo "      To keep the access across rebuilds, see \"Keeping Full Disk Access across rebuilds\" in the README." >&2
fi
