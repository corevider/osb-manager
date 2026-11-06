# OSB Manager for Windows: usage statistics and reports

This page describes what OSB Manager sends to `api.osb.lol`, when, and how the code keeps it from getting in the way of the game. The protocol is `PLATFORM.md` of the osb-platform repository, sections 6.3, 7 and 10 and appendix C; the consent wording is `docs/legal/CONSENT.md`, version `2026-11-04.1`. The code is in `src/OsbManager.Core/Telemetry/` (logic, no UI) and `src/OsbManager/UI/` (dialogs).

## The rule

**Nothing is sent without the user's consent.** The default is off. Without a recorded, current consent the app makes no request to `api.osb.lol` or anywhere else for this feature: no registration, no config read, no ping, no statistics, no report. The one exception is an explicit user action: pressing **Send** in the report window, after the window has shown exactly what will be sent and the user has confirmed.

## Consent states and what the network sees

| State | How it comes about | Network behaviour |
| --- | --- | --- |
| Undecided | A fresh install; a missing, corrupt or unreadable `privacy.json`; a stored identity that this Windows user cannot open. The first-run prompt is shown. | None. The scheduler holds no timer and waits for a consent change. |
| Declined | **No thanks** in the first-run prompt. | None. |
| Granted | **Share** in the prompt, or **Share usage statistics** in **Help → Privacy…**. The wire consent version (`1`), the text version id (`2026-11-04.1`) and the time are written to `privacy.json`. | After a random 60 to 180 s: `GET /v1/config`, then (only when there is something to send) one `POST /v1/installs`, then one `POST /v1/telemetry` per interval. One request at a time. |
| Granted with characters | The second toggle, **Show my characters in the OSB dashboard**. Its version and time are recorded. | As Granted, plus `character` in the payload; one `PUT /v1/installs/me/consent` when the toggle changes. |
| Withdrawn | The first toggle switched off, or **Delete my data**. | At once: the local ID and key, the consent and the queued reports are deleted, the scheduler is interrupted and any request in flight is aborted. One best-effort `DELETE /v1/installs/me` is sent with the old key, only when the install had been registered. Then nothing. |
| Outdated | The stored text version id is missing or older than the app's (every consent given before `2026-11-04.1`), or the wire version is lower. The first-run prompt is shown again. | Same as Undecided until the user accepts again. **No thanks** here ends the old consent: the local ID and key are wiped and one best-effort `DELETE /v1/installs/me` is sent for a registered install; queued reports stay. |

Actions of the user that make a request in any state:

| Action | Request |
| --- | --- |
| **Send** in the report window, after the confirmation | One `POST /v1/reports`. Linked to the install only when consent is Granted and the install is registered; not linked to an install otherwise. |
| A report that could not be delivered | Retried from the outbox with the backoff, for at most 72 hours, even when consent is off. It is the same report the user chose to send. Withdrawing consent deletes the outbox. |
| **Download my data** | `GET /v1/installs/me/export`, only while Granted and registered. |
| **Delete my data** | The withdrawal above. |

The report window, the preview and the **Show what is sent** box only read local data and build text. They make no request.

## What is sent

Registration (`POST /v1/installs`): a random install ID (UUIDv4), a random 256-bit install key, `app` = `manager-win`, the app version, `os` = `windows`, the UI language, and the consent version and the characters flag.

Telemetry (`POST /v1/telemetry`), at most every 10 minutes: for every open game window with a status younger than 2 minutes (at most 20, newest first):

| Field | Source |
| --- | --- |
| `slot` | First 16 hex characters of `HMAC-SHA256(key = the 32 key bytes, message = "slot:" + Account.Id)`. The account ID, name and login ID are never sent. |
| `state` | The table below. |
| `level`, `gold`, `hp_pct`, `mp_pct`, `scrolls` | `BotStatus`, only inside the world, clamped to the server's ranges. `gold` is a decimal string. |
| `bot_version` | `BotStatus.BotVersion`, only when it matches `[0-9A-Za-z.+-]{1,32}`. |
| `session` | `BotStatus.Session`: a random 8-byte `key` (new when the session starts or a counter goes down), `ms`, `kills`, `deaths`, `xp`, `gold`, `sox`. |
| `character` | Only with the second consent: the character name the page reports and the server name from the account settings, each cut to 32 characters. |

An account without a window is reported once as `offline`. An account with no change and no running session is sent at most once per hour. A body is cut to the accounts that fit 60,000 bytes and is never over 64 KB.

