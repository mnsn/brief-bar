#!/bin/bash
# Creates the two keys that releases are signed with, once, and copies each secret that the release
# workflow needs to the clipboard in turn, for you to paste into the release environment on GitHub and
# into your password manager. Both keys are made in memory and never stored on this Mac: GitHub and
# your password manager keep the only copies.
#   scripts/make-release-keys.sh [--new-certificate | --new-update-key]
#
# - The release certificate, "BriefBar Release", signs every release, and macOS ties Full Disk
#   Access to it. It's not your own "BriefBar Signing" (make signing-identity): if its key were on a
#   Mac where codesign could use it, any program running there could sign itself as a BriefBar
#   release and get BriefBar's Full Disk Access on every Mac. The designated requirement it gives the
#   app goes to Resources/ReleaseRequirement.txt, which the release workflow checks every release
#   against.
# - The update signing key, an EdDSA (Ed25519) key for Sparkle. Its public key goes to SUPublicEDKey in
#   Resources/Info.plist: installed apps accept only updates signed with it.
#
# The clipboard keeps each secret on this Mac (Universal Clipboard doesn't offer it to your other
# devices) and out of clipboard managers' history, and is cleared at the end. The public halves are
# written only at the end, so if you stop before then, nothing is saved: run it again, and replace what
# you pasted. Once they're written, it refuses to run, because new keys would cost every user their
# Full Disk Access, or their updates. Only if one leaks or is lost: --new-certificate replaces the
# release certificate and keeps the update signing key, and --new-update-key the other way around.
# Never both at once: Sparkle accepts an update with a new certificate or a new key, not both. See
# "The release keys" in CONTRIBUTING.md.
set -euo pipefail
cd "$(dirname "$0")/.."

NAME="BriefBar Release"
PLIST="Resources/Info.plist"
REQUIREMENT_FILE="Resources/ReleaseRequirement.txt"
# macOS's own LibreSSL (see scripts/make-signing-identity.sh).
OPENSSL=/usr/bin/openssl

NEW_CERTIFICATE=true
NEW_UPDATE_KEY=true
case "${1:-}" in
    "") ;;
    --new-certificate) NEW_UPDATE_KEY=false ;;
    --new-update-key) NEW_CERTIFICATE=false ;;
    *) echo "Usage: $0 [--new-certificate | --new-update-key]" >&2; exit 2 ;;
esac
if [[ ! -t 0 ]]; then
    echo "Run this in Terminal: it waits for you between secrets." >&2
    exit 1
fi
CURRENT_KEY="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$PLIST")"
if $NEW_CERTIFICATE && $NEW_UPDATE_KEY; then
    if [[ -e "$REQUIREMENT_FILE" || -n "$CURRENT_KEY" ]]; then
        cat >&2 <<EOF
The release keys exist already: $REQUIREMENT_FILE and SUPublicEDKey in $PLIST name them. To paste
the secrets again, copy them from your password manager. New keys would cost every user their Full
Disk Access, or their updates; "The release keys" in CONTRIBUTING.md says how to replace one anyway.
EOF
        exit 1
    fi
elif [[ ! -s "$REQUIREMENT_FILE" || -z "$CURRENT_KEY" ]]; then
    echo "There are no release keys to replace yet: run it without options." >&2
    exit 1
fi
wait_for_return() { read -r -p "$1 " _; }
copy() { printf '%s' "$1" | swift scripts/copy-secret.swift; }
COPIED=false
trap 'if $COPIED; then swift scripts/copy-secret.swift --clear || true; fi' EXIT
certificate_config() {
    printf '%s\n' "[ req ]" "distinguished_name = subject" "prompt = no" "x509_extensions = codesigning" \
        "[ subject ]" "CN = $NAME" "[ codesigning ]" "basicConstraints = critical, CA:false" \
        "keyUsage = critical, digitalSignature" "extendedKeyUsage = critical, codeSigning" \
        "subjectKeyIdentifier = hash"
}

