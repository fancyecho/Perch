#!/usr/bin/env bash
# Builds a signed, updatable release.
#   scripts/release.sh 0.2.0            build build/Perch-0.2.0.zip and its .sig
#   scripts/release.sh 0.2.0 --publish  also create the GitHub release v0.2.0 with both files
# Release notes come from docs/releases/<version>.md when present.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?usage: scripts/release.sh <version> [--publish]}"
PUBLISH="${2:-}"
ZIP="build/Perch-$VERSION.zip"
NOTES="docs/releases/$VERSION.md"

/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" Resources/Info.plist
BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" Resources/Info.plist

# The app must carry the public half of the key we are about to sign with.
EMBEDDED_KEY="$(/usr/libexec/PlistBuddy -c "Print :PerchUpdatePublicKey" Resources/Info.plist)"
SIGNING_KEY="$(swift scripts/sign-update.swift --public)"
if [[ "$EMBEDDED_KEY" != "$SIGNING_KEY" ]]; then
  echo "PerchUpdatePublicKey in Info.plist does not match the signing key" >&2
  exit 1
fi

scripts/build.sh release
rm -f "$ZIP" "$ZIP.sig"
ditto -c -k --keepParent build/Perch.app "$ZIP"
swift scripts/sign-update.swift "$ZIP" > "$ZIP.sig"
echo "Archive:   $ZIP"
echo "Signature: $ZIP.sig"
shasum -a 256 "$ZIP"

if [[ "$PUBLISH" == "--publish" ]]; then
  if [[ -n "$(git status --porcelain)" ]]; then
    echo "Commit your changes before publishing (Info.plist version included)." >&2
    exit 1
  fi
  NOTES_ARGS=(--generate-notes)
  [[ -f "$NOTES" ]] && NOTES_ARGS=(--notes-file "$NOTES")
  gh release create "v$VERSION" "$ZIP" "$ZIP.sig" --title "Perch $VERSION" "${NOTES_ARGS[@]}"
fi
