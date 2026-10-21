#!/bin/bash
# Creates a throwaway keychain holding a throwaway "BriefBar Signing" certificate, for CI and for make package
# on your Mac, puts it on the keychain search list, where codesign on macOS 15 and 26 looks, and prints its
# path. codesign may use its key without asking, so that nothing asks for a password: don't give a build signed
# with it Full Disk Access. Nothing can export the key. Build with it, then delete it, which takes it off the
# search list too, and its folder:
#   export BRIEFBAR_SIGNING_KEYCHAIN="$(scripts/ci-signing-identity.sh)"
#   make package
#   security delete-keychain "$BRIEFBAR_SIGNING_KEYCHAIN" && rmdir "$(dirname "$BRIEFBAR_SIGNING_KEYCHAIN")"
# Releases are never signed with it: their certificate comes from the release environment (see "Releasing" in
# CONTRIBUTING.md).
#   scripts/ci-signing-identity.sh [folder]   (default: a new temporary folder that only you can read)
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/signing.sh

NAME="${BRIEFBAR_SIGNING_IDENTITY:-BriefBar Signing}"
if [[ $# -gt 0 ]]; then
    FOLDER="$1"
    MADE_FOLDER=false
else
    FOLDER="$(mktemp -d)"
    MADE_FOLDER=true
fi
KEYCHAIN="$FOLDER/briefbar-signing.keychain-db"
# Nothing else is ever in this keychain, so its password only needs to last until it's deleted.
PASSWORD="$(/usr/bin/openssl rand -hex 16)"

# On failure, nothing is left behind, since the caller never learns the keychain's path. (A keychain that was
# there already, which create-keychain refuses to replace, is left alone.)
trap 'status=$?; if [[ $status -ne 0 ]] && $MADE_FOLDER; then rm -rf "$FOLDER"; fi' EXIT
security create-keychain -p "$PASSWORD" "$KEYCHAIN"
trap 'status=$?; if [[ $status -ne 0 ]]; then
    security delete-keychain "$KEYCHAIN" 2>/dev/null || true
    if $MADE_FOLDER; then rm -rf "$FOLDER"; fi
fi' EXIT
# Locks only after 6 hours, so a long build can't lose access to the key halfway.
security set-keychain-settings -lut 21600 "$KEYCHAIN"
security unlock-keychain -p "$PASSWORD" "$KEYCHAIN"
# Only codesign may use the key without asking, and nothing can export it. The password and the identity reach
# it through a pipe, not a command line or a file.
P12_PASSWORD="$(/usr/bin/openssl rand -hex 16)"
{ printf '%s\n' "$P12_PASSWORD"; printf '%s\n' "$P12_PASSWORD" | make_identity "$NAME"; } |
    signing_key import "$KEYCHAIN" "$NAME" --trust /usr/bin/codesign >&2
# Lets codesign use the key without a prompt, which nothing could answer on a build machine.
security set-key-partition-list -S apple-tool:,apple: -s -k "$PASSWORD" "$KEYCHAIN" >/dev/null
add_to_search_list "$KEYCHAIN"
signing_identity "$NAME" "$KEYCHAIN" >/dev/null
# As it's used from now on: still no app but codesign, and still not exportable.
signing_key check "$NAME" "$KEYCHAIN" --trust /usr/bin/codesign >&2
echo "$KEYCHAIN"
