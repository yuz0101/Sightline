#!/bin/bash
# Writes build/appcast.xml for the current version, signed with Sparkle's EdDSA key.
#
# Usage:
#   Scripts/make_appcast.sh [path/to/Sightline.zip]
#
# Environment:
#   SIGHTLINE_REPO   GitHub owner/name, default yuz0101/Sightline
#   SIGHTLINE_TAG    Release tag, default v<CFBundleShortVersionString>
#
# The key pair is created once with Vendor/Sparkle/bin/generate_keys; the private
# half stays in the login keychain, the public half lives in Info.plist.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"
ZIP="${1:-$ROOT/build/Sightline.zip}"
[ -f "$ZIP" ] || { echo "error: no archive at $ZIP" >&2; exit 1; }

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/Resources/Info.plist")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$ROOT/Resources/Info.plist")"
REPO="${SIGHTLINE_REPO:-yuz0101/Sightline}"
TAG="${SIGHTLINE_TAG:-v$VERSION}"
URL="https://github.com/$REPO/releases/download/$TAG/Sightline.zip"
SIGN_UPDATE="$ROOT/Vendor/Sparkle/bin/sign_update"
[ -x "$SIGN_UPDATE" ] || { echo "error: $SIGN_UPDATE missing; run Scripts/fetch_sparkle.sh" >&2; exit 1; }

# Prints: sparkle:edSignature="..." length="12345"
if [ -n "${SPARKLE_PRIVATE_KEY_FILE:-}" ]; then
	ATTRIBUTES="$("$SIGN_UPDATE" --ed-key-file "$SPARKLE_PRIVATE_KEY_FILE" "$ZIP")"
else
	ATTRIBUTES="$("$SIGN_UPDATE" "$ZIP")"
fi
DATE="$(date -u '+%a, %d %b %Y %H:%M:%S +0000')"

cat > "$ROOT/build/appcast.xml" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Sightline</title>
    <link>https://github.com/$REPO</link>
    <description>Attention-weighted window boards for wide displays.</description>
    <language>en</language>
    <item>
      <title>Version $VERSION</title>
      <pubDate>$DATE</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <enclosure url="$URL" type="application/octet-stream" $ATTRIBUTES/>
    </item>
  </channel>
</rss>
XML

echo "==> wrote build/appcast.xml ($VERSION, build $BUILD)"
echo "    upload it as a release asset named appcast.xml so SUFeedURL can point at"
echo "    https://github.com/$REPO/releases/latest/download/appcast.xml"
