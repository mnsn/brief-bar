#!/bin/bash
# Rehearses an update through BriefBar's updater, the way an installed copy gets one: a copy of a build at
# version 0.9.0 checks a feed on this Mac, downloads 0.9.1 and installs it by itself, with Sparkle in the updater.
# Both copies are signed with a throwaway certificate, the feed and the zip with a throwaway EdDSA key, and they
# have a bundle identifier of their own, so your BriefBar and its settings play no part. It checks that the update
# kept the designated requirement, which Full Disk Access depends on, and leaves nothing behind: no keychain,
# preferences, caches or launchd jobs.
#   scripts/update-rehearsal.sh [app]   (default: build/BriefBar.app, from make app or make package)
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/signing.sh

APP="${1:-build/BriefBar.app}"
ID=com.asaf.BriefBar.rehearsal
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
[[ -x "$APP/Contents/Helpers/BriefBar Updater.app/Contents/MacOS/BriefBarUpdater" ]] ||
    { echo "update-rehearsal: no app with an updater at $APP. Run make app first." >&2; exit 1; }
WORK="$(mktemp -d)"
KEYCHAIN=""
SERVER=""
UPDATER_PID=""
ZIP_HASH=""
cleanup() {
    # Ending its input tells the updater to quit, as BriefBar quitting does.
    exec 3>&- 2>/dev/null || true
    [[ -z "$UPDATER_PID" ]] || kill "$UPDATER_PID" 2>/dev/null || true
    [[ -z "$SERVER" ]] || kill "$SERVER" 2>/dev/null || true
    for label in "$ID-sparkle-updater" "$ID-sparkle-progress"; do
        launchctl remove "$label" 2>/dev/null || true
    done
    defaults delete "$ID" 2>/dev/null || true
    rm -rf "$HOME/Library/Preferences/$ID.plist" "$HOME/Library/Caches/$ID" "$HOME/Library/Caches/$ID.Updater" \
        "$HOME/Library/HTTPStorages/$ID.Updater" "$HOME/Library/HTTPStorages/$ID.Updater.binarycookies"
    # What generate_appcast kept of the zip it signed.
    [[ -z "$ZIP_HASH" ]] || rm -rf "$HOME/Library/Caches/Sparkle_generate_appcast/$ZIP_HASH"
    for app in "$WORK"/*/BriefBar.app; do
        "$LSREGISTER" -u "$app" >/dev/null 2>&1 || true
    done
    [[ -z "$KEYCHAIN" ]] || security delete-keychain "$KEYCHAIN" 2>/dev/null || true
    rm -rf "$WORK"
}
trap cleanup EXIT
fail() {
    echo "update-rehearsal: $1" >&2
    exit 1
}

mkdir -p "$WORK/keychain" "$WORK/feed"
KEYCHAIN="$(./scripts/ci-signing-identity.sh "$WORK/keychain" 2>/dev/null)"
HASH="$(signing_identity "BriefBar Signing" "$KEYCHAIN")"
KEYS="$(swift - <<'SWIFT'
import CryptoKit
let key = Curve25519.Signing.PrivateKey()
print(key.rawRepresentation.base64EncodedString(), key.publicKey.rawRepresentation.base64EncodedString())
SWIFT
)"
PUBLIC_KEY="${KEYS#* }"

# Sparkle fetches only over http or https: a server for the feed folder, on this Mac only.
PORT="$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')"
python3 -m http.server "$PORT" --bind 127.0.0.1 --directory "$WORK/feed" > "$WORK/server.log" 2>&1 &
SERVER=$!
FEED="http://127.0.0.1:$PORT"

# A copy of the app at a version, with the rehearsal's identifier, feed and key, signed again.
copy_at() {
    local app="$WORK/$1/BriefBar.app" version="$2"
    mkdir -p "$WORK/$1"
    ditto "$APP" "$app"
    /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $ID" -c "Set :SUFeedURL $FEED/appcast.xml" \
        -c "Set :SUPublicEDKey $PUBLIC_KEY" -c "Set :CFBundleShortVersionString $version" \
        -c "Set :CFBundleVersion $version" "$app/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $ID.Updater" -c "Set :CFBundleShortVersionString $version" \
        -c "Set :CFBundleVersion $version" "$app/Contents/Helpers/BriefBar Updater.app/Contents/Info.plist"
    ./scripts/sign-app.sh "$app" "$HASH" "$KEYCHAIN" 2>/dev/null
}
copy_at installed 0.9.0
copy_at update 0.9.1
INSTALLED="$WORK/installed/BriefBar.app"
BEFORE="$(codesign -d -r- "$INSTALLED" 2>&1 | sed -n 's/^#* *designated => //p')"
ditto -c -k --sequesterRsrc --keepParent "$WORK/update/BriefBar.app" "$WORK/feed/BriefBar.zip"
ZIP_HASH="$(shasum -a 256 "$WORK/feed/BriefBar.zip" | cut -d ' ' -f 1)"
echo "A rehearsal of an update." > "$WORK/feed/changes.md"
printf '%s\n' "${KEYS% *}" | ./scripts/make-appcast.sh "$WORK/feed" "$FEED/" > "$WORK/appcast.log" ||
    { cat "$WORK/appcast.log" >&2; fail "couldn't sign the feed."; }

# Checks automatically, never checked before, and installs updates by itself: so the updater checks as it starts,
# downloads 0.9.1, and since 0.9.0 isn't running, installs it at once. Its input stays open, as BriefBar keeps it.
defaults write "$ID" SUEnableAutomaticChecks -bool YES
defaults write "$ID" SUAutomaticallyUpdate -bool YES
defaults write "$ID" SUHasLaunchedBefore -bool YES
mkfifo "$WORK/input"
exec 3<>"$WORK/input"
"$INSTALLED/Contents/Helpers/BriefBar Updater.app/Contents/MacOS/BriefBarUpdater" < "$WORK/input" > "$WORK/updater.log" 2>&1 &
UPDATER_PID=$!
START=$SECONDS
VERSION=""
while (( SECONDS - START < 180 )); do
    VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$INSTALLED/Contents/Info.plist" 2>/dev/null || true)"
    [[ "$VERSION" == 0.9.1 ]] && break
    sleep 1
done
if [[ "$VERSION" != 0.9.1 ]]; then
    echo "The feed server saw: $(grep -o '"GET [^"]*"' "$WORK/server.log" | tr '\n' ' ')" >&2
    log show --last 5m --style compact \
        --predicate 'subsystem == "org.sparkle-project.Sparkle" OR (subsystem == "com.asaf.BriefBar" AND category == "updater")' \
        2>/dev/null | tail -20 >&2 || true
    fail "the copy is still at version ${VERSION:-?} after $(( SECONDS - START )) s."
fi
# The installer may still be finishing up.
for _ in {1..20}; do
    codesign --verify --deep --strict "$INSTALLED" 2>/dev/null && break
    sleep 0.5
done
codesign --verify --deep --strict "$INSTALLED" || fail "the updated copy's signature isn't valid."
AFTER="$(codesign -d -r- "$INSTALLED" 2>&1 | sed -n 's/^#* *designated => //p')"
[[ "$AFTER" == "$BEFORE" ]] || fail "the update changed the designated requirement, from $BEFORE to $AFTER."
UPDATED_UPDATER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$INSTALLED/Contents/Helpers/BriefBar Updater.app/Contents/Info.plist")"
[[ "$UPDATED_UPDATER" == 0.9.1 ]] || fail "the updater inside is still at $UPDATED_UPDATER."
echo "update-rehearsal passed: the updater installed 0.9.1 over 0.9.0 from a signed feed in $(( SECONDS - START )) s, updater included, and the designated requirement didn't change ($AFTER)."
