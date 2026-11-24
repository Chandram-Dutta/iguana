#!/bin/bash
# Build Iguana.app into ./build and sign it.
#
# Signing with a real identity matters: macOS ties the Accessibility permission to the signature,
# so an app signed the same way every time keeps its permission across rebuilds. With no identity
# the app is signed ad hoc and the permission has to be granted again after each build.
#
#   scripts/bundle.sh            build and sign
#   SIGN_IDENTITY="..." scripts/bundle.sh   pick the signing identity yourself
#   TEAM_ID="..." scripts/bundle.sh         sign as another developer team
#   UNIVERSAL=1 scripts/bundle.sh   build for Apple silicon and Intel in one binary
#   HARDENED=1 scripts/bundle.sh    sign with the hardened runtime and a timestamp (needed to notarize)
#
# scripts/release.sh uses the last two to make the build that is handed to other people.
set -euo pipefail
cd "$(dirname "$0")/.."

ARCHS=""
if [ "${UNIVERSAL:-0}" = 1 ]; then ARCHS="--arch arm64 --arch x86_64"; fi
# shellcheck disable=SC2086
swift build -c release $ARCHS
# shellcheck disable=SC2086
BIN="$(swift build -c release $ARCHS --show-bin-path)/iguana"
APP="build/Iguana.app"
# The app's identity to macOS. Its Accessibility permission, its login item and its saved
# preferences all hang on this, so changing it makes macOS treat the app as a new one.
BUNDLE_ID="xyz.onlychan.iguana"
VERSION="$("$BIN" version)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/iguana"

# macOS decides between the old and the new look of every system control, and of the window
# itself, from the SDK version stamped into the binary. This toolchain stamps the deployment
# target there instead of the SDK it really built against, which leaves the app looking like
# an app from macOS 14 on a system that has Liquid Glass. Put the real version in.
EXE="$APP/Contents/MacOS/iguana"
SDK_VERSION="$(xcrun --sdk macosx --show-sdk-version 2>/dev/null || true)"
MIN_VERSION="$(otool -l "$EXE" | awk '/LC_BUILD_VERSION/ {f=1} f && $1 == "minos" && !seen {print $2; seen = 1}')"
STAMPED="$(otool -l "$EXE" | awk '/LC_BUILD_VERSION/ {f=1} f && $1 == "sdk" && !seen {print $2; seen = 1}')"
if [ -n "$SDK_VERSION" ] && [ -n "$MIN_VERSION" ] && [ "$STAMPED" != "$SDK_VERSION" ]; then
    # vtool warns that the signature is now invalid, which is expected: the app is signed below.
    if ! STAMP_LOG="$(vtool -set-build-version macos "$MIN_VERSION" "$SDK_VERSION" -replace -output "$EXE.stamped" "$EXE" 2>&1)"; then
        echo "$STAMP_LOG" >&2
        exit 1
    fi
    mv "$EXE.stamped" "$EXE"
    chmod +x "$EXE"
    echo "stamped as built with the macOS $SDK_VERSION SDK (was $STAMPED)"
fi
# The app icon, and the logo the settings window shows in its sidebar.
cp assets/Iguana.icns "$APP/Contents/Resources/Iguana.icns"
sips -z 128 128 assets/logo-rounded.png --out "$APP/Contents/Resources/logo.png" >/dev/null
# A larger one for the welcome tour.
sips -z 512 512 assets/logo-rounded.png --out "$APP/Contents/Resources/logo-large.png" >/dev/null
cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleName</key><string>Iguana</string>
    <key>CFBundleDisplayName</key><string>Iguana</string>
    <key>CFBundleExecutable</key><string>iguana</string>
    <key>CFBundleIconFile</key><string>Iguana</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
EOF

# Iguana is signed by one team, whichever certificates the keychain holds. A Developer ID of
# that team is the identity other people's Macs accept; an Apple Development one only keeps the
# permission stable on this Mac. A certificate of another team is never used by accident.
TEAM_ID="${TEAM_ID:-DR99P625RR}"
IDENTITIES="$(security find-identity -v -p codesigning 2>/dev/null || true)"

# The team a signing certificate belongs to, from its fingerprint.
team_of() {
    security find-certificate -a -Z -p 2>/dev/null | awk -v want="$1" '
        /^SHA-1 hash:/ { keep = ($3 == want) && !done }
        keep && /BEGIN CERTIFICATE/ { on = 1 }
        on { print }
        on && /END CERTIFICATE/ { on = 0; done = 1 }' |
        openssl x509 -noout -subject 2>/dev/null | sed -E 's/.*OU ?= ?([A-Z0-9]+).*/\1/' || true
}

# The first certificate of a kind that belongs to the team.
pick() {
    for hash in $(echo "$IDENTITIES" | awk -v kind="$1" 'index($0, kind) {print $2}'); do
        if [ "$(team_of "$hash")" = "$TEAM_ID" ]; then
            echo "$hash"
            return
        fi
    done
}

IDENTITY="${SIGN_IDENTITY:-$(pick "Developer ID Application")}"
if [ -z "$IDENTITY" ]; then IDENTITY="$(pick "Apple Development")"; fi
OPTIONS=""
if [ "${HARDENED:-0}" = 1 ]; then OPTIONS="--options runtime --timestamp"; fi
if [ -n "$IDENTITY" ]; then
    # shellcheck disable=SC2086
    codesign --force $OPTIONS --sign "$IDENTITY" --identifier "$BUNDLE_ID" "$APP"
    echo "signed with $IDENTITY (team $TEAM_ID)"
else
    codesign --force --sign - --identifier "$BUNDLE_ID" "$APP"
    echo "no certificate of team $TEAM_ID found: signed ad hoc (Accessibility permission will reset on every rebuild)"
fi
echo "built $APP ($VERSION)"
