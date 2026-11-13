# OSB Manager for macOS: usage statistics and reports

This page describes what OSB Manager for macOS sends to `api.osb.lol`, when, and how the code keeps it from getting in the way of the game. The protocol is `PLATFORM.md` of the osb-platform repository, sections 6.3, 7 and 10 and appendices A and C; the consent wording is `docs/legal/CONSENT.md` there, version `2026-11-12.1` (consent version 2), which replaces the texts of Appendix A. Error reports and performance data follow `docs/design/DIAGNOSTICS.md` there, section 3.8 for this app. The behaviour matches the Windows app ([docs/telemetry.md](../telemetry.md)). The code is in `macos/OsbManager/Sources/OsbManagerCore/Telemetry/` (logic, no UI) and `macos/OsbManager/Sources/OsbManagerApp/` (windows).

## The rule

**Nothing is sent without the user's consent.** The default is off. Without a recorded, current consent the app makes no request to `api.osb.lol` or anywhere else for this feature: no registration, no config read, no ping, no statistics. The one exception is an explicit user action: pressing **Send** in the report window, after the window has shown exactly what will be sent. The app never calls the statistics "anonymous": an install ID is pseudonymous. Only a report sent without usage statistics is called anonymous.

## Consent states and what the network sees

| State | How it comes about | Network behaviour |
| --- | --- | --- |
| Undecided | A fresh install; a missing, empty or corrupt `privacy.json`; a file that claims consent but whose install key is not in the Keychain. The first-run prompt is shown in the main window. | None. The scheduler holds no timer and waits for a consent change. |
| Outdated | `privacy.json` holds consent version 1 (text `2026-11-04.1`, every Share given in Manager 1.1.0 and earlier), or another text version than the app's. The prompt is shown once more with the lead line "What OSB Manager shares has changed: it now includes error reports and performance data." (`PrivacyState.sharedBefore`). | None. **No thanks** or the close button withdraws: the old ID and key are deleted and one best-effort `DELETE /v1/installs/me` is sent for a registered install (the outbox stays). **Share** keeps the ID and key and registers again with `usage_version: 2`. |
| Declined | **No thanks**, or the close button, of the first-run prompt. | None. The prompt is not shown again. |
| Granted | **Share** in the prompt, or **Share usage statistics, error reports and performance data** in the Privacy window. The consent version (`2`), the text version (`2026-11-12.1`) and the time are written to `privacy.json`. A fresh grant starts the diagnostics buffers empty. | After a random 60 to 180 s: `GET /v1/config`, then (only when there is something to send) one `POST /v1/installs`, then one `POST /v1/telemetry` per interval. One request at a time. |
| Granted with characters | The second switch, **Show my characters in the OSB dashboard**. | As Granted, plus `character` in the payload; one `PUT /v1/installs/me/consent` when the switch changes. |
| Withdrawn | The first switch off, or **Delete my data**. | At once: the local ID and key (also in the Keychain), the consent, the queued reports and the diagnostics state (buffers, trail, pending files, the `diagnostics/` folder) are deleted, the diagnostics session number moves on, the scheduler is interrupted and any request in flight is aborted. One best-effort `DELETE /v1/installs/me` is sent with the old key, only when the install had been registered. Then nothing. |

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

Registration (`POST /v1/installs`): a random install ID (UUIDv4), a random 256-bit install key, `app` = `manager-mac`, the app version, `os` = `macos`, the UI language, and the consent version (`usage_version: 2`) and the characters flag. `PUT /v1/installs/me/consent` also sends `usage_version: 2`.

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
| `privacy.json` | The consent record (version `2`, text version, time, characters flag), the install ID, the "registered" flag, the cached config and the last send. **Not** the install key. A corrupt file means consent off. |
| `outbox/` | At most 5 reports waiting to be sent: `<id>.json` and an optional `<id>.png`, written atomically. |
| `outbox/failed/` | Reports that could not be sent in 72 hours. |
| `diagnostics/` | Pending error reports, `run.json` and `run.signal` (see below). Created only while recording. |

The install key is a generic password in the login Keychain: service `com.corevider.osb-manager.install-key`, account `install-key`, `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`. It is created when consent is given and deleted when it is withdrawn.

## Windows and menus

