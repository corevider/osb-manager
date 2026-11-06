# Maintaining OSB Manager

OSB Manager lives at `github.com/corevider/osb-manager`. This page is for the maintainers. The tokens, what each workflow can do and how they are protected are in [SECURITY.md](../SECURITY.md).

## How the automation fits together

| Workflow | Starts when | What it does | Why it is safe |
| --- | --- | --- | --- |
| `ci.yml` | every pull request, every push to `main`, or by hand | Windows: `dotnet build -warnaserror`, `dotnet test`, the page script tests and the token guard tests. macOS (`macos-26`, arm64): the `OsbManagerCore` unit tests | plain `pull_request` event: no secrets, read-only token, even for forks |
| `claude-review.yml` | a PR by an `OWNER`, `MEMBER` or `COLLABORATOR`; any other PR after a maintainer adds the label `ok-to-review`; or by hand | a plain step saves the PR's text and diff; the agent reads them and main, leaves inline comments and returns a summary that ends with `VERDICT: MERGE` or `VERDICT: HOLD` | `pull_request_target` with main checked out, never the PR's code; the agent has no shell, network or write access and cannot approve or merge; the token guard checks what it posted |
| `claude-fix.yml` | an issue by an `OWNER`, `MEMBER` or `COLLABORATOR`; any other issue after a maintainer adds the label `ok-to-fix`; or by hand | the agent edits the code for the issue; a separate job builds and tests the patch on Windows; a third job opens a PR | the agent has no shell, network or token; its code runs only in a job without secrets; protected files are refused; the PR still needs a maintainer's approval |
| `merge-approved.yml` | a maintainer approves a PR from a branch of this repository, or by hand with a PR number | merges when the approval covers the current head commit, the `windows` and `macos` checks passed and Claude did not say `HOLD`; never touches PRs that change protected files | runs no PR code; only reads a human approval |
| `release.yml` | a maintainer pushes a tag `v<version>` that equals `<Version>` in `src/OsbManager/OsbManager.csproj` | builds and tests the tag, runs `scripts/package-windows.ps1` and attaches the zip and its `.sha256` to a draft release | runs the tagged commit only; signs nothing; the draft is published by hand |

Each workflow file starts with a comment that says why it is safe. Keep that comment true when you change the file.

An outside PR is reviewed once the label is added, at the commit that was there then. New commits from an outside author do not start another review: remove and add the label again after you have looked at them.

The macOS job runs only the `OsbManagerCore` tests: `OSB_CORE_ONLY=1` makes `Package.swift` declare `OsbManagerCore` and `OsbManagerCoreTests` alone. `CefBridge`, the CEF targets and `OsbManagerCefTests` need the CEF binary distribution and a GUI session, so they run on the operator's Mac (`macos/scripts/test.sh`). The job uses `macos-26` because the package declares macOS 26 and Swift tools 6.2.

## After the first push (the operator, once)

1. **Labels.** Create `ok-to-review` and `ok-to-fix`.
2. **Environment.** Settings, Environments, New environment, name `claude`.
   - Deployment branches and tags: **Selected branches and tags**, add the rule `main`.
   - Optional: add yourself under **Required reviewers**. Every Claude run then waits until you approve it in the run's page.
   - Environment secrets: add `CLAUDE_CODE_OAUTH_TOKEN` (made with `claude setup-token`) or `ANTHROPIC_API_KEY` (a CI-only key with a spend limit). See SECURITY.md.
   - If the environment ever does not work for a run (the job fails with a deployment protection error), the fallback is repository secrets with the same names. The gates and the guard stay the same, but any workflow on `main` could then read them.
3. **Claude GitHub App.** Install the Claude GitHub App on the repository (run `/install-github-app` in Claude Code, or install it from github.com/apps/claude).
4. **Security settings.** Settings, Advanced Security: enable secret scanning, push protection and private vulnerability reporting.
5. **Actions settings.** Settings, Actions, General: "Fork pull request workflows from outside collaborators" set to **Require approval for all outside collaborators**; default workflow permissions **Read repository contents**; allow GitHub Actions to create pull requests only if you use the fix bot.
6. **Branch protection on `main`** (Settings, Rules, Rulesets, New branch ruleset, target `main`):
   1. Require a pull request before merging, with **1 approving review**. Dismiss stale approvals when new commits are pushed. Require approval of the most recent push.
   2. Require status checks to pass: **`windows`** and **`macos`** (they appear after the first run of `ci.yml`). Require branches to be up to date.
   3. Block force pushes and deletion of `main`.
   4. Do not give write access to people you do not trust with the secrets: a collaborator can change a workflow on a branch of this repository.
