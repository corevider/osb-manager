#!/bin/sh
here="$(cd "$(dirname "$0")" && pwd)"
script="$here/release-mac.sh"
sandbox="$(mktemp -d)"
trap 'rm -rf "$sandbox"' EXIT
mkdir -p "$sandbox/bin" "$sandbox/home"

cat > "$sandbox/bin/security" <<'STUB'
#!/bin/sh
cat "$FAKE_IDENTITIES"
STUB
cat > "$sandbox/bin/xcrun" <<'STUB'
#!/bin/sh
echo "xcrun $*" >> "$FAKE_CALLS"
if [ "$FAKE_PROFILE" = ok ]; then
    exit 0
fi
echo "Error: no profile" >&2
exit 1
STUB
cat > "$sandbox/bin/codesign" <<'STUB'
#!/bin/sh
echo "codesign $*" >> "$FAKE_CALLS"
STUB
chmod +x "$sandbox/bin/security" "$sandbox/bin/xcrun" "$sandbox/bin/codesign"

passed=0
failed=0

run_case() {
    name="$1"
    expected_status="$2"
    expected_text="$3"
    shift 3
    : > "$sandbox/calls"
    output="$(env -u TEAM_ID -u SIGN_IDENTITY -u SSH_CONNECTION HOME="$sandbox/home" PATH="$sandbox/bin:$PATH" FAKE_CALLS="$sandbox/calls" RELEASE_ALLOW_SSH=0 "$@" sh "$script" 2>&1)"
    status=$?
    ok=1
    [ "$status" -eq "$expected_status" ] || ok=0
    printf '%s' "$output" | grep -qF -- "$expected_text" || ok=0
    if grep -q "^codesign" "$sandbox/calls"; then
        ok=0
    fi
    if [ "$ok" -eq 1 ]; then
        passed=$((passed + 1))
        echo "ok   $name"
    else
        failed=$((failed + 1))
        echo "FAIL $name (status $status, wanted $expected_status, text \"$expected_text\")"
        printf '%s\n' "$output" | head -n 6
    fi
}

other_company='  1) 2222222222222222222222222222222222222222 "Apple Distribution: Example Other Ltd (EXAMPLE001)"
  2) FDE74EFE0BBD88082A0234C4CF7C54A985B3BC50 "Apple Development: Someone (8R4859AVZV)"
  3) 1111111111111111111111111111111111111111 "Developer ID Application: Example Other Ltd (EXAMPLE001)"'
corevider='  4) AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA "Developer ID Application: Corevider Ltd (F2JRW9TB5A)"'

printf '%s\n' "$other_company" > "$sandbox/only-other"
printf '%s\n%s\n' "$other_company" "$corevider" > "$sandbox/with-corevider"
printf '%s\n%s\n%s\n' "$other_company" "$corevider" '  5) BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB "Developer ID Application: Corevider Ltd (F2JRW9TB5A)"' > "$sandbox/two-corevider"
printf '%s\n%s\n%s\n' "$other_company" "$corevider" '  5) AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA "Developer ID Application: Corevider Ltd (F2JRW9TB5A)"' > "$sandbox/same-hash-twice"
: > "$sandbox/none"

run_case "no TEAM_ID is refused" 2 "TEAM_ID is not set" FAKE_IDENTITIES="$sandbox/with-corevider" FAKE_PROFILE=ok
run_case "malformed TEAM_ID is refused" 2 "10 capital letters and digits" TEAM_ID=abc FAKE_IDENTITIES="$sandbox/with-corevider" FAKE_PROFILE=ok
run_case "SSH session is refused" 2 "SSH session" SSH_CONNECTION="1.2.3.4 1 5.6.7.8 22" TEAM_ID=F2JRW9TB5A FAKE_IDENTITIES="$sandbox/with-corevider" FAKE_PROFILE=ok
run_case "empty keychain stops" 1 "No \"Developer ID Application: ...(F2JRW9TB5A)\" identity" TEAM_ID=F2JRW9TB5A FAKE_IDENTITIES="$sandbox/none" FAKE_PROFILE=ok
run_case "another team's Developer ID is never used" 1 "No \"Developer ID Application: ...(F2JRW9TB5A)\" identity" TEAM_ID=F2JRW9TB5A FAKE_IDENTITIES="$sandbox/only-other" FAKE_PROFILE=ok
run_case "two Corevider identities stop" 1 "More than one" TEAM_ID=F2JRW9TB5A FAKE_IDENTITIES="$sandbox/two-corevider" FAKE_PROFILE=ok
run_case "SIGN_IDENTITY of another team is refused" 2 "does not match the team" TEAM_ID=F2JRW9TB5A SIGN_IDENTITY="Developer ID Application: Example Other Ltd (EXAMPLE001)" FAKE_IDENTITIES="$sandbox/with-corevider" FAKE_PROFILE=ok
run_case "SIGN_IDENTITY without a team id is refused" 2 "SIGN_IDENTITY must look like" SIGN_IDENTITY="Developer ID Application: Corevider Ltd" FAKE_IDENTITIES="$sandbox/with-corevider" FAKE_PROFILE=ok
run_case "one Corevider identity passes, missing notary profile stops" 1 "notary profile \"osb-notary\" for team F2JRW9TB5A is missing" TEAM_ID=F2JRW9TB5A FAKE_IDENTITIES="$sandbox/with-corevider" FAKE_PROFILE=missing
run_case "same identity listed twice counts once" 1 "notary profile \"osb-notary\" for team F2JRW9TB5A is missing" TEAM_ID=F2JRW9TB5A FAKE_IDENTITIES="$sandbox/same-hash-twice" FAKE_PROFILE=missing
run_case "profile name is configurable" 1 "notary profile \"custom\" for team F2JRW9TB5A is missing" TEAM_ID=F2JRW9TB5A NOTARY_PROFILE=custom FAKE_IDENTITIES="$sandbox/with-corevider" FAKE_PROFILE=missing

echo "passed $passed, failed $failed"
[ "$failed" -eq 0 ]