- **Privacy…** (app menu): both switches, the policy links (the privacy policy, **KVKK notice (Turkish)** and **KVKK explicit consent (Turkish)**), the server message, the install ID with **Copy**, "Last sent", **Show what is sent** (the exact next payload, pretty-printed), **Delete my data…** and **Download my data…**.
- **Report a problem…** (app menu): kind, description, the optional screenshot, the exact JSON, the confirmation text, **Send** and **Cancel**, and the report code after sending.
- **First-run prompt**: a panel at the top of the main window, never in a game window and without blocking anything. **Share** and **No thanks** have the same size and neither is the default button; the close button counts as **No thanks**.
- **English only** (DIAGNOSTICS.md D4), whatever the system language: the Privacy window, the first-run prompt, the report window, the unsent reports and every confirmation and message. The texts are in `ConsentTexts.swift`; the consent texts are those of `CONSENT.md` `2026-11-12.1` word for word, and `ConsentTextsTests` compares them with the Windows `PrivacyTexts.English`. The help text still names "the Windows and WebView2 versions", as `CONSENT.md` does; a Mac wording needs a new text version.
- The `locale` of the registration and the language of a report are data, not UI: the first preferred language as a two- or three-letter code (`InterfaceLocale.code`), `en` when it cannot be read.

## Error reports and performance data: the diagnostics core

The Mac app follows `DIAGNOSTICS.md` section 3.8. T086 built the core in `Sources/OsbManagerCore/Telemetry/Diagnostics/`; T096 added the capture, the run marker and fatal-signal file, the perf sampler and the batch job, and the server accepts the real Mac type names and `run_end.signal` (S1 to S3 of 3.8.9).

**Recording.** Everything below records only while `hub.recording` is true: consent version 2 is granted, a `GET /v1/config` of this run returned a `diagnostics` block with `enabled: true`, the run's `sample_pct` draw admits it, and fewer than 3 faults were reported. Before the first config read of a run nothing is recorded, written or timed; files left by the previous run stay on disk unread until that read. A config read with the flag off (or a missing or malformed block, or `client_ok: false`, or a cached config older than 24 hours) wipes the buffers, the run marker and the pending files. Switching consent off wipes them too and forgets the flag, so switching it on again waits for a new config read.

| Type | Role |
| --- | --- |
| `DiagnosticsHub` | One per app (`TelemetryService.diagnostics`). `recording` is true only while consent version 2 is granted, `applyServer(_:)` saw an enabled and sampled-in config, and fewer than 3 faults were reported. Owns `terms`, `run`, `trail`, `limiter` and `pending`. `consentChanged()` is called by the privacy observer: switching on clears the buffers and calls `onBegin` observers; switching off calls `wipe()`, which clears the buffers, deletes the `diagnostics/` folder, moves `session` on and calls `onWipe` observers. A sender keeps the `session` it started with and drops its work when `isCurrent(session:)` is false. |
| `record(_:)` | Scrubs an event and passes it to the limiter. Returns `nil` while not recording. |
| `writePending(_:)` | Scrubs and writes one event as a pending file, synchronously (for the uncaught-exception handler). |
| `pendingEvents()` | Reads the pending files back (each with its id for `pending.delete(id:)` after a 202). |
| `DiagnosticEvent.make(_:at:count:context:trail:)` | Builds an event and its fingerprint from a detail: `.process(RendererTermination.detail(status:errorCode:))`, `.hang(HangDetail)`, `.gpu(GpuDetail(code: DiagnosticScrubber.gpuFailure(text) ...))`, `.error(ErrorDetail)`, `.warn`, `.runEnd`. |
| `FrameReducer.reduce(_:)` | `[NativeFrame(ownImage:symbol:)]` (symbol already demangled) to frames: own modules only, `Module.Type.method`, closures as `.<closure>`, Objective-C and C++ of `CefBridge`, at most 16, foreign runs as one `ext`. |
| `ErrorTypeNames` | `exception(named:)`, `swiftError(_:)` keep the real type names; `wire(_:)` sends anything outside `System.`, `Microsoft.`, `OsbManager.`, `Windows.`, `Foundation.`, `OsbManagerCore.`, `OsbManagerApp.` and `OsbManagerCef.` as `Exception`. `serverAcceptsMacNamespaces` is true since T096 (S1). |
| `PrivateTerms` | `forThisMac(dataFolder:)` pins the user name, full name, host and computer names and the home and data folders; `add(accounts:)` adds account names, login IDs, servers and characters; `add(_:)` adds a character name a page reports. |
| `DiagnosticTrail` | 50 codes (`TrailCodes`), repeats counted, nothing kept while not recording. |
| `DiagnosticLimiter` | 30 distinct events an hour, 200 a day, one pending event per fingerprint, the same fingerprint at most once an hour on the wire, the trail only on the first occurrence, sampling by `sampleDraw` and `samplePercent`; `take()`, `peek()`, `giveBack(_:dropped:)`. The rules are pure functions in `DiagnosticRules`. |
| `DiagnosticJson.batch(_:terms:now:)` | Scrubs every event again and writes the 3.3 body with `app: manager-mac`: at most 50 events of 4 KB, 2 perf entries of 8 KB, whole minutes, cut to 60 KB (trails first, then the oldest events, then perf). |
| `DiagnosticFormats` | Patterns and limits of 3.3, `minuteText`, `exitCode`, `osBuild`, `chromiumVersion` (for `env.webview2`), `ramBucket`, `coreBucket`, `gpuVendor(deviceName:)`, `newRunKey`. |

