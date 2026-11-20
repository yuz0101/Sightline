#!/bin/bash
# Builds a universal, Developer ID–signed, notarized Sightline.app for GitHub Releases.
#
# Prerequisites:
#   1. Apple Developer Program membership ($99/year).
#   2. A "Developer ID Application" certificate in the login keychain.
#   3. Notary credentials stored once (an app-specific password from appleid.apple.com):
#        xcrun notarytool store-credentials SightlineNotary \
#          --apple-id you@example.com --team-id YOURTEAMID
#
# Usage:
#   DEVELOPER_ID_APP="Developer ID Application: Your Name (TEAMID)" ./Scripts/release_app.sh
#   NOTARY_PROFILE=SightlineNotary (optional; defaults to that name)
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"
STAGING="$(mktemp -d /private/tmp/sightline-release.XXXXXXXX)"
trap 'rm -rf "$STAGING"' EXIT
APP="$STAGING/Sightline.app"
mkdir -p "$ROOT/build"
IDENTITY="${DEVELOPER_ID_APP:?set DEVELOPER_ID_APP to your Developer ID Application identity}"
PROFILE="${NOTARY_PROFILE:-SightlineNotary}"

# Multi-arch builds go through xcbuild, which ships with Xcode, not with the
# Command Line Tools. Point at Xcode when it is installed.
if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode.app/Contents/Developer ]; then
	export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
case "$IDENTITY" in
	"Developer ID Application:"*) ;;
	*) echo "error: a Developer ID Application identity is required" >&2; exit 1 ;;
esac
SIGHTLINE_BUILD_DIR="$STAGING" SIGHTLINE_SIGN_IDENTITY="$IDENTITY" SIGHTLINE_UNIVERSAL_BUILD=1 "$ROOT/Scripts/build_app.sh"
lipo "$APP/Contents/MacOS/Sightline" -verify_arch arm64 x86_64
echo "==> notarizing (this uploads to Apple and can take a few minutes)"
rm -f "$ROOT/build/Sightline.zip"
/usr/bin/ditto -c -k --norsrc --noextattr --noqtn --keepParent "$APP" "$ROOT/build/Sightline.zip"
NOTARY_AUTH=(--keychain-profile "$PROFILE")
if [ -n "${ASC_KEY_PATH:-}" ]; then
	NOTARY_AUTH=(--key "$ASC_KEY_PATH" --key-id "${ASC_KEY_ID:?set ASC_KEY_ID}")
	if [ -n "${ASC_ISSUER_ID:-}" ]; then NOTARY_AUTH+=(--issuer "$ASC_ISSUER_ID"); fi
fi
xcrun notarytool submit "$ROOT/build/Sightline.zip" "${NOTARY_AUTH[@]}" --wait

echo "==> stapling the ticket"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"

echo "==> checking Gatekeeper"
spctl -a -vvv "$APP"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/Resources/Info.plist")"

echo "==> packaging"
rm -f "$ROOT/build/Sightline.zip" "$ROOT/build/Sightline.zip.sha256"
/usr/bin/ditto -c -k --norsrc --noextattr --noqtn --keepParent "$APP" "$ROOT/build/Sightline.zip"
(cd "$ROOT/build" && shasum -a 256 Sightline.zip > Sightline.zip.sha256)
echo "==> writing the appcast"
"$ROOT/Scripts/make_appcast.sh" "$ROOT/build/Sightline.zip"

echo "==> release artifacts"
echo "    build/Sightline.zip"
echo "    build/Sightline.zip.sha256"
echo "    build/appcast.xml"
echo
echo "Publish with:"
echo "  gh release create v$VERSION build/Sightline.zip build/Sightline.zip.sha256 build/appcast.xml \\"
echo "    --title \"Sightline $VERSION\" --notes \"...\""
echo "Keep the appcast asset name exactly appcast.xml: SUFeedURL expects"
echo "https://github.com/<owner>/<repo>/releases/latest/download/appcast.xml"
