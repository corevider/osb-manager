#!/bin/sh
set -e
cd "$(dirname "$0")/../.."
base="${SRO_BASE:-sro/t008}"
tar -cf - --exclude=.build --exclude=.DS_Store \
    macos/OsbManager macos/cef macos/scripts docs/macos/app-icon-1024.png \
    src/OsbManager/Browser/autologin.js src/OsbManager/Browser/light.js src/OsbManager/Browser/gpu.js \
    src/OsbManager/Browser/drops.js src/OsbManager/Browser/bridge.js \
    | ssh "${SRO_SSH_HOST:-mac}" "mkdir -p ~/$base && tar -xf - -C ~/$base"
ssh "${SRO_SSH_HOST:-mac}" "SRO_BASE=\$HOME/$base VARIANT=${VARIANT:-both} BUILD_NUMBER=${BUILD_NUMBER:-$(git rev-list --count HEAD)} sh \$HOME/$base/macos/scripts/build-app.sh"
