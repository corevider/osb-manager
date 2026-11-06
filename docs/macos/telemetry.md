# OSB Manager for macOS: usage statistics and reports

This page describes what OSB Manager for macOS sends to `api.osb.lol`, when, and how the code keeps it from getting in the way of the game. The protocol is `PLATFORM.md` of the osb-platform repository, sections 6.3, 7 and 10 and appendices A and C; the consent wording is `docs/legal/CONSENT.md` there, version `2026-11-04.1`, which replaces the texts of Appendix A. The behaviour matches the Windows app ([docs/telemetry.md](../telemetry.md)). The code is in `macos/OsbManager/Sources/OsbManagerCore/Telemetry/` (logic, no UI) and `macos/OsbManager/Sources/OsbManagerApp/` (windows).

## The rule

**Nothing is sent without the user's consent.** The default is off. Without a recorded, current consent the app makes no request to `api.osb.lol` or anywhere else for this feature: no registration, no config read, no ping, no statistics. The one exception is an explicit user action: pressing **Send** in the report window, after the window has shown exactly what will be sent. The app never calls the statistics "anonymous": an install ID is pseudonymous. Only a report sent without usage statistics is called anonymous.

## Consent states and what the network sees

| State | How it comes about | Network behaviour |
| --- | --- | --- |
| Undecided | A fresh install; a missing, empty or corrupt `privacy.json`; a file that claims consent but whose install key is not in the Keychain. The first-run prompt is shown in the main window. | None. The scheduler holds no timer and waits for a consent change. |
| Declined | **No thanks**, or the close button, of the first-run prompt. | None. The prompt is not shown again. |
| Granted | **Share** in the prompt, or **Share usage statistics** in the Privacy window. The consent version (`1`), the text version (`2026-11-04.1`) and the time are written to `privacy.json`. | After a random 60 to 180 s: `GET /v1/config`, then (only when there is something to send) one `POST /v1/installs`, then one `POST /v1/telemetry` per interval. One request at a time. |
| Granted with characters | The second switch, **Show my characters in the OSB dashboard**. | As Granted, plus `character` in the payload; one `PUT /v1/installs/me/consent` when the switch changes. |
| Withdrawn | The first switch off, or **Delete my data**. | At once: the local ID and key (also in the Keychain), the consent and the queued reports are deleted, the scheduler is interrupted and any request in flight is aborted. One best-effort `DELETE /v1/installs/me` is sent with the old key, only when the install had been registered. Then nothing. |
| Outdated | `privacy.json` holds a consent with another text version than the app's (older or newer). | Same as Undecided: no request until the user accepts again. |

Actions of the user that make a request in any state:

| Action | Request |
| --- | --- |
| **Send** in the report window | One `POST /v1/reports`. Linked to the install only when consent is Granted and the install is registered; anonymous otherwise. |
| A report that could not be delivered | Retried from the outbox with the backoff, for at most 72 hours, even when consent is off. It is the same report the user chose to send. Withdrawing consent deletes the outbox. |
| **Download my data** | `GET /v1/installs/me/export`, only while Granted and registered. |
| **Delete my data** | The withdrawal above. |

The report window, the preview and **Show what is sent** only read local data and build text. They make no request. The app never reads `GET /v1/config` for a report; it uses the cached config only to know that the server switched reports off.

The tests prove zero requests for undecided, declined, withdrawn, corrupt, empty, outdated and "key missing" consent over 24 simulated hours with changing game states (`ConsentGateTests`).

## What is sent

Registration (`POST /v1/installs`): a random install ID (UUIDv4), a random 256-bit install key, `app` = `manager-mac`, the app version, `os` = `macos`, the UI language, and the consent version and the characters flag.

Telemetry (`POST /v1/telemetry`), at most every 10 minutes: for every open game window with a status younger than 2 minutes (at most 20, newest first):

| Field | Source |
| --- | --- |
| `slot` | First 16 hex characters of `HMAC<SHA256>` (CryptoKit) over `"slot:" + Account.id` with the 32 install key bytes. The account ID, name and login ID are never sent. |
| `state` | The table below. |
| `level`, `gold`, `hp_pct`, `mp_pct`, `scrolls` | `BotStatus`, only inside the world, clamped to the server's ranges. `gold` is a decimal string. Percentages round half to even, like the Windows app. |
| `bot_version` | `BotStatus.botVersion`, only when it matches `[0-9A-Za-z.+-]{1,32}`. |
| `session` | `BotStatus.session`: a random 8-byte `key` (new when the session starts or a counter goes down), `ms`, `kills`, `deaths`, `xp`, `gold`, `sox`. |
| `character` | Only with the second consent: the character name the page reports and the server name from the account settings, each cut to 32 characters. |

