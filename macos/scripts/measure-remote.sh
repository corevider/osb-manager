#!/bin/sh
seconds="${1:-60}"
pattern="${2:-OSB Manager.app/Contents}"

snapshot() {
    ps -axo pid=,cputime=,rss=,command= | grep -F "$pattern" | grep -v grep | awk '
    function seconds(text,    parts, count, total, i) {
        count = split(text, parts, ":")
        total = 0
        for (i = 1; i <= count; i++) total = total * 60 + parts[i]
        return total
    }
    {
        role = "app"
        if (match($0, /--type=[a-z-]+/)) role = substr($0, RSTART + 7, RLENGTH - 7)
        if (role == "utility" && match($0, /NetworkService/)) role = "network"
        if (role == "utility" && match($0, /StorageService/)) role = "storage"
        if (role == "gpu-process") role = "gpu"
        printf "%s %s %.2f %d\n", $1, role, seconds($2), $3
    }'
}

first="$(mktemp)"
last="$(mktemp)"
snapshot > "$first"
sleep "$seconds"
snapshot > "$last"

awk -v seconds="$seconds" '
    NR == FNR { start[$1] = $3; next }
    ($1 in start) {
        cpu = ($3 - start[$1]) / seconds * 100
        printf "%-10s pid %-6s cpu %6.1f%%  rss %6.0f MB\n", $2, $1, cpu, $4 / 1024
        total[$2] += cpu
        memory[$2] += $4 / 1024
        all += cpu
        allmem += $4 / 1024
    }
    END {
        print "--"
        for (role in total) printf "%-10s cpu %6.1f%%  rss %6.0f MB\n", role, total[role], memory[role]
        printf "%-10s cpu %6.1f%% (%.2f cores)  rss %6.0f MB\n", "total", all, all / 100, allmem
    }' "$first" "$last"
rm -f "$first" "$last"
