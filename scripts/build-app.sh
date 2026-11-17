#!/bin/bash
# Builds build/WiFiUtil.app as a universal (arm64 + x86_64) release binary and signs it with the
# hardened runtime and Support/WiFiUtil.entitlements.
# Signing identity: $SIGN_IDENTITY, default "Apple Development". A "Developer ID Application"
# identity also gets a secure timestamp (required for notarization); scripts/release.sh uses that.
# Works from any directory.
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

archs=(--arch arm64 --arch x86_64)
swift build -c release --product WiFiUtil "${archs[@]}"
bin="$(swift build -c release --product WiFiUtil "${archs[@]}" --show-bin-path)"

plutil -lint -s Support/Info.plist
plutil -lint -s Support/WiFiUtil.entitlements

app="build/WiFiUtil.app"
exe="$app/Contents/MacOS/WiFiUtil"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin/WiFiUtil" "$exe"
cp Support/Info.plist "$app/Contents/Info.plist"
cp Support/oui.tsv "$app/Contents/Resources/oui.tsv"

# The linker records rpaths into this machine's Xcode toolchain. Every Swift library the app links
# lives in /usr/lib/swift on macOS 15+, so those paths are unused; drop them so the shipped binary
# doesn't point at locations on the build machine.
while read -r rpath; do
    install_name_tool -delete_rpath "$rpath" "$exe"
done < <(otool -l "$exe" | awk '$1 == "path" { print $2 }' | grep -v -e '^/usr/lib/' -e '^@' | sort -u)

for arch in arm64 x86_64; do
    if ! lipo "$exe" -verify_arch "$arch"; then
        echo "error: $exe is missing the $arch slice." >&2
        exit 1
    fi
done

# Developer ID builds need a secure timestamp for notarization; local dev builds skip it so they
# don't depend on Apple's timestamp server.
case "$identity" in
    "Developer ID Application"*) timestamp=--timestamp ;;
    *) timestamp=--timestamp=none ;;
esac

codesign --force --sign "$identity" --options runtime "$timestamp" \
    --entitlements Support/WiFiUtil.entitlements "$app"
codesign --verify --strict --deep "$app"

echo "$root/$app"
