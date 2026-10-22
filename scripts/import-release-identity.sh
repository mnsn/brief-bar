#!/bin/bash
# Imports the release certificate into a new keychain, for the release workflow's approved job, puts the
# keychain on the keychain search list, where codesign on macOS 15 and 26 looks, and prints its path. The
# certificate comes from the environment: RELEASE_CERTIFICATE_P12 (base64 of a PKCS #12 file) and
# RELEASE_CERTIFICATE_PASSWORD, the release environment's secrets (see scripts/make-release-keys.sh).
#   scripts/import-release-identity.sh [folder]   (default: a new temporary folder that only you can read)
# Delete the keychain when done, which takes it off the search list too: security delete-keychain <path>
set -euo pipefail
# Only this script reads the secrets, through printf below: no program it starts inherits them, from the first.
export -n RELEASE_CERTIFICATE_P12 RELEASE_CERTIFICATE_PASSWORD
cd "$(dirname "$0")/.."
source scripts/signing.sh

: "${RELEASE_CERTIFICATE_P12:?The release environment has no RELEASE_CERTIFICATE_P12 secret.}"
: "${RELEASE_CERTIFICATE_PASSWORD:?The release environment has no RELEASE_CERTIFICATE_PASSWORD secret.}"
NAME="${BRIEFBAR_SIGNING_IDENTITY:-BriefBar Release}"
FOLDER="${1:-$(mktemp -d)}"
KEYCHAIN="$FOLDER/briefbar-release.keychain-db"
# Nothing else is ever in this keychain, so its password only needs to last until it's deleted.
KEYCHAIN_PASSWORD="$(/usr/bin/openssl rand -hex 16)"

security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
# On failure, nothing is left behind, since the caller never learns the keychain's path.
trap 'status=$?; if [[ $status -ne 0 ]]; then security delete-keychain "$KEYCHAIN" 2>/dev/null || true; fi' EXIT
security set-keychain-settings -lut 21600 "$KEYCHAIN"
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
# Only codesign may use the key without asking, and nothing can export it, so the steps after this one can sign
# with it but not take it (scripts/signing-key.swift: security import's -x has no effect on a PKCS #12). The
# password and the certificate reach it through a pipe, not its command line or a file.
printf '%s\n%s\n' "$RELEASE_CERTIFICATE_PASSWORD" "$RELEASE_CERTIFICATE_P12" |
    signing_key import "$KEYCHAIN" "$NAME" --trust /usr/bin/codesign >&2
# Lets codesign use the key without a prompt, which a runner couldn't answer.
security set-key-partition-list -S apple-tool:,apple: -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN" >/dev/null
add_to_search_list "$KEYCHAIN"
if ! signing_identity "$NAME" "$KEYCHAIN" >/dev/null; then
    echo "RELEASE_CERTIFICATE_P12 holds no certificate named \"$NAME\" with its private key." >&2
    exit 1
fi
# As it's used from now on: still no app but codesign, and still not exportable.
signing_key check "$NAME" "$KEYCHAIN" --trust /usr/bin/codesign >&2
echo "$KEYCHAIN"
