#!/bin/bash
# Builds the universal "BriefBar.app", checks it and zips it into build/release, with the zip's SHA-256.
# CI keeps it as the run's artifact. (Releases come once the repository is public; see CONTRIBUTING.md.)
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/BriefBar.app"
OUT="build/release"
ZIP="BriefBar.zip"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
# The build sets CFBundleVersion to this version, so keep it to plain numbers that compare the same way.
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "The version in Resources/Info.plist ($VERSION) isn't like 1.2.3." >&2
    exit 1
fi

# Signed with the certificate that BRIEFBAR_SIGNING_* names.
./scripts/build-app.sh --universal
./scripts/check-app.sh "$APP" --universal

rm -rf "$OUT"
mkdir -p "$OUT"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$OUT/$ZIP"
(cd "$OUT" && shasum -a 256 "$ZIP" > "$ZIP.sha256")
echo "Packaged $OUT/$ZIP (version $VERSION)"
