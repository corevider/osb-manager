#!/bin/sh
tag="$1"
shift
base="${SRO_BASE:-$HOME/sro/t008}"
app="${E2E_APP:-$base/OSB Manager E2E.app}"
executable="$(basename "$app" .app)"
out="$base/out/$tag"
data="$base/data-${DATA_TAG:-$tag}"
limit="${E2E_LIMIT:-1800}"
pattern="$app/Contents/MacOS/$executable --data $data"
rm -rf "$out"
[ -n "$KEEP_DATA" ] || rm -rf "$data"
mkdir -p "$out"
ioreg -n Root -d1 -a | grep -c ScreenIsLocked > "$out/screen-locked-before.txt"
ps -axo pid=,command= | grep -F "$app" | grep -v grep > "$out/processes-before.txt"
open -n -a "$app" --stdout "$out/stdout.txt" --stderr "$out/stderr.txt" --args --data "$data" --out "$out" "$@"
sleep 3
waited=0
while pgrep -f "$pattern" >/dev/null; do
    sleep 2
    waited=$((waited + 2))
    if [ "$waited" -ge "$limit" ]; then
        pkill -f "$pattern"
        echo "killed after $limit s" > "$out/killed.txt"
        break
    fi
done
sleep 4
ps -axo pid=,command= | grep -F "$app" | grep -v grep > "$out/processes-after.txt"
echo "finished $tag after $waited s"
