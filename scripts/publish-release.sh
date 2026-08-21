#!/usr/bin/env bash

set -euo pipefail

readonly PRODUCT_NAME="maclm-agent"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

fail() {
    echo "error: $*" >&2
    exit 1
}

VERSION="${1:-}"
[[ -n "$VERSION" ]] || fail "usage: $0 <version>"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]] ||
    fail "invalid version: $VERSION"
readonly VERSION
readonly TAG="v$VERSION"
readonly DIST_DIR="$REPO_ROOT/dist"
readonly DMG_PATH="$DIST_DIR/$PRODUCT_NAME-$VERSION.dmg"
readonly NOTES_PATH="$DIST_DIR/release-notes-$VERSION.md"

command -v gh >/dev/null 2>&1 || fail "GitHub CLI is required: https://cli.github.com/"
gh auth status >/dev/null 2>&1 || fail "GitHub CLI is not authenticated; run: gh auth login"

[[ -z "$(git -C "$REPO_ROOT" status --porcelain)" ]] ||
    fail "working tree must be clean before publishing"
git -C "$REPO_ROOT" rev-parse --verify --quiet "refs/tags/$TAG" >/dev/null ||
    fail "local tag does not exist: $TAG"
[[ -f "$DMG_PATH" ]] || fail "release artifact not found: $DMG_PATH"

readonly REPOSITORY="$(gh repo view --json nameWithOwner --jq '.nameWithOwner')"

if gh release view "$TAG" --repo "$REPOSITORY" >/dev/null 2>&1; then
    fail "GitHub Release already exists for $TAG; refusing to overwrite it"
fi

git -C "$REPO_ROOT" ls-remote --exit-code --tags origin "refs/tags/$TAG" >/dev/null 2>&1 ||
    fail "tag $TAG is not present on origin; push it before publishing"

mkdir -p "$DIST_DIR"
TEMP_ROOT="$(mktemp -d "/tmp/$PRODUCT_NAME-release-notes.XXXXXX")"
readonly TEMP_ROOT
trap 'rm -rf "$TEMP_ROOT"' EXIT

readonly FEAT_NOTES="$TEMP_ROOT/feat"
readonly FIX_NOTES="$TEMP_ROOT/fix"
readonly DOCS_NOTES="$TEMP_ROOT/docs"
readonly OTHER_NOTES="$TEMP_ROOT/other"
: >"$FEAT_NOTES"
: >"$FIX_NOTES"
: >"$DOCS_NOTES"
: >"$OTHER_NOTES"

PREVIOUS_TAG="$(git -C "$REPO_ROOT" describe --tags --abbrev=0 "$TAG^" 2>/dev/null || true)"
if [[ -n "$PREVIOUS_TAG" ]]; then
    LOG_RANGE="$PREVIOUS_TAG..$TAG"
else
    LOG_RANGE="$TAG"
fi

while IFS=$'\t' read -r commit subject || [[ -n "$commit" ]]; do
    [[ -n "$commit" ]] || continue
    case "$subject" in
        feat:*) printf -- '- %s (`%s`)\n' "${subject#feat: }" "$commit" >>"$FEAT_NOTES" ;;
        fix:*) printf -- '- %s (`%s`)\n' "${subject#fix: }" "$commit" >>"$FIX_NOTES" ;;
        docs:*) printf -- '- %s (`%s`)\n' "${subject#docs: }" "$commit" >>"$DOCS_NOTES" ;;
        *) printf -- '- %s (`%s`)\n' "$subject" "$commit" >>"$OTHER_NOTES" ;;
    esac
done < <(git -C "$REPO_ROOT" log --reverse --pretty=format:'%h%x09%s' "$LOG_RANGE")

write_section() {
    local title="$1"
    local notes_file="$2"
    printf '## %s\n\n' "$title" >>"$NOTES_PATH"
    if [[ -s "$notes_file" ]]; then
        cat "$notes_file" >>"$NOTES_PATH"
    else
        printf '_No changes._\n' >>"$NOTES_PATH"
    fi
    printf '\n' >>"$NOTES_PATH"
}

printf '# maclm-agent %s\n\nChanges since %s.\n\n' \
    "$VERSION" "${PREVIOUS_TAG:-the initial commit}" >"$NOTES_PATH"
write_section "Features" "$FEAT_NOTES"
write_section "Fixes" "$FIX_NOTES"
write_section "Documentation" "$DOCS_NOTES"
if [[ -s "$OTHER_NOTES" ]]; then
    write_section "Other changes" "$OTHER_NOTES"
fi

echo "==> Release notes: $NOTES_PATH"
cat "$NOTES_PATH"

echo "==> Publishing $TAG to $REPOSITORY"
gh release create "$TAG" "$DMG_PATH" \
    --repo "$REPOSITORY" \
    --verify-tag \
    --title "$PRODUCT_NAME $VERSION" \
    --notes-file "$NOTES_PATH"
