#!/bin/bash
# Fetches the Sparkle release and vendors the pieces Sightline needs.
#
#   Vendor/Sparkle/Sparkle.framework   linked and embedded by build_app.sh
#   Vendor/Sparkle/bin/generate_keys   creates the EdDSA key pair (once)
#   Vendor/Sparkle/bin/sign_update     signs a release archive for the appcast
#
# Sparkle is not consumed through SwiftPM on purpose: the package manager needs a
# git clone, which is unreliable on some networks, while a release tarball is a
# single resumed download. Run this script once per checkout.
set -euo pipefail

SPARKLE_VERSION="${SPARKLE_VERSION:-2.10.1}"
cd "$(dirname "$0")/.."
ROOT="$PWD"
DEST="$ROOT/Vendor/Sparkle"
CACHE="$ROOT/.scratch/Sparkle-$SPARKLE_VERSION.tar.xz"
# Filled in after the first verified download; empty means "do not check".
SHA256="${SPARKLE_SHA256:-1a856d2a9edb8e628de88121d7be04cf0e2167f8641650b78fca00b14244cf27}"

mkdir -p "$DEST" "$ROOT/.scratch"

if [ ! -f "$CACHE" ]; then
	echo "==> downloading Sparkle $SPARKLE_VERSION (about 16 MB, resumable)"
	curl --fail --location --retry 20 --retry-delay 5 --retry-all-errors \
		--continue-at - --output "$CACHE" \
		"https://github.com/sparkle-project/Sparkle/releases/download/$SPARKLE_VERSION/Sparkle-$SPARKLE_VERSION.tar.xz"
fi

if [ -n "$SHA256" ]; then
	actual="$(shasum -a 256 "$CACHE" | awk '{print $1}')"
	if [ "$actual" != "$SHA256" ]; then
		echo "error: checksum mismatch for $CACHE" >&2
		echo "  expected $SHA256" >&2
		echo "  got      $actual" >&2
		rm -f "$CACHE"
		exit 1
	fi
fi

echo "==> extracting into Vendor/Sparkle"
rm -rf "$DEST/Sparkle.framework" "$DEST/bin"
mkdir -p "$DEST/bin"
tar -xJf "$CACHE" -C "$ROOT/.scratch"
EXTRACTED="$ROOT/.scratch/Sparkle-$SPARKLE_VERSION"
if [ ! -d "$EXTRACTED" ]; then
	# The archive may unpack straight into .scratch when it has no top folder.
	EXTRACTED="$ROOT/.scratch"
fi
cp "$EXTRACTED/LICENSE" "$DEST/LICENSE"
cp -R "$EXTRACTED/Sparkle.framework" "$DEST/Sparkle.framework"
cp "$EXTRACTED/bin/generate_keys" "$EXTRACTED/bin/sign_update" "$DEST/bin/"
chmod +x "$DEST/bin/"*

echo "==> vendored Sparkle $SPARKLE_VERSION"
echo "    framework: $DEST/Sparkle.framework"
echo "    tools:     $DEST/bin/generate_keys, $DEST/bin/sign_update"
