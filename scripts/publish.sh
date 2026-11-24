#!/bin/bash
# Publish what scripts/release.sh left in ./dist as a GitHub release.
#
#   scripts/publish.sh           release the version that is in dist, as tag v<version>
#   scripts/publish.sh v0.2.0    the same, checking that it is the tag meant
#
# The tag is created on the commit that is checked out if it does not exist yet. A release that
# already exists gets the files again, replacing the old ones.
set -euo pipefail
cd "$(dirname "$0")/.."

DMG="$(ls dist/Iguana-*.dmg 2>/dev/null | head -n 1 || true)"
if [ -z "$DMG" ]; then
    echo "error: nothing in dist. Run scripts/release.sh first." >&2
    exit 1
fi
VERSION="$(basename "$DMG" .dmg | sed 's/^Iguana-//')"
TAG="v$VERSION"
if [ -n "${1:-}" ] && [ "$1" != "$TAG" ]; then
    echo "error: dist holds version $VERSION, which is tag $TAG, not $1." >&2
    exit 1
fi
if ! xcrun stapler validate "$DMG" >/dev/null 2>&1; then
    echo "error: $DMG is not notarized. A release must be one that other Macs will open." >&2
    echo "Run: NOTARY_PROFILE=iguana scripts/release.sh" >&2
    exit 1
fi

FILES=(dist/Iguana-"$VERSION".dmg dist/Iguana.dmg dist/Iguana-"$VERSION".zip dist/iguana.rb dist/checksums.txt)
if gh release view "$TAG" >/dev/null 2>&1; then
    gh release upload "$TAG" "${FILES[@]}" --clobber
else
    gh release create "$TAG" "${FILES[@]}" --title "Iguana $VERSION" --generate-notes --target "$(git rev-parse HEAD)"
fi
gh release view "$TAG" --json url --jq .url

# The Homebrew tap fetches the cask of the latest release by itself, once an hour. Ask it to do
# so now where that is allowed; from a workflow in this repository it is not, and the hourly
# run picks the release up.
if gh workflow run "Update cask" -R Chandram-Dutta/homebrew-tap >/dev/null 2>&1; then
    echo "asked the Homebrew tap to update"
else
    echo "the Homebrew tap will pick this release up within the hour"
fi
