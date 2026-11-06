# Releasing OSB Manager for macOS: Developer ID signing and notarisation

The release is `OSB-Manager-macos-arm64.zip`: the app signed with Corevider's **Developer ID Application** certificate, the hardened runtime and the entitlements CEF needs, notarised by Apple and stapled. It fixes two problems of the ad-hoc build: the Gatekeeper warning on a downloaded app, and the Keychain question that returned after every update.

The signing and the notarisation are done by the operator, in the Mac's own Terminal, with one script. Codesign and notarytool cannot reach the login keychain from an SSH session, and nobody else ever needs the certificate, the private key or the notary credentials.

**The team.** Corevider's Apple team id is `F2JRW9TB5A`. The certificate is `Developer ID Application: <team name> (F2JRW9TB5A)`. The Mac may hold other signing identities too. The script uses only a `Developer ID Application: ... (F2JRW9TB5A)` identity and refuses to guess: it needs `TEAM_ID`, and it stops when it finds no match or more than one.

## One-time setup (the operator, once)

### Step 1: the certificate

Either with Xcode:

1. Xcode → Settings → Accounts → **+** → Apple ID, and sign in with the Corevider Apple ID. Any other Apple ID in the list stays; do not remove it.
2. Select the Corevider team → **Manage Certificates…** → **+** → **Developer ID Application**.

Or without Xcode:

1. Keychain Access → Certificate Assistant → **Request a Certificate From a Certificate Authority…**: the Corevider email, a common name such as "Corevider Developer ID", **Saved to disk**. This creates the private key in the login keychain.
2. developer.apple.com → Account (signed in with the Corevider Apple ID, team Corevider) → Certificates, IDs & Profiles → Certificates → **+** → **Developer ID Application** → upload the request → download the `.cer`.
3. Open the `.cer` (double-click). Keychain Access adds it to the login keychain, next to the private key from step 1.

Check it, in Terminal:

```sh
security find-identity -v -p codesigning
```

One line must read `"Developer ID Application: <team name> (F2JRW9TB5A)"`. Any other identity is ignored.

### Step 2: the notary credentials

Create them for the Corevider team, then store them once, in the Mac's own Terminal:

- **App Store Connect API key (recommended).** In App Store Connect (Corevider account) → Users and Access → Integrations → App Store Connect API → create a team key with the **Developer** role. Download the `.p8` once, and note the key id and the issuer id.

  ```sh
  xcrun notarytool store-credentials osb-notary --key ~/path/AuthKey_<KEY_ID>.p8 --key-id <KEY_ID> --issuer <ISSUER_ID>
  ```

- **Or an Apple ID with an app-specific password.** At appleid.apple.com (the Corevider Apple ID) → Sign-In and Security → App-Specific Passwords → create one named "notarytool".

  ```sh
  xcrun notarytool store-credentials osb-notary --apple-id <corevider apple id> --team-id F2JRW9TB5A
  ```

  `notarytool` asks for the app-specific password itself.

