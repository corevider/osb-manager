#!/bin/sh
set -e
root="${CEF_ROOT:-$HOME/sro/cef}"
mkdir -p "$root"
archive="$root/$CEF_FILE"
folder="$root/${CEF_FILE%.tar.bz2}"

sha1_of() {
    shasum -a 1 "$1" | cut -d' ' -f1
}

index_sha1() {
    curl -sSfL "$CEF_INDEX_URL" | CEF_FILE="$CEF_FILE" python3 -c '
import json, os, sys
index = json.load(sys.stdin)
name = os.environ["CEF_FILE"]
for version in index["macosarm64"]["versions"]:
    for entry in version["files"]:
        if entry["name"] == name:
            print(entry["sha1"])
            sys.exit(0)
sys.exit(1)
'
}

if [ -f "$folder/.verified" ] && [ "$(cat "$folder/.verified")" = "$CEF_SHA1" ]; then
    echo "CEF $CEF_VERSION is ready in $folder (verified earlier, SHA-1 $CEF_SHA1)"
    exit 0
fi

listed="$(index_sha1)" || { echo "The pinned file is not in the CEF index: $CEF_FILE" >&2; exit 1; }
if [ "$listed" != "$CEF_SHA1" ]; then
    echo "The index lists $listed for $CEF_FILE, the pin is $CEF_SHA1." >&2
    exit 1
fi

if [ ! -f "$archive" ] || [ "$(sha1_of "$archive")" != "$CEF_SHA1" ]; then
    rm -f "$archive"
    curl -fL --retry 3 -o "$archive.part" "$CEF_DOWNLOAD_URL/$(printf '%s' "$CEF_FILE" | sed 's/+/%2B/g')"
    mv "$archive.part" "$archive"
fi

actual="$(sha1_of "$archive")"
if [ "$actual" != "$CEF_SHA1" ]; then
    rm -f "$archive"
    echo "SHA-1 mismatch for $CEF_FILE: got $actual, expected $CEF_SHA1. The file was deleted." >&2
    exit 1
fi

rm -rf "$folder"
tar -xjf "$archive" -C "$root"
printf '%s' "$CEF_SHA1" > "$folder/.verified"
rm -f "$archive"
echo "CEF $CEF_VERSION verified (SHA-1 $actual) and extracted to $folder"
