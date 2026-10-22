#!/bin/bash
# Signs "BriefBar.app" from the inside out: Sparkle.framework (ad hoc), then the updater
# (Contents/Helpers/BriefBar Updater.app) with its one entitlement, then the app with none, both with the
# hardened runtime and the same signature. scripts/build-app.sh runs it for every build: ad hoc, unless you made
# a certificate of your own (scripts/make-signing-identity.sh). The release workflow runs it again, through
# scripts/sign-release.sh, with the release certificate, which only its approved job holds.
#   scripts/sign-app.sh <app> [<SHA-1> [keychain]]
# With a certificate's SHA-1 (scripts/signing.sh finds it by its exact name), it signs with exactly that
# certificate, found in the keychain if one is given, and checks that each signature names it. Without, ad hoc.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/signing.sh

APP="${1:?Usage: $0 <app> [<SHA-1> [keychain]]}"
HASH="${2:-}"
KEYCHAIN="${3:-}"
UPDATER="$APP/Contents/Helpers/BriefBar Updater.app"
FRAMEWORK="$UPDATER/Contents/Frameworks/Sparkle.framework"
UPDATER_ENTITLEMENTS="Resources/BriefBarUpdater.entitlements"

# Sparkle's own helpers (Autoupdate and Updater.app) run as their own processes and keep the signatures they ship
# with. The framework is signed again, without its XPC services, ad hoc: with library validation off (see
# Resources/BriefBarUpdater.entitlements), the updater loads it whoever signed it, and the updater's own signature
# seals the framework's exact code.
codesign --force --sign - --preserve-metadata=identifier,entitlements,flags,runtime "$FRAMEWORK"
# The hardened runtime keeps other processes from injecting code into either: macOS ignores DYLD_* variables for
# them, and doesn't let debuggers attach. BriefBar has no entitlements, so library validation stays on, and it
# loads only Apple's libraries. No timestamp, so signing makes no network request.
if [[ -z "$HASH" ]]; then
    codesign --force --sign - --options runtime --entitlements "$UPDATER_ENTITLEMENTS" "$UPDATER"
    codesign --force --sign - --options runtime "$APP"
else
    sign_with "$HASH" "$UPDATER" "$KEYCHAIN" --options runtime --entitlements "$UPDATER_ENTITLEMENTS" --timestamp=none
    sign_with "$HASH" "$APP" "$KEYCHAIN" --options runtime --timestamp=none
fi
