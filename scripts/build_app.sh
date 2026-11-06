#!/bin/bash
# Builds dist/WhiteShot.app and a disk image, dist/WhiteShot-<version>.dmg.
#
#   ./scripts/build_app.sh
#
# Without any environment variables the app is ad-hoc signed: fine for your own Mac, but
# Gatekeeper will warn everyone else (right-click > Open). For a signed and notarized release
# other people can open without warnings, set both of these (an Apple Developer Program
# membership, a "Developer ID Application" certificate and stored notarytool credentials are
# the one-time setup; see CONTRIBUTING.md):
#
#   SIGNING_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
#   NOTARY_PROFILE="your-notarytool-profile" \
#   ./scripts/build_app.sh
#
# The version comes from the git tag (v1.2.0 -> 1.2.0), so tag first, then build. A signed build refuses to run
# unless HEAD is exactly at a version tag; untagged builds are 0.0.0.
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="WhiteShot"
DERIVED_DATA=".build"
APP="dist/${APP_NAME}.app"
SIGNING_IDENTITY="${SIGNING_IDENTITY:-}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"

command -v xcodegen >/dev/null 2>&1 || { echo "ERROR: xcodegen not found. Install it with 'brew install xcodegen'." >&2; exit 1; }

echo "==> Generating the Xcode project..."
xcodegen generate --spec project.yml >/dev/null

# The version is the git tag. It goes into the build as settings, so the Info.plist is right from the start.
TAG_VERSION="$(scripts/stamp_version.sh --print)"
VERSION_SETTINGS=()
if [ -n "$TAG_VERSION" ]; then
  VERSION_SETTINGS=("MARKETING_VERSION=$TAG_VERSION" "CURRENT_PROJECT_VERSION=$TAG_VERSION")
fi

echo "==> Building the release binary..."
# Unsigned on purpose: signing happens once, below, the same way for every path.
xcodebuild -project "${APP_NAME}.xcodeproj" -scheme "$APP_NAME" -configuration Release \
  -derivedDataPath "$DERIVED_DATA" -destination "platform=macOS" CODE_SIGNING_ALLOWED=NO \
  ${VERSION_SETTINGS[@]+"${VERSION_SETTINGS[@]}"} build >/dev/null

rm -rf dist
mkdir -p dist
cp -R "${DERIVED_DATA}/Build/Products/Release/${APP_NAME}.app" "$APP"

# What the finished app says; for a signed release it has to be exactly the tag.
VERSION="$(plutil -extract CFBundleShortVersionString raw "$APP/Contents/Info.plist")"
if [ -n "$SIGNING_IDENTITY" ]; then
  # A signed release must be exactly the tagged commit, or the number inside would not say what it is.
  TAG="$(git describe --tags --exact-match --match 'v[0-9]*' HEAD 2>/dev/null || true)"
  [ -n "$TAG" ] || { echo "ERROR: HEAD is not at a version tag. Commit, 'git tag vX.Y.Z', then build." >&2; exit 1; }
  [ "${TAG#v}" = "$VERSION" ] || { echo "ERROR: the app says $VERSION but the tag is $TAG." >&2; exit 1; }
fi
echo "==> Version: $VERSION"

# Cloud-synced folders attach extended attributes that codesign refuses to sign over.
xattr -cr "$APP"

if [ -n "$SIGNING_IDENTITY" ]; then
  echo "==> Signing with $SIGNING_IDENTITY..."
  # Hardened runtime and a secure timestamp are both required for notarization.
  codesign --force --deep --options runtime --timestamp \
    --entitlements "WhiteShot/WhiteShot.entitlements" --sign "$SIGNING_IDENTITY" "$APP"
else
  echo "==> Ad-hoc signing (set SIGNING_IDENTITY for a release build)..."
  codesign --force --deep --sign - "$APP" 2>&1 | grep -v "replacing existing signature" || true
fi
codesign --verify --deep --strict "$APP"

notarize() {  # notarize <file>: submit, wait, fail loudly if rejected
  xcrun notarytool submit "$1" --keychain-profile "$NOTARY_PROFILE" --wait
}

if [ -n "$SIGNING_IDENTITY" ] && [ -n "$NOTARY_PROFILE" ]; then
  echo "==> Notarizing the app..."
  ditto -c -k --keepParent "$APP" "dist/${APP_NAME}-notarize.zip"
  notarize "dist/${APP_NAME}-notarize.zip"
  rm "dist/${APP_NAME}-notarize.zip"
  xcrun stapler staple "$APP"
fi

echo "==> Building the disk image..."
DMG="dist/${APP_NAME}-${VERSION}.dmg"
STAGING="$(mktemp -d)"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGING" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGING"

if [ -n "$SIGNING_IDENTITY" ]; then
  # Gatekeeper checks the disk image too once it carries a download quarantine flag, so it
  # has to be signed itself, not only the app inside it.
  echo "==> Signing the disk image..."
  codesign --force --timestamp --sign "$SIGNING_IDENTITY" "$DMG"
  if [ -n "$NOTARY_PROFILE" ]; then
    echo "==> Notarizing the disk image..."
    notarize "$DMG"
    xcrun stapler staple "$DMG"
  fi
fi

echo
echo "Done:"
echo "  $APP"
echo "  $DMG"
