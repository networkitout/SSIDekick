#!/bin/bash
# Builds, signs (Developer ID), notarizes and staples WiFiUtil, then prints the path of the zip to ship.
#
# Needs, once per machine (see README "Releasing"):
#   - a "Developer ID Application" certificate with its private key in the login keychain
#   - notary credentials stored with `xcrun notarytool store-credentials` under $NOTARY_PROFILE
#
# Environment:
#   SIGN_IDENTITY   Developer ID identity to sign with. Optional when the keychain holds exactly one.
#   NOTARY_PROFILE  notarytool keychain profile name. Default: wifiutil-notary
# Works from any directory.
set -euo pipefail

export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
profile="${NOTARY_PROFILE:-wifiutil-notary}"

# Captured first: under pipefail, grep closing the pipe early could fail the pipeline even on a match.
identities="$(security find-identity -v -p codesigning)"
dev_ids="$(sed -n 's/.*"\(Developer ID Application: .*\)"$/\1/p' <<<"$identities" | sort -u)"

if [[ -n "${SIGN_IDENTITY:-}" ]]; then
    if [[ "$SIGN_IDENTITY" != "Developer ID Application"* ]]; then
        echo "error: SIGN_IDENTITY must be a \"Developer ID Application\" identity; got \"$SIGN_IDENTITY\"." >&2
        exit 1
    fi
    identity="$SIGN_IDENTITY"
elif [[ -z "$dev_ids" ]]; then
    cat >&2 <<'EOF'
error: no "Developer ID Application" signing identity in the keychain.
Apps for other people's Macs must be signed with Developer ID and notarized, which needs a paid
Apple Developer Program membership. Create the certificate in Xcode > Settings > Accounts >
Manage Certificates (+ > Developer ID Application), then run this script again.
Identities found now:
EOF
    sed 's/^/  /' <<<"$identities" >&2
    exit 1
elif [[ "$(wc -l <<<"$dev_ids")" -gt 1 ]]; then
    echo "error: more than one Developer ID Application identity; set SIGN_IDENTITY to one of:" >&2
    sed 's/^/  /' <<<"$dev_ids" >&2
    exit 1
else
    identity="$dev_ids"
fi

app="$(SIGN_IDENTITY="$identity" scripts/build-app.sh | tail -n 1)"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")"
outdir="$root/build/release"
zip="$outdir/WiFiUtil-$version.zip"
mkdir -p "$outdir"
rm -f "$zip"

echo "Submitting $app for notarization (profile \"$profile\"); this usually takes a few minutes..."
ditto -c -k --keepParent "$app" "$zip"
result="$(xcrun notarytool submit "$zip" --keychain-profile "$profile" --wait --output-format json)"
status="$(plutil -extract status raw -o - - <<<"$result" 2>/dev/null || echo unknown)"
if [[ "$status" != "Accepted" ]]; then
    id="$(plutil -extract id raw -o - - <<<"$result" 2>/dev/null || echo '<submission id>')"
    echo "error: notarization status \"$status\"." >&2
    echo "$result" >&2
    echo "See why with: xcrun notarytool log $id --keychain-profile \"$profile\"" >&2
    exit 1
fi

xcrun stapler staple "$app"
xcrun stapler validate "$app"
spctl --assess --type execute --verbose "$app"

# Re-zip so the shipped archive carries the stapled ticket (works offline on first launch).
rm -f "$zip"
ditto -c -k --keepParent "$app" "$zip"

echo "$zip"
