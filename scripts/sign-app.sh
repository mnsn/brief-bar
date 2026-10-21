#!/bin/bash
# Signs "BriefBar.app" from the inside out: Sparkle.framework (ad hoc), then the app, with the hardened runtime
# and its one entitlement. scripts/build-app.sh runs it for every build: ad hoc, unless you made a certificate
# of your own (scripts/make-signing-identity.sh). The release workflow runs it again, through
# scripts/sign-release.sh, with the release certificate, which only its approved job holds.
#   scripts/sign-app.sh <app> [<SHA-1> [keychain]]
# With a certificate's SHA-1 (scripts/signing.sh finds it by its exact name), it signs with exactly that
# certificate, found in the keychain if one is given, and checks that the signature names it. Without, ad hoc.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/signing.sh

APP="${1:?Usage: $0 <app> [<SHA-1> [keychain]]}"
HASH="${2:-}"
KEYCHAIN="${3:-}"
FRAMEWORK="$APP/Contents/Frameworks/Sparkle.framework"
ENTITLEMENTS="Resources/BriefBar.entitlements"

# Sparkle's helpers (Autoupdate and Updater.app) run as their own processes and keep the signatures they ship
# with. The framework is signed again, without its XPC services, ad hoc: with library validation off (see
# Resources/BriefBar.entitlements), the app loads it whoever signed it, and the app's own signature seals the
# framework's exact code. So a certificate's key is used once per build, and macOS asks once.
if [[ -d "$FRAMEWORK" ]]; then
    codesign --force --sign - --preserve-metadata=identifier,entitlements,flags,runtime "$FRAMEWORK"
fi
# The hardened runtime keeps other processes from injecting code into an app that may hold Full Disk Access:
# macOS ignores DYLD_* variables for it, and doesn't let debuggers attach. No timestamp, so signing makes no
# network request.
if [[ -z "$HASH" ]]; then
    codesign --force --sign - --options runtime --entitlements "$ENTITLEMENTS" "$APP"
else
    sign_with "$HASH" "$APP" "$KEYCHAIN" --options runtime --entitlements "$ENTITLEMENTS" --timestamp=none
fi
