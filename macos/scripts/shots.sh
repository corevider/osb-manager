#!/bin/sh
set -e
cd "$(dirname "$0")/../.."
out="$1"
if [ -z "$out" ]; then
    echo "Usage: sh macos/scripts/shots.sh <folder for the PNG files>" >&2
    exit 2
fi
host="${SRO_SSH_HOST:-mac}"
base="${SRO_BASE:-sro/shots}"
tar -cf - --exclude='.build' macos tools/OsbManager.Shots/fixture.json | ssh "$host" "rm -rf ~/$base/src ~/$base/out && mkdir -p ~/$base/src && tar -xf - -C ~/$base/src"
ssh "$host" ". ~/$base/src/macos/cef/cef-version.env; cd ~/$base/src/macos/OsbManager && CEF_ROOT=\$HOME/sro/cef/\${CEF_FILE%.tar.bz2} swift build --arch arm64 --product OsbManagerShots --scratch-path ~/$base/build > ~/$base/build.log 2>&1 || { tail -40 ~/$base/build.log; exit 1; }; ~/$base/build/debug/OsbManagerShots --fixture ~/$base/src/tools/OsbManager.Shots/fixture.json --out ~/$base/out"
mkdir -p "$out"
scp -q "$host:$base/out/*.png" "$out/"
ls -l "$out"
