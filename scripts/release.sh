#!/bin/bash
# Make the build that is handed to other people, in ./dist:
#
#   Iguana-<version>.dmg   to download and drag into Applications
#   Iguana.dmg             the same file, under a name that stays the same between versions
#   Iguana-<version>.zip   the same app, for Homebrew
#   iguana.rb              the Homebrew cask, filled in for this build
#   checksums.txt
#
# The app is built for Apple silicon and Intel, signed with the hardened runtime, and stamped
# with the SDK it was built with.
#
# For macOS to open it on someone else's Mac without a warning, two more things are needed:
#
#   1. A "Developer ID Application" certificate in the keychain (Apple Developer Program).
#      Without one the build is signed with whatever is there, and Gatekeeper will refuse it.
#   2. Notarization. Store the credentials once:
#        xcrun notarytool store-credentials iguana --team-id <team id>
#      then run:  NOTARY_PROFILE=iguana scripts/release.sh
#
#   RELEASE_URL_BASE   where the files will be downloaded from, without the version, for the
#                      cask. The project's GitHub releases unless set.
#   HOMEPAGE           the project's page, for the cask. The project's site unless set.
#
#   scripts/release.sh --check   say whether this Mac is ready to make a build others can open,
#                                without building anything
#   TEAM_ID                      release as another developer team than the one set below
set -euo pipefail
cd "$(dirname "$0")/.."

# The developer team Iguana is released by. scripts/bundle.sh signs with this team's certificate.
export TEAM_ID="${TEAM_ID:-DR99P625RR}"

if [ "${1:-}" = "--check" ]; then
    READY=1
    FOUND="$(security find-identity -v -p codesigning 2>/dev/null | grep "Developer ID Application" | grep "($TEAM_ID)" || true)"
    if [ -n "$FOUND" ]; then
        echo "Developer ID certificate of team $TEAM_ID: found"
        echo "$FOUND" | sed -E 's/^ *[0-9]+\) [A-F0-9]+ /    /'
    else
        echo "Developer ID certificate of team $TEAM_ID: MISSING"
        echo "    Xcode > Settings > Accounts > the team > Manage Certificates > + > Developer ID Application"
        READY=0
    fi
    PROFILE="${NOTARY_PROFILE:-iguana}"
    if xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
        echo "Notarization credentials: found (profile \"$PROFILE\")"
    else
        echo "Notarization credentials: MISSING (profile \"$PROFILE\")"
        echo "    xcrun notarytool store-credentials $PROFILE --team-id $TEAM_ID"
        READY=0
    fi
    if [ "$READY" = 1 ]; then
        echo "Ready: NOTARY_PROFILE=$PROFILE scripts/release.sh"
    else
        echo "Not ready yet."
    fi
    exit $((1 - READY))
fi

UNIVERSAL=1 HARDENED=1 scripts/bundle.sh

APP="build/Iguana.app"
EXE="$APP/Contents/MacOS/iguana"
VERSION="$("$EXE" version)"
DIST="dist"
DMG="$DIST/Iguana-$VERSION.dmg"
ZIP="$DIST/Iguana-$VERSION.zip"
AUTHORITY="$(codesign -dvv "$APP" 2>&1 | awk -F= '/^Authority=/ && !seen {print $2; seen = 1}')"
DEVELOPER_ID=0
case "$AUTHORITY" in "Developer ID Application"*) DEVELOPER_ID=1 ;; esac

rm -rf "$DIST"
mkdir -p "$DIST"

notarize() {
    xcrun notarytool submit "$1" --keychain-profile "$NOTARY_PROFILE" --wait
}

NOTARIZED=0
if [ -n "${NOTARY_PROFILE:-}" ]; then
    if [ "$DEVELOPER_ID" != 1 ]; then
        echo "error: NOTARY_PROFILE is set, but the app is signed with \"${AUTHORITY:-nothing}\"." >&2
        echo "Apple only notarizes apps signed with a Developer ID Application certificate." >&2
        exit 1
    fi
    # The app first, so that the ticket can be attached to it before it is packed.
    ditto -c -k --keepParent "$APP" "$DIST/notarize.zip"
    notarize "$DIST/notarize.zip"
    rm "$DIST/notarize.zip"
    xcrun stapler staple "$APP"
    NOTARIZED=1
fi

# The zip, for Homebrew.
ditto -c -k --keepParent "$APP" "$ZIP"

# The disk image: the app beside a shortcut to Applications.
STAGE="build/dmg"
rm -rf "$STAGE"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -quiet -volname "Iguana $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
rm -rf "$STAGE"
if [ "$DEVELOPER_ID" = 1 ]; then
    # By fingerprint, not by name: two certificates can carry the same name.
    IDENTITY="$(security find-identity -v -p codesigning | grep "Developer ID Application" | grep "($TEAM_ID)" | awk '!seen {print $2; seen = 1}')"
    codesign --force --timestamp --sign "$IDENTITY" "$DMG"
fi
if [ "$NOTARIZED" = 1 ]; then
    notarize "$DMG"
    xcrun stapler staple "$DMG"
fi

# The same disk image under a name that does not change, so that a link to the latest release
# (.../releases/latest/download/Iguana.dmg) keeps working from one version to the next.
cp "$DMG" "$DIST/Iguana.dmg"

SHA="$(shasum -a 256 "$ZIP" | awk '{print $1}')"
(cd "$DIST" && shasum -a 256 "Iguana-$VERSION.dmg" "Iguana-$VERSION.zip" > checksums.txt)

URL_BASE="${RELEASE_URL_BASE:-https://github.com/Chandram-Dutta/iguana/releases/download}"
sed -e "s|{{VERSION}}|$VERSION|" -e "s|{{SHA256}}|$SHA|" -e "s|{{URL_BASE}}|$URL_BASE|" \
    -e "s|{{HOMEPAGE}}|${HOMEPAGE:-https://iguana.onlychan.xyz}|" \
    -e '1,2d' packaging/homebrew/iguana.rb.template > "$DIST/iguana.rb"

echo
echo "Iguana $VERSION"
echo "  architectures: $(lipo -archs "$EXE")"
echo "  signed by:     ${AUTHORITY:-nobody (ad hoc)}"
echo "  notarized:     $([ "$NOTARIZED" = 1 ] && echo yes || echo no)"
echo "  files:"
ls -lh "$DIST" | awk 'NR > 1 {printf "    %-28s %s\n", $9, $5}'
echo
if [ "$NOTARIZED" != 1 ]; then
    echo "This build is NOT ready to hand out: macOS will refuse to open it on another Mac."
    if [ "$DEVELOPER_ID" != 1 ]; then echo "  missing: a Developer ID Application certificate"; fi
    echo "  missing: notarization (NOTARY_PROFILE)"
    echo "It is fine for trying the packaging, and on this Mac."
fi
