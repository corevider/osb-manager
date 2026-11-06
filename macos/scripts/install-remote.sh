#!/bin/sh
set -e
base="${SRO_BASE:?SRO_BASE must name the build folder}"
variant="${VARIANT:-app}"
case "$variant" in
    e2e) name="OSB Manager E2E" ;;
    *) name="OSB Manager" ;;
esac
case "$DEST" in
    "~") DEST="$HOME" ;;
    "~/"*) DEST="$HOME/${DEST#"~/"}" ;;
esac
target="$DEST/$name.app"
staging="$DEST/.$name.app.new"
previous="$DEST/.$name.app.old"
bundle_mb="${SRO_BUNDLE_MB:-400}"
build_mb="${SRO_BUILD_MB:-2500}"

running() {
    pgrep -f "$target/Contents/MacOS/$name" >/dev/null 2>&1
}

refuse_when_running() {
    if running; then
        echo "$name is running from $target. Quit it, then run this script again." >&2
        exit 3
    fi
}

free_mb() {
    df -m "$1" | awk 'NR == 2 { print $4 }'
}

require_space() {
    folder="$1"
    needed="$2"
    reason="$3"
    mkdir -p "$folder"
    available="$(free_mb "$folder")"
    if [ "$available" -lt "$needed" ]; then
        echo "Not enough free disk space for $reason: $available MB free in $folder, $needed MB needed." >&2
        echo "Free some space on the Mac and run this script again. Nothing was changed." >&2
        exit 4
    fi
}

cleanup() {
    rm -rf "$base" "$staging"
}
trap cleanup EXIT

refuse_when_running
require_space "$(dirname "$base")" "$build_mb" "the build"
require_space "$DEST" $((bundle_mb * 2)) "two copies of the app (the new one is put in place next to the old one before the old one is removed)"

OUT_DIR="$base" SRO_BASE="$base" VARIANT="$variant" VERSION="$VERSION" BUILD_NUMBER="$BUILD_NUMBER" SIGN_IDENTITY="$SIGN_IDENTITY" sh "$base/macos/scripts/build-app.sh"

rm -rf "$staging"
mv "$base/$name.app" "$staging"
codesign --verify --deep --strict "$staging"

refuse_when_running
if [ -e "$target" ]; then
    rm -rf "$previous"
    mv "$target" "$previous"
fi
if ! mv "$staging" "$target"; then
    if [ -e "$previous" ]; then
        mv "$previous" "$target"
    fi
    echo "Could not move the new app into place; the old app was put back." >&2
    exit 1
fi
rm -rf "$previous"

installed_version="$(defaults read "$target/Contents/Info" CFBundleShortVersionString)"
installed_build="$(defaults read "$target/Contents/Info" CFBundleVersion)"
signature="ad hoc"
if [ -n "$SIGN_IDENTITY" ]; then
    signature="$SIGN_IDENTITY"
fi

if [ "${DESKTOP_LINK:-1}" = 1 ]; then
    desktop="${DESKTOP_DIR:-$HOME/Desktop}"
    if mkdir -p "$desktop" 2>/dev/null && ln -sfn "$target" "$desktop/$name" 2>/dev/null; then
        echo "Desktop link: $desktop/$name"
    else
        echo "Warning: could not create the desktop link in $desktop." >&2
        echo "macOS can block Desktop access for SSH sessions. The app is installed. On the Mac, in Terminal, run:" >&2
        echo "  ln -sfn \"$target\" \"$desktop/$name\"" >&2
    fi
fi

echo "Installed to $target"
echo "Version $installed_version (build $installed_build), signed: $signature"
