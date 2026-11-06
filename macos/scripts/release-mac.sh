#!/bin/sh
set -e

usage() {
    cat <<'EOF'
Builds, signs, notarises and staples OSB Manager for macOS with the Corevider Developer ID.
Run it once in the Mac's own Terminal, never over SSH: codesign and notarytool need the login keychain.

Usage: TEAM_ID=<Corevider team id> sh macos/scripts/release-mac.sh

Environment:
  TEAM_ID          Corevider's Apple team id (10 letters and digits). Required, unless SIGN_IDENTITY is given.
  SIGN_IDENTITY    Full name "Developer ID Application: <name> (<TEAM_ID>)". Optional.
  NOTARY_PROFILE   Keychain profile made with "xcrun notarytool store-credentials" (default osb-notary).
  RELEASE_OUT      Folder for the zip and its checksum (default ~/sro/release-out).
  BUILD_NUMBER     Build number (default: the file BUILD_NUMBER in the source folder, or the git commit count).
  SMOKE_SECONDS    Seconds the signed app must stay running before notarising (default 8, 0 turns it off).

Only an identity whose name starts with "Developer ID Application: " and ends with "(<TEAM_ID>)" is used.
The Mac may hold other companies' certificates; they are never picked.
EOF
}

fail() {
    echo "$1" >&2
    exit "${2:-1}"
}

case "$1" in
    -h | --help)
        usage
        exit 0
        ;;
esac

if [ -n "$SSH_CONNECTION" ] && [ "$RELEASE_ALLOW_SSH" != 1 ]; then
    fail "This is an SSH session. Run this script in the Mac's own Terminal: codesign and notarytool cannot reach the login keychain from SSH." 2
fi

root="$(cd "$(dirname "$0")/../.." && pwd)"
profile="${NOTARY_PROFILE:-osb-notary}"
release_out="${RELEASE_OUT:-$HOME/sro/release-out}"
zip_name="OSB-Manager-macos-arm64.zip"
app_name="OSB Manager"
identity_prefix="Developer ID Application: "

valid_team_id() {
    case "$1" in
        *[!A-Z0-9]* | "") return 1 ;;
    esac
    [ "${#1}" -eq 10 ]
}

team_of_identity() {
    name="$1"
    case "$name" in
        "$identity_prefix"*"("??????????")") ;;
        *) return 1 ;;
    esac
    rest="${name%")"}"
    printf '%s' "${rest##*"("}"
}

if [ -n "$SIGN_IDENTITY" ]; then
    identity_team="$(team_of_identity "$SIGN_IDENTITY")" || fail "SIGN_IDENTITY must look like \"${identity_prefix}<name> (<TEAM_ID>)\". Got: $SIGN_IDENTITY" 2
    if [ -n "$TEAM_ID" ] && [ "$TEAM_ID" != "$identity_team" ]; then
        fail "TEAM_ID $TEAM_ID does not match the team $identity_team in SIGN_IDENTITY. Nothing was signed." 2
    fi
    TEAM_ID="$identity_team"
fi

if [ -z "$TEAM_ID" ]; then
    fail "TEAM_ID is not set. Give Corevider's team id, for example: TEAM_ID=<team id> sh macos/scripts/release-mac.sh. The script never picks a signing identity by itself." 2
fi
valid_team_id "$TEAM_ID" || fail "TEAM_ID must be 10 capital letters and digits. Got: $TEAM_ID" 2

identity_list="$(security find-identity -v -p codesigning 2>/dev/null || true)"
matches="$(printf '%s\n' "$identity_list" | grep -F "\"$identity_prefix" | grep -F "($TEAM_ID)\"" || true)"
if [ -n "$SIGN_IDENTITY" ]; then
    matches="$(printf '%s\n' "$matches" | grep -F "\"$SIGN_IDENTITY\"" || true)"
fi
identity_hashes="$(printf '%s\n' "$matches" | awk 'NF >= 2 { print $2 }' | sort -u)"
identity_count="$(printf '%s\n' "$identity_hashes" | awk 'NF' | wc -l | tr -d ' ')"

