#!/bin/bash
# Make the disk image that Iguana is downloaded as: the app beside a shortcut to Applications,
# on a picture in which the iguana's tongue catches the folder.
#
#   scripts/dmg.sh <path to Iguana.app> <version> <output.dmg>
#
# The window is laid out by dmgbuild (https://dmgbuild.readthedocs.io), a small Python tool that
# writes the layout itself and never opens Finder. Its settings are packaging/dmg/settings.py,
# and the picture is packaging/dmg/background.png with its @2x beside it.
#
# dmgbuild is looked for in three places, in this order:
#
#   path   a dmgbuild that is already installed, whichever version it is
#   uvx    uvx fetches the pinned version and runs it
#   venv   a Python environment of its own under build/, made with python3 and pip
#
# If none of them works, or the image it makes is not right, this says so and makes the plain
# image instead: the same two things with no picture. A release is never held up by the picture.
#
#   DMGBUILD_ROUTES="uvx venv" scripts/dmg.sh ...   try only these, in this order
#   DMGBUILD_ROUTES=none scripts/dmg.sh ...         make the plain image
#
# The image is not signed here. scripts/release.sh does that.
set -euo pipefail

if [ $# -ne 3 ]; then
    echo "usage: scripts/dmg.sh <path to Iguana.app> <version> <output.dmg>" >&2
    exit 2
fi
APP="${1%/}"
VERSION="$2"
OUT="$3"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

if [ ! -d "$APP" ]; then
    echo "error: $APP is not an app." >&2
    exit 1
fi
if [ -z "$VERSION" ]; then
    echo "error: the version is empty." >&2
    exit 1
fi

# The version of dmgbuild, and of the two libraries it needs, that the layout was made and
# checked with. An exact one, so that a release made next year lays the window out the same
# way. This is the newest dmgbuild that runs on the Python that comes with Xcode (3.9), which
# is the one Python every Mac that can build Iguana has.
DMGBUILD_VERSION="1.6.5"
DS_STORE_VERSION="1.3.1"
MAC_ALIAS_VERSION="2.2.2"

VOLUME="Iguana $VERSION"
SETTINGS="$ROOT/packaging/dmg/settings.py"
PICTURE="$ROOT/packaging/dmg/background.png"
ICON="$ROOT/assets/Iguana.icns"
ROUTES="${DMGBUILD_ROUTES-path uvx venv}"

# Each route sets DMGBUILD to the command that runs dmgbuild, or fails.
DMGBUILD=()

route_path() {
    command -v dmgbuild >/dev/null 2>&1 || return 1
    DMGBUILD=(dmgbuild)
}

route_uvx() {
    command -v uvx >/dev/null 2>&1 || return 1
    DMGBUILD=(uvx --quiet --from "dmgbuild==$DMGBUILD_VERSION" --with "ds_store==$DS_STORE_VERSION"
        --with "mac_alias==$MAC_ALIAS_VERSION" dmgbuild)
}

route_venv() {
    local venv="$ROOT/build/dmgbuild-$DMGBUILD_VERSION"
    if [ ! -x "$venv/bin/dmgbuild" ]; then
        command -v python3 >/dev/null 2>&1 || return 1
        rm -rf "$venv"
        python3 -m venv "$venv" >/dev/null 2>&1 || return 1
        "$venv/bin/python" -m pip install --quiet --disable-pip-version-check \
            "dmgbuild==$DMGBUILD_VERSION" "ds_store==$DS_STORE_VERSION" "mac_alias==$MAC_ALIAS_VERSION" \
            >/dev/null 2>&1 || { rm -rf "$venv"; return 1; }
    fi
    DMGBUILD=("$venv/bin/dmgbuild")
}

# The image holds the app, whole, and the layout. dmgbuild carries on when a copy fails, so an
# image is looked into before it is trusted. It is mounted where Finder does not show it.
MOUNT=""
unmount() {
    if [ -n "$MOUNT" ]; then
        hdiutil detach "$MOUNT" -quiet 2>/dev/null || hdiutil detach "$MOUNT" -force -quiet 2>/dev/null || true
        rmdir "$MOUNT" 2>/dev/null || true
        MOUNT=""
    fi
}
trap unmount EXIT

image_is_right() {
    local right=0
    MOUNT="$(mktemp -d "${TMPDIR:-/tmp}/iguana-dmg.XXXXXX")"
    if ! hdiutil attach "$OUT" -nobrowse -noautoopen -readonly -mountpoint "$MOUNT" -quiet; then
        rmdir "$MOUNT" 2>/dev/null || true
        MOUNT=""
        return 1
    fi
    diff -rq "$APP" "$MOUNT/$(basename "$APP")" >/dev/null 2>&1 || right=1
    [ "$(readlink "$MOUNT/Applications" 2>/dev/null)" = "/Applications" ] || right=1
    [ -s "$MOUNT/.DS_Store" ] || right=1
    [ -s "$MOUNT/.background.tiff" ] || right=1
    [ -s "$MOUNT/.VolumeIcon.icns" ] || right=1
    unmount
    return "$right"
}

designed_image() {
    local route
    for route in $ROUTES; do
        case "$route" in
            path | uvx | venv) ;;
            none) continue ;;
            *)
                echo "warning: DMGBUILD_ROUTES names \"$route\", which is not path, uvx or venv." >&2
                continue
                ;;
        esac
        DMGBUILD=()
        # Asking for its help shows that the route really runs: uvx may have nothing to fetch
        # it from, and an installed dmgbuild may be broken.
        if ! "route_$route" || ! "${DMGBUILD[@]}" --help >/dev/null 2>&1; then
            continue
        fi
        rm -f "$OUT"
        if "${DMGBUILD[@]}" -s "$SETTINGS" -D "app=$APP" -D "background=$PICTURE" -D "icon=$ICON" \
            "$VOLUME" "$OUT" && image_is_right; then
            return 0
        fi
        echo "warning: dmgbuild ($route) did not make a good disk image." >&2
    done
    return 1
}

# What the image was before it had a picture: the app beside a shortcut to Applications.
plain_image() {
    local stage="$ROOT/build/dmg"
    rm -rf "$stage"
    mkdir -p "$stage"
    cp -R "$APP" "$stage/"
    ln -s /Applications "$stage/Applications"
    hdiutil create -quiet -volname "$VOLUME" -srcfolder "$stage" -ov -format UDZO "$OUT"
    rm -rf "$stage"
}

mkdir -p "$(dirname "$OUT")"
if ! designed_image; then
    echo "warning: dmgbuild $DMGBUILD_VERSION did not make the disk image (tried: ${ROUTES:-nothing})." >&2
    echo "The disk image is made without its picture and layout. Everything else is the same." >&2
    echo "To get the picture: install uv (brew install uv), or pip install dmgbuild==$DMGBUILD_VERSION." >&2
    rm -f "$OUT"
    plain_image
fi
