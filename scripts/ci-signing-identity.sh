#!/bin/bash
# Creates a throwaway keychain holding a throwaway "BriefBar Signing" certificate, for CI and for
# trying the build without your own certificate, and prints the keychain's path. Its key is open to
# codesign, so that nothing asks for a password: don't give a build signed with it Full Disk Access.
# Build with it:
#   export BRIEFBAR_SIGNING_KEYCHAIN="$(scripts/ci-signing-identity.sh)"
#   make package
# Delete it afterwards with `security delete-keychain <path>`. Releases will never be signed with it:
# their certificate will come from the approval-gated release environment (see "Signing" in
# CONTRIBUTING.md).
#   scripts/ci-signing-identity.sh [folder]   (default: a new temporary folder)
set -euo pipefail
cd "$(dirname "$0")/.."

FOLDER="${1:-$(mktemp -d)}"
KEYCHAIN="$FOLDER/briefbar-signing.keychain-db"
PASSWORD="$(openssl rand -hex 16)"

security create-keychain -p "$PASSWORD" "$KEYCHAIN"
# No automatic locking, so a long build can't lose access to the key halfway.
security set-keychain-settings "$KEYCHAIN"
security unlock-keychain -p "$PASSWORD" "$KEYCHAIN"
BRIEFBAR_KEYCHAIN_PASSWORD="$PASSWORD" ./scripts/make-signing-identity.sh "$KEYCHAIN" >&2
echo "$KEYCHAIN"
