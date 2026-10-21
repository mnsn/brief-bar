#!/bin/bash
# Writes a configuration profile that grants BriefBar Full Disk Access ahead of time, for
# organizations that manage their Macs (Intune, Jamf, Kandji…). Deployed through MDM, users never see
# the Full Disk Access step. macOS ignores such profiles unless MDM installs them. The access is the
# app's, but it reads nothing with it until a user turns on a source that needs it, such as Teams.
#   scripts/make-pppc-profile.sh [app] [output]
#   (default: build/BriefBar.app, and build/BriefBar-Full-Disk-Access.mobileconfig)
# The profile holds the app's designated requirement, so every copy you deploy must be signed with the
# same certificate as the app given here.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="${1:-build/BriefBar.app}"
OUT="${2:-build/BriefBar-Full-Disk-Access.mobileconfig}"

if [[ ! -d "$APP" ]]; then
    echo "There's no app at $APP. Build it first with 'make app'." >&2
    exit 1
fi
REQUIREMENT="$(codesign -d -r- "$APP" 2>&1 | sed -n 's/^#* *designated => //p')"
if [[ -z "$REQUIREMENT" || "$REQUIREMENT" == *cdhash* ]]; then
    echo "$APP is signed ad hoc, so no profile can name it across builds. Use a release, which every version" >&2
    echo "signs with the same certificate, or sign your builds with one of your own (make signing-identity)." >&2
    exit 1
fi
IDENTIFIER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")"
xml() { sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' <<< "$1"; }

mkdir -p "$(dirname "$OUT")"
cat > "$OUT" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>PayloadContent</key>
	<array>
		<dict>
			<key>PayloadDisplayName</key>
			<string>BriefBar: Full Disk Access</string>
			<key>PayloadIdentifier</key>
			<string>$(xml "$IDENTIFIER").pppc.policy</string>
			<key>PayloadType</key>
			<string>com.apple.TCC.configuration-profile-policy</string>
			<key>PayloadUUID</key>
			<string>$(uuidgen)</string>
			<key>PayloadVersion</key>
			<integer>1</integer>
			<key>Services</key>
			<dict>
				<key>SystemPolicyAllFiles</key>
				<array>
					<dict>
						<key>Authorization</key>
						<string>Allow</string>
						<key>CodeRequirement</key>
						<string>$(xml "$REQUIREMENT")</string>
						<key>Comment</key>
						<string>Reads Notification Center's database, read-only, for the sources a user turns on, such as Microsoft Teams' unread chats in the menu bar.</string>
						<key>Identifier</key>
						<string>$(xml "$IDENTIFIER")</string>
						<key>IdentifierType</key>
						<string>bundleID</string>
						<key>StaticCode</key>
						<false/>
					</dict>
				</array>
			</dict>
		</dict>
	</array>
	<key>PayloadDescription</key>
	<string>Lets BriefBar read Notification Center's database for the sources its users turn on, such as Teams, so they skip the Full Disk Access step.</string>
	<key>PayloadDisplayName</key>
	<string>BriefBar Full Disk Access</string>
	<key>PayloadIdentifier</key>
	<string>$(xml "$IDENTIFIER").pppc</string>
	<key>PayloadScope</key>
	<string>System</string>
	<key>PayloadType</key>
	<string>Configuration</string>
	<key>PayloadUUID</key>
	<string>$(uuidgen)</string>
	<key>PayloadVersion</key>
	<integer>1</integer>
</dict>
</plist>
EOF
plutil -lint "$OUT" >/dev/null
echo "Wrote $OUT for $IDENTIFIER"
echo "It grants Full Disk Access to code that satisfies: $REQUIREMENT"
echo "Deploy it with your MDM. Installed by hand, macOS ignores it."
