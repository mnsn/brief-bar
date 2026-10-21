#!/bin/bash
# Optional: creates "BriefBar Signing", a self-signed code-signing certificate, in your login keychain.
# Without it, builds from source are signed ad hoc, and macOS ties Full Disk Access to that exact build, so
# each rebuild needs the access again. With it, scripts/build-app.sh signs every build with exactly this
# certificate, so the app's designated requirement names it rather than the code's hashes, and macOS keeps
# BriefBar's Full Disk Access across rebuilds. Run it once per Mac; running it again checks that the key works.
#   scripts/make-signing-identity.sh [--replace | --delete | --check] [keychain]
# The key is as powerful as that access: anything that can sign with it can sign itself as BriefBar, and get
# the Full Disk Access you gave BriefBar. So no app may use it without asking, not even codesign or security,
# and it can't be exported (scripts/signing-key.swift): macOS asks for your login password each time something
# signs with it, a build included. Choose Allow, never Always Allow. Builds won't sign with a key that some app
# may use without asking, or that can be exported, and check again after signing.
# --replace deletes the certificate and its key first, and makes new ones. Then allow the next build again.
# --delete only deletes them: builds are then signed ad hoc again, and each one needs the access again.
# --check only says, without asking for anything, whether the key is still safe: it fails with status 3 if
# some app may use it without asking, or it can be exported. Without a keychain, it checks every one that
# codesign would look in.
# BRIEFBAR_SIGNING_IDENTITY picks another name.
set -euo pipefail

REPLACE=false
DELETE=false
CHECK=false
case "${1:-}" in
    --replace) REPLACE=true; shift ;;
    --delete) DELETE=true; shift ;;
    --check) CHECK=true; shift ;;
    -*) echo "Usage: $0 [--replace | --delete | --check] [keychain]" >&2; exit 2 ;;
esac
NAME="${BRIEFBAR_SIGNING_IDENTITY:-BriefBar Signing}"
KEYCHAIN_ARGUMENT="${1:-}"
KEYCHAIN="${KEYCHAIN_ARGUMENT:-$HOME/Library/Keychains/login.keychain-db}"
source "$(dirname "$0")/signing.sh"
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$SIGNING_SCRIPTS/../Resources/Info.plist")"
# Full Disk Access keeps the requirement of the build that was allowed, even when it's turned off and on.
ALLOW_AGAIN="run tccutil reset SystemPolicyAllFiles $BUNDLE_ID (or remove BriefBar from Privacy & Security › Full Disk Access with −), and add it again with +"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Whether the key is still safe: no app may use it without asking, and it can't be exported. Only its
# attributes and access list are read, so macOS doesn't ask anything.
key_is_safe() {
    require_safe_key "$NAME" "$NAME" ${KEYCHAIN_ARGUMENT:+"$KEYCHAIN_ARGUMENT"}
}

# Signs a throwaway copy of a tool with the certificate, by its SHA-1, to check that the key works (macOS
# asks) and to show what macOS will match. Then checks that the answer wasn't Always Allow.
check_identity() {
    local hash
    hash="$(signing_identity "$NAME" "$KEYCHAIN")" || exit 1
    cp /usr/bin/true "$WORK/probe"
    echo "macOS asks whether codesign may use the key: enter your login password and choose Allow."
    if ! sign_with "$hash" "$WORK/probe" "$KEYCHAIN" --timestamp=none; then
        echo "codesign couldn't use the \"$NAME\" key. Run this again, and when macOS asks whether codesign" >&2
        echo "may use it, enter your login password and choose Allow." >&2
        exit 1
    fi
    echo "Code signed with it is identified by: $(codesign -d -r- "$WORK/probe" 2>&1 | sed -n 's/^#* *designated => //p')"
    key_is_safe || exit 1
}

if $CHECK; then
    STATUS=0
    key_is_safe || STATUS=$?
    exit $STATUS
fi

if $REPLACE || $DELETE; then
    # Each certificate named exactly so, and its key, one item at a time: nothing else is touched.
    signing_key delete "$NAME" "$KEYCHAIN"
    if $DELETE; then
        echo "Builds are signed ad hoc now. To allow each new one, $ALLOW_AGAIN."
        exit 0
    fi
fi

STATUS=0
signing_identity "$NAME" "$KEYCHAIN" >/dev/null 2>"$WORK/found" || STATUS=$?
case $STATUS in
    0)
        echo "\"$NAME\" is already in $KEYCHAIN."
        key_is_safe || exit 1
        check_identity
        exit 0
        ;;
    1) ;;
    *)
        cat "$WORK/found" >&2
        echo "Run this again with --replace, to start over with one." >&2
        exit 1
        ;;
esac
# security's -c matches part of a name, so only a certificate named exactly so counts.
if security find-certificate -a -c "$NAME" "$KEYCHAIN" 2>/dev/null | grep -F "\"labl\"<blob>=\"$NAME\"" >/dev/null; then
    echo "$KEYCHAIN has a \"$NAME\" certificate but not its private key. Run this again with --replace." >&2
    exit 1
fi

# It never leaves the keychain after this. If macOS imported it otherwise than asked, it's deleted.
P12_PASSWORD="$(/usr/bin/openssl rand -hex 16)"
if ! { printf '%s\n' "$P12_PASSWORD"; printf '%s\n' "$P12_PASSWORD" | make_identity "$NAME"; } |
    signing_key import "$KEYCHAIN" "$NAME"; then
    signing_key delete "$NAME" "$KEYCHAIN" >/dev/null || true
    echo "Couldn't create \"$NAME\" in $KEYCHAIN." >&2
    exit 1
fi
echo "Created \"$NAME\" in $KEYCHAIN. No app may use its key without asking, and it can't be exported."
check_identity
echo "macOS asks like that each time a build is signed. Choose Allow, never Always Allow: that would let anything"
echo "running as you sign code as BriefBar, and get the Full Disk Access you gave it. To allow the next build,"
echo "$ALLOW_AGAIN; later builds keep the access."