if [ "$identity_count" -eq 0 ]; then
    echo "No \"${identity_prefix}...($TEAM_ID)\" identity was found by: security find-identity -v -p codesigning" >&2
    echo "Do setup step 1 in docs/macos/RELEASE.md (the Developer ID Application certificate for team $TEAM_ID)." >&2
    echo "Nothing else is used: certificates of other teams stay untouched." >&2
    exit 1
fi
if [ "$identity_count" -gt 1 ]; then
    echo "More than one \"${identity_prefix}...($TEAM_ID)\" identity was found:" >&2
    printf '%s\n' "$matches" | sed -e 's/^ *[0-9]*) *[0-9A-Fa-f]* */  /' >&2
    echo "Remove the extra certificate, or set SIGN_IDENTITY to the one full name you want." >&2
    exit 1
fi
identity_hash="$(printf '%s\n' "$identity_hashes" | awk 'NF')"
identity_name="$(printf '%s\n' "$matches" | head -n 1 | sed -e 's/^[^"]*"//' -e 's/"[^"]*$//')"
echo "Signing identity: $identity_name"
echo "Team id: $TEAM_ID"

notary_error="$(xcrun notarytool history --keychain-profile "$profile" --team-id "$TEAM_ID" 2>&1 >/dev/null)" || {
    echo "The notary profile \"$profile\" for team $TEAM_ID is missing or not usable." >&2
    echo "Do setup step 2 in docs/macos/RELEASE.md (xcrun notarytool store-credentials $profile ... --team-id $TEAM_ID), in this Terminal." >&2
    printf '%s\n' "$notary_error" | head -n 3 >&2
    exit 1
}
echo "Notary profile: $profile (team $TEAM_ID)"

version="$(tr -d '[:space:]' < "$root/macos/OsbManager/VERSION")"
if [ -n "$BUILD_NUMBER" ]; then
    build="$BUILD_NUMBER"
elif [ -f "$root/BUILD_NUMBER" ]; then
    build="$(tr -d '[:space:]' < "$root/BUILD_NUMBER")"
elif [ -d "$root/.git" ]; then
    build="$(git -C "$root" rev-list --count HEAD)"
else
    fail "No build number. Set BUILD_NUMBER, or put it in the file BUILD_NUMBER in $root." 2
fi
case "$build" in
    *[!0-9]* | "") fail "The build number must be digits only. Got: $build" 2 ;;
esac

work="$HOME/sro/release-build"
trap 'rm -rf "$work"' EXIT
rm -rf "$work"
mkdir -p "$work/src" "$release_out"
free_mb="$(df -m "$work" | awk 'NR == 2 { print $4 }')"
if [ "$free_mb" -lt 2500 ]; then
    fail "Not enough free disk space: $free_mb MB free, 2500 MB needed. Free some space and run this script again." 4
fi

sources="macos/OsbManager macos/cef macos/scripts docs/macos/app-icon-1024.png src/OsbManager/Browser/autologin.js src/OsbManager/Browser/light.js src/OsbManager/Browser/gpu.js src/OsbManager/Browser/drops.js src/OsbManager/Browser/bridge.js"
if [ -d "$root/.git" ]; then
    echo "Building from git archive HEAD ($(git -C "$root" rev-parse --short HEAD))."
    git -C "$root" archive HEAD $sources | tar -xf - -C "$work/src"
else
    echo "Building from the staged sources in $root (made with git archive HEAD)."
    tar -cf - -C "$root" $sources | tar -xf - -C "$work/src"
fi

set -a
. "$work/src/macos/cef/cef-version.env"
set +a
sh "$work/src/macos/scripts/cef-fetch-remote.sh"
sh "$work/src/macos/scripts/cef-wrapper-remote.sh"

echo "Building and signing OSB Manager $version (build $build)."
OUT_DIR="$work" SRO_BASE="$work/src" VARIANT=app VERSION="$version" BUILD_NUMBER="$build" SIGN_IDENTITY="$identity_hash" sh "$work/src/macos/scripts/build-app.sh"
app="$work/$app_name.app"