An account without a window is reported once as `offline`. An account with no change and no running session is sent at most once per hour. A body is cut to the accounts that fit 60,000 bytes and is never over 64 KB.

Never sent: login IDs, passwords, account names, positions, party, chat, item names, drop texts, file paths, machine names, hardware IDs, other software.

Reports (`POST /v1/reports`): the kind, the description (2000 characters), the app and OS versions, the language, and diagnostics: the Manager version, the macOS version, the number of game windows and, per window, only `phase`, `login.stage`, `login.message` (64 characters), `bot_version`, `light`, `gpu.retries`, `gpu.failed`, plus the names and versions of the installed userscripts. No logs, no account, login or character names. An optional screenshot of one game window is added only if the user takes it; the thumbnail is shown first and **Remove** takes it out. The picture comes from the browser of that window (no Screen Recording permission is involved), is re-encoded as a fresh PNG with only the image chunks kept (no EXIF, text or time chunks), at most 1920 px wide and 768 KB (it is scaled down in steps until it fits).

## State mapping

`AccountStates.map` turns a `BotStatus` into the `state` of the platform. The first matching row wins. The table is the same as on Windows.

| `inWorld` | `dead` | `botVersion` | `townTrip` | `hunting` | `loginStage` | `phase` | `state` |
| --- | --- | --- | --- | --- | --- | --- | --- |
| yes | yes | any | any | any | any | any | `dead` |
| yes | no | none (no bot) | any | any | any | any | `idle` |
| yes | no | set | yes | any | any | any | `town` |
| yes | no | set | no | yes | any | any | `hunting` |
| yes | no | set | no | no | any | any | `stopped` |
| no | any | any | any | any | `title`, `server`, `credentials`, `connecting`, `retry`, `character`, `entering`, `choose`, `failed` | any | `login` |
| no | any | any | any | any | other | `signed-out`, `character-select` | `login` |
| no | any | any | any | any | other | none or `world` | `loading` |
| no | any | any | any | any | other | anything else | `unknown` |

`offline` is not mapped from a status: it is sent once for a window that has closed or stopped reporting.

## Schedule and failures

- **Start delay** 60 to 180 s after the scheduler starts (after the main window appears) or consent is turned on. **Interval** `max(300, config.interval_s, next_after_s)` times a random 0.9 to 1.1. **Config** read at the start and then every 6 hours; a failed read keeps the last good config for 24 hours.
- **Backoff** after the n-th failure in a row: a random wait between 0 and `min(6 h, 60 s × 2^n)`, never under 60 s. `Retry-After` (429, 503) replaces it, clamped to 60 s to 24 h.
- **Statuses**: 400, 404, 413, 415 drop the item; 401 re-registers once and a second 401 stops sending until the next start; 403 pauses for 24 hours; 409 creates a new ID and key; 503 `disabled` stops telemetry until the next config read; a redirect (3xx) is a failure and is never followed.
- **Fail safe**: three unexpected errors switch the module off until the app restarts.
- **Reports**: the outbox keeps at most 5 reports of at most 900 KB; a report older than 72 hours moves to `outbox/failed/`, and **Unsent reports…** in the app menu offers **Send again** and **Delete** for each.

## Never blocks the game