Never sent: login IDs, passwords, account names, positions, party, chat, item names, drop texts, file paths, machine names, hardware IDs, other software.

Reports (`POST /v1/reports`): the kind, the description (2000 characters), the app and OS versions, the language, and diagnostics: the Manager version, the Windows version, the .NET version, the number of game windows and, per window, only `Phase`, `LoginStage`, `LoginMessage` (64 characters), `BotVersion`, `Light`, `GpuRetries`, `GpuFailed`, plus the names and versions of the installed userscripts. No logs, no account, login or character names. An optional screenshot of one game window (PNG, at most 1920 px wide and 768 KB) is added only if the user takes it, and the thumbnail is shown first.

## State mapping

`AccountStates.Map` turns a `BotStatus` into the `state` of the platform. The first matching row wins.

| `InWorld` | `Dead` | `BotVersion` | `TownTrip` | `Hunting` | `LoginStage` | `Phase` | `state` |
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

- **Start delay** 60 to 180 s after the app starts or consent is turned on. **Interval** `max(300, config.interval_s, next_after_s)` times a random 0.9 to 1.1. **Config** read at the start and then every 6 hours; a failed read keeps the last good config for 24 hours.
- **Backoff** after the n-th failure in a row: a random wait between 0 and `min(6 h, 60 s × 2^n)`, never under 60 s. `Retry-After` (429, 503) replaces it, clamped to 60 s to 24 h.
- **Statuses**: 400, 404, 413, 415 drop the item; 401 re-registers once and a second 401 stops sending until the next start; 403 pauses for 24 hours; 409 creates a new ID and key; 503 `disabled` stops telemetry until the next config read.
- **Fail safe**: three unexpected exceptions switch the module off until the app restarts.
- **Never blocks**: one `HttpClient` (`SocketsHttpHandler`: no cookies, no redirects, connect timeout 5 s, 10 minute connection lifetime), a 15 s limit per request measured on the injected `TimeProvider`, `ConfigureAwait(false)` everywhere, the loop on the thread pool. The game windows only write their latest status into a concurrent dictionary (`StatusRegistry`); telemetry reads copies of the immutable records and never calls into a window or the UI thread. The UI shows results from properties that its own 1 s timer reads.

## Files

| Path under `%LOCALAPPDATA%\OSB Manager` | Contents |
| --- | --- |
| `privacy.json` | The consent record (version, time, characters flag), the install ID, the install key protected with DPAPI (current user, entropy `OsbManager.installkey.v1`), the cached config and the last send. A corrupt file means consent off. |
| `outbox\` | At most 5 reports waiting to be sent: `<id>.json` and an optional `<id>.png`, written atomically. |
| `outbox\failed\` | Reports that could not be sent in 72 hours. **Help → Unsent reports…** offers **Send again** and **Delete**. |

## Tests and test-only switches

`tests/OsbManager.Tests/Telemetry/` holds the tests: a fake `TimeProvider`, a fake `HttpMessageHandler`, and one test per case C1 to C17 of the protocol. Nothing in the tests calls the live API.

Debug builds (not compiled into release builds) read these environment variables, for the latency measurements:

| Variable | Effect |
| --- | --- |
| `OSBMANAGER_TEST_API_URL` | Uses this address (https, or http on the loopback) instead of `https://api.osb.lol/v1`. |
| `OSBMANAGER_TEST_TIME_SCALE` | Runs the telemetry clock and timers that many times faster. |
| `OSBMANAGER_TEST_CONSENT` | `1` records consent at start. |
| `OSBMANAGER_TEST_LATENCY_LOG` | Writes UI and message latency samples to this file. |
| `OSBMANAGER_TEST_DIALOG_SHOTS` | Saves screenshots of the dialogs to this folder and exits. |

## Consent wording

All user-facing consent texts come from `docs/legal/CONSENT.md` of the osb-platform repository (Turkish for the `tr` UI culture, English otherwise): the first-run prompt with its title, the usage and characters switches, the confirmation when the usage switch is turned off, the delete confirmation, the report notice with the extra line when usage statistics are off, the report code line and the screenshot text. Turkish also shows the two KVKK links in the Privacy window. `PrivacyTexts.TextVersion` is the version id; `TelemetryLimits.ConsentVersion` stays `1` on the wire.

Usage statistics are called pseudonymous in the docs and never anonymous in the texts. Only a report sent without usage statistics says it is anonymous, as CONSENT.md words it, and the note under the preview says it is not linked to an install.
