# Release process

Releases are built locally for Apple Silicon, signed ad-hoc, packaged as a
compressed DMG, and published through GitHub Releases. The application is not
notarized by Apple.

## Prerequisites

- A clean working tree on the commit to be released.
- Xcode with the macOS 15 SDK.
- An authenticated GitHub CLI session (`gh auth status`).
- An existing local and remote tag named `v<version>`.

## Build and publish

From the repository root, replace `0.2.4` with the release version:

```sh
git status --short --branch
gh auth status

VERSION=0.2.4
./scripts/build-release.sh "$VERSION"
./scripts/make-dmg.sh "$VERSION"
```

Verify the image before publication:

```sh
hdiutil verify "dist/maclm-agent-$VERSION.dmg"
MOUNT_OUTPUT="$(hdiutil attach -readonly -nobrowse "dist/maclm-agent-$VERSION.dmg")"
MOUNT_POINT="$(printf '%s\n' "$MOUNT_OUTPUT" | awk -F '\t' '/\/Volumes\// { print $NF; exit }')"
ls -la "$MOUNT_POINT"
codesign --verify --deep --strict --verbose=2 "$MOUNT_POINT/maclm-agent.app"
hdiutil detach "$MOUNT_POINT"
```

Commit the release-pipeline changes before publishing so the clean-tree guard
passes. Ensure that the release tag points to the intended application source,
then push the commit and tag:

```sh
git push origin HEAD
git push origin "v$VERSION"
./scripts/publish-release.sh "$VERSION"
```

`publish-release.sh` refuses to overwrite an existing release. It writes
`dist/release-notes-<version>.md`, grouping commits since the previous tag under
`feat:`, `fix:`, and `docs:` categories, and uploads the DMG with those notes.

After downloading the published DMG on a test Mac, copy the application to
`/Applications` and perform the documented Finder right-click → Open flow. A
locally created image normally has no quarantine attribute, so the complete
first-launch Gatekeeper flow must be validated using the downloaded asset.

## Future Developer ID notarization

The rest of the pipeline can stay unchanged. Replace `codesign --sign -` with a
Developer ID Application identity, then add these steps after signing:

```sh
xcrun notarytool submit "dist/maclm-agent-$VERSION.dmg" --wait \
    --keychain-profile "<notarytool-profile>"
xcrun stapler staple "dist/maclm-agent-$VERSION.dmg"
```

The Developer ID identity and notarytool credentials must be supplied through
the local signing environment; they are not stored in this repository.
