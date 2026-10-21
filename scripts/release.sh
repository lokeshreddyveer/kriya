#!/bin/bash
# Builds Kriya, signs it with your Developer ID, has Apple notarize it, staples the ticket and packs a DMG that opens
# with no Gatekeeper warning.
#
#   scripts/release.sh --check              only checks that the certificate and notary login are usable
#   scripts/release.sh <version> <build>    full release, e.g. scripts/release.sh 0.1.0 1
#
# One-time setup (the same login works for every app on your team):
#   xcrun notarytool store-credentials Kriya-NOTARY --apple-id <Apple ID email> --team-id <TEAM ID>
# Environment:
#   NOTARY_PROFILE      keychain profile name (default Kriya-NOTARY; StreamSetu-NOTARY or BrowserSetu-NOTARY work if you have one)
#   SIGN_IDENTITY       certificate hash to use (default: the first "Developer ID Application" certificate found)
#   SPARKLE_PUBLIC_KEY  public half of the update-signing key; the updater stays off in a build without it
#
# Nothing is uploaded except the notarization submission itself, which Apple requires.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export PATH="$HOME/.cargo/bin:$PATH"

fail() { echo "✘ $*" >&2; exit 1; }

NOTARY_PROFILE="${NOTARY_PROFILE:-Kriya-NOTARY}"
if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
  for other in StreamSetu-NOTARY BrowserSetu-NOTARY; do
    if xcrun notarytool history --keychain-profile "$other" >/dev/null 2>&1; then NOTARY_PROFILE="$other"; break; fi
  done
fi
SIGN_IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning | grep "Developer ID Application" | head -1 | awk '{print $2}')}"
[ -n "$SIGN_IDENTITY" ] || fail "no 'Developer ID Application' certificate found. Create one in Xcode > Settings > Accounts > Manage Certificates."
IDENTITY_NAME=$(security find-identity -v -p codesigning | grep "$SIGN_IDENTITY" | head -1 | sed 's/.*"\(.*\)"/\1/')
TEAM_ID=$(echo "$IDENTITY_NAME" | sed -n 's/.*(\([A-Z0-9]\{10\}\))$/\1/p')
[ -n "$TEAM_ID" ] || fail "could not read the team ID from '$IDENTITY_NAME'."
xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 \
  || fail "notary profile '$NOTARY_PROFILE' is not set up. Run the one-time setup at the top of this script."
echo "▸ Signing as: $IDENTITY_NAME"
echo "▸ Notary profile: $NOTARY_PROFILE"

[ "${1:-}" = "--check" ] && { echo "✔ certificate and notary login are usable"; exit 0; }

VERSION="${1:?usage: scripts/release.sh <version> <build>  (or --check)}"
BUILD="${2:?usage: scripts/release.sh <version> <build>  (or --check)}"
APP_NAME="Kriya"
DERIVED="build/release"
DIST="dist"
rm -rf "$DIST" "$DERIVED"; mkdir -p "$DIST"

echo "▸ Running the core's tests"; scripts/build-core.sh test
echo "▸ Building the Rust core (universal)"; scripts/build-core.sh
cp apps/macos/Generated/CORE_SOURCE_HASH "$DIST/core-build-identity.txt"
(cd apps/macos && xcodegen generate --spec project.yml >/dev/null)

echo "▸ Building $VERSION ($BUILD) for Apple Silicon and Intel"
xcodebuild -project apps/macos/Kriya.xcodeproj -scheme Kriya -configuration Release \
  -derivedDataPath "$DERIVED" ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
  MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD" \
  SPARKLE_PUBLIC_KEY="${SPARKLE_PUBLIC_KEY:-ERIBpYqmQwW3v6Jy6G1KMI0Rgu6HXA3Og6XmyySGPKQ=}" \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$SIGN_IDENTITY" DEVELOPMENT_TEAM="$TEAM_ID" \
  ENABLE_HARDENED_RUNTIME=YES OTHER_CODE_SIGN_FLAGS="--timestamp" build | tail -3

APP="$DERIVED/Build/Products/Release/$APP_NAME.app"
[ -d "$APP" ] || fail "the build did not produce $APP"

# Sparkle's helpers are signed innermost first with the same identity, hardened runtime and a timestamp, as notarization requires.
SP="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
if [ -d "$SP" ]; then
  for part in "$SP/XPCServices/Installer.xpc" "$SP/XPCServices/Downloader.xpc" "$SP/Autoupdate" "$SP/Updater.app" "$APP/Contents/Frameworks/Sparkle.framework"; do
    [ -e "$part" ] && codesign --force --timestamp --options runtime --sign "$SIGN_IDENTITY" "$part"
  done
  codesign --force --timestamp --options runtime --sign "$SIGN_IDENTITY" --entitlements apps/macos/Kriya.entitlements "$APP"
fi
codesign --verify --deep --strict --verbose=2 "$APP" 2>&1 | tail -2

# The Finder extension must be there and sandboxed (Finder refuses an unsandboxed one); the app itself must not be.
APPEX="$APP/Contents/PlugIns/KriyaFinder.appex"
[ -d "$APPEX" ] || fail "the Finder extension is missing from the app."
EXT_SANDBOX="$(codesign -d --entitlements - --xml "$APPEX" 2>/dev/null | python3 -c 'import sys,plistlib; d=sys.stdin.buffer.read(); print(str(plistlib.loads(d[d.index(b"<?xml"):]).get("com.apple.security.app-sandbox", "absent")).lower())' 2>/dev/null || echo unknown)"
[ "$EXT_SANDBOX" = "true" ] || fail "the Finder extension's sandbox entitlement is '$EXT_SANDBOX', not true."

# The binary must hold both processors, and must not be sandboxed: a sandboxed build cannot do what Kriya does.
ARCHS_FOUND="$(lipo -archs "$APP/Contents/MacOS/$APP_NAME")"
case "$ARCHS_FOUND" in *arm64*x86_64*|*x86_64*arm64*) ;; *) fail "the app is not universal (found: $ARCHS_FOUND)";; esac
SANDBOX="$(codesign -d --entitlements - --xml "$APP" 2>/dev/null | python3 -c 'import sys,plistlib; d=sys.stdin.buffer.read(); print(str(plistlib.loads(d[d.index(b"<?xml"):]).get("com.apple.security.app-sandbox", "absent")).lower())' 2>/dev/null || echo unknown)"
[ "$SANDBOX" = "absent" ] || fail "the app's sandbox entitlement is '$SANDBOX'; Kriya must be released unsandboxed."

echo "▸ Notarizing the app (this waits for Apple)"
ZIP="$DIST/$APP_NAME.zip"
ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$APP"
rm -f "$ZIP"

echo "▸ Making the disk image"
STAGE="$DIST/stage"; mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
DMG="$DIST/Kriya-$VERSION.dmg"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"
codesign --sign "$SIGN_IDENTITY" --timestamp "$DMG"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"
spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG" 2>&1 | tail -2
echo "✔ $DMG is signed, notarized and stapled"
shasum -a 256 "$DMG"
echo "Next: sign the DMG for Sparkle (sign_update), add it to appcast.xml, and upload the DMG."
