#!/bin/bash
set -euo pipefail
VERSION=${1:?usage: scripts/release.sh <version> [--adhoc]}
ADHOC=${2:-}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT=$ROOT/build/release
cd "$ROOT"

if [ "$ADHOC" = --adhoc ]; then
  IDENTITY="-"
else
  IDENTITY=${DEVELOPER_ID:-Developer ID Application: Tomasz Kubiak (76QV9GADHD)}
  SPARKLE_FEED_URL=${SPARKLE_FEED_URL:-https://github.com/tomaszkubiak-courses/macscp/releases/latest/download/appcast.xml}
fi

[ -d Frameworks/CSSH.xcframework ] || scripts/build-cssh.sh
xcodegen -q
rm -rf "$OUT" && mkdir -p "$OUT"
xcodebuild -project MacSCP.xcodeproj -scheme MacSCP -configuration Release -derivedDataPath "$OUT/dd" \
  -destination "generic/platform=macOS" ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
  MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$(git rev-list --count HEAD)" \
  CODE_SIGN_IDENTITY="$IDENTITY" CODE_SIGN_STYLE=Manual OTHER_CODE_SIGN_FLAGS="--timestamp" CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
  SPARKLE_FEED_URL="${SPARKLE_FEED_URL:-}" \
  build | grep -E 'error:|BUILD' || true
APP=$OUT/dd/Build/Products/Release/MacSCP.app
[ -d "$APP" ] || { echo "build failed" >&2; exit 1; }
if [ "$ADHOC" != --adhoc ]; then
  SIGN=(codesign --force --timestamp --options runtime -s "$IDENTITY")
  SP="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
  "${SIGN[@]}" "$SP/XPCServices/Installer.xpc"
  "${SIGN[@]}" --preserve-metadata=entitlements "$SP/XPCServices/Downloader.xpc"
  "${SIGN[@]}" "$SP/Autoupdate"
  "${SIGN[@]}" "$SP/Updater.app"
  "${SIGN[@]}" "$APP/Contents/Frameworks/Sparkle.framework"
  "${SIGN[@]}" "$APP"
fi
codesign --verify --deep --strict "$APP"
lipo -archs "$APP/Contents/MacOS/MacSCP"

DMG=$OUT/MacSCP-$VERSION.dmg
STAGE=$OUT/dmg && mkdir -p "$STAGE" && cp -R "$APP" "$STAGE/" && ln -s /Applications "$STAGE/Applications"
hdiutil create -quiet -volname "MacSCP $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
codesign --force --timestamp -s "$IDENTITY" "$DMG" 2>/dev/null || codesign --force -s "$IDENTITY" "$DMG"

if [ "$ADHOC" != --adhoc ]; then
  xcrun notarytool submit "$DMG" --keychain-profile "${NOTARY_PROFILE:-notary}" --wait
  xcrun stapler staple "$DMG"
  spctl --assess --type open --context context:primary-signature -v "$DMG"
  GEN=$(find "$OUT/dd/SourcePackages/artifacts" -path '*Sparkle/bin/generate_appcast' | head -1)
  mkdir -p build/updates && cp "$DMG" build/updates/
  KEYARG=(); [ -n "${SPARKLE_KEY_FILE:-}" ] && KEYARG=(--ed-key-file "$SPARKLE_KEY_FILE")
  "$GEN" ${KEYARG[@]+"${KEYARG[@]}"} --download-url-prefix "https://github.com/tomaszkubiak-courses/macscp/releases/download/v$VERSION/" build/updates
  for old in build/updates/MacSCP-*.dmg; do
    v=$(basename "$old" .dmg); v=${v#MacSCP-}
    [ "$v" = "$VERSION" ] || sed -i '' "s|download/v$VERSION/MacSCP-$v.dmg|download/v$v/MacSCP-$v.dmg|" build/updates/appcast.xml
  done
  echo "Upload build/updates/appcast.xml, $DMG and build/updates/*.delta referenced in the appcast;" \
    "update Casks/macscp.rb sha256: $(shasum -a 256 "$DMG" | cut -d' ' -f1)"
fi
echo "$DMG"
