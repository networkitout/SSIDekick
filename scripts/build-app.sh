#!/bin/bash
# Builds build/WiFiUtil.app from the release product and signs it (no hardened runtime).
# Signing identity: $SIGN_IDENTITY, default "Apple Development". Works from any directory.
set -euo pipefail

export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
identity="${SIGN_IDENTITY:-Apple Development}"
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

# Captured first: under pipefail, grep -q closing the pipe early could fail the pipeline even on a match.
identities="$(security find-identity -v -p codesigning)"
if ! grep -qF -- "$identity" <<<"$identities"; then
    echo "error: no valid code signing identity matching \"$identity\" in the keychain." >&2
    echo "Set SIGN_IDENTITY to one listed by: security find-identity -v -p codesigning" >&2
    exit 1
fi

swift build -c release --product WiFiUtil
bin="$(swift build -c release --product WiFiUtil --show-bin-path)"

plutil -lint -s Support/Info.plist

app="build/WiFiUtil.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin/WiFiUtil" "$app/Contents/MacOS/WiFiUtil"
cp Support/Info.plist "$app/Contents/Info.plist"
cp Support/oui.tsv "$app/Contents/Resources/oui.tsv"

codesign --force --sign "$identity" "$app"
codesign --verify --strict "$app"

echo "$root/$app"
