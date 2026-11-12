# OSB Manager for Windows: usage statistics, error reports, performance data and reports

This page describes what OSB Manager sends to `api.osb.lol`, when, and how the code keeps it from getting in the way of the game. The protocol is `PLATFORM.md` of the osb-platform repository, sections 6.3, 7 and 10 and appendix C; the consent wording is `docs/legal/CONSENT.md`, version `2026-11-12.1` (consent wire version `2`). Error reports and performance data follow `docs/design/DIAGNOSTICS.md` of the same repository, with the operator decisions of 2026-11-12 (D1 to D6). The code is in `src/OsbManager.Core/Telemetry/` (logic, no UI), `src/OsbManager.Core/Telemetry/Diagnostics/` (the diagnostics core) and `src/OsbManager/UI/` (dialogs).

## The rule

**Nothing is sent or recorded without the user's consent.** One switch, **Share usage statistics, error reports and performance data**, covers all three kinds of data (D1); there is no second switch and no partial withdrawal. The default is off. Without a recorded, current consent the app makes no request to `api.osb.lol` or anywhere else for this feature: no registration, no config read, no ping, no statistics, no report. The one exception is an explicit user action: pressing **Send** in the report window, after the window has shown exactly what will be sent and the user has confirmed.

## Consent states and what the network sees