Files: `<data folder>/diagnostics/pending-<seconds>-<random>.json`, at most 10 of at most 16 KB, written atomically and only while recording, deleted after sending, after 7 days and at once on switch-off. A leftover folder is deleted at start when consent is off.

### Capture points (T096)

`DiagnosticsCapture` (`TelemetryService.capture`, also `AppServices.diagnostics`) is the only way in. Every call returns at once while not recording. Events are built and recorded on one serial utility queue (`osb.diagnostics.capture`); the main thread only reads values it already has (the status, the window flags) and posts. Frames are resolved during the call that captures them, so return addresses never outlive it.

| Mac source | Call | Event | Windows counterpart |
| --- | --- | --- | --- |
| `CefRequestHandler::OnRenderProcessTerminated`: the bridge passes `status` and `error_code` as integers (`rendererDidTerminateWithStatus:errorCode:`); `error_string` is never read or passed | `processFailed(status:errorCode:context:)` with `RendererTermination.detail` | `process_failed`, `render_process_exited`, the mapped reason, `exit_code` in hex | `GameWindow.OnProcessFailed` |
| `OnRenderProcessUnresponsive` / `OnRenderProcessResponsive` (CEF hang monitor, default handling kept) into `PageHealth.markUnresponsive()` / `markResponsive()`; a status report after a hang; the `PageHealth` ladder (`watchPage`) | `unresponsive(outcome:waitedSeconds:context:)` | `unresponsive`: `responded` with the seconds since the hang began, or `reloaded`, `restarted`, `gave_up` with the seconds without a sign of life when the silence rule acted | `RenderProcessUnresponsive`, `NoteHang` |
| `BotStatus.gpuFailed` appears (from `gpu.js`) | `gpuFailed(_:retries:context:)` with `DiagnosticScrubber.gpuFailure` | `gpu_failed`, code and `gpuRetries` | `LogRenderer` |
| `NSSetUncaughtExceptionHandler` (`CrashHandlers.install`, chained to the handler that was set before) | `crash(exceptionName:returnAddresses:)`: synchronous `hub.writePending`, then `crashed` in `run.json` | `dotnet_exception`, origin `appdomain`, `handled` false, type `Foundation.<name>` from the allowlist or `Foundation.NSException`, frames from `callStackReturnAddresses`. Never the reason or `userInfo`. | `CrashHooks` and `Capture.Crash` |
| `AppLog.error(_:_:)` with an error (the app's failure paths, such as `GameWindowController.fail`) through `AppLog.onError` | `caught(_:context:)` | `dotnet_exception`, origin `caught`, `handled` true, the type from `ErrorTypeNames.swiftError`, frames from `Thread.callStackReturnAddresses` without the logging and capture frames. Never the description. | `Log.ExceptionLogged` |
| Fatal signals `SIGABRT`, `SIGSEGV`, `SIGBUS`, `SIGILL`, `SIGTRAP`, `SIGFPE` | the C target `CrashSignals` | no event; the next start sends `run_end` `crash` with `signal` | none (Windows has no signals) |
| The previous run (`run.json`, `run.signal`) at the first recording start | `beginRun` | `run_end` `clean`, `unclean` or `crash`, `uptime_s`, `previous_version`, `signal`, written as a pending file | `RunMarker.ReadPrevious` |

Trail codes go with the existing log lines of `GameWindowController` (`window.start`, `window.closed`, `window.renderer-exited`, `window.unresponsive`, `window.responding`, `window.reload`, `window.restart`, `window.gave-up`, `login.failed:<stage>`, `login.reload`, `gpu.retry`, `gpu.failed:<code>`, `settings.light-on`), with the window ordinal (`WindowOrdinals`), and with those of `MainWindowController`, `OsbController` and `UpdateController` (`settings.fps-limit`, `script.install-failed`, `script.update-failed`, `update.download`, `update.failed`), as Windows' `MainForm` does. The log text never goes into the trail.

Private terms: all accounts (names, login IDs, servers, characters) when the hub is made, each account again when its window starts, and every character name a page reports. No Keychain item is read for this.

**Frames.** `NativeStack` resolves each return address with `dladdr`, keeps it only when `dli_fbase` is the image that holds `OsbManagerCore` (`#dsohandle`; the app's main executable in the app, the test bundle in tests), demangles the symbol with `swift_demangle` or `__cxa_demangle` (both looked up with `dlsym`) and passes it to `FrameReducer`. The address, offset, image path and the mangled and demangled text stay inside the call.

### Run marker and fatal signals

- `RunMarker` writes `<data>/diagnostics/run.json` (`version`, `started`, `alive`, `crashed`, `clean`, whole minutes, atomic) when recording begins, moves `alive` with each 60 s sample, sets `crashed` from the exception handler and `clean` on a normal quit (`AppDelegate` calls `TelemetryController.finishRun()` before the message loop ends).
- When it begins it also opens `run.signal` (`O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC`, `0600`) and hands the descriptor to `crash_signals_set_descriptor`; `crash_signals_install` installs the six handlers once. A handler writes one byte, the signal number, with `write`, restores the previous handler with `sigaction` and calls `raise`; it calls nothing else. A clean quit closes and deletes `run.signal`; a wipe closes it and the folder goes.
- At the next start, once recording begins, a marker younger than 7 days gives one `run_end`: `crash` when `crashed` is set or `run.signal` has a byte (`signal` is the name of that byte when it is one of the six numbers), `clean` when `clean` is set, else `unclean`. It is written as a pending file and goes out with the next batch.
- Measured on macOS 26.5 with CEF 156 (T096): after the uncaught-exception handler has run, the process ends with `SIGTRAP` (exit status 133), not `SIGABRT`, so that `run_end` carries `signal: sigtrap`.

### Performance entry

`DiagnosticsCapture` runs one `DispatchSourceTimer` on its queue every 60 s. Each tick moves `alive` in `run.json`; while `perf` is on and the run is sampled in, it reads one `PerfSample` with `ProcessSampler` and adds it to `PerfCollector`; one entry is complete per `perf_interval_s` (default 1800 s) and at most 2 wait.

| Field | Source |
| --- | --- |
| `mem_mb.app`, `cpu_pct.app` | `task_info(TASK_VM_INFO)` `phys_footprint` (fallback `MACH_TASK_BASIC_INFO` `resident_size`); CPU from `MACH_TASK_BASIC_INFO` plus `TASK_THREAD_TIMES_INFO` |
| `mem_mb.renderer`, `cpu_pct.renderer_each` | the renderer PIDs the windows report (`rendererProcessId`), `proc_pid_rusage(RUSAGE_INFO_V4)` `ri_phys_footprint` and `ri_user_time + ri_system_time` (Mach time, converted with `mach_timebase_info`) |
| `mem_mb.gpu`, `mem_mb.utility`, `cpu_pct.gpu` | the app's children (`proc_listchildpids`) by `proc_name` suffix: `(GPU)`, `(Renderer)` (one that is no window's renderer counts only in the total), anything else utility. The names are never sent. |
| `mem_mb.browser_total`, `cpu_pct.browser_total` | the app plus all its helpers |
| `js_heap_mb` | `Runtime.getHeapUsage` through `CefBrowserHost::ExecuteDevToolsMethod` (`readHeapUsage:` in the bridge), started on the main thread once per span about 2 minutes before it ends, per window, skipped for a window that does not answer within 10 s |
| `windows` | `open`, `light`, `hidden` (hidden, minimised or not visible by `occlusionState`), `in_world`, from a cache that `GameManager.watchPages` refreshes each second while recording |

`task_for_pid` is never used. No PID, process name, path or title leaves the sampler. `wasm_mb` is absent.

### The batch job

The diagnostics job is a second job of `TelemetryScheduler`. In one wake-up the usage cycle runs first, then the diagnostics cycle when it is due, so the shared `TelemetryClient` never has two requests in flight. It has its own failure counter, pause and `disabled` state (`JobState`); the usage schedule does not move when diagnostics fail.

1. Read the effective config (`TelemetryConfig.diagnosticsSettings`, clamped as 3.1: `interval_s` 600 to 86400, `perf_interval_s` 1800 to 86400, `sample_pct` 0 to 100) and pass it to `hub.applyServer`. Off: wait for the next config read.
2. Nothing to send (no pending file, no event ready, no perf entry while `perf` is on): wait one interval.
3. Register first when the install is not registered yet (the shared registration).
4. `DiagnosticsUploader.prepare` takes the events from the limiter and the perf entries, adds the pending files, and builds the body with `DiagnosticJson.batch`. `hub.isCurrent(session:)` is checked before the request and after it; a switch-off in between cancels the request (the privacy observer cancels the scheduler step) and the result is dropped.
5. 202: delete the sent pending files; next run after `max(interval_s, next_after_s)` with jitter. 400, 404, 413, 415: drop the batch. 401: register again; a second stops the job until restart. 403 `consent_required`: one `PUT /v1/installs/me/consent`, then try again after an interval; a second 403 stops the job until restart. Anything else: give the events and perf entries back (`limiter.giveBack`) and back off as usage does (429 and 503 `Retry-After`, 503 `disabled` until the next config read).
6. An unexpected error in the job counts as a hub fault; the third switches diagnostics off until restart and logs it once. Nothing is recorded about it.

**Show what is sent.** The Privacy window's preview shows "Usage statistics, next batch" and "Error reports and performance data, next batch" (the same section titles as Windows). The diagnostics part is `TelemetryService.previewNextDiagnostics()`: the exact body that `prepare` would send, pretty-printed, built without taking anything; nothing is sent.

### OSB inside the Mac Manager (T097)

OSB in a game page records errors only after the Manager tells it to, and sends them through the Manager, never to `api.osb.lol` itself (`DIAGNOSTICS.md` 3.6 and 3.8.8). The Windows counterparts are `OsbPageBatch.cs`, `OsbPageBatchReceiver.cs`, `OsbVocabulary.cs` and `OsbPerfRotation.cs`.

- **Bridge.** `cef-shim.js` gives the page `window.chrome.webview`, so OSB's `hosted()` is true. `postMessage(object)` reaches the app as JSON text; a message from the app arrives at `addEventListener('message', …)` as `event.data`, an object.
- **Switch.** `GameWindowController.syncPageDiagnostics` runs after each page load, after OSB first reports its version after a load and every second from `GameManager.watchPages`. While `hub.recording` is true and the vocabulary loaded it posts `{"type":"osb-diagnostics","on":true,"perf":false}`; when recording stops it posts `{"type":"osb-diagnostics","on":false}`. It posts only when the state changes, and forgets the state on a reload or a renderer end, so a new page always gets it again.
- **Perf rotation.** `DiagnosticsCapture.tickOsbPerf` (every second) drives `OsbPerfRotation` while recording, the server's `perf` flag and the sample draw allow it: once per `perf_interval_s` it asks one window, the next ordinal after the last one asked among the windows whose OSB reported in the last 15 s. That window gets `perf: true`, every other one `perf: false`. One answer per ask is accepted, within the span plus 5 minutes; an unasked or second answer is dropped and counted.
- **Receive path.** `PageMessageInbox` recognises `osb-diagnostics-batch` and `osb-diagnostics-perf` by the type at the start or the end of the text and hands the text on unparsed. On the main thread `OsbPageBatchReceiver.offer` and `offerPerf` only check recording and the size (12 KB, 2 KB) and queue the text, at most 4 waiting. On the capture queue: the session check, one good batch per window per 55 s (a bad one does not count), the strict parse of `OsbPageBatch` (`PageJson` refuses duplicate keys and nesting deeper than 8, and tells whole numbers from decimals and the raw size of each event), `OsbVocabulary.map`, with `context.window` set to the window's ordinal, then `hub.record`, which scrubs with the private terms (account names, login IDs, servers, the character name the page reported, the Mac's names and folders). A perf answer becomes an `OsbPerfEntry` with the OSB version from the page's status; the hub keeps one, and `DiagnosticsUploader.prepare` sends it as `osb_perf` only while `perf` is on.
- **Counts.** `OsbPageBatchReceiver.counts`: `accepted`, `invalid`, `oversize`, `tooFrequent`, `afterOff`, `perfAccepted`, `perfNotAsked`, `mapped`. Too frequent batches, a full queue and unasked answers add to `dropped.rate_limited`; oversize ones to `dropped.oversize`.
- **Vocabulary.** `Resources/diagnostics-vocabulary.json` is a byte copy of the Windows `src/OsbManager.Core/Telemetry/Diagnostics/diagnostics-vocabulary.json` (`OsbVocabularyCopyTests` fails when they differ). `build-app.sh` copies it into the app's `Resources`. When it cannot be read, the app logs one warning and takes no message from a page.
- **Script source names.** `ScriptInjection.build` starts every userscript with `//# sourceURL=osb-manager-script/<name>.user.js`, the `@name` reduced to `[A-Za-z0-9._-]` and 64 characters, so OSB's frames carry `osb-manager-script/OSB.user.js` and errors of other scripts are not counted as OSB's. The app's own page scripts have no such line.

