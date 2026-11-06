#!/bin/sh
app="${APP:?APP must name the app bundle}"
out="${OUT:?OUT must name the output folder}"
limit="${RUN_SECONDS:-300}"
name="$(basename "$app" .app)"
data="$out/data"
reports="$HOME/Library/Logs/DiagnosticReports"
rm -rf "$out"
mkdir -p "$out" "$data"
marker="$out/.started"
touch "$marker"

"$app/Contents/MacOS/$name" --data "$data" --scenario hardened --out "$out" > "$out/stdout.log" 2> "$out/stderr.log" &
pid=$!
waited=0
while kill -0 "$pid" 2>/dev/null && [ "$waited" -lt "$limit" ]; do
    sleep 1
    waited=$((waited + 1))
done
if kill -0 "$pid" 2>/dev/null; then
    kill -TERM "$pid"
    sleep 5
    kill -0 "$pid" 2>/dev/null && kill -KILL "$pid"
    echo "timeout after $limit seconds" > "$out/result.txt"
else
    wait "$pid"
    echo "exit $?" > "$out/result.txt"
fi
echo "seconds $waited" >> "$out/result.txt"

find "$reports" -name "$name*" -newer "$marker" 2>/dev/null > "$out/crash-reports.txt"
while IFS= read -r report; do
    [ -n "$report" ] && cp "$report" "$out/"
done < "$out/crash-reports.txt"
echo "crash reports: $(wc -l < "$out/crash-reports.txt" | tr -d ' ')" >> "$out/result.txt"

{
    echo "codesign --verify --deep --strict --verbose=2"
    codesign --verify --deep --strict --verbose=2 "$app" 2>&1 | tail -n 3
    for bundle in "$app" "$app"/Contents/Frameworks/*Helper*.app; do
        echo
        echo "codesign -d --entitlements :- ${bundle#"$app"/Contents/Frameworks/}"
        codesign -dvv "$bundle" 2>&1 | grep -E "^Identifier|flags"
        codesign -d --entitlements :- "$bundle" 2>/dev/null | plutil -convert xml1 -o - - 2>/dev/null | grep -E "<key>|<true/>" || echo "(no entitlements)"
    done
} > "$out/codesign-checks.txt" 2>&1

cat "$out/result.txt"
grep -q '"loginScreenReached" : true' "$out/hardened-summary.json" 2>/dev/null || { echo "FAIL: the public login page was not reached"; exit 1; }
grep -q "^exit 0" "$out/result.txt" || { echo "FAIL: the app did not quit by itself"; exit 1; }
[ "$(wc -l < "$out/crash-reports.txt" | tr -d ' ')" -eq 0 ] || { echo "FAIL: crash reports were written"; exit 1; }
echo "PASS: hardened runtime run"
