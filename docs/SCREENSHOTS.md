# Screenshots of the Manager

The screenshots of the OSB Manager main window on the website are rendered by a tool, not taken from a running
app. There is one tool per platform. Each builds the real main window from the current source, fills it from the
same fixture file with made-up accounts, and draws each tab into a PNG file. So both platforms show the same evening.

## Regenerate the Windows screenshots

On Windows, from the repository root:

```powershell
dotnet run --project tools/OsbManager.Shots -- --fixture tools/OsbManager.Shots/fixture.json --out <folder>
```

The tool writes one PNG file per entry in the fixture's `shots` list into `<folder>` and prints their paths. The same
fixture gives the same pixels on every run. The website keeps them as lossless WebP files in `src/assets/shots/`
(`win-account`, `win-status`, `win-stats`, `win-sox`, `win-scripts`, `win-memory` and `win-log`); in the website
repository, `node tools/import-manager-shots.mjs <folder>` converts and copies them.

## Regenerate the macOS screenshots

On Windows, in Git Bash, from the repository root (the Mac is reached over SSH, as for the other macOS scripts):

```sh
sh macos/scripts/shots.sh <folder>
```

It copies `macos/` and the fixture to `~/sro/shots/` on the Mac (`SRO_BASE` changes the folder, `SRO_SSH_HOST` the
host, default `mac`), builds the `OsbManagerShots` tool there, runs it, and copies the PNG files back into `<folder>`.
On the Mac itself, from `macos/OsbManager` (with `CEF_ROOT` set as for `swift build`):

```sh
swift run OsbManagerShots --fixture ../../tools/OsbManager.Shots/fixture.json --out <folder>
```

The website keeps them as lossless WebP files in `src/assets/shots/` (`mac-status`, `mac-stats`, `mac-sox`,
`mac-account` and `mac-log`). `node tools/import-manager-shots.mjs <folder>` in the website repository imports the
Windows set, the macOS set or both, whichever the folder holds; a set with a missing file stops the import. The same
fixture gives the same pixels on every run.

## What the Windows tool does

- It creates a new, empty data folder in the temporary folder and deletes it when it is done. It never reads the
  data folder of an installed app.
- It writes the fixture's accounts, SoX list and settings (update checks off) into that folder and declines the
  usage data question there.
- It opens the main window with a `ShowcaseFeed`: fixed bot reports, cache counters and memory numbers that take the
  place of live game windows. With a feed, the main window starts no game window, no telemetry and no update check,
  so the tool makes no network request.
- The window is never shown on screen. It is laid out at the fixture's client size (1224 × 721), then every font,
  size, margin, padding, column and splitter is multiplied by the fixture's `scale` (2), and the window is drawn into
  a bitmap with `DrawToBitmap`. The result reads like the app on a 200 % display: 2448 × 1442 pixels. Check boxes and
  tree glyphs are drawn by Windows at the size of the current display, so they stay small.
- The Log tab shows the fixture's log lines instead of the tool's own log, which would name the temporary folder.

## What the macOS tool does

`OsbManagerShots` is its own executable target in `macos/OsbManager`. It is not part of the app bundle
(`build-app.sh` builds only the `OsbManager` product), and the app has no option that turns on a fixture.

- It creates a new data folder `osb-shots-<random>` in the temporary folder, writes the fixture's accounts, SoX list
  and settings (update checks off) into it, and deletes it at the end. It never reads
  `~/Library/Application Support/OSB Manager`.
- Saved passwords are an in-memory store holding a marker for the accounts with `savedPassword`, so the Account tab
  shows "saved (leave empty to keep it)". The Keychain is never opened.
- The main window gets a `ShowcaseFeed`: the fixture's bot reports as `GameView`s, the cache counters, the session
  start and the log lines. With a feed, `GameManager` opens no game window and the main window starts no refresh
  timer. The tool never creates the telemetry or update controllers, never loads CEF and makes no network request.
- The state text comes from the app's own `GameWindowState`; the tool stops with an error when it does not match the
  fixture's `state` (plus "(hidden)" for a hidden window).
- The window uses the dark appearance (`NSAppearance(named: .darkAqua)`), whatever the Mac's setting. It is never
  shown on screen: the tool draws it with `cacheDisplay(in:to:)` into a bitmap at the fixture's `scale` (2), from its
  own window only.
- `cacheDisplay` cannot draw the tab control of `NSTabView` on macOS 26: it comes out as an empty white bar. The
  tool therefore draws a standard `NSSegmentedControl` with the same labels and selected tab in its own hidden
  window, and puts that picture in the tab control's place.
- The formats are the English (US) ones, whatever the Mac's language.
- The log line "browser started (profile acc-…)" uses the Windows profile name; the tool writes the account's
  `dataStoreId` instead, as the macOS app logs it.

## The fixture

`tools/OsbManager.Shots/fixture.json` holds:

- `accounts`: the account list. `window` describes an open game window: its state line, light mode, minimised, the
  bot report (`status`, the same fields the page bridge sends) and its memory numbers. `savedPassword` only marks
  the account as having a saved password, so the Account tab shows automatic login as it is set up. The fixture
  holds no password, and the password field stays empty.
- `sox`: the SoX list, oldest first, as the app stores it.
- `cache`, `processes`: the footer's cache counters and the Memory tab's process totals.
- `log`: the lines of the Log tab.
- `scripts`: userscripts to install, as lines of source. Only the metadata block matters.
- `dataStoreId` (per account): the browser profile id the macOS app shows on the Account tab.
- `macShots`: the PNG files of the macOS tool: `file`, `tab`, `size` (the window's content size in points) and
  `crop` (in pixels of the scaled content, without the title bar). The Windows tool ignores both macOS keys.
- `shots`: the PNG files to write. Each names the right-hand tab, and can set the left-hand tab (`left`), the width of
  the left panel (`leftWidth`), the window's client size (`size`, before scaling) and a crop of the result (`crop`, in
  pixels of the scaled image). A short window keeps a list and its buttons together, as the SoX tab with its
  **Only my characters** option.

Every account, login ID and character name in the fixture is made up. Monster and item names come from the game.
Keep it that way: no real player, no real login and no path of a real computer.