### Release symbols

`dladdr` reads the local symbol table of the executable. A stripped release (`strip -x`) would name every own frame after the nearest exported symbol. `macos/scripts/check-frame-symbols.sh <executable>` runs in `build-app.sh` right after `swift build`, before anything is assembled or signed, for every built product. It fails when `nm` shows fewer than 100 local (`t`) `OsbManagerCore` Swift functions, or when `<executable> --check-frames` does not resolve its own frames to `OsbManagerCore.NativeStack.selfCheck` and `OsbManagerApp.FrameCheck.run`. `--check-frames` is the only argument it accepts that way; it prints the own frames and exits before CEF loads. It changes nothing in signing or notarization.

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
| `--dialog-shots <folder>` | Saves screenshots of the main window at start, the first-run prompt with and without the lead line, the Privacy window off and on and the Report window, and quits. English only. |
| `--language <code>` | Overrides the language sent as `locale` (data only; every text stays English). |
| `--test-install-key-file <file>` | Reads a made-up install key from this file into the in-memory key store, so a test `privacy.json` with consent version 1 loads as Outdated. Never a real key. |
| `--test-uncaught-exception` | Once diagnostics record and the run marker is written, raises an uncaught `NSInvalidArgumentException` on a new thread, with a canary reason and `userInfo`. The app aborts; the next start sends the pending event and a `run_end` crash. |
| `--in-memory-credentials` | Keeps game logins in memory instead of the Keychain (no Keychain item is read or written). |
| `--test-stop-sharing <seconds>` | After this many seconds, switches sharing off as the Privacy switch does (withdrawal, wipe, `DELETE /v1/installs/me`). |

