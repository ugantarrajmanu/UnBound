#!/usr/bin/env bash
# Builds the downloadable release artifacts into dist/:
#   Unbound-<version>.dmg   Mac menu-bar app (universal: Apple Silicon + Intel)
#   Unbound-<version>.apk   Android tablet app
#
# Mac signing (auto-detected, or set MAC_SIGN_IDENTITY):
#   "Developer ID Application: …"  → distributable; notarized when NOTARY_PROFILE is set
#   "Apple Development: …"         → runs on this Mac / your test Macs only
#   none                           → ad-hoc ("-"), for local testing
# Notarization one-time setup:
#   xcrun notarytool store-credentials unbound-notary --apple-id <id> --team-id <team> --password <app-specific-pw>
#   NOTARY_PROFILE=unbound-notary scripts/package.sh
#
# Android signing: uses UNBOUND_KEYSTORE / UNBOUND_KEYSTORE_PASSWORD if set; otherwise creates
# a release key in ~/.unbound-signing/ on first run. BACK THAT FOLDER UP — losing the key means
# existing installs can never be updated.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${VERSION:-1.0.0}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
BUNDLE_ID="app.unbound.mac"
DIST="$ROOT/dist"
WORK="$ROOT/dist/.work"
rm -rf "$WORK" && mkdir -p "$WORK" "$DIST"

step() { printf '\n==> %s\n' "$*"; }

# ---------------------------------------------------------------- Mac app
step "Building Unbound for Mac (arm64 + x86_64)"
UNIVERSAL=(-c release --package-path "$ROOT/mac" --product Unbound --arch arm64 --arch x86_64)
swift build "${UNIVERSAL[@]}" 2>&1 | grep -vE '^\[[0-9]+/[0-9]+\]' || true
BIN="$(swift build "${UNIVERSAL[@]}" --show-bin-path)/Unbound"
lipo -info "$BIN"

step "Rendering app icon"
swift "$ROOT/scripts/make-icon.swift" "$WORK/AppIcon.iconset" >/dev/null
iconutil -c icns "$WORK/AppIcon.iconset" -o "$WORK/AppIcon.icns"

step "Assembling Unbound.app"
APP="$WORK/Unbound.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Unbound"
cp "$WORK/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Unbound</string>
    <key>CFBundleDisplayName</key><string>Unbound</string>
    <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
    <key>CFBundleExecutable</key><string>Unbound</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${BUILD_NUMBER}</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
    <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSLocalNetworkUsageDescription</key>
    <string>Unbound lets your Android tablet find this Mac on Wi-Fi so it can be used as a second display.</string>
    <key>NSBonjourServices</key><array><string>_unbound._tcp</string></array>
    <key>NSHumanReadableCopyright</key><string>© $(date +%Y) Unbound</string>
</dict>
</plist>
PLIST

if [[ -z "${MAC_SIGN_IDENTITY:-}" ]]; then
  MAC_SIGN_IDENTITY="$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application:[^"]*\)".*/\1/p' | head -1)"
  [[ -z "$MAC_SIGN_IDENTITY" ]] && MAC_SIGN_IDENTITY="$(security find-identity -v -p codesigning | sed -n 's/.*"\(Apple Development:[^"]*\)".*/\1/p' | head -1)"
  [[ -z "$MAC_SIGN_IDENTITY" ]] && MAC_SIGN_IDENTITY="-"
fi
step "Signing with: $MAC_SIGN_IDENTITY"
SIGN_ARGS=(--force --options runtime --sign "$MAC_SIGN_IDENTITY")
[[ "$MAC_SIGN_IDENTITY" == Developer\ ID* ]] && SIGN_ARGS+=(--timestamp)
codesign "${SIGN_ARGS[@]}" "$APP"
codesign --verify --strict --verbose=1 "$APP"

step "Creating DMG"
DMG="$DIST/Unbound-$VERSION.dmg"
STAGE="$WORK/dmg"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -quiet -volname "Unbound $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO "$DMG"
if [[ "$MAC_SIGN_IDENTITY" == Developer\ ID* ]]; then
  codesign --force --timestamp --sign "$MAC_SIGN_IDENTITY" "$DMG"
elif [[ "$MAC_SIGN_IDENTITY" != "-" ]]; then
  codesign --force --sign "$MAC_SIGN_IDENTITY" "$DMG"
fi

if [[ "$MAC_SIGN_IDENTITY" == Developer\ ID* && -n "${NOTARY_PROFILE:-}" ]]; then
  step "Notarizing (this can take a few minutes)"
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG"
  spctl --assess --type open --context context:primary-signature --verbose "$DMG" || true
  MAC_STATUS="signed with Developer ID and notarized — ready to publish"
elif [[ "$MAC_SIGN_IDENTITY" == Developer\ ID* ]]; then
  MAC_STATUS="signed with Developer ID but NOT notarized (set NOTARY_PROFILE) — Gatekeeper will warn"
else
  MAC_STATUS="NOT distributable: needs a Developer ID Application certificate (other Macs will block it)"
fi

# ---------------------------------------------------------------- Android app
step "Building Unbound for Android (release)"
if command -v jenv >/dev/null && J="$(cd "$ROOT" && jenv prefix 2>/dev/null)"; then export JAVA_HOME="$J"; fi
if [[ -z "${UNBOUND_KEYSTORE:-}" ]]; then
  KEYDIR="$HOME/.unbound-signing"
  if [[ ! -f "$KEYDIR/release.jks" ]]; then
    step "Creating Android release key in $KEYDIR (BACK THIS UP)"
    mkdir -p "$KEYDIR" && chmod 700 "$KEYDIR"
    PASS="$(openssl rand -base64 24 | tr -d '/+=')"
    "$JAVA_HOME/bin/keytool" -genkeypair -keystore "$KEYDIR/release.jks" -alias unbound -keyalg RSA -keysize 4096 \
      -validity 10000 -storepass "$PASS" -keypass "$PASS" -dname "CN=Unbound, O=Unbound" >/dev/null 2>&1
    printf 'UNBOUND_KEYSTORE_PASSWORD=%s\n' "$PASS" > "$KEYDIR/keystore.env"
    chmod 600 "$KEYDIR/keystore.env" "$KEYDIR/release.jks"
  fi
  export UNBOUND_KEYSTORE="$KEYDIR/release.jks"
  # shellcheck disable=SC1091
  source "$KEYDIR/keystore.env"
  export UNBOUND_KEYSTORE_PASSWORD
fi
(cd "$ROOT/android" && ./gradlew -q --console=plain assembleRelease)
APK="$DIST/Unbound-$VERSION.apk"
cp "$ROOT/android/app/build/outputs/apk/release/app-release.apk" "$APK"
APKSIGNER="$(ls -d "$HOME"/Library/Android/sdk/build-tools/*/apksigner 2>/dev/null | sort -V | tail -1)"
[[ -n "$APKSIGNER" ]] && "$APKSIGNER" verify "$APK" && echo "APK signature verified"

rm -rf "$WORK"
step "Done"
( cd "$DIST" && shasum -a 256 "Unbound-$VERSION.dmg" "Unbound-$VERSION.apk" )
echo
echo "Mac:     $MAC_STATUS"
echo "Android: signed release APK (sideload, or upload to Google Play)"