| State | How it comes about | Network behaviour |
| --- | --- | --- |
| Undecided | A fresh install; a missing, corrupt or unreadable `privacy.json`; a stored identity that this Windows user cannot open. The first-run prompt is shown. | None. The scheduler holds no timer and waits for a consent change. |
| Declined | **No thanks** in the first-run prompt. | None. |
| Granted | **Share** in the prompt, or **Share usage statistics, error reports and performance data** in **Help → Privacy…**. The wire consent version (`2`), the text version id (`2026-11-12.1`) and the time are written to `privacy.json`. The diagnostics buffers start empty. | After a random 60 to 180 s: `GET /v1/config`, then (only when there is something to send) one `POST /v1/installs`, then one `POST /v1/telemetry` per interval. One request at a time. |
| Granted with characters | The second toggle, **Show my characters in the OSB dashboard**. Its version and time are recorded. | As Granted, plus `character` in the payload; one `PUT /v1/installs/me/consent` when the toggle changes. |
| Withdrawn | The first toggle switched off, or **Delete my data**. | At once: the local ID and key, the consent and the queued reports are deleted, the diagnostics trail, pending events and every file in `diagnostics\` are wiped, the diagnostics session token is cancelled, the scheduler is interrupted and any request in flight is aborted. One best-effort `DELETE /v1/installs/me` is sent with the old key, only when the install had been registered. Then nothing. |
| Outdated | The stored wire version is lower than `2`, or the text version id is missing or older than `2026-11-12.1`: every consent given to version `1` (`2026-11-04.1`) is outdated after this update. The first-run prompt is shown again with the lead line "What OSB Manager shares has changed: it now includes error reports and performance data." (D3, D6). | Same as Undecided until the user accepts again. **No thanks**, or closing the prompt with its **×**, ends the old consent: the local ID and key and the diagnostics files are wiped and one best-effort `DELETE /v1/installs/me` is sent for a registered install; queued reports stay. |

Actions of the user that make a request in any state:

| Action | Request |
| --- | --- |
| **Send** in the report window, after the confirmation | One `POST /v1/reports`. Linked to the install only when consent is Granted and the install is registered; not linked to an install otherwise. |
| A report that could not be delivered | Retried from the outbox with the backoff, for at most 72 hours, even when consent is off. It is the same report the user chose to send. Withdrawing consent deletes the outbox. |
| **Download my data** | `GET /v1/installs/me/export`, only while Granted and registered. |
| **Delete my data** | The withdrawal above. |

The report window, the preview and the **Show what is sent** box only read local data and build text. They make no request.

## What is sent

Registration (`POST /v1/installs`, schema 1): a random install ID (UUIDv4), a random 256-bit install key, `app` = `manager-win`, the app version, `os` = `windows`, the Windows UI language as `locale` (data, not UI), and `consent` with `usage_version: 2` and the characters flag. `PUT /v1/installs/me/consent` sends `usage_version: 2` too.

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
| `diagnostics\` | Only while consent is on: at most 10 pending files `pending-<unix seconds>-<random>.json` of at most 16 KB each (already scrubbed event JSON, written atomically: crashes and the `run_end` of an unclean exit), and the run marker `run.json`. Deleted after sending, after 7 days, and all at once when consent is off, outdated, declined or unreadable at start. |
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
| `OSBMANAGER_TEST_WITHDRAW_AFTER` | Switches the consent off through the real withdraw path after this many seconds, for the "turn it off, nothing more is sent" check. |
| `OSBMANAGER_TEST_DIALOG_SHOTS` | Saves screenshots of the dialogs to this folder and exits. |

## Consent wording and language

OSB Manager is **English only**, whatever the Windows language (D4). `PrivacyTexts.English` is the one text set: the Privacy window, the first-run prompt, the report window, the unsent reports, every confirmation and message. There is no Turkish set and no culture switch. The texts are copied exactly from `CONSENT.md` `2026-11-12.1`, sections 1 to 4 (T079, commit `8fdf5e7` of osb-platform; a lawyer still reviews them, decision X8). The KVKK pages stay Turkish on the site and are linked from the prompt and the Privacy window as **KVKK notice (Turkish)** and **KVKK explicit consent (Turkish)**. `locale` in registration and in a report stays the Windows language: it is data, not UI.

`PrivacyTexts.TextVersion` is the text id `2026-11-12.1`; `TelemetryLimits.ConsentVersion` is `2` on the wire. Usage statistics are called pseudonymous in the docs and never anonymous in the texts. Only a report sent without usage statistics, and the daily totals without the install ID, are called anonymous, as CONSENT.md words it.

## Error reports and performance data: the diagnostics core

T080 builds the local, pure part: the hub, the scrubber, the limiter, the trail and the pending files. T081 adds the capture, the run marker, the perf sampler, the batch job and the preview, all described in the sections after the scrubber rules.

`TelemetryService.Diagnostics` is a `DiagnosticsHub`, gated by the one switch:

| Part | Type | What it does |
| --- | --- | --- |
| Gate | `DiagnosticsHub.Recording`, `OnConsentChanged`, `Wipe`, `Session`, `Wiped` | Records only while consent is Granted. A fresh grant starts empty buffers. Any other change (withdrawn, declined, outdated) wipes the trail, the limiter and every file in `diagnostics\`, cancels `Session` (the token T081 passes to its request, so an in-flight request is aborted) and raises `Wiped`. At start with consent off, leftover files are deleted. |
| Recording | `DiagnosticsHub.Record(event)`, `WritePending(event)` | Scrub, then dedupe and limit; or write one scrubbed event to a pending file synchronously (the crash path). Both do nothing while consent is off. |
| Models | `DiagnosticEvent`, `ErrorDetail`, `ProcessDetail`, `HangDetail`, `GpuDetail`, `StopDetail`, `WarnDetail`, `RunEndDetail`, `DiagnosticContext`, `TrailItem`, `PerfEntry`, `DiagnosticEnv`, `DiagnosticBatch` | The schema of DIAGNOSTICS.md 3.3. |
| Writer | `DiagnosticJson.Batch(batch, terms, now)`, `Event(event, terms)`, `ParseEvent(json)` | The JSON of 3.3 with every limit: 50 events, 2 perf entries, 4 KB per event (else the trail goes, else the event, counted as oversize), 8 KB per perf entry, per-window arrays sorted and cut to 64, minute-aligned times, events older than 7 days or more than 10 minutes ahead dropped. A body over 60 KB loses trails (newest events first), then events (oldest first, `dropped.oversize`), then perf. Every event is scrubbed again inside the writer. |
| Scrubber | `DiagnosticScrubber` | DIAGNOSTICS.md 5.2, below. |
| Private terms | `PrivateTerms` | In memory only, case-insensitive, terms of 3 or more characters, 2000 entries (oldest out) plus the pinned machine terms. `ForThisMachine(dataFolder)` pins `Environment.UserName`, `MachineName`, `UserDomainName` and the data folder path. T081 adds account names, login IDs and the character and server names the pages report with `Add`/`AddRange`. Never sent, written or logged. |
| Frames | `FrameReducer.FromException`, `Reduce` | `new StackTrace(e, fNeedFileInfo: false)`. `Namespace.Type.Method+IL_01A3` for `System.`, `Microsoft.`, `OsbManager.` and `Windows.`, generic arity removed, compiler-generated names kept. Every other run of frames is one `ext`. At most 16. A frame that does not match the 3.3 pattern is `ext`. |
| Fingerprint | `DiagnosticFingerprint` | First 16 hex of SHA-256 of `manager\|<kind>\|...`: exceptions `type\|origin\|<first 5 own frames without +IL_, joined by commas>`; process failures `kind\|reason\|description code`; unresponsive `outcome`; GPU `code`; run end `outcome`; warnings `category\|code`. |
| Trail | `DiagnosticTrail`, `TrailCodes` | Ring buffer of the last 50 codes (level, fixed code, window ordinal, time), filled only while consent is on. A repeat of the newest entry raises its count. Snapshots give seconds before the event, never a clock time. |
| Limits | `DiagnosticLimiter` | One pending event per fingerprint (repeats add to `count`, capped at 100000). At most 30 new events in a sliding hour and 200 in a sliding day (beyond: `dropped.rate_limited`). The same fingerprint on the wire at most once an hour. The trail only on the first occurrence in a run. `run_end` is never limited. The run's sampling draw (0 to 99) records only when below `sample_pct` and counts nothing otherwise. `Take` and `Return` let the sender give back a failed batch. Clock injected. |
| Pending files | `PendingDiagnostics` | `diagnostics\` in the data folder, see Files. |

### Scrubber rules (DIAGNOSTICS.md 5.2)

- No free text: every field is an enum, a number, a version, a fingerprint, a `code`, a `frame` or a `template`, re-checked against the 3.3 patterns before writing.
- Exceptions: never `Message`, `Data`, `Source`, `HelpLink`, `TargetSite` or `ToString()`. The type's full name only for the allowlisted namespaces and when it fits `^[A-Za-z_][A-Za-z0-9_.]{0,127}$` (nested types with `+` become `Exception`). `HResult` as hex; for a `Win32Exception` its native code as `HRESULT_FROM_WIN32` (`0x8007xxxx`). At most 3 inner types.
- Page strings: phase, login stage and mode go through fixed lists (else `other`). `GpuFailed` text is mapped to `adapter-null`, `device-lost`, `out-of-memory`, `unsupported` or `other`. Process descriptions come only from a fixed list of Chromium service names. Process kinds and reasons come from the WebView2 enum names in snake case.
- Templates (OSB engine errors, for T084): quoted parts become `<q>`, URLs `<url>`, numbers `<n>`, private terms `<x>`; other characters are dropped; cut to 160. Errors of other types send no template.
- Path guard: any string with `X:\`, `\\`, `/Users/`, `/home/`, `%VAR%` or `Users` followed by a separator becomes `<path>` (template, frame) or is dropped.
- Private terms: a hit in a frame or template replaces it with `<x>`. A hit in an optional field drops the field. A hit in a required field (type, code, version) drops the whole event.

The canary tests (`DiagnosticsCoreTests.Canary_*`, made-up values only) cover a log line with a player name, a path with a user name, the machine name, a chat line and an exception message holding an account name. Each fails when the scrubber is switched off.

## Capture, run marker and performance sampling (T081)

Every capture method of `TelemetryService.Capture` (`DiagnosticsCapture`) first asks `hub.Recording`, then puts the raw values into `DiagnosticsInbox`: a `Channel` bounded at 64 with `DropWrite` (a dropped item raises `dropped.rate_limited`). One thread-pool reader scrubs, fingerprints and counts. The callers (the window's message handler, the UI timers) do a flag check and a queue write and nothing else. The only exception is `Crash`, which runs on the crashing thread and writes the pending file synchronously. Three unexpected exceptions inside the diagnostics code switch the hub off until restart (`DiagnosticsHub.Faulted`); the diagnostics code never reports its own errors.

| Capture point | Where | What is recorded |
| --- | --- | --- |
| WebView2 process failure | `GameWindow.OnProcessFailed` | `process_failed`: kind, reason, exit code as hex and the description only when it is one of the known Chromium service names, through the T080 scrubber functions. `FrameInfosForFailedProcess` is never read. Every kind is recorded, including `render_process_unresponsive`. |
| Unresponsive window | `RenderProcessUnresponsive`, `PageHealth` steps, the page responding again | `unresponsive`: outcome `responded`, `reloaded`, `restarted` or `gave_up`, and the seconds waited. |
| GPU failure | `GameWindow.LogRenderer` | `gpu_failed`: code from the fixed pattern table (`adapter-null`, `device-lost`, `out-of-memory`, `unsupported`, `other`) and the retry count. The text of the failure is never kept. |
| Handled exception | `AppLog.Error(message, exception)` raises `ExceptionLogged` | `dotnet_exception` with `handled: true`, origin `caught`: type, HRESULT, inner types, our frames. Never the message. This covers `GameWindow.Fail` and every `MainForm` error path that logs an exception. |
| Unhandled exception | `CrashHooks` (installed in `Program.Main`) | `AppDomain.UnhandledException`: `Crash`, a synchronous pending file, origin `appdomain`. `Application.ThreadException`: recorded with origin `ui_thread`, the standard `ThreadExceptionDialog` is still shown, and **Quit** also writes the pending file. `TaskScheduler.UnobservedTaskException`: origin `task`, nothing else changes. |
| Run marker | `RunMarker`, `diagnostics\run.json` | See below: every recorded run ends in one `run_end` (`clean`, `unclean` or `crash`) at the next start. |
| Trail | `DiagnosticsCapture.Trail` at the existing log call sites | Fixed codes only, never the log text. |
| Private terms | `AppServices.LearnTerms`, `DiagnosticsCapture.Learn` | Account names, login IDs, servers, characters and profile names when accounts load, are added or are saved; the character a page reports, once per change. Added again at the start of every fresh grant. |

Trail call sites (one code per log site; the window ordinal is the start order and never the account ID):

| Code | Call site |
| --- | --- |
| `window.start`, `window.closed` | `MainForm.Launch` and its `FormClosed` |
| `window.renderer-exited`, `window.unresponsive`, `window.responding` | `GameWindow.OnProcessFailed`, page responding again |
| `window.reload`, `window.restart`, `window.gave-up` | `PageHealth` and `RendererRecovery` steps |
| `login.failed:<stage>`, `login.reload` | login stopped (the stage before it failed, through the stage allowlist), login reload |
| `gpu.retry`, `gpu.failed:<code>` | `GameWindow.LogRenderer` |
| `update.download`, `update.failed` | `MainForm` update install |
| `script.install-failed`, `script.update-failed` | `MainForm` userscript install and update |
| `settings.light-on`, `settings.fps-limit` | light mode switched on, frame rate limit changed |

**Run marker.** `RunMarker` writes `diagnostics\run.json` (version, start minute, last-alive minute, crashed flag, clean flag) at start and when a fresh grant begins, only while consent is on, and rewrites the alive minute at every sample. A clean exit (`MainForm` closing path, `Application.ApplicationExit`) rewrites it with the clean flag and the final alive minute, only while recording; a run that already crashed keeps its crash flag. At the next start, a marker that is not older than 7 days becomes one pending `run_end` event: outcome `clean`, `unclean`, or `crash` when the crash path set the flag, with the uptime and the previous version. So every recorded run has a `run_end`, which gives the crash rate its denominator (DG18). Switching the consent off deletes the marker, and with consent off no marker exists.

**Performance entry.** One local sample every 60 s on the thread pool (`PeriodicTimer`, started only while the switch is on and stopped when it goes off), one perf entry per `perf_interval_s` (default 30 minutes: 30 samples, `span_s` 1800). Nothing is sampled while the config says `perf: false` or `diagnostics.enabled: false`, or when the run was sampled out.

| Value | Source |
| --- | --- |
| Memory per role: renderers (each, sorted, with median and maximum over the span), GPU, utility, browser total, the app | Private bytes of the processes in the cached process list. `BrowserProcessCache` holds the pid and kind of `CoreWebView2Environment.GetProcessInfos()`; it is refreshed on `ProcessInfosChanged` and once per tick through a UI post (a list copy). The sampler reads the counters of those PIDs on its own thread, never per window. |
| CPU per role | `Process.TotalProcessorTime` deltas between the first and the last sample of each PID in the span, as percent of one core, summed per role. |
| JS heap and WASM per window | `GameWindow.ReadPageMemoryAsync`, once per span, started about two minutes before the span ends from `Application.Idle` through `BeginInvoke`, with a 10 s limit for all windows together. The sampler never awaits it. |
| Windows | Open, light, hidden and in-world counts, refreshed in the existing one-second UI timer while recording. |
| Env | OS build, WebView2 runtime, .NET, memory bucket (`GC` total plus 1 GB, rounded down), core bucket, and `gpu_vendor` once a game page reported it (T084, below). |

**The batch job.** `TelemetryScheduler` runs it as the second job of its loop, behind the same gate, timeouts and backoff, with its own failure counters:

- It runs right after usage statistics in the same wake-up, never before. Both jobs start together after the 60 to 180 s start delay or after a fresh grant.
- It reads the `diagnostics` block of the config that the usage job stores (`GET /v1/config`): `interval_s` is clamped to 600 to 86400, `perf_interval_s` to 1800 to 86400, `sample_pct` to 0 to 100. A missing or malformed block is disabled, and so is a config older than 24 hours.
- Nothing is sent while the server flag is off, `client_ok` is false, consent is not Granted, `hub.Recording` is false, the diagnostics code faulted, or there is nothing to send. No empty batch is ever sent.
- The batch is the pending files first, then the limiter's events (the same fingerprint at most once an hour), then the perf entries when `perf` is true. The install registers first when needed (the same `POST /v1/installs`).
- The request is linked to `hub.Session`: switching the consent off aborts it, and the events are not returned afterwards.
- **202:** the sent pending files are deleted and the next batch waits `max(interval_s, next_after_s)` with jitter. **Failure (network, 429, 5xx, 503):** the events go back to the limiter, the perf entries to the collector, the pending files stay, and the wait follows the shared backoff (never under 60 s, `Retry-After` honoured). **503 `disabled`:** the job is off until the next config read. **400, 404, 413, 415:** the batch is dropped (a broken batch is not sent again) and the job backs off. **401:** the install is marked unregistered and registers again; a second 401 stops the job until restart.
- **403 `consent_required`:** one `PUT /v1/installs/me/consent` with the local state, the events go back, and the job tries again after the normal interval. A second 403 stops the job until the next app start. Any other 403 pauses the job for 24 hours.

**Show what is sent.** The Privacy window's preview shows two sections, **Usage statistics, next batch** and **Error reports and performance data, next batch**. The second is built by the same function as the real send (`DiagnosticsUploader`), peeking instead of taking, so it is the next batch exactly as it would go out, and the preview sends nothing. It is empty while the switch is off, while the server flag is off, or when there is nothing to send.

## OSB inside OSB Manager and the GPU vendor (T084)

DIAGNOSTICS.md 3.6. OSB in a game window makes no diagnostics request of its own; it records only when the Manager says so and hands its events to the Manager through page messages.

**Messages.**

| Message | Direction | Form | When |
| --- | --- | --- | --- |
| `osb-diagnostics` | Manager to page | `{ "type": "osb-diagnostics", "on": true, "perf": false }`, `perf: true` for the one window asked for perf, or `{ "type": "osb-diagnostics", "on": false }` | `GameWindow.SyncPageDiagnostics`, from the one-second `WatchPage` tick, after each navigation and once OSB has loaded in the page (the first status report with a bot version after a navigation). It is sent only when the wanted state differs from what this page was last told; `on: false` goes only to a page that was told `on: true`. |
| `osb-diagnostics-batch` | page to Manager | `{ "type": "osb-diagnostics-batch", "events": [ ... ] }`, events only, 1 to 10, at most 12 KB | From OSB's own idle-time job, at most once per 60 s, only while on. |
| `osb-diagnostics-perf` | page to Manager | `{ "type": "osb-diagnostics-perf", "perf": { ... } }`, one OSB-shape perf entry, at most 2 KB | Once, at the end of the span the Manager asked this window for. |

**The receive path.** `GameWindow.OnWebMessageReceived` recognises the two page messages by their type alone (`OsbPageBatch.IsBatch` and `IsPerf`: the message starts with `{"type":"…"` or ends with `,"type":"…"}`, so no parse runs on the UI thread) and calls `OsbPageBatchReceiver.Offer` or `OfferPerf`. These do a recording check, a size check against the string length and a push into the receiver's own channel (4 items, `DropWrite`). The page queue is separate from `DiagnosticsInbox`, so a flood of page messages never pushes out the Manager's own events. One thread-pool reader then:

1. drops the message when the hub session changed or recording stopped since the push (`AfterOff`);
2. for a batch, drops it when the same window posted less than 55 s earlier (OSB posts every 60 s; 5 s of delivery jitter are allowed) and counts it in `dropped.rate_limited`;
3. drops it when its UTF-8 size is over 12 KB (batch) or 2 KB (perf) and counts it in `dropped.oversize`;
4. parses it strictly with `OsbPageBatch.Parse` or `ParsePerf`: the rules of 3.3 and 3.3.1 with `source: "osb"`. Any unknown field, duplicate property, `null`, control character or lone surrogate, comment, trailing comma, depth over 8, wrong enum, number out of range, a decimal where an integer belongs, more than one decimal, `uptime_s` not a multiple of 60, a reserved or malformed fingerprint, an `at` that is not minute aligned or outside 7 days back and 10 minutes ahead, a Manager-only field (`hresult`, a Manager origin, `window` in the context or trail, `goldChange`), a `perf` or `dropped` field in a batch, or a Manager perf field in a perf answer rejects the whole message (`Invalid`, counted locally only, because the wire has no counter for it). Only `js_error`, `bot_stop` and `warn` are accepted from the page;
5. for a batch, sets `context.window` to the window's ordinal and records each event through `DiagnosticsHub.Record`, which runs the Manager's own scrubber with its private terms (account names, login IDs, servers, characters, the character name the page reported, the machine terms) and its limiter. A template that holds a term becomes `<x>`; a module, town phase or trail code that holds one is dropped; a type that holds one drops the event;
6. for a perf answer, takes it only when the rotation asked this window and it has not answered yet (`OsbPerfRotation.Accept`; otherwise `PerfNotAsked`, counted in `dropped.rate_limited`), checks the OSB version the window reported (version pattern, no private term) and keeps the entry as the hub's one pending OSB perf entry (a newer one replaces it).

The counters are in `OsbPageBatchReceiver.Counts`: accepted, invalid, oversize, too frequent, after off, perf accepted, perf not asked.

**OSB perf, one window per span.** `TelemetryService.TickOsbPerf` runs in the one-second UI timer. While recording, the config has `diagnostics.enabled` and `perf`, and the run is sampled in, `OsbPerfRotation` starts a span every `perf_interval_s` and asks one window, in ordinal order after the last one asked, among the windows that reported an OSB version in the last 15 s. Every other window is told `perf: false` and records no perf. A window that does not answer is not asked again in the next span (the turn moves on); its late answer is still taken for 5 minutes into the next span (OSB closes its span at its next 60 s sample), then it is told `perf: false`. When one window is the only candidate and answers late, the rotation gives its current ask a new id, so the window is told `perf: true` again and starts a new span. The kept entry rides in the next batch as `osb_perf: [ { "app_version": "<OSB version>", …OSB perf entry } ]` (DIAGNOSTICS.md 9.2 at osb-platform `3063f98`), at most one, only while the config perf flag is on, and goes back to the hub when the send fails. OSB records its span with its default `perf_interval_s` of 1800 s.

**The GPU vendor.** `gpu.js` reads `GPUAdapterInfo.vendor` once, from the adapter the game uses, the first time the game asks it for a device (`installDeviceRetry`), and maps it with `gpuVendor` to `nvidia`, `amd`, `intel`, `apple`, `qualcomm`, `other` or `unknown` (also the PCI vendor IDs `0x10de`, `0x1002`, `0x1022`, `0x8086`, `0x106b`, `0x5143`). Only the enum is kept; the device name, the description, the driver and any ID are never read into the report. `bridge.js` adds it to the existing `gpu` object of the status message as `vendor`. `BotStatus` accepts it only when it is one of the seven values, `GameWindow` hands it to `DiagnosticsHub.GpuVendor` while recording, and `DiagnosticsUploader` writes it as `env.gpu_vendor`. Switching the consent off forgets it.

**OSB side** (the `osb` repository): `Diag.hostMessage` takes `osb-diagnostics` only from `window.chrome.webview` inside the Manager and only with a boolean `on` (and a boolean `perf`, when present). With `on: true` OSB records as in 3.4 through `Diag.sync()`; with `on: false` or no message it records nothing and wipes its buffers. Its idle-time job posts at most one batch per 60 s, cut to 10 events and 12 KB (counting each `<`, `>`, `&` and `'` as 6 bytes, in case the host escapes them): trails go first, newest events first, then whole events, oldest first. `Perf.sync` runs only when the Manager asked this window for perf; at the end of that span `Perf.close` posts the answer through `Diag.hostPerfDone` and switches perf off again.

**macOS.** The macOS Manager (`macos/`, not changed) never sends `osb-diagnostics`, so OSB there records nothing. Its `PageMessageInbox.accept` returns nil for the two new page types and counts them in `rejectedMessages`; its `BotStatus` parser ignores the new `gpu.vendor` field.