if $NEW_CERTIFICATE; then
    # The release certificate, valid for 20 years: codesign won't sign with an expired one. The key and
    # the certificate stay in variables, and reach openssl through pipes, never files.
    IDENTIFIER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$PLIST")"
    KEY="$("$OPENSSL" genrsa 3072 2>/dev/null)"
    CERTIFICATE="$("$OPENSSL" req -x509 -new -sha256 -days 7305 -config <(certificate_config) \
        -key <(printf '%s\n' "$KEY"))"
    P12_PASSWORD="$("$OPENSSL" rand -base64 24)"
    P12="$("$OPENSSL" pkcs12 -export -name "$NAME" -inkey <(printf '%s\n' "$KEY") \
        -in <(printf '%s\n' "$CERTIFICATE") -passout "file:"<(printf '%s\n' "$P12_PASSWORD") | base64)"
    KEY=""
    # A designated requirement names a self-signed certificate by its SHA-1 hash.
    LEAF="$(printf '%s\n' "$CERTIFICATE" | "$OPENSSL" x509 -outform DER | shasum -a 1 | cut -d ' ' -f 1)"
    REQUIREMENT="identifier \"$IDENTIFIER\" and certificate leaf = H\"$LEAF\""
    echo "Release certificate: $REQUIREMENT"
fi
if $NEW_UPDATE_KEY; then
    # The update signing key: a random Ed25519 seed, in the form Sparkle's generate_keys exports it,
    # and its public key.
    KEYS="$(swift - <<'SWIFT'
        import CryptoKit
        let key = Curve25519.Signing.PrivateKey()
        print(key.rawRepresentation.base64EncodedString(), key.publicKey.rawRepresentation.base64EncodedString())
SWIFT
    )"
    SPARKLE_KEY="${KEYS% *}"
    PUBLIC_KEY="${KEYS#* }"
    KEYS=""
    if [[ "$(printf '%s' "$PUBLIC_KEY" | base64 -D 2>/dev/null | wc -c | tr -d ' ')" != 32 ]]; then
        echo "Couldn't make the update signing key." >&2
        exit 1
    fi
    echo "Update signing key:  $PUBLIC_KEY"
fi
cat <<EOF

Now save the secrets. On github.com, open the repository's Settings › Environments › release; under
"Environment secrets", "Add environment secret" adds one and its pencil replaces one. Save each in
your password manager too: with GitHub, it keeps the only copy. This copies each value to the
clipboard in turn, for this Mac only (Universal Clipboard doesn't offer it to your other devices) and
marked so that clipboard managers skip it, and clears the clipboard at the end.

EOF
NEXT="Press Return to"
if $NEW_CERTIFICATE; then
    wait_for_return "$NEXT copy RELEASE_CERTIFICATE_P12."
    copy "$P12"
    COPIED=true
    wait_for_return "Copied. Paste it as RELEASE_CERTIFICATE_P12 and in your password manager, then press Return to copy RELEASE_CERTIFICATE_PASSWORD."
    copy "$P12_PASSWORD"
    NEXT="Copied. Paste it as RELEASE_CERTIFICATE_PASSWORD and in your password manager, then press Return to"
fi
if $NEW_UPDATE_KEY && $NEW_CERTIFICATE; then
    wait_for_return "$NEXT copy SPARKLE_PRIVATE_KEY."
    copy "$SPARKLE_KEY"
    NEXT="Copied. Paste it as SPARKLE_PRIVATE_KEY and in your password manager, then press Return to"
elif $NEW_UPDATE_KEY; then
    # Installed apps accept the release that brings the new public key only if it's signed with the old
    # key, so the secret keeps the old one until that release is out.
    wait_for_return "$NEXT copy the new update signing key."
    copy "$SPARKLE_KEY"
    COPIED=true
    NEXT="Copied. Save it in your password manager, but replace SPARKLE_PRIVATE_KEY only once the next release is out (see CONTRIBUTING.md). Then press Return to"
fi
wait_for_return "$NEXT clear the clipboard."
swift scripts/copy-secret.swift --clear
COPIED=false

# Only now, with every secret saved, the public halves.
if $NEW_CERTIFICATE; then
    printf '%s\n' "$REQUIREMENT" > "$REQUIREMENT_FILE"
fi
if $NEW_UPDATE_KEY; then
    # PlistBuddy would drop the comments in Info.plist, so edit its text.
    PUBLIC_KEY="$PUBLIC_KEY" perl -0pi -e 's{(<key>SUPublicEDKey</key>\s*<string>)[^<]*(</string>)}{$1$ENV{PUBLIC_KEY}$2}' "$PLIST"
    if [[ "$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$PLIST")" != "$PUBLIC_KEY" ]]; then
        echo "Couldn't set SUPublicEDKey in $PLIST. Set it to $PUBLIC_KEY by hand." >&2
        exit 1
    fi
fi
cat <<EOF

Done. Commit the public halves, which the app and the release workflow check against:
  git add $PLIST $REQUIREMENT_FILE
  git commit -m "Set the release signing keys"
EOF
