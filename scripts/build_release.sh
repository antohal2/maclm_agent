#!/bin/bash

set -euo pipefail

readonly VERSION="0.1.0"
readonly PRODUCT_NAME="maclm-agent"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
readonly PROJECT="$REPO_ROOT/maclm-agent.xcodeproj"
readonly SCHEME="maclm-agent"
readonly BUILD_ROOT="$REPO_ROOT/build/release"
readonly ARCHIVE_PATH="$BUILD_ROOT/$PRODUCT_NAME.xcarchive"
readonly ARCHIVED_APP="$ARCHIVE_PATH/Products/Applications/$PRODUCT_NAME.app"
readonly DIST_DIR="$REPO_ROOT/dist"
readonly DIST_APP="$DIST_DIR/$PRODUCT_NAME.app"
readonly DMG_PATH="$DIST_DIR/$PRODUCT_NAME-$VERSION.dmg"
readonly DMG_VOLUME_NAME="$PRODUCT_NAME $VERSION"
readonly DMG_STAGING="$(mktemp -d "/tmp/$PRODUCT_NAME-dmg.XXXXXX")"

cleanup() {
    if [[ "$DMG_STAGING" == "/tmp/$PRODUCT_NAME-dmg."* ]]; then
        rm -rf "$DMG_STAGING"
    fi
}
trap cleanup EXIT

for tool in xcodebuild codesign hdiutil ditto xattr; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "error: required tool not found: $tool" >&2
        exit 1
    fi
done

rm -rf "$BUILD_ROOT"
mkdir -p "$BUILD_ROOT" "$DIST_DIR"
rm -rf "$DIST_APP"
rm -f "$DMG_PATH"

echo "Archiving $PRODUCT_NAME $VERSION..."
xcodebuild archive \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration Release \
    -destination "generic/platform=macOS" \
    -archivePath "$ARCHIVE_PATH" \
    ARCHS=arm64 \
    ONLY_ACTIVE_ARCH=YES \
    CODE_SIGNING_ALLOWED=NO

if [[ ! -d "$ARCHIVED_APP" ]]; then
    echo "error: archived application not found: $ARCHIVED_APP" >&2
    exit 1
fi

# Without a Developer ID identity, xcodebuild -exportArchive with a
# development export method can still request a provisioning identity.
# Copying the already-built .app from the archive is deterministic and lets us
# apply the explicitly requested ad-hoc signature without Apple credentials.
ditto --noextattr --noqtn "$ARCHIVED_APP" "$DIST_APP"
xattr -cr "$DIST_APP"

echo "Applying ad-hoc signature..."
codesign --force --deep --options runtime --sign - "$DIST_APP"
codesign --verify --deep --strict --verbose=2 "$DIST_APP"

ditto --noextattr --noqtn "$DIST_APP" "$DMG_STAGING/$PRODUCT_NAME.app"
xattr -cr "$DMG_STAGING/$PRODUCT_NAME.app"
codesign --force --deep --options runtime --sign - \
    "$DMG_STAGING/$PRODUCT_NAME.app"
codesign --verify --deep --strict --verbose=2 \
    "$DMG_STAGING/$PRODUCT_NAME.app"
ln -s /Applications "$DMG_STAGING/Applications"

echo "Creating $DMG_PATH..."
hdiutil create \
    -volname "$DMG_VOLUME_NAME" \
    -srcfolder "$DMG_STAGING" \
    -format UDZO \
    -ov \
    "$DMG_PATH"

# A DMG can carry an ad-hoc code signature too. This is an integrity marker,
# not a substitute for Developer ID signing or Apple notarization.
codesign --force --sign - "$DMG_PATH"
codesign --verify --verbose=2 "$DMG_PATH"

echo
echo "Release artifacts:"
echo "  App: $DIST_APP"
echo "  DMG: $DMG_PATH"
echo
echo "Signature details:"
codesign -dv --verbose=4 "$DIST_APP" 2>&1
