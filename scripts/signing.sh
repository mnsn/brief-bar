# Sourced by the scripts that sign BriefBar: scripts/build-app.sh, scripts/sign-app.sh,
# scripts/sign-release.sh, scripts/make-signing-identity.sh and the keychain scripts. They find the identity to
# sign with by its exact name, check its key, and sign with its SHA-1, so that codesign can't pick another one.
# Given a name, codesign uses an identity preference by that name if there is one, and otherwise a certificate
# whose name merely contains it: neither need be the one whose key was checked. scripts/test-signing-key.sh
# tests these.

SIGNING_SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

signing_key() { swift -suppress-warnings "$SIGNING_SCRIPTS/signing-key.swift" "$@"; }

# signing_identity <name> [keychain]: prints the SHA-1 of the one identity whose certificate is named exactly
# <name>, in the keychain or on the search list. Fails with status 1 if there's none, and 4 if there's more
# than one.
signing_identity() { signing_key find "$@"; }

# require_safe_key <name or SHA-1> <name> [keychain]: fails, and says what to do, if some app may use the
# certificate's key without asking, or it can be exported, or that can't be told. Such a key would let
# anything running as you sign code as BriefBar, and get the Full Disk Access you gave BriefBar.
require_safe_key() {
    local status=0
    signing_key check "$1" ${3:+"$3"} || status=$?
    case $status in
        0) return 0 ;;
        3)
            echo "So anything running as you could sign code as BriefBar with \"$2\", and get the Full Disk Access" >&2
            echo "you gave BriefBar. Delete it, to build ad hoc, or replace it, and when macOS asks, choose Allow," >&2
            echo "never Always Allow:" >&2
            echo "  scripts/make-signing-identity.sh --delete   (or --replace)" >&2
            ;;
        2) echo "Couldn't check who may use the key of \"$2\"." >&2 ;;
    esac
    return $status
}

# sign_with <SHA-1> <path> <keychain, or ""> [codesign options...]: signs with exactly that certificate, and
# checks that the signature names it. On macOS 15 and 26, codesign finds it only in a keychain on the search
# list, even with --keychain.
sign_with() {
    local hash="$1" target="$2" keychain="$3" requirement
    shift 3
    if [[ ! "$hash" =~ ^[0-9A-F]{40}$ ]]; then
        echo "Not a certificate's SHA-1: \"$hash\"." >&2
        return 1
    fi
    codesign --force "$@" --sign "$hash" ${keychain:+--keychain "$keychain"} "$target" || return 1
    requirement="$(codesign -d -r- "$target" 2>&1 | sed -n 's/^#* *designated => //p')"
    if [[ "$requirement" != *"certificate leaf = H\"$(printf '%s' "$hash" | tr 'A-F' 'a-f')\""* ]]; then
        echo "$target isn't signed with the certificate $hash: $requirement" >&2
        return 1
    fi
}

# add_to_search_list <keychain>: puts a keychain of its own, such as CI's or the release workflow's, on the
# keychain search list, where codesign on macOS 15 and 26 looks. Deleting the keychain takes it off again.
add_to_search_list() {
    local line current=()
    while IFS= read -r line; do
        line="$(printf '%s' "$line" | sed -E 's/^[[:space:]]*"//; s/"[[:space:]]*$//')"
        [[ -n "$line" && "$line" != "$1" ]] && current+=("$line")
    done <<< "$(security list-keychains -d user)"
    security list-keychains -d user -s ${current[@]+"${current[@]}"} "$1"
}

# make_identity <name>: a PKCS #12, in base64, with a self-signed certificate named <name> for code signing only,
# valid for 10 years, and its key, protected with the password on the first line of standard input. The key
# stays in variables, and reaches openssl through pipes, never a file. macOS's own LibreSSL: `security import`
# can't read the .p12 files that OpenSSL 3 writes by default.
make_identity() {
    local password key config certificate
    IFS= read -r password
    config="[ req ]
distinguished_name = subject
prompt = no
x509_extensions = codesigning
[ subject ]
CN = $1
[ codesigning ]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
subjectKeyIdentifier = hash"
    key="$(/usr/bin/openssl genrsa 3072 2>/dev/null)"
    certificate="$(/usr/bin/openssl req -x509 -new -sha256 -days 3650 -config <(printf '%s\n' "$config") \
        -key <(printf '%s\n' "$key"))"
    /usr/bin/openssl pkcs12 -export -name "$1" -inkey <(printf '%s\n' "$key") -in <(printf '%s\n' "$certificate") \
        -passout "file:"<(printf '%s\n' "$password") | base64
}
