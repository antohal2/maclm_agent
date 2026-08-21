#!/usr/bin/env bash

set -euo pipefail

readonly PRODUCT_NAME="maclm-agent"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
readonly PROJECT="$REPO_ROOT/maclm-agent.xcodeproj"
readonly SCHEME="maclm-agent"
readonly BUILD_ROOT="$REPO_ROOT/build"
readonly DERIVED_DATA="$BUILD_ROOT/DerivedData"
readonly APP_PATH="$BUILD_ROOT/$PRODUCT_NAME.app"

fail() {
    echo "error: $*" >&2
    exit 1
}

version_from_tag() {
    local tag
    tag="$(git -C "$REPO_ROOT" describe --tags --exact-match --match 'v*' HEAD 2>/dev/null)" ||
        fail "version is required when HEAD is not tagged (example: $0 0.2.4)"
    printf '%s\n' "${tag#v}"
}

VERSION="${1:-}"
if [[ -z "$VERSION" ]]; then
    VERSION="$(version_from_tag)"
fi
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]] ||
    fail "invalid version: $VERSION"
readonly VERSION

for tool in xcodebuild codesign ditto spctl xattr; do
    command -v "$tool" >/dev/null 2>&1 || fail "required tool not found: $tool"
done

[[ "$BUILD_ROOT" == "$REPO_ROOT/build" ]] || fail "refusing to clean unexpected path: $BUILD_ROOT"

echo "==> Cleaning $BUILD_ROOT"
rm -rf "$BUILD_ROOT"
mkdir -p "$BUILD_ROOT"

echo "==> Building $PRODUCT_NAME $VERSION (Release, arm64)"
xcodebuild build \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration Release \
    -destination 'generic/platform=macOS' \
    -derivedDataPath "$DERIVED_DATA" \
    ARCHS=arm64 \
    ONLY_ACTIVE_ARCH=NO \
    MARKETING_VERSION="$VERSION" \
    CODE_SIGNING_ALLOWED=NO

readonly BUILT_APP="$DERIVED_DATA/Build/Products/Release/$PRODUCT_NAME.app"
[[ -d "$BUILT_APP" ]] || fail "built application not found: $BUILT_APP"

SIGNING_ROOT="$(mktemp -d "/tmp/$PRODUCT_NAME-release-signing.XXXXXX")"
readonly SIGNING_ROOT
readonly SIGNING_APP="$SIGNING_ROOT/$PRODUCT_NAME.app"

cleanup() {
    if [[ "$SIGNING_ROOT" == "/tmp/$PRODUCT_NAME-release-signing."* && -d "$SIGNING_ROOT" ]]; then
        rm -rf "$SIGNING_ROOT"
    fi
}
trap cleanup EXIT

ditto --noextattr --noqtn "$BUILT_APP" "$SIGNING_APP"
xattr -cr "$SIGNING_APP"

# If the target already declares an entitlements file, pass the same file to
# the replacement signature. Accessibility itself does not require an
# entitlement, and this project currently has none configured.
ENTITLEMENTS_SETTING="$(
    xcodebuild \
        -project "$PROJECT" \
        -scheme "$SCHEME" \
        -configuration Release \
        -showBuildSettings 2>/dev/null |
        awk -F ' = ' '/^[[:space:]]*CODE_SIGN_ENTITLEMENTS = / && !seen { print $2; seen = 1 }'
)"

SIGNING_ARGUMENTS=(--force --deep --sign - --options runtime --timestamp=none)
if [[ -n "$ENTITLEMENTS_SETTING" ]]; then
    if [[ "$ENTITLEMENTS_SETTING" = /* ]]; then
        ENTITLEMENTS_PATH="$ENTITLEMENTS_SETTING"
    else
        ENTITLEMENTS_PATH="$REPO_ROOT/$ENTITLEMENTS_SETTING"
    fi
    [[ -f "$ENTITLEMENTS_PATH" ]] ||
        fail "configured entitlements file not found: $ENTITLEMENTS_PATH"
    SIGNING_ARGUMENTS+=(--entitlements "$ENTITLEMENTS_PATH")
    echo "==> Preserving entitlements from $ENTITLEMENTS_PATH"
else
    echo "==> No target entitlements file is configured"
fi

echo "==> Applying ad-hoc signature"
codesign "${SIGNING_ARGUMENTS[@]}" "$SIGNING_APP"

# Sign outside the File Provider-backed checkout: its automatic FinderInfo
# metadata can make codesign reject an unsigned bundle. Copying the completed
# signed bundle back to build/ preserves a verifiable signature.
ditto --noextattr --noqtn "$SIGNING_APP" "$APP_PATH"
# Let File Provider finish attaching its bookkeeping metadata, then remove the
# disallowed FinderInfo xattr without altering the completed code signature.
sleep 1
xattr -cr "$APP_PATH"

echo "==> Verifying signature"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"

echo "==> Signature details (expected: Signature=adhoc)"
codesign --display --verbose=4 "$APP_PATH" 2>&1

echo "==> Embedded entitlements"
if ! codesign --display --entitlements - "$APP_PATH" 2>&1; then
    echo "No embedded entitlements."
fi

echo "==> Gatekeeper assessment (failure is expected for an ad-hoc, unnotarized build)"
set +e
spctl --assess --type execute --verbose=4 "$APP_PATH"
SPCTL_STATUS=$?
set -e
echo "spctl exit code: $SPCTL_STATUS (informational only)"

echo "==> Built $APP_PATH"
