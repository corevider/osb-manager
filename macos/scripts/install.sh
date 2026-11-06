#!/bin/sh
set -e

usage() {
    cat <<'EOF'
Builds OSB Manager on the Mac (over SSH) from the committed code (git archive HEAD) and installs it for the current Mac user.

Usage: sh macos/scripts/install.sh [--dest <folder>] [--no-desktop-link]

  --dest <folder>      Install into this folder on the Mac (default ~/Applications).
  --no-desktop-link    Do not put a link named "OSB Manager" on the Mac's Desktop.
  --variant app|e2e    Build the test app instead (bundle id com.corevider.osb-manager.e2e).

The first run downloads CEF (about 310 MB) into ~/sro/cef on the Mac, checks its SHA-1
against the pin and the CEF index, and builds the CEF wrapper library. Later runs reuse both.

Environment:
  SIGN_IDENTITY        Name of a code-signing identity in the Mac's keychain. Signs with it and
                       the hardened runtime. Without it the app is signed ad hoc.
  SRO_SSH_HOST         SSH host of the Mac (default mac).
  SRO_DESKTOP          Desktop folder for the link (default ~/Desktop on the Mac).
  BUILD_NUMBER         Overrides the build number (default: the git commit count).
EOF
}

dest="~/Applications"
link=1
variant=app
while [ $# -gt 0 ]; do
    case "$1" in
        --dest)
            [ $# -ge 2 ] || { echo "--dest needs a folder." >&2; exit 2; }
            dest="$2"
            shift 2
            ;;
        --no-desktop-link)
            link=0
            shift
            ;;
        --variant)
            [ $# -ge 2 ] || { echo "--variant needs app or e2e." >&2; exit 2; }
            variant="$2"
            shift 2
            ;;
        -h | --help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option $1." >&2
            usage >&2
            exit 2
            ;;
    esac
done

case "$dest" in
    *[!A-Za-z0-9_./~-]* | "")
        echo "Use a --dest made of letters, digits and . _ / ~ - only." >&2
        exit 2
        ;;
esac
case "$variant" in
    app | e2e) ;;
    *)
        echo "--variant must be app or e2e." >&2
        exit 2
        ;;
esac
case "$SIGN_IDENTITY" in
    *"'"*)
        echo "SIGN_IDENTITY must not contain a single quote." >&2
        exit 2
        ;;
esac

cd "$(dirname "$0")/../.."
host="${SRO_SSH_HOST:-mac}"
version="$(tr -d '[:space:]' < macos/OsbManager/VERSION)"
build="${BUILD_NUMBER:-$(git rev-list --count HEAD)}"
base="sro/build-install"

echo "Making sure CEF is on the Mac and verified..."
cat macos/cef/cef-version.env macos/scripts/cef-fetch-remote.sh | ssh "$host" 'sh -s'
cat macos/cef/cef-version.env macos/scripts/cef-wrapper-remote.sh | ssh "$host" 'sh -s'

echo "Building OSB Manager $version (build $build) on the Mac..."
git archive HEAD \
    macos/OsbManager macos/cef macos/scripts docs/macos/app-icon-1024.png \
    src/OsbManager/Browser/autologin.js src/OsbManager/Browser/light.js src/OsbManager/Browser/gpu.js \
    src/OsbManager/Browser/drops.js src/OsbManager/Browser/bridge.js \
    | ssh "$host" "rm -rf ~/$base && mkdir -p ~/$base && tar -xf - -C ~/$base"

ssh "$host" "env SRO_BUNDLE_MB='${SRO_BUNDLE_MB:-400}' SRO_BUILD_MB='${SRO_BUILD_MB:-2500}' SRO_BASE=\"\$HOME/$base\" DEST='$dest' VARIANT='$variant' VERSION='$version' BUILD_NUMBER='$build' DESKTOP_LINK='$link' DESKTOP_DIR='$SRO_DESKTOP' SIGN_IDENTITY='$SIGN_IDENTITY' sh \"\$HOME/$base/macos/scripts/install-remote.sh\""
