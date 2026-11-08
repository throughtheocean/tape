#!/bin/bash
# Builds, signs, notarizes and staples Tape for distribution outside the Mac App Store.
# Output: dist/Tape-<version>.zip and dist/Tape-<version>.dmg, both notarized and stapled.
# Prerequisites: a "Developer ID Application" identity in the login keychain, and notarytool credentials
# stored under the keychain profile "notary". No password is read or stored here.
set -euo pipefail
cd "$(dirname "$0")/.."

PROFILE=notary
DIST=dist
DERIVED=build/release-dd
ENTITLEMENTS=App/Tape.entitlements

step() { printf '\n==> %s\n' "$*"; }
fail() { printf '\nRELEASE FAILED: %s\n' "$*" >&2; exit 1; }

# Tracked changes would ship code that is not in any commit; untracked files do not affect the build.
if ! git diff --quiet HEAD --; then
  fail "uncommitted changes to tracked files; commit or stash them first"
fi

step "Signing identity"
IDENTITIES=$(security find-identity -v -p codesigning | grep '"Developer ID Application: ' || true)
COUNT=$(printf '%s' "$IDENTITIES" | grep -c . || true)
[[ "$COUNT" -eq 1 ]] || fail "expected exactly one Developer ID Application identity, found $COUNT"
IDENTITY=$(printf '%s' "$IDENTITIES" | sed -E 's/.*"(Developer ID Application: [^"]+)".*/\1/')
TEAM=$(printf '%s' "$IDENTITY" | sed -E 's/.*\(([A-Z0-9]+)\)$/\1/')
echo "$IDENTITY (team $TEAM)"

step "Release build"
command -v xcodegen >/dev/null && xcodegen generate -q
xcodebuild -project Tape.xcodeproj -scheme Tape -configuration Release -derivedDataPath "$DERIVED" \
  CODE_SIGN_IDENTITY="$IDENTITY" DEVELOPMENT_TEAM="$TEAM" clean build -quiet
BUILT="$DERIVED/Build/Products/Release/Tape.app"
[[ -d "$BUILT" ]] || fail "no app at $BUILT"

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$BUILT/Contents/Info.plist")
APP="$DIST/Tape.app"
UPLOAD="$DIST/Tape-$VERSION-upload.zip"
ZIP="$DIST/Tape-$VERSION.zip"
DMG="$DIST/Tape-$VERSION.dmg"
echo "version $VERSION"

step "Copy to $DIST"
mkdir -p "$DIST"
rm -rf "$APP" "$UPLOAD" "$ZIP" "$DMG" "$DIST/dmg-root"
ditto "$BUILT" "$APP"

step "Sign"
# --entitlements keeps the microphone entitlement; re-signing without it would drop it.
codesign --force --deep --options runtime --timestamp --entitlements "$ENTITLEMENTS" --sign "$IDENTITY" "$APP"

step "Verify signature"
codesign --verify --deep --strict --verbose=2 "$APP"
SIGNATURE=$(codesign -dv --verbose=4 "$APP" 2>&1)
echo "$SIGNATURE"
grep -q 'flags=0x10000(runtime)' <<<"$SIGNATURE" || fail "Hardened Runtime flag missing"
grep -q "Authority=$IDENTITY" <<<"$SIGNATURE" || fail "not signed by $IDENTITY"
grep -q 'Timestamp=' <<<"$SIGNATURE" || fail "no secure timestamp"
codesign -d --entitlements - "$APP" 2>/dev/null | grep -q 'com.apple.security.device.audio-input' \
  || fail "microphone entitlement missing"

# Submits a file and waits; prints the notary log and stops unless the status is Accepted.
notarize() {
  local file=$1 result id status
  result=$(xcrun notarytool submit "$file" --keychain-profile "$PROFILE" --wait --output-format json) || true
  echo "$result"
  id=$(plutil -extract id raw -o - - <<<"$result" 2>/dev/null || echo "")
  status=$(plutil -extract status raw -o - - <<<"$result" 2>/dev/null || echo "unknown")
  if [[ "$status" != "Accepted" ]]; then
    [[ -n "$id" ]] && xcrun notarytool log "$id" --keychain-profile "$PROFILE" || true
    fail "notarization of $file: status $status"
  fi
  echo "notarization of $file: Accepted (id $id)"
}

step "Notarize app"
ditto -c -k --keepParent "$APP" "$UPLOAD"
notarize "$UPLOAD"
rm -f "$UPLOAD"

step "Staple app"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"

step "Gatekeeper check (app)"
SPCTL=$(spctl -a -vv -t exec "$APP" 2>&1)
echo "$SPCTL"
grep -q 'source=Notarized Developer ID' <<<"$SPCTL" || fail "Gatekeeper does not see a notarized Developer ID app"

step "Final zip"
ditto -c -k --keepParent "$APP" "$ZIP"

step "DMG"
mkdir -p "$DIST/dmg-root"
ditto "$APP" "$DIST/dmg-root/Tape.app"
ln -s /Applications "$DIST/dmg-root/Applications"
hdiutil create -volname "Tape $VERSION" -srcfolder "$DIST/dmg-root" -fs HFS+ -format UDZO -ov "$DMG" -quiet
rm -rf "$DIST/dmg-root"
codesign --force --timestamp --sign "$IDENTITY" "$DMG"
codesign --verify --verbose=2 "$DMG"
notarize "$DMG"
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"

step "Gatekeeper check (dmg)"
SPCTL_DMG=$(spctl -a -vv -t open --context context:primary-signature "$DMG" 2>&1)
echo "$SPCTL_DMG"
grep -q 'source=Notarized Developer ID' <<<"$SPCTL_DMG" || fail "Gatekeeper does not see a notarized Developer ID disk image"

step "Done"
echo "$ZIP"
echo "$DMG"
echo "$APP"
