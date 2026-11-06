#!/bin/sh
set -e
cd "$(dirname "$0")/../.."
host="${SRO_SSH_HOST:-mac}"
base="sro/hardened-test"
result="${RESULT_DIR:-build/hardened-run}"

tar -cf - --exclude=.build --exclude=.DS_Store \
    macos/OsbManager macos/cef macos/scripts docs/macos/app-icon-1024.png \
    src/OsbManager/Browser/autologin.js src/OsbManager/Browser/light.js src/OsbManager/Browser/gpu.js \
    src/OsbManager/Browser/drops.js src/OsbManager/Browser/bridge.js \
    | ssh "$host" "rm -rf ~/$base && mkdir -p ~/$base && tar -xf - -C ~/$base"

ssh "$host" "SRO_BASE=\$HOME/$base VARIANT=e2e BUILD_NUMBER=${BUILD_NUMBER:-$(git rev-list --count HEAD)} HARDENED_RUNTIME=1 sh \$HOME/$base/macos/scripts/build-app.sh > /dev/null"

status=0
ssh "$host" "APP=\"\$HOME/$base/OSB Manager E2E.app\" OUT=\$HOME/$base/out sh \$HOME/$base/macos/scripts/hardened-run-remote.sh" || status=$?

rm -rf "$result"
mkdir -p "$result"
scp -q "$host:$base/out/result.txt" "$host:$base/out/hardened-summary.json" "$host:$base/out/codesign-checks.txt" "$host:$base/out/crash-reports.txt" "$result/" || true
scp -q "$host:$base/out/game-hardened.png" "$result/" || true
ssh "$host" "rm -rf ~/$base"
exit "$status"
