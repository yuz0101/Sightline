#!/bin/bash
# Builds Sightline.app: SwiftPM release binary + Sparkle + Info.plist + signature.
#
# Signing is optional. The script signs with, in order:
#   1. $SIGHTLINE_SIGN_IDENTITY, when set;
#   2. the first "Apple Development" identity found on this Mac;
#   3. ad-hoc, with an explicit identifier-based designated requirement.
#
# Case 3 still keeps the Accessibility grant alive across rebuilds. A bare ad-hoc
# signature would key the grant on the cdhash, which changes on every build, so
# macOS would ask for permission again each time. The explicit requirement below
# replaces the cdhash with the bundle identifier.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"
OUTPUT_DIR="${SIGHTLINE_BUILD_DIR:-$ROOT/build}"
# File-provider-backed folders can add Finder metadata while codesign runs.
STAGING="$(mktemp -d /private/tmp/sightline-build.XXXXXXXX)"
trap 'rm -rf "$STAGING"' EXIT
APP="$STAGING/Sightline.app"
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$ROOT/Resources/Info.plist")"
IDENTITY="${SIGHTLINE_SIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ]; then
	# Use a local development certificate when one exists. Contributors without
	# an Apple account fall through to the ad-hoc path below.
	IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
		| sed -n 's/.*"\(Apple Development: [^"]*\)".*/\1/p' | head -1)"
fi
if [ ! -d "$ROOT/Vendor/Sparkle/Sparkle.framework" ] || [ ! -f "$ROOT/Vendor/Sparkle/LICENSE" ]; then
	"$ROOT/Scripts/fetch_sparkle.sh"
fi

mkdir -p "$ROOT/.scratch/tmp"
export TMPDIR="$ROOT/.scratch/tmp"

echo "==> swift build -c release"
BUILD_ARGS=(-c release --disable-sandbox --product Sightline --scratch-path "$ROOT/.scratch/products" -Xswiftc -gnone)
ARCHS=("$(uname -m)")
if [ "${SIGHTLINE_UNIVERSAL_BUILD:-0}" = 1 ]; then
	ARCHS=(arm64 x86_64)
fi
BINS=()
for arch in "${ARCHS[@]}"; do
	swift build "${BUILD_ARGS[@]}" --arch "$arch"
	BINS+=("$(swift build "${BUILD_ARGS[@]}" --arch "$arch" --show-bin-path)/Sightline")
done

echo "==> assembling $APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
EXE="$APP/Contents/MacOS/Sightline"
lipo -create "${BINS[@]}" -output "$EXE"
# The loose SwiftPM executable can find the vendor directory; a shipped app
# must load the embedded framework and must not disclose its build directory.
install_name_tool -delete_rpath "$ROOT/Vendor/Sparkle" "$EXE"
strip -S -x "$EXE"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
# A side-by-side development build needs its own identity in Privacy & Security.
# Set SIGHTLINE_PREVIEW_NAME to the name the user will see in Accessibility.
if [ -n "${SIGHTLINE_PREVIEW_NAME:-}" ]; then
	BUNDLE_ID="$BUNDLE_ID.preview"
	/usr/bin/plutil -replace CFBundleIdentifier -string "$BUNDLE_ID" "$APP/Contents/Info.plist"
	/usr/bin/plutil -replace CFBundleName -string "$SIGHTLINE_PREVIEW_NAME" "$APP/Contents/Info.plist"
	/usr/bin/plutil -replace CFBundleDisplayName -string "$SIGHTLINE_PREVIEW_NAME" "$APP/Contents/Info.plist"
	/usr/bin/plutil -remove SUFeedURL "$APP/Contents/Info.plist"
fi
cp "$ROOT/Vendor/Sparkle/LICENSE" "$APP/Contents/Resources/Sparkle-LICENSE"
cp -R "$ROOT/Vendor/Sparkle/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"

ICONSET="$ROOT/.scratch/Sightline.iconset"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
	for scale in 1 2; do
		pixels=$((size * scale))
		suffix=""
		if [ "$scale" = 2 ]; then suffix="@2x"; fi
		sips -z "$pixels" "$pixels" "$ROOT/Resources/Sightline.png" \
			--out "$ICONSET/icon_${size}x${size}${suffix}.png" >/dev/null
	done
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/Sightline.icns"

echo "==> signing"
xattr -cr "$APP"

sign() {
	if [ -n "$IDENTITY" ]; then
		case "$IDENTITY" in
			"Developer ID Application:"*) codesign --force --sign "$IDENTITY" --options runtime --timestamp "$@" ;;
			*) codesign --force --sign "$IDENTITY" --options runtime "$@" ;;
		esac
	else
		codesign --force --sign - --options runtime "$@"
	fi
}

FW="$APP/Contents/Frameworks/Sparkle.framework"
# Sparkle ships nested helpers; they must be signed before their container,
# otherwise codesign --verify --strict reports a modified bundle.
sign "$FW/Versions/B/Autoupdate"
sign "$FW/Versions/B/Updater.app"
sign "$FW/Versions/B/XPCServices/Downloader.xpc"
sign "$FW/Versions/B/XPCServices/Installer.xpc"
sign "$FW"
sign --identifier "$BUNDLE_ID" "$APP"

if [ -z "$IDENTITY" ]; then
	echo "==> no signing identity found; ad-hoc with an identifier-based requirement"
	codesign --force --sign - --identifier "$BUNDLE_ID" --options runtime \
		-r='designated => identifier "'"$BUNDLE_ID"'"' "$APP"
	SIGNED_WITH="ad-hoc (identifier-based requirement)"
else
	SIGNED_WITH="$IDENTITY"
fi

codesign --verify --deep --strict "$APP"
mkdir -p "$OUTPUT_DIR"
rm -rf "$OUTPUT_DIR/Sightline.app"
ditto --noextattr --norsrc --noqtn "$APP" "$OUTPUT_DIR/Sightline.app"
echo "==> built $OUTPUT_DIR/Sightline.app (signed with $SIGNED_WITH)"
