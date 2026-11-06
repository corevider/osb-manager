#!/bin/sh
set -e
base="${SRO_BASE:?SRO_BASE must name the build folder}"
app="${APP:-$base/OSB Manager.app}"
out="${OUT:-$base/measure}"
settle="${SETTLE_SECONDS:-150}"
measure="${MEASURE_SECONDS:-600}"
scale="${TIME_SCALE:-60}"
port="${PORT:-18765}"
mkdir -p "$out"

run_phase() {
    phase="$1"
    server_mode="$2"
    data="$out/data-$phase"
    rm -rf "$data"
    : > "$out/$phase-requests.jsonl"
    server_pid=""
    if [ "$server_mode" != "none" ]; then
        python3 "$base/macos/scripts/fake-api.py" "$server_mode" "$port" "$out/$phase-requests.jsonl" &
        server_pid=$!
        sleep 1
    fi
    set -- --data "$data" --start alpha,beta,gamma --latency-log "$out/$phase-latency.jsonl"
    if [ "$server_mode" != "none" ]; then
        set -- "$@" --telemetry-url "http://127.0.0.1:$port/v1" --telemetry-time-scale "$scale" --telemetry-consent
    fi
    started=$(python3 -c 'import time; print(time.time())')
    open -n "$app" --args "$@"
    sleep 5
    app_pid=$(pgrep -f "$app/Contents/MacOS" | head -1)
    sleep $((settle + measure))
    finished=$(python3 -c 'import time; print(time.time())')
    kill -TERM "$app_pid" 2>/dev/null || true
    sleep 20
    kill -KILL "$app_pid" 2>/dev/null || true
    [ -n "$server_pid" ] && kill "$server_pid" 2>/dev/null || true
    echo "$phase $started $finished" >> "$out/phases.txt"
}

: > "$out/phases.txt"
for phase in ${PHASES:-baseline hang answers}; do
    case "$phase" in
        baseline) run_phase baseline none ;;
        hang) run_phase hang hang ;;
        answers) run_phase answers telemetry-hang ;;
    esac
done
