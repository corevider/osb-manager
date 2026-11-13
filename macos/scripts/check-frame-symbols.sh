#!/bin/sh
set -e
executable="${1:?usage: check-frame-symbols.sh <executable>}"
minimum="${MIN_LOCAL_SYMBOLS:-100}"

local_count="$(nm "$executable" | awk '$2 == "t" && $3 ~ /^_\$s14OsbManagerCore/' | wc -l | tr -d ' ')"
if [ "$local_count" -lt "$minimum" ]; then
    echo "$executable has lost its local symbols ($local_count local OsbManagerCore functions, at least $minimum expected)." >&2
    echo "Crash and error frames would carry the names of the nearest exported symbol. Do not strip local symbols (strip -x, STRIP_STYLE)." >&2
    exit 1
fi

if ! output="$("$executable" --check-frames 2>&1)"; then
    echo "$executable did not resolve its own frames to their own names:" >&2
    echo "$output" >&2
    exit 1
fi

echo "frame symbols ok: $local_count local OsbManagerCore functions; own frames: $(printf '%s' "$output" | tr '\n' ' ')"