`macos/scripts/fake-api.py` is the local server of the measurement (`hang` never answers anything; `telemetry-hang` answers the config and the registration and never answers telemetry; `diagnostics` answers the config with diagnostics, perf and `sample_pct` 100 on, answers telemetry and `POST /v1/diagnostics` with 202 and logs each diagnostics body), `macos/scripts/measure-telemetry.sh` runs the phases and `macos/scripts/latency-summary.py` computes p50, p99 and max.

The diagnostics tests are `DiagnosticsCaptureTests` (the capture paths, the run marker and signal byte, the end-to-end golden batch, the canaries on the captured paths, perf), `OsbPageDiagnosticsTests.swift` (the page messages, the strict parser, the vocabulary copy, the receiver limits, the canaries a page let through, the hostile page, the perf rotation, consent and the server flag) and `DiagnosticsSchedulerTests` (the job: order, one request at a time, backoff, the flag, `sample_pct`, perf, 403, 503 `disabled`, switch-off during a request, faults, the preview). The golden batch `Fixtures/manager-mac-batch.json` is built from captured events through `DiagnosticsUploader.prepare`, with one OSB `js_error` received through the page path and one `osb_perf` entry; `OSB_WRITE_GOLDEN=<file>` writes it, and osb-platform keeps a byte-identical copy.
