#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=$(grep MARKETING_VERSION project.yml | awk '{print $2}')
OUT=build/release
rm -rf "$OUT"; mkdir -p "$OUT"

if [[ -n "$(git status --porcelain)" ]]; then
  echo "working tree not clean"; exit 1
fi

xcodegen generate -q
xcodebuild -project Tape.xcodeproj -scheme Tape -configuration Release \
  -archivePath "$OUT/Tape.xcarchive" archive
xcodebuild -exportArchive -archivePath "$OUT/Tape.xcarchive" \
  -exportOptionsPlist ExportOptions.plist -exportPath "$OUT/export"

APP="$OUT/export/Tape.app"
ZIP="$OUT/Tape-$VERSION.zip"

ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile tape-notary --wait
xcrun stapler staple "$APP"
ditto -c -k --keepParent "$APP" "$ZIP"

codesign --verify --deep --strict --verbose=2 "$APP"
spctl -a -vv -t exec "$APP"
echo "$ZIP"
