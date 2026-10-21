#!/bin/bash
# Builds "BriefBar.app" into ./build, for this Mac's architecture, signed with the certificate that
# scripts/make-signing-identity.sh creates. Never ad hoc: macOS ties Full Disk Access, and the keychain
# item that keeps Teams' unread chats, to the app's signature, and an ad-hoc signature changes with
# every build.
#   --universal   builds for both Apple silicon and Intel instead.
#   --install     also copies it to ~/Applications and (re)launches it.
# BRIEFBAR_SIGNING_IDENTITY names another certificate; BRIEFBAR_SIGNING_KEYCHAIN is a keychain to find
# it in, instead of the search list.
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="BriefBar"
EXECUTABLE="BriefBar"
APP="build/$APP_NAME.app"
IDENTITY="${BRIEFBAR_SIGNING_IDENTITY:-BriefBar Signing}"
KEYCHAIN="${BRIEFBAR_SIGNING_KEYCHAIN:-}"

UNIVERSAL=false
INSTALL=false
for arg in "$@"; do
    case "$arg" in
        --universal) UNIVERSAL=true ;;
        --install) INSTALL=true ;;
        *) echo "Unknown option: $arg" >&2; exit 2 ;;
    esac
done

if ! security find-certificate -c "$IDENTITY" ${KEYCHAIN:+"$KEYCHAIN"} >/dev/null 2>&1; then
    echo "There's no signing certificate named \"$IDENTITY\". Create it once with 'make signing-identity'." >&2
    exit 1
fi
# If some app may use the key without asking, any program running as you could sign itself as
# BriefBar with it, and get its Full Disk Access. A throwaway keychain of its own (CI) is the exception.
if [[ -z "$KEYCHAIN" ]]; then
    STATUS=0
    swift -suppress-warnings scripts/signing-key.swift check "$IDENTITY" || STATUS=$?
    if [[ $STATUS -eq 3 ]]; then
        echo "So any program running as you could sign itself as BriefBar, and get its Full Disk Access." >&2
        echo "Replace the certificate with one that every app has to ask to use, then build again:" >&2
        echo "  scripts/make-signing-identity.sh --replace" >&2
        exit 1
    elif [[ $STATUS -ne 0 ]]; then
        echo "warning: couldn't check which apps may use the key of \"$IDENTITY\"." >&2
    fi
fi

BUILD_FLAGS=(-c release)
if $UNIVERSAL; then
    BUILD_FLAGS+=(--arch arm64 --arch x86_64)
fi
swift build "${BUILD_FLAGS[@]}" --product "$EXECUTABLE"
BIN_DIR="$(swift build "${BUILD_FLAGS[@]}" --show-bin-path)"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
if /usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' Resources/Info.plist >/dev/null 2>&1; then
    echo "Resources/Info.plist sets CFBundleVersion. Remove it: the build sets it to CFBundleShortVersionString." >&2
    exit 1
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/$EXECUTABLE" "$APP/Contents/MacOS/$EXECUTABLE"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# The version itself, so a later update can compare versions.
/usr/libexec/PlistBuddy -c "Add :CFBundleVersion string $VERSION" "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

if [[ -z "$KEYCHAIN" ]]; then
    echo "Signing with \"$IDENTITY\": macOS asks for your login password so that codesign can use its key." >&2
    echo "Click Allow, never Always Allow." >&2
fi
./scripts/sign-app.sh "$APP"
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
