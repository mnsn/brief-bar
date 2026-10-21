#!/bin/bash
# Creates "BriefBar Signing", a self-signed code-signing certificate, in your login keychain. Every
# build is signed with it (scripts/build-app.sh), so the app's designated requirement names this
# certificate rather than the code's hashes, and macOS keeps BriefBar's Full Disk Access, and its
# keychain item, across rebuilds. Ad-hoc signed builds lose both every time. Run it once per Mac.
#   scripts/make-signing-identity.sh [--replace] [keychain]
#
# No app may use the certificate's private key without asking, not even codesign: any program that
# could would be able to sign itself as BriefBar and get the Full Disk Access you gave it. So each
# build asks for your login password: click Allow, never Always Allow. scripts/build-app.sh refuses to
# sign with a key that some app may use without asking. --replace deletes the certificate and makes a
# new one, and the next build then needs Full Disk Access once more.
#
# BRIEFBAR_SIGNING_IDENTITY picks another name. With BRIEFBAR_KEYCHAIN_PASSWORD set, for a
# throwaway keychain of its own (CI, scripts/ci-signing-identity.sh), codesign may use the key without
# asking.
set -euo pipefail
cd "$(dirname "$0")/.."

NAME="${BRIEFBAR_SIGNING_IDENTITY:-BriefBar Signing}"
REPLACE=false
if [[ "${1:-}" == "--replace" ]]; then
    REPLACE=true
    shift
fi
KEYCHAIN="${1:-$HOME/Library/Keychains/login.keychain-db}"
OPEN_TO_CODESIGN=false
if [[ -n "${BRIEFBAR_KEYCHAIN_PASSWORD:-}" ]]; then
    if [[ "$KEYCHAIN" == *"/login.keychain"* ]]; then
        echo "BRIEFBAR_KEYCHAIN_PASSWORD is only for a keychain of its own, not the login keychain." >&2
        exit 1
    fi
    OPEN_TO_CODESIGN=true
fi
# macOS's own LibreSSL, on every Mac. Homebrew's OpenSSL 3, the default openssl on some Macs and on
# GitHub's macOS 26 runners, writes PKCS #12 files with AES and SHA-256, which older versions of
# macOS can't import.
OPENSSL=/usr/bin/openssl
signing_key() { swift -suppress-warnings scripts/signing-key.swift "$@"; }

if security find-certificate -c "$NAME" "$KEYCHAIN" >/dev/null 2>&1; then
    if $REPLACE; then
        # find-certificate -c matches part of the name, so only exact matches are deleted.
        HASHES="$(security find-certificate -a -c "$NAME" -Z "$KEYCHAIN" | awk -v name="$NAME" '
            /^SHA-1 hash:/ { hash = $3 }
            /"labl"<blob>=/ { label = $0; sub(/^[^=]*="/, "", label); sub(/"$/, "", label); if (label == name) print hash }
        ')"
        for hash in $HASHES; do
            security delete-identity -Z "$hash" "$KEYCHAIN" >/dev/null 2>&1 ||
                security delete-certificate -Z "$hash" "$KEYCHAIN" >/dev/null
        done
        echo "Deleted the old \"$NAME\" from $KEYCHAIN."
    else
        STATUS=0
        $OPEN_TO_CODESIGN || signing_key check "$NAME" "$KEYCHAIN" || STATUS=$?
        if [[ $STATUS -eq 0 ]]; then
            echo "\"$NAME\" is already in $KEYCHAIN. Nothing to do."
            exit 0
        elif [[ $STATUS -eq 3 ]]; then
            cat >&2 <<EOF
So any program running as you could sign itself with it as BriefBar, and get the Full Disk Access
you gave BriefBar. Replace it with a certificate that every app has to ask to use:
  scripts/make-signing-identity.sh --replace
Then give the next build Full Disk Access once more.
EOF
        else
            echo "To start over with a new \"$NAME\", run: scripts/make-signing-identity.sh --replace" >&2
        fi
        exit 1
    fi
fi

# A leaf certificate for code signing only, valid for 10 years. Nothing needs to trust it: macOS
# matches the certificate itself against the app's designated requirement. The key and the certificate
# stay in variables, and reach openssl and the keychain through pipes, never files.
CONFIG="[ req ]
distinguished_name = subject
prompt = no
x509_extensions = codesigning
[ subject ]
CN = $NAME
[ codesigning ]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
subjectKeyIdentifier = hash"
KEY="$("$OPENSSL" genrsa 3072 2>/dev/null)"
CERTIFICATE="$("$OPENSSL" req -x509 -new -sha256 -days 3650 -config <(printf '%s\n' "$CONFIG") -key <(printf '%s\n' "$KEY"))"
P12_PASSWORD="$("$OPENSSL" rand -hex 16)"
P12="$("$OPENSSL" pkcs12 -export -name "$NAME" -inkey <(printf '%s\n' "$KEY") -in <(printf '%s\n' "$CERTIFICATE") \
    -passout "file:"<(printf '%s\n' "$P12_PASSWORD") | base64)"
KEY=""

if $OPEN_TO_CODESIGN; then
    printf '%s\n%s\n' "$P12_PASSWORD" "$P12" | signing_key import "$KEYCHAIN" "$NAME" --trust /usr/bin/codesign
    # Lets Apple's tools use every key in the keychain, which is why it's only for a keychain of its own.
    security set-key-partition-list -S apple-tool:,apple: -s -k "$BRIEFBAR_KEYCHAIN_PASSWORD" "$KEYCHAIN" >/dev/null
    # Sign a throwaway copy of a tool to check that the identity works, and show what macOS will match.
    WORK="$(mktemp -d)"
    trap 'rm -rf "$WORK"' EXIT
    cp /usr/bin/true "$WORK/probe"
    codesign --force --sign "$NAME" --keychain "$KEYCHAIN" --timestamp=none "$WORK/probe"
    REQUIREMENT="$(codesign -d -r- "$WORK/probe" 2>&1 | sed -n 's/^#* *designated => //p')"
    echo "Created \"$NAME\" in $KEYCHAIN."
    echo "Code signed with it is identified by: $REQUIREMENT"
else
    printf '%s\n%s\n' "$P12_PASSWORD" "$P12" | signing_key import "$KEYCHAIN" "$NAME"
    signing_key check "$NAME" "$KEYCHAIN"
    LEAF="$(printf '%s\n' "$CERTIFICATE" | "$OPENSSL" x509 -outform DER | shasum -a 1 | cut -d ' ' -f 1)"
    echo "Created \"$NAME\" in $KEYCHAIN (certificate leaf = H\"$LEAF\")."
    echo "No app may use its key without asking. Each build asks for your login password so that codesign"
    echo "can sign with it: click Allow, never Always Allow."
fi