- The scheduler is a `Task` at `.utility` priority driving an `actor TelemetryScheduler` and an `actor TelemetryClient`. All waits use an injected clock, so tests run on simulated time.
- The only main-actor work is one short hop that copies at most the status values of the open windows (`ManagerStatusSource`). Networking, JSON, HMAC and file writes run off the main actor. Consent changes from the windows are `async` methods of a plain class, so they also run off the main actor. The privacy file and the Keychain are first read off the main actor at start; on a fresh install the Keychain is not touched at all.
- One `URLSession` from `URLSessionConfiguration.ephemeral`: `httpCookieStorage = nil`, `urlCache = nil`, `waitsForConnectivity = false`, `timeoutIntervalForRequest = 15`, `timeoutIntervalForResource = 15`, a session delegate that refuses every redirect, no cookies, TLS validation untouched. A request is also raced against a 15 s sleep on the injected clock and cancelled when that wins. There is no separate 5 s connect limit; the 15 s limit covers connecting.
- One request at a time: a background request that finds another one running returns at once; a request the user started waits its turn.
- Closing the client (when the service stops at quit) cancels the running request and refuses every later one with `cancelled`. The `URLSession` is invalidated only once no request holds it, so no task is ever created on an invalidated session (that raised an uncaught `NSException`, T034).
- `User-Agent: OSBManager/<version> (macOS)` with the short version from the bundle.
- The base URL is fixed to `https://api.osb.lol/v1` in release builds. Debug builds only (`#if DEBUG`) accept the options in the table below. A client needs `https`, or `http` on the loopback.

## Files

| Path under `~/Library/Application Support/OSB Manager` | Contents |
| --- | --- |
| `privacy.json` | The consent record (version `1`, text version, time, characters flag), the install ID, the "registered" flag, the cached config and the last send. **Not** the install key. A corrupt file means consent off. |
| `outbox/` | At most 5 reports waiting to be sent: `<id>.json` and an optional `<id>.png`, written atomically. |
| `outbox/failed/` | Reports that could not be sent in 72 hours. |

The install key is a generic password in the login Keychain: service `com.corevider.osb-manager.install-key`, account `install-key`, `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`. It is created when consent is given and deleted when it is withdrawn.

## Windows and menus

- **Privacy…** (app menu): both switches, the policy links (and, in Turkish, the two KVKK texts), the server message, the install ID with **Copy**, "Last sent", **Show what is sent** (the exact next payload, pretty-printed), **Delete my data…** and **Download my data…**.
- **Report a problem…** (app menu): kind, description, the optional screenshot, the exact JSON, the confirmation text, **Send** and **Cancel**, and the report code after sending.
- **First-run prompt**: a panel at the top of the main window, never in a game window and without blocking anything. **Share** and **No thanks** have the same size and neither is the default button; the close button counts as **No thanks**.
- English or Turkish follows the first preferred language (`tr` gives Turkish). The texts are in `ConsentTexts.swift` and follow `CONSENT.md` word for word.

## Tests and test-only switches

`macos/OsbManager/Tests/OsbManagerCoreTests/` holds the tests (Swift Testing): a manual clock, a `URLProtocol` fake server that never reaches the network, and one test per case C1 to C17 of the protocol (the case ID is in the test name), the golden payloads, the consent gate, the privacy file, the outbox and the screenshot encoder. `sh macos/scripts/test.sh` runs them on the Mac. The real Keychain test runs only with `REAL_KEYCHAIN=1`.

The manual clock never moves while work is pending. Before it wakes the next sleeper, the test kit waits until all of these hold:

- no consent or outbox change is still on its way to a scheduler;
- each scheduler is parked or asleep, and the number of sleepers on the service clock matches the sleeping schedulers;
- every request timeout armed on the client clock belongs to a request that the fake server holds open.

The schedulers report their state through an internal `waitState`. Wall-clock time only bounds how long the kit waits. It never decides when simulated time moves.

Debug builds (`CONFIGURATION=debug sh macos/scripts/build-app.sh`; not compiled into release builds) read these launch options:

| Option | Effect |
| --- | --- |
| `--telemetry-url <url>` | Uses this address (https, or http on the loopback) instead of `https://api.osb.lol/v1`, with a key store in memory (the Keychain is not used). |
| `--telemetry-time-scale <n>` | Runs the scheduler and request clocks `n` times faster. |
| `--telemetry-consent` | Records consent at start, with a key store in memory. |
| `--latency-log <file>` | Writes the 1 s timer lateness, the page message handling time and the main queue hop delay, one JSON line each. |
| `--dialog-shots <folder>` | Saves screenshots of the first-run prompt, the Privacy window and the Report window and quits. |
| `--language <en or tr>` | Overrides the interface language. |

`macos/scripts/fake-api.py` is the local server of the measurement (`hang` never answers anything; `telemetry-hang` answers the config and the registration and never answers telemetry), `macos/scripts/measure-telemetry.sh` runs the phases and `macos/scripts/latency-summary.py` computes p50, p99 and max.
