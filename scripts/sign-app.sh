#!/bin/bash
# Signs "BriefBar.app" with the certificate, with the hardened runtime and no entitlements.
# scripts/build-app.sh runs it for every build.
#   scripts/sign-app.sh <app>
# BRIEFBAR_SIGNING_IDENTITY names the certificate (default "BriefBar Signing");
# BRIEFBAR_SIGNING_KEYCHAIN is a keychain to find it in, instead of the search list.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="${1:?Usage: $0 <app>}"
IDENTITY="${BRIEFBAR_SIGNING_IDENTITY:-BriefBar Signing}"
KEYCHAIN="${BRIEFBAR_SIGNING_KEYCHAIN:-}"

# No timestamp, so signing makes no network request.
SIGN=(--sign "$IDENTITY" --timestamp=none)
if [[ -n "$KEYCHAIN" ]]; then
    SIGN+=(--keychain "$KEYCHAIN")
fi
# The hardened runtime keeps other processes from injecting code into an app that may hold Full Disk
# Access: macOS ignores DYLD_* variables for it, and doesn't let debuggers attach. With no
# entitlements, library validation stays on too, so the app loads only Apple's libraries and its own.
codesign --force "${SIGN[@]}" --options runtime "$APP"