codesign --verify --deep --strict "$app"
signature_details="$(codesign -dv --verbose=4 "$app" 2>&1)"
signed_team="$(printf '%s\n' "$signature_details" | sed -n 's/^TeamIdentifier=//p')"
if [ "$signed_team" != "$TEAM_ID" ]; then
    fail "The signed app has TeamIdentifier \"$signed_team\", not $TEAM_ID. Nothing was sent to Apple." 1
fi
printf '%s\n' "$signature_details" | grep -q "flags=.*runtime" || fail "The signed app does not have the hardened runtime. Nothing was sent to Apple." 1
requirement="$(codesign -d -r- "$app" 2>&1 | sed -n 's/^designated => //p')"
case "$requirement" in
    *cdhash*) fail "The designated requirement is tied to one build (cdhash), so Keychain access would not carry over to updates: $requirement" 1 ;;
esac
printf '%s
' "$requirement" | grep -qF "$TEAM_ID" || fail "The designated requirement does not name team $TEAM_ID: $requirement" 1
echo "Signed app: TeamIdentifier $signed_team, hardened runtime on."
echo "Designated requirement: $requirement"

smoke_seconds="${SMOKE_SECONDS:-8}"
if [ "$smoke_seconds" -gt 0 ]; then
    echo "Starting the signed app for $smoke_seconds seconds with an empty data folder."
    "$app/Contents/MacOS/$app_name" --data "$work/smoke-data" > "$work/smoke.log" 2>&1 &
    smoke_pid=$!
    sleep "$smoke_seconds"
    if ! kill -0 "$smoke_pid" 2>/dev/null; then
        head -n 5 "$work/smoke.log" | cut -c1-300 >&2
        fail "The signed app quit by itself within $smoke_seconds seconds. Nothing was sent to Apple." 1
    fi
    kill -TERM "$smoke_pid"
    wait "$smoke_pid" 2>/dev/null || true
    echo "The signed app started and stayed up."
fi

rm -f "$work/notarize.zip"
ditto -c -k --keepParent "$app" "$work/notarize.zip"
echo "Submitting to Apple with team $TEAM_ID, profile $profile. This can take a few minutes."
submit_output="$(xcrun notarytool submit "$work/notarize.zip" --wait --keychain-profile "$profile" --team-id "$TEAM_ID" 2>&1)" || true
printf '%s\n' "$submit_output"
submission_id="$(printf '%s\n' "$submit_output" | awk '/^ *id: / { print $2; exit }')"
submission_status="$(printf '%s\n' "$submit_output" | sed -n 's/^ *status: //p' | tail -n 1)"
if [ "$submission_status" != "Accepted" ]; then
    if [ -n "$submission_id" ]; then
        echo "Notarisation was not accepted. The log of submission $submission_id:" >&2
        xcrun notarytool log "$submission_id" --keychain-profile "$profile" --team-id "$TEAM_ID" >&2 || true
    fi
    fail "Notarisation failed (status: ${submission_status:-unknown}). Nothing was released." 1
fi
echo "Notarised with team $TEAM_ID."

xcrun stapler staple "$app"
xcrun stapler validate "$app"
gatekeeper="$(spctl -a -vv -t exec "$app" 2>&1)" || true
printf '%s\n' "$gatekeeper"
printf '%s\n' "$gatekeeper" | grep -q "accepted" || fail "Gatekeeper does not accept the stapled app." 1
printf '%s\n' "$gatekeeper" | grep -q "Notarized Developer ID" || fail "Gatekeeper does not report a notarised Developer ID source." 1

rm -f "$release_out/$zip_name" "$release_out/$zip_name.sha256"
ditto -c -k --keepParent "$app" "$release_out/$zip_name"
(cd "$release_out" && shasum -a 256 "$zip_name" > "$zip_name.sha256")
echo "Release: $release_out/$zip_name"
cat "$release_out/$zip_name.sha256"
echo "Done. Team $TEAM_ID, version $version (build $build)."
