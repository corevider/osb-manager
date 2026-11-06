# OSB Manager for macOS

The macOS version of the multi-account manager, named **OSB Manager**. It is a native app: Swift and AppKit for the window, CEF (Chromium Embedded Framework) for the game, one browser profile per account. There is no Electron. The package, targets and modules are named `OsbManager`, like the Windows app. Everything the user sees says OSB Manager.

It lives in `macos/OsbManager/`, one Swift package. History: the app began on `WKWebView`. In the world, one hidden light-mode account cost 0.43 cores on CEF against 1.17 cores on `WKWebView`, so the app moved to CEF.

It has accounts, game windows, the shared page scripts, userscripts, the start queue, light mode, hiding, the frame limit, automatic login and the Status, Stats, SoX, Scripts and Log tabs. See [Not done yet](#not-done-yet).

## Requirements

- macOS 26.0 or later, on Apple Silicon.
- To build: Xcode 26 (Swift 6.2 or later) and the command line tools (`clang++`, `curl`, `python3`, `shasum`, `iconutil`, `sips`). The only dependency is CEF, downloaded by the build scripts.
- About 3 GB of free disk for the build and 800 MB for the bundle copies; the installer checks and says so.

## Identity

| What | Value |
|---|---|
| Name | OSB Manager |
| App | `OSB Manager.app` (executable `OSB Manager`, helpers `OSB Manager Helper*.app`) |
| Bundle identifier | `com.corevider.osb-manager` |
| Data folder | `~/Library/Application Support/OSB Manager/` |
| Keychain service | `com.corevider.osb-manager` (one generic password per account, account = the account `id`) |
| Keychain service of the install key | `com.corevider.osb-manager.install-key` (one generic password, account `install-key`, only while usage statistics are on) |
| CEF root cache path | `<data folder>/cef` |
| Test app | `OSB Manager E2E.app`, bundle id `com.corevider.osb-manager.e2e`, so its Keychain service and data never meet the real ones |

The strings live in `OsbManagerCore/AppIdentity.swift`, `Info.plist.in` and `scripts/build-app.sh`; a unit test keeps them equal.

## Install, update and uninstall

From the repository root, in Git Bash on Windows (the Mac is reached with `ssh mac`, or the SSH host in `SRO_SSH_HOST`; it needs Xcode 26):

```sh
sh macos/scripts/install.sh
```

This fetches and verifies CEF the first time, builds the release app on the Mac and installs it for the Mac user in `~/Applications/OSB Manager.app` (no admin rights), with a link named **OSB Manager** on `~/Desktop`. Run the same command again to update.

| Option | Meaning |
|---|---|
| `--dest <folder>` | Install into another folder on the Mac (letters, digits and `. _ / ~ -` only). |
| `--no-desktop-link` | Do not create the Desktop link. |
| `--variant e2e` | Build the test app (`OSB Manager E2E.app`) instead. |
| `SIGN_IDENTITY="<name>"` (environment) | Sign with this code-signing identity and the hardened runtime instead of ad hoc, without notarising (see [Signing](#signing-the-keychain-prompt-and-notarisation); the release uses [RELEASE.md](RELEASE.md)). |
| `SRO_SSH_HOST`, `SRO_DESKTOP`, `BUILD_NUMBER` (environment) | Another SSH host name for the Mac (default `mac`); another Desktop folder; another build number. |

What the script does, in order:

1. Runs the CEF fetch and wrapper steps (see [How it is built](#how-it-is-built)). When CEF is already in `~/sro/cef/` and was verified, nothing is downloaded.
2. Copies the sources to `~/sro/build-install/` on the Mac.
3. Refuses to go on if the app is running from the install folder: "OSB Manager is running from … Quit it, then run this script again." Quit with ⌘Q first.
4. Checks the free disk space. The build needs about 2.5 GB. The swap needs room for two copies of the bundle (about 330 MB each) in the install folder, because the new app is put next to the old one before the old one is removed. If there is not enough, the script says how much is free and how much is needed, and changes nothing.
5. Builds. If the build or the signing fails, the old app stays untouched.
6. Installs atomically: the new bundle is moved next to the target (`.OSB Manager.app.new`), checked with `codesign --verify --deep --strict`, the old app is moved to `.OSB Manager.app.old`, the new one is moved in, the old one is deleted. If the move fails the old app is put back.
7. Creates the Desktop link (a symbolic link) unless `--no-desktop-link`. macOS can block Desktop access for processes started over SSH; then the script prints the `ln -sfn` command to run in Terminal on the Mac, and still finishes.
8. Deletes the build folder and prints the installed path, the version and how it was signed.

**Version.** The version is in `macos/OsbManager/VERSION`; the build number is the git commit count at install time. Both are in the About panel (**OSB Manager → About OSB Manager**) and in the first line of each day's log ("OSB Manager 1.0.0 (build 43) started.").

**Icon.** The icon is the OSB seal on the dark-leather tile (`brand/README.md`). `docs/macos/app-icon-1024.png` is its master: a 1024 px PNG with the 824 px tile in the macOS icon grid and a soft shadow, rendered on Windows by `python scripts/make-icon.py`. `deploy.sh` and `install.sh` copy it to the Mac with the sources, and `build-app.sh` makes the ten sizes with `sips` and `AppIcon.icns` with `iconutil` (set `ICON_MASTER` to use another PNG). macOS 26 puts an icon whose shape does not fill its rounded-square mask on a grey plate. The tile fills the standard 824 px rounded square of the grid, so it shows as it is.

**What an update keeps.** Accounts, settings, scripts and the SoX list are in the data folder, which the installer never touches. The game data of each account (cookies, local storage, IndexedDB, cache) is in `<data folder>/cef/<profile>`, also kept. The saved passwords follow the bundle identifier, which never changes. Only the macOS Keychain prompt described below can appear after an update.

**Quit and second launch.** ⌘Q, the Dock's Quit and `kill <pid>` (SIGTERM) take one path: the app closes every game window, saves their positions, waits until each browser has closed, leaves CEF's message loop and exits. ⌘Q and the Dock ask first when a character is in the game; SIGTERM does not ask. If a browser does not close within 20 seconds the app leaves anyway and logs it. Starting the app a second time with the same data folder does not open a second copy and shows no error: the second process brings the running one to the front and exits before it starts CEF.

**Uninstall.**

1. Quit the app.
2. Delete `~/Applications/OSB Manager.app` and the Desktop link `~/Desktop/OSB Manager`.
3. Delete the data folder `~/Library/Application Support/OSB Manager` (accounts, settings, scripts, SoX list, logs and every account's browser profile).
4. Delete the saved passwords: in Keychain Access search for `com.corevider.osb-manager` and delete the items, or use **Forget password** for each account before step 3.

## Updates

The app checks the GitHub releases for a newer signed version, as the Windows app does (see [the README](../../README.md#updates) for the checks, the hosts and the signed manifest). Here:

- **Menu.** **OSB Manager → Check for Updates Now…** checks at once; **OSB Manager → Check for Updates** is the switch (on by default, saved as `checkForUpdates` in `settings.json`). Off means no update request.
- **User-Agent.** `OSBManager/<version> (macOS)`. The requests use an ephemeral session: no cookies, no cache, no stored credentials.
- **Notice.** A panel at the top of the main window with **Install and restart**, **Later** and **Release notes**. Nothing is installed without **Install and restart**.
- **Checks before the swap.** After the zip matched the signed size and SHA-256, it is unpacked with `ditto -x -k` into `updates/` in the data folder. It must hold exactly `OSB Manager.app`, whose `Info.plist` has the bundle identifier `com.corevider.osb-manager` and the signed version. Then:
  1. `codesign --verify --deep --strict` must pass;
  2. `spctl --assess --type exec` must accept it;
  3. `codesign -dv` must report `TeamIdentifier=F2JRW9TB5A` and `Identifier=com.corevider.osb-manager`.
- **The swap.** The new app is moved next to the running one as `.OSB Manager.app.new`. The game windows are closed, the running app is renamed to `.OSB Manager.app.old`, and the new one takes its name. If that rename fails, the old app is put back. The new app is started with `open -n` and the same options plus `--updated-from <pid>`. It writes `updates/started-<pid>` and waits for the old process to quit before it takes the data folder lock. If no sign of it comes within 30 seconds, the old app is put back and keeps running. The new app deletes `.OSB Manager.app.old` when it starts.
- **Where it works.** Any folder the user can write to, such as `~/Applications` or `/Applications` for an admin user. Otherwise the app says so and offers the release page. A build that does not run from an `.app` bundle (for example `swift run`) only offers the release page.
- **The Keychain.** Saved passwords are generic passwords in the login Keychain whose access list names the app by its designated requirement: `identifier "com.corevider.osb-manager" and anchor apple generic and … certificate leaf[subject.OU] = F2JRW9TB5A`. An update passes the checks above only if it is signed by the same team with the same identifier, so it meets the same requirement and macOS does not ask again. A copy you built yourself with `install.sh` is signed ad hoc; after an update to the Developer ID release the Keychain asks once per saved password (**Always Allow**), as [RELEASE.md](RELEASE.md#the-keychain-after-the-first-developer-id-build) explains.

## Signing, the Keychain prompt and notarisation

The release is signed with Corevider's Developer ID and notarised; the steps are in [RELEASE.md](RELEASE.md). `install.sh` still builds ad hoc by default, for the operator's own Mac.

- **Ad hoc (default).** `codesign --sign -`, inside out: every CEF library, the CEF framework, the five helper apps, then the app, each with its entitlements. macOS runs the app on the Mac that built it. Every build has a different code identity (`cdhash`).
- **Developer ID (the release).** `macos/scripts/release-mac.sh` signs with `--options runtime --timestamp`, notarises, staples and writes `OSB-Manager-macos-arm64.zip` with its SHA-256. It uses only the Corevider identity (`TEAM_ID` is required) and runs only in the Mac's own Terminal. `SIGN_IDENTITY="<name>"` on `install.sh` signs with the hardened runtime and that identity too, without notarising.
- **The hardened runtime and the entitlements.** Files in `macos/OsbManager/`, applied by `build-app.sh`:

  | File | Used by | Content and reason |
  |---|---|---|
  | `App.entitlements` | the main app | No entitlement. The browser process does not run JIT code: with the main app signed without `allow-jit` the game still rendered, WebGPU and WebAssembly worked, and nothing crashed. |
  | `Helper.entitlements` | `OSB Manager Helper` and `OSB Manager Helper (Renderer)` | `com.apple.security.cs.allow-jit`. The renderer runs V8, which needs executable JIT memory: with all helpers signed without it the renderer crashed at once (`EXC_BREAKPOINT`, four crash reports) and the game never loaded. The generic helper hosts the utility, network and storage services and also gets it as a precaution (a utility service can run V8, for example for proxy auto-config scripts); the test did not isolate it. |
  | `HelperBasic.entitlements` | the GPU, Alerts and Plugin helpers | No entitlement. The game ran with the GPU helper unsigned for JIT (WebGPU on Metal worked). |

  Left out on purpose: `com.apple.security.cs.allow-unsigned-executable-memory` (the game runs without it, and `allow-jit` covers V8) and `com.apple.security.cs.disable-library-validation`. Library validation lets a process load only libraries signed by Apple or by its own team. All parts of the release carry the same Developer ID team, so the main app and the helpers load the CEF framework without the exception. An ad-hoc signature has no team, so an ad-hoc build with the hardened runtime cannot load the framework (`mapping process and mapped file (non-platform) have different Team IDs`); therefore `build-app.sh` adds `disable-library-validation` to ad-hoc hardened builds only (`HARDENED_RUNTIME=1`), and `release-mac.sh` signs without it. This difference could not be tested without the Developer ID certificate; the release script starts the signed app before notarising to catch it.
- **Testing the hardened runtime without the certificate.** `sh macos/scripts/test-hardened.sh` builds the test app with the ad-hoc hardened runtime on the Mac, starts it with the `hardened` scenario (one throwaway account, no login, only the public page), and checks that the login screen is reached, WebGPU and WebAssembly work, and no crash report appears. `sh macos/scripts/test-release-mac.sh` checks the identity and notary-profile rules of the release script with stand-ins for `security`, `xcrun` and `codesign`.
- **The Keychain prompt after an update.** A password saved by one ad-hoc build is not readable by a later build without asking (measured on ad-hoc builds), because the item's access list names that build's `cdhash`. The app reads the password on a background thread, so it stays responsive while the dialog is open. **Always Allow** stops the question for that build; **Deny**, then enter the password again in the Account tab, works too. Game data, accounts and settings are not affected.
- **After the move to Developer ID.** The designated requirement of a Developer ID build is `identifier "com.corevider.osb-manager" and anchor apple generic and ... certificate leaf[subject.OU] = <team id>`, the same for every build. The first Developer ID build asks once more for each saved password (**Always Allow**); later Developer ID builds do not ask. No change to the items or the code is needed.
- **The cookie key.** Chromium encrypts its cookie database with a key it keeps in the Keychain. OSB Manager starts CEF with `--use-mock-keychain`, so the key is a fixed one inside Chromium and no Keychain item and no dialog is involved, also after updates. The price: the cookie database is only as private as the data folder, which is in the user's home. A Keychain-backed key would show the access prompt again after every ad-hoc update and would lose the cookies when the item is denied.
- **Notarisation.** Written in `release-mac.sh` and checked there with stand-ins for Apple's tools; the first real run is the operator's.

## How it is built

One Swift package, `macos/OsbManager/`:

| Target | Role |
|---|---|
| `OsbManagerCore` | Accounts, settings, scripts, SoX, Stats, credentials, the page message rules and identity. No UI, fully unit tested. |
| `CefBridge` | Objective-C++ over the CEF C++ API: the application class, the runtime, one `SroCefBrowser` per game window, the render-process app. Its public header is plain Objective-C. |
| `OsbManagerCef` | The Swift browser layer: the `GameBrowser` protocol, the CEF implementation, `CefProfiles`. |
| `OsbManagerApp` | AppKit: main window, game windows, menus, dialogs. Talks to the browser only through `GameBrowser`. |
| `OsbManager` | The app executable. |
| `OsbManagerE2E` | The test driver executable (not part of the installed app). |

The helper process is one C++ binary (`Helper/helper_main.cc` and `SroCefApp.cc`) built with `clang++` and copied into five helper apps (plain, Alerts, GPU, Plugin, Renderer). The bundle is about 330 MB: the CEF framework is 326 MB.

**CEF fetch.** `macos/cef/cef-version.env` pins the exact CEF build (`156.0.15+gcf671c0+chromium-156.0.8078.80`, macOS arm64, standard distribution) and its SHA-1. `sh macos/scripts/cef-fetch.sh` runs on the Mac: it compares the pin with the CEF index, downloads only to `~/sro/cef/`, checks the SHA-1 of the archive (deleting it on a mismatch), extracts it and writes a `.verified` marker. Later runs find the marker and do nothing. No CEF binary is in the repository.

**CEF wrapper.** `sh macos/scripts/cef-wrapper.sh` compiles the 214 wrapper sources with `clang++` (no CMake) into `libcef_dll_wrapper.a` under `~/sro/cef/…/wrapper-build/`. It is skipped when the library exists.

**Process model.** `CefInitialize` with `root_cache_path = <data>/cef`, and `CefRunMessageLoop`. Each account gets its own `CefRequestContext` with `cache_path = <data>/cef/<dataStoreId>` and persistent session cookies. The first browser is created one main-queue hop after `OnContextInitialized`: creating it inside that callback gave a browser that never finished closing.

**Flags** (browser process): `--disable-background-timer-throttling`, `--disable-renderer-backgrounding`, `--disable-backgrounding-occluded-windows`, `--use-mock-keychain`, and `--disable-features=IntensiveWakeUpThrottling` (merged with other values). They are the Windows flags minus the Windows-only feature. No timer shim is injected.

**Script injection and the bridge.** The scripts go to the renderer when the browser is created. In the main frame of `https://opensro.online` the renderer runs, when the V8 context is created: `cef-shim.js` (it defines `window.chrome.webview.postMessage`, `addEventListener` and `removeEventListener`; `dispatch` is native and not visible to the page), optional test scripts, the shared bridge (`autologin.js`, `light.js`, `gpu.js`, `drops.js`, `bridge.js`), then the userscripts. Page to app is a process message the browser accepts only from the main frame, with the origin taken from the browser-side frame URL, at most 16 KiB. App to page is a process message too; no script text is built. Mute is the native `SetAudioMuted` of the browser.

## Build, test and run from Windows over SSH

Everything is built, tested and run on the Mac. From the repository root in Git Bash:

```sh
sh macos/scripts/cef-fetch.sh
sh macos/scripts/cef-wrapper.sh
sh macos/scripts/deploy.sh
sh macos/scripts/test.sh
```

| Script | What it does |
|---|---|
| `cef-fetch.sh`, `cef-wrapper.sh` | CEF download and wrapper library, once. |
| `deploy.sh` | Copies the sources to `~/sro/t008` and builds both bundles there (`VARIANT=app`, `e2e` or `both`). |
| `test.sh` | `swift test` for every test target on the Mac (`SRO_BASE`, `TEST_LOG`). The package needs `CEF_ROOT` to compile; the script sets it. |
| `run-e2e.sh <tag> --scenario <name> …` | Runs the test app on the Mac with an own data folder and output folder, waits for it and lists the processes before and after. |
| `measure-remote.sh <seconds> [pattern]` | CPU and memory per process role of a running app, from `ps`. |
| `tables.py <folder>` | Markdown CPU and memory tables from a `measure-summary.json`. |
| `install.sh`, `install-remote.sh`, `build-app.sh` | The installer described above and the bundle build it uses. |

Test scenarios of `OsbManagerE2E` (`--scenario`): `full` (default: two accounts, start queue, title screen, userscript, frame limit, light, mute, hidden and minimised windows, window placement, account removal), `login`, `stats`, `measure`, `persist` (`--phase seed|check|remove`), `retention` (`--phase seed|check`, around an update), `about`, `scriptupdate` (installs OSB 2.0.1 from its public GitHub release, presses **Update** in the Scripts tab and checks that the app stays up and the table shows the newer version; no game window). They use made-up accounts, random passwords, a test bundle id and Keychain service, and never log in to the game. Run them only with the screen unlocked.

## Usage statistics and reports

Opt-in only, off by default, with a first-run panel in the main window, **Privacy…** and **Report a problem…** in the app menu, and English or Turkish texts. What is sent, when, and how it stays off the game's path: [telemetry.md](telemetry.md).

## The data folder

`~/Library/Application Support/OSB Manager/`, or the folder after `--data`.

| Path | Content |
| --- | --- |
| `accounts.json` | A list, in list order. Each account: `id`, `name`, `startLight`, `window` (`x`, `y`, `width`, `height`, `maximized`), `dataStoreId` (the UUID that names its browser profile folder), and the login settings `loginId`, `server`, `character`, `autoLogin`. The password is never in this file. Entries with a bad id, a bad or duplicate name, a duplicate id or data store, or an unreadable field are dropped when the file loads. A file that is not JSON is moved to `accounts.invalid-<time>.json` and the app starts empty. |
| `sox.json` | The SoX drop list: at most 1000 entries, with the Windows field names. |
| `settings.json` | `frameLimit` (30, 60, 120 or 0 for no limit; default 60) `shareGameFiles` (the shared pack cache; **on** when the key is missing, an explicit value is kept) and `checkForUpdates` (on when missing). |
| `scripts/` | `scripts.json` (`id`, `enabled`, `sourceUrl`) and one `<id>.user.js` per installed userscript. |
| `cef/` | CEF's root cache: one folder per account named after its `dataStoreId` (lower case), plus CEF's own files. |
| `logs/` | `app-yyyyMMdd.log`, one per day, and `cef.log`. |
| `privacy.json` | The answer about usage statistics and, only when the user said yes, the random install ID (the key is in the Keychain). See [telemetry.md](telemetry.md). |
| `outbox/` | Reports that could not be sent yet; `outbox/failed/` after 72 hours. |
| `updates/` | A downloaded update while it is checked and installed, and the start marker of the new version. Deleted at the next start. |
| `packcache/` | The shared game pack cache (see [The shared game file cache](#the-shared-game-file-cache)). Created when the setting is on. |

Window positions use the macOS screen coordinates (origin at the bottom left). Removing an account deletes its profile folder after its browser has closed, and its Keychain item.

## Using it

- **Main window.** The account list is on the left (**+**, **−**, **▲**, **▼**; double-click starts an account). The tabs are **Account**, **Status**, **Stats**, **SoX**, **Scripts** and **Log**. The bottom row has **Start**, **Start light**, **Start all**, **Start all light**, **Close all**, the frame limit menu, **Open data folder**, and "N/M in game · K open". A footer line shows "Bot <version>" (or "—") and, with the cache on, the cache line.
- **Stats and SoX.** As in the Windows app: per-account session rows and an "All characters" row; the Star, Moon and Sun drops the game announces, newest first, **Only my characters** on by default, **Clear list** asks first; the list is kept in `sox.json`.
- **Start queue.** Several starts open one window every 15 seconds, in list order. A waiting account shows "Starts in N s".
- **Game menu** (acts on the focused game window or the selected account): **Reload** (⌘R), **Light mode** (⌘L), **Mute** (⇧⌘M), **Hide window / Show window** (⇧⌘H). The **Window** menu lists every open game window, hidden ones too. The **Edit** menu works in the game page and in the main window's fields.
- **Light mode.** The shared bridge decides when it starts (world loaded and hunting, or 15 seconds after load). Light mode also mutes the window.
- **Userscripts.** Add from a URL (https only) or a file. They run at document start in the main frame, after the bridge, through the same Tampermonkey-style wrapper as the Windows app (`@match`, `@include`, `@exclude`, `@run-at`, `@noframes`, `GM_info`, `GM_addStyle`, `GM_getValue`, `GM_setValue`, `GM_deleteValue`, `GM_listValues` and the `GM.*` forms). `GM_addStyle` waits for the page's root element when the script runs before it exists. A change applies when a game window reloads (**Scripts → Reload open game windows**).
- **Window handling.** Position, size and maximised state are saved per account and restored. Closing a window with a character in the game asks first. Zoom and minimise work; the page follows the window size.

## Automatic login

With **Log in automatically** on, the page bridge goes through the game's own login screen as a player would (the page side is the shared `autologin.js`, unchanged). The app supplies the settings and the password.

- **Account tab.** Login ID, Password, Server (empty: the game's default), Character (empty: you choose it), **Log in automatically**, **Save** and **Forget password**. Leave the Password field empty to keep the saved password. The field shows "saved (leave empty to keep it)" when a password is stored, and "Enter the password again" when automatic login is on but no password is saved.
- **Where the password is.** In your macOS login Keychain, as a generic password: service = the app's bundle identifier, account = the account's `id`, accessible only while the Mac is unlocked and only on this Mac. It is never written to `accounts.json`, `settings.json` or the logs.
- **When it is sent.** The app sends the page `auto-login` (enabled only with automatic login on, a login ID and a saved password) whenever the game page loads and whenever you save the account. The page asks for the password only when it reaches the login form. The app answers only if the request came from the main frame of `https://opensro.online` and the window still shows that page, gives at most 3 passwords per window in 10 minutes and at least 15 seconds apart, reads the Keychain off the main thread, and sends the message through the browser's own message channel. Any refusal sends the page a reason.
- **Removing it.** **Forget password**, removing the account, or Keychain Access.

## The shared game file cache

The game loads its files as ranges of a few large pack files (`https://opensro.online/assets/packs/<name>.bin`, one closed `Range: bytes=a-b` per request, from a worker). With **View → Share game files between accounts** on (the default), every account reads these ranges from one cache in `<data folder>/packcache/`. The first account downloads a range, the next ones get it from disk. Three windows that ask for the same range at the same moment share one download.

- **How it works.** `SroCefBridge` returns a `CefResourceRequestHandler` from `CefRequestHandler::GetResourceRequestHandler` (and from the account's `CefRequestContextHandler`, for requests without a frame). For a `GET` of a pack with one closed range of at most 64 MiB it waits for `SharedAssetCache` in `OnBeforeResourceLoad` (asynchronous, the IO thread never blocks) and answers from `GetResourceHandler` with a `206`: `Content-Type: application/octet-stream`, `Content-Length`, `Content-Range: bytes a-b/total`, `Accept-Ranges: bytes`, `Cache-Control: no-store`. The matching rules are `PackRequest.match` and the headers `PackResponse.headers` in `OsbManagerCore`; the bridge is `CefPackInterception`.
- **What falls through to the network, unchanged.** Every other request, every request that is not a closed range of a valid pack name (https, host `opensro.online`, no query), and every request the cache cannot answer: a failed download, a wrong length, a pack that changed size. The failure counts in the footer ("N fell back to the browser") and is logged at most once every 10 seconds.
- **CEF and ranges.** CEF applies the request's `Range` itself to a handler's body (it skips the start bytes and then reads the length). The handler already holds exactly the range, so its `Skip` reports success without moving; this is what makes the served bytes equal to a direct download.
- **The setting.** It takes effect at once for new requests (no reload needed). The footer shows "shared cache 54 MB (2 packs) · served from disk 5 MB · downloaded 49 MB" while it is on. **File → Clear shared asset cache…** deletes the cache (it asks to close the game windows first).
- **On disk.** Per pack, a sparse `*.bin` and a `*.bin.index` in the Windows format. A pack that becomes complete is checked against the hash in its name and deleted when it does not match. The cache saves downloads and time, not disk: each account still keeps the files it loaded in its own browser profile.
- **Off.** Nothing is intercepted, no `packcache/` folder is created, the browser loads everything itself.
- **Limits.** The cache lives in memory per request (a served range of up to 64 MiB is held until the browser has read it). In-world behaviour with the whole 2 GB of packs is not measured.

## Hidden windows

**Hide window** closes the window's view and takes the window off screen (`orderOut`); minimising works the same for the page. Chromium marks the page hidden, the game stops drawing and switches to its hidden path; the bot keeps running. Timers keep full speed because of the flags above, without a timer shim. Two details matter: hiding only the window is not enough with `--disable-backgrounding-occluded-windows` (the page then stays visible), so the content view is hidden too; and the window must be shown again before the page draws again.

In the world, one light-mode hidden account cost 0.43 cores in the maintainer's test.

## Differences from the Windows app

- The game window menu is the **Game** menu in the menu bar, not a menu inside each window.
- Hide and Show are new; Windows only minimises.
- Userscripts are injected into the main frame only.
- The shared pack cache is intercepted in the browser process (CEF request handlers), as on Windows, and the setting is **on** by default. The pack files are the same format, in `<data folder>/packcache/`.
- The saved password is in the Keychain, not encrypted with DPAPI.
- The close confirmation uses a standard alert.
- Chromium runs as several processes per account's profile set (browser, GPU, network, storage, one renderer per account and one spare).

## Not done yet

- **The first signed and notarised release** (the script and the operator steps are in [RELEASE.md](RELEASE.md); the operator's run is still to be reported).
- **Updates.** There is no self-update; update by running `install.sh` again.
- **Not verified:** anything that needs a game login (a real automatic login, in-world light mode, the bot, in-world CPU of several accounts), file and permission dialogs, downloads, drag and drop, the CEF sandbox profile of the helpers (they exit when the sandbox cannot start, and they started), macOS 15 or earlier, and a 120 Hz display.
- Status and stats depend on the bot's `window.SROLean` object. Without the bot, the app shows only the page state.
- The first start of a new account is slow (see the report): the game downloads its files into the account's profile.