7. **Tag protection.** A second ruleset for tags matching `v*`: only maintainers may create, update or delete them.

## Releasing

Releases are made by hand, because the macOS package is signed and notarised on the operator's Mac and the update manifests are signed with the release key on the operator's PC.

1. Bump `<Version>` in `src/OsbManager/OsbManager.csproj` and `macos/OsbManager/VERSION` in a PR and merge it. Both must be the same `major.minor.patch`: the apps offer an update only when the signed version is newer than their own.
2. Tag the merge commit `v<version>` and push the tag. `release.yml` builds the Windows zip and attaches it with its SHA-256 to a draft release.
3. Build, sign and notarise the macOS zip on the Mac ([docs/macos/RELEASE.md](macos/RELEASE.md)).
4. Put both zips and their `.sha256` files in one folder on the PC that holds the release key, for example `C:\osb-release\1.2.3\`. Download the Windows zip from the draft (or build it with `scripts/package-windows.ps1`) and copy the macOS zip from the Mac.
5. Sign the update manifests (Windows PowerShell or PowerShell 7):

   ```powershell
   .\scripts\sign-update.ps1 -KeyPath <path to the release key> -Zip C:\osb-release\1.2.3\OSB-Manager-windows-x64.zip,C:\osb-release\1.2.3\OSB-Manager-macos-arm64.zip -Version 1.2.3
   ```

   The script checks each zip against its `.sha256` file, writes `OSB-Manager-<platform>.update.json` and `OSB-Manager-<platform>.update.json.sig` next to it, checks each signature and warns if the key is not one of the keys built into the app. It never prints the key.
6. Upload to the draft release, so that it has these ten files:
   - `OSB-Manager-windows-x64.zip`, `.zip.sha256`, `.update.json`, `.update.json.sig`;
   - `OSB-Manager-macos-arm64.zip`, `.zip.sha256`, `.update.json`, `.update.json.sig`.

   ```powershell
   gh release upload v1.2.3 C:\osb-release\1.2.3\OSB-Manager-* --repo corevider/osb-manager
   ```

7. Write the notes. The release **title** is what the apps show in the update notice, so make it short ("OSB Manager 1.2.3"). Publish the release.

A release without the two `.update.json` files and their signatures is still a normal download; the apps just do not offer it as an update.

Without `release.yml` (or when it fails), run `scripts/package-windows.ps1` on Windows and use `dist/OSB-Manager-windows-x64.zip` and its `.sha256`.

## The release key (the operator, once)

The update manifests are signed with an ECDSA P-256 key. Only its public half is in the code.

1. On the PC that will sign releases, in PowerShell from the repository root:

   ```powershell
   .\scripts\new-update-key.ps1 -KeyPath "$env:USERPROFILE\osb-release-key\osb-update-key.pem"
   ```

   It refuses a path inside the repository and never overwrites a file. It writes the private key (PKCS#8 PEM) readable only by your Windows user, and prints the public key and its fingerprint.
2. Give the printed public key to the coordinator. It goes into `src/OsbManager.Core/Updates/UpdateKeys.cs` and `macos/OsbManager/Sources/OsbManagerCore/Updates/UpdateKeys.swift` (a test checks that both lists match). Until then the apps make no update request at all.
3. Keep the key file out of every repository, synced folder and shared backup. Keep one offline copy (for example on a USB stick in a drawer): without the key no update can be signed.

**Rotating the key.** Make a new key, ship a release whose apps hold both the old and the new public key (two are allowed), sign that release with the old key, and sign later releases with the new one. Once most installs have updated, remove the old public key in a later release. If the key is lost or leaks, remove its public key at once and publish a release signed with the new key; installs that only know the leaked key need a manual download.