The profile is named `osb-notary` (the script's default; use another name with `NOTARY_PROFILE`). If a profile with that name already exists for another team, pick a different name. Check the profile:

```sh
xcrun notarytool history --keychain-profile osb-notary --team-id F2JRW9TB5A
```

It prints a list (empty at first) and no error.

## Each release

### Step 3: send the committed sources to the Mac

From the repository root on Windows, in Git Bash, with everything committed:

```sh
BUILD_NUMBER=$(git rev-list --count HEAD)
git archive HEAD \
    macos/OsbManager macos/cef macos/scripts docs/macos/app-icon-1024.png \
    src/OsbManager/Browser/autologin.js src/OsbManager/Browser/light.js src/OsbManager/Browser/gpu.js \
    src/OsbManager/Browser/drops.js src/OsbManager/Browser/bridge.js \
    | ssh "${SRO_SSH_HOST:-mac}" "rm -rf ~/sro/release && mkdir -p ~/sro/release && tar -xf - -C ~/sro/release && echo $BUILD_NUMBER > ~/sro/release/BUILD_NUMBER"
```

### Step 4: run the release script in the Mac's own Terminal

```sh
cd ~/sro/release
TEAM_ID=F2JRW9TB5A sh macos/scripts/release-mac.sh
```

Do not run it over SSH; the script refuses. macOS may ask for the login password when codesign first uses the private key; type it in the dialog yourself (**Always Allow** is fine for your own key). The script prints nothing secret.

What it does, in order (it stops at the first problem and says what to fix):

1. Requires `TEAM_ID` (or a full `SIGN_IDENTITY` ending in `(<TEAM_ID>)`). It never picks an identity without a team id.
2. Looks the identity up with `security find-identity -v -p codesigning`, and accepts only `Developer ID Application: ... (<TEAM_ID>)`. No match: it names setup step 1. More than one: it lists them and stops.
3. Checks that the notary profile works for that team. Missing: it names setup step 2.
4. Builds from the sources (a `git archive HEAD` made in step 3; run from a git checkout it makes its own `git archive HEAD`), with the CEF in `~/sro/cef` (fetched and verified when missing), signing inside out with `--options runtime --timestamp` and the entitlements.
5. Checks the signed app: `codesign --verify --deep --strict`, `TeamIdentifier` equal to `TEAM_ID`, the hardened runtime flag, and a designated requirement that names the team and not a single build.
6. Starts the signed app for 8 seconds with an empty data folder (no account, no network use) and checks it stays up. `SMOKE_SECONDS=0` turns this off.
7. Zips with `ditto -c -k --keepParent`, submits with `xcrun notarytool submit --wait --keychain-profile osb-notary --team-id <TEAM_ID>`, prints the result and the team id it used. On failure it prints `notarytool log` and stops.
8. Staples (`xcrun stapler staple`), zips the stapled app again, and verifies with `stapler validate` and `spctl -a -vv` (it must say `Notarized Developer ID`).
9. Writes `~/sro/release-out/OSB-Manager-macos-arm64.zip` and `OSB-Manager-macos-arm64.zip.sha256`, and removes its build folder.

Copy the result back (Git Bash on Windows):

```sh
scp "${SRO_SSH_HOST:-mac}:sro/release-out/OSB-Manager-macos-arm64.zip*" .
```

Then sign the update manifest for both zips on the PC that holds the release key, as [docs/MAINTAINING.md](../MAINTAINING.md#releasing) says. The release key never goes to the Mac.

### If it fails

| Message | Fix |
| --- | --- |
| `This is an SSH session` | Run it in Terminal on the Mac. |
| `TEAM_ID is not set` | Add `TEAM_ID=F2JRW9TB5A`. |
| `No "Developer ID Application: ...(F2JRW9TB5A)" identity` | Step 1. The certificate and its private key must both be in the login keychain. |
| `More than one ... identity` | Delete the extra certificate in Keychain Access, or set `SIGN_IDENTITY` to the full name. |
| `The notary profile ... is missing or not usable` | Step 2, in the same Terminal. A locked keychain gives the same message: unlock it by logging in to the Mac normally. |
| `Notarisation failed (status: Invalid)` | Read the printed `notarytool log`. It names each file Apple rejected and why. |
| `The signed app quit by itself` | The signed build does not start: read the lines the script printed. Nothing was sent to Apple. |

## The Keychain after the first Developer ID build

Saved game passwords are Keychain items made by the app, and their access list names the app by its **designated requirement**.

- An ad-hoc build has the requirement `cdhash H"..."`: one build. Every new build is a different app to the Keychain, so it asks again.
- A Developer ID build has `identifier "com.corevider.osb-manager" and anchor apple generic and ... and certificate leaf[subject.OU] = F2JRW9TB5A`. It is the same for every build signed with that certificate.

So: **the first Developer ID build asks once more for each saved password**. Answer **Always Allow**. That adds the new requirement to the item's access list, and **later Developer ID builds do not ask again**. Nothing in the code or in the items needs a change, and nobody should touch the Keychain items by hand. The script prints the requirement it signed with, so it can be checked.

The cookie key is not involved: the app starts CEF with `--use-mock-keychain`, so Chromium uses no Keychain item.

## After the first successful run

The README still carries both wordings, marked: the signed one (pending) and the ad-hoc Gatekeeper note. After the first release run succeeds and the zip is checked on another Mac, delete the ad-hoc note and the "pending" mark, and say in `docs/macos/README.md` that the release is signed and notarised.
