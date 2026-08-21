#!/usr/bin/env bash

set -euo pipefail

readonly PRODUCT_NAME="maclm-agent"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
readonly BUILD_APP="$REPO_ROOT/build/$PRODUCT_NAME.app"
readonly DIST_DIR="$REPO_ROOT/dist"

fail() {
    echo "error: $*" >&2
    exit 1
}

VERSION="${1:-}"
[[ -n "$VERSION" ]] || fail "usage: $0 <version>"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]] ||
    fail "invalid version: $VERSION"
readonly VERSION
readonly DMG_PATH="$DIST_DIR/$PRODUCT_NAME-$VERSION.dmg"
readonly VOLUME_NAME="$PRODUCT_NAME $VERSION"

for tool in hdiutil ditto codesign xattr; do
    command -v "$tool" >/dev/null 2>&1 || fail "required tool not found: $tool"
done

[[ -d "$BUILD_APP" ]] ||
    fail "built application not found; run ./scripts/build-release.sh $VERSION first"
xattr -cr "$BUILD_APP"
codesign --verify --deep --strict --verbose=2 "$BUILD_APP"

TEMP_ROOT="$(mktemp -d "/tmp/$PRODUCT_NAME-dmg.XXXXXX")"
readonly TEMP_ROOT
readonly STAGING_DIR="$TEMP_ROOT/staging"
readonly RW_DMG="$TEMP_ROOT/$PRODUCT_NAME-rw.dmg"

cleanup() {
    if [[ "$TEMP_ROOT" == "/tmp/$PRODUCT_NAME-dmg."* && -d "$TEMP_ROOT" ]]; then
        rm -rf "$TEMP_ROOT"
    fi
}
trap cleanup EXIT

mkdir -p "$STAGING_DIR" "$DIST_DIR"
ditto --noextattr --noqtn "$BUILD_APP" "$STAGING_DIR/$PRODUCT_NAME.app"
ln -s /Applications "$STAGING_DIR/Applications"
rm -f "$DMG_PATH"

echo "==> Creating writable disk image"
hdiutil create \
    -volname "$VOLUME_NAME" \
    -srcfolder "$STAGING_DIR" \
    -format UDRW \
    -ov \
    "$RW_DMG"

echo "==> Compressing $DMG_PATH (UDZO)"
hdiutil convert "$RW_DMG" \
    -format UDZO \
    -imagekey zlib-level=9 \
    -ov \
    -o "$DMG_PATH"

echo "==> Created $DMG_PATH"
