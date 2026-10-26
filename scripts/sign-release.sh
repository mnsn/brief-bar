#!/bin/bash
# Signs a packaged release with the release certificate, in the release workflow's approved job: unzips
# build/release/BriefBar.zip, signs its updater and the app again with exactly "BriefBar Release" (or the
# certificate BRIEFBAR_SIGNING_IDENTITY names), by its SHA-1, from BRIEFBAR_SIGNING_KEYCHAIN, checks them
# (scripts/check-app.sh checks that the updater's requirement names the same certificate), and zips it again,
# with its new SHA-256 in BriefBar.zip.sha256 and notes.md.
#   scripts/sign-release.sh [release dir]   (default: build/release)
# Every release must be signed with the same certificate: macOS ties Full Disk Access to the app's designated
# requirement, which names it. So the result must match Resources/ReleaseRequirement.txt, which
# scripts/make-release-keys.sh writes.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/signing.sh

OUT="${1:-build/release}"
ZIP="BriefBar.zip"
APP="build/BriefBar.app"
IDENTITY="${BRIEFBAR_SIGNING_IDENTITY:-BriefBar Release}"
KEYCHAIN="${BRIEFBAR_SIGNING_KEYCHAIN:?Set BRIEFBAR_SIGNING_KEYCHAIN, as the release workflow does with scripts/import-release-identity.sh.}"
EXPECTED_FILE="Resources/ReleaseRequirement.txt"

if [[ ! -s "$EXPECTED_FILE" ]]; then
    echo "$EXPECTED_FILE is missing. Run scripts/make-release-keys.sh (see \"Releasing\" in CONTRIBUTING.md)." >&2
    exit 1
fi
EXPECTED="$(tr -d '\n' < "$EXPECTED_FILE")"
HASH="$(signing_identity "$IDENTITY" "$KEYCHAIN")"

(cd "$OUT" && shasum -a 256 -c "$ZIP.sha256")
OLD_SHA="$(cut -d ' ' -f 1 "$OUT/$ZIP.sha256")"
rm -rf "$APP"
ditto -x -k "$OUT/$ZIP" build

./scripts/sign-app.sh "$APP" "$HASH" "$KEYCHAIN"
REQUIREMENT="$(codesign -d -r- "$APP" 2>&1 | sed -n 's/^#* *designated => //p')"
if [[ "$REQUIREMENT" != "$EXPECTED" ]]; then
    echo "The app is signed with another certificate than earlier releases, so every user would lose" >&2
    echo "Full Disk Access. Expected: $EXPECTED" >&2
    echo "Got:      $REQUIREMENT" >&2
    exit 1
fi
./scripts/check-app.sh "$APP" --release

if [[ "$(grep -c "$OLD_SHA" "$OUT/notes.md")" != 1 ]]; then
    echo "$OUT/notes.md doesn't give the zip's SHA-256 exactly once." >&2
    exit 1
fi
rm -f "$OUT/$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$OUT/$ZIP"
(cd "$OUT" && shasum -a 256 "$ZIP" > "$ZIP.sha256")
SHA256="$(cut -d ' ' -f 1 "$OUT/$ZIP.sha256")"
sed -i '' "s/$OLD_SHA/$SHA256/" "$OUT/notes.md"
echo "Signed $OUT/$ZIP with the release certificate: $REQUIREMENT"
