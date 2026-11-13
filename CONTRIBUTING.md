# Contributing to OSB Manager

Pull requests and issues are welcome. This page says what a change needs before it can be merged. AI coding agents also read [AGENTS.md](AGENTS.md), which points here.

## Before you start

- **Open an issue first** for a new feature, a larger change, anything that changes what the app sends over the network, or a change to the page scripts in `src/OsbManager/Browser/` or to the messages between the page and the app. The Windows and macOS apps share those scripts and messages.
- **Security problems** go to a private report as [SECURITY.md](SECURITY.md) describes, never to a public issue.
- **Windows and macOS.** A behaviour change on one app usually needs the same change on the other. If yours does not, say why in the pull request.

## Rules for the code

- **No comments in code.** Use clear names and small functions instead. Explain the why in the commit message, the pull request or the docs (`docs/`, `docs/macos/`). The note at the top of each workflow file in `.github/workflows/` is the only exception. Before you push, this must print nothing:

  ```sh
  git diff origin/main -- '*.cs' '*.swift' '*.mm' '*.h' '*.c' '*.cc' '*.js' '*.mjs' | grep -E '^\+\s*(//|/\*)'
  git diff origin/main -- '*.ps1' '*.sh' '*.py' | grep -E '^\+\s*#[^!]'
  ```

- **English** for code, docs, commit messages, error messages and every text the app shows.
- **Follow the existing style** of the file you change: 4-space indentation, descriptive names, one job per function and type.
- **No new dependencies** (NuGet packages, Swift packages, npm packages, binaries) without an issue first.
- **Privacy.** Nothing new may leave the user's computer outside the existing privacy switch, and the app never sends names, passwords, chat, log text or file paths. See [Privacy and usage statistics](README.md#privacy-and-usage-statistics).
- **Secrets and personal data.** Never commit a token, key, password or certificate. Tests, fixtures, screenshots, logs and issues use made-up account, character and server names only.
- **Tests.** Add or update tests for every behaviour change. Do not delete or skip a test to make CI pass.

## Build and test

Windows, with the .NET 10 SDK and Node.js:

```powershell
dotnet build OsbManager.slnx -warnaserror
dotnet test OsbManager.slnx
node --test tests/bridge/*.test.mjs
```

macOS (Apple Silicon, macOS 26, Xcode with Swift 6.2 or later), in `macos/OsbManager`:

```sh
OSB_CORE_ONLY=1 swift test --arch arm64
```

The whole macOS app, with CEF, is built as [docs/macos/README.md](docs/macos/README.md) describes. CI runs the Windows checks and the macOS core tests on every pull request.

## Commits and pull requests

- **Commit messages** follow [Conventional Commits](https://www.conventionalcommits.org/): `<type>(<scope>): <subject>`.
  - Types: `feat`, `fix`, `docs`, `style`, `refactor`, `test`, `chore`, `perf`.
  - Scope examples: `macos`, `updates`, `telemetry`, `bridge`.
  - The subject is in the imperative mood, short, without a final period, for example `fix(macos): export the CefBridge classes for the Swift Build backend`.
  - Add a body for anything that is not trivial: what was wrong and why this fixes it.
- **One topic per pull request**, as small as it can be.
- **The description** says what changed, why, and how you tested it, with the commands and your OS and toolchain versions.
- **Do not bump versions or write release notes.** The maintainers do that when they release.

## After you open a pull request

- CI builds and tests it. A maintainer may start a Claude review by adding a label.
- A maintainer reviews it and may ask for changes. Nothing is merged without a maintainer's approval.
- A merged change ships with the next release.
