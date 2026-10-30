#!/usr/bin/env bash
# Builds a signed, updatable release.
#   scripts/release.sh 0.2.0            build build/Perch-0.2.0.zip and its .sig
#   scripts/release.sh 0.2.0 --publish  also create the GitHub release v0.2.0 with both files
#
# The version comes from Resources/Info.plist: bump CFBundleShortVersionString there and commit it
# first. The build number (commit count) is stamped into the built app only, so releasing never
# leaves the working tree dirty. Release notes come from docs/releases/<version>.md when present.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?usage: scripts/release.sh <version> [--publish]}"
PUBLISH="${2:-}"
ZIP="build/Perch-$VERSION.zip"
NOTES="docs/releases/$VERSION.md"
PLIST=Resources/Info.plist

PLIST_VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$PLIST")"
if [[ "$PLIST_VERSION" != "$VERSION" ]]; then
  echo "Info.plist says $PLIST_VERSION; set CFBundleShortVersionString to $VERSION and commit it first." >&2
  exit 1
fi

if [[ "$PUBLISH" == "--publish" ]]; then
  if [[ -n "$(git status --porcelain)" ]]; then
    echo "Commit your changes before publishing." >&2
    exit 1
  fi
  git fetch -q origin
  if [[ "$(git rev-parse HEAD)" != "$(git rev-parse '@{u}')" ]]; then
    echo "Push main first, so the release tag points at a commit that is on GitHub." >&2
    exit 1
  fi
fi

# The app must carry the public half of the key we are about to sign with.
EMBEDDED_KEY="$(/usr/libexec/PlistBuddy -c "Print :PerchUpdatePublicKey" "$PLIST")"
SIGNING_KEY="$(swift scripts/sign-update.swift --public)"
if [[ "$EMBEDDED_KEY" != "$SIGNING_KEY" ]]; then
  echo "PerchUpdatePublicKey in Info.plist does not match the signing key" >&2
  exit 1
fi

scripts/build.sh release
BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" build/Perch.app/Contents/Info.plist
scripts/sign.sh build/Perch.app

rm -f "$ZIP" "$ZIP.sig"
ditto -c -k --keepParent build/Perch.app "$ZIP"
swift scripts/sign-update.swift "$ZIP" > "$ZIP.sig"
echo "Archive:   $ZIP (build $BUILD_NUMBER)"
echo "Signature: $ZIP.sig"
shasum -a 256 "$ZIP"

if [[ "$PUBLISH" == "--publish" ]]; then
  NOTES_ARGS=(--generate-notes)
  [[ -f "$NOTES" ]] && NOTES_ARGS=(--notes-file "$NOTES")
  gh release create "v$VERSION" "$ZIP" "$ZIP.sig" --target "$(git rev-parse HEAD)" --title "Perch $VERSION" "${NOTES_ARGS[@]}"
fi
