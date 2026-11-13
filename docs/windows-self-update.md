# Windows self-update

How **Install and restart** replaces the running OSB Manager on Windows, why it loads assemblies before it replaces the exe, and how to check the whole flow before a release.

## The flow

`MainForm.InstallUpdate` runs these steps. The step names are the ones the failure text uses.

1. **Download** (`UpdateChecker.DownloadAsync`): fetch the zip and check it against the signed manifest.
2. **Stage** (`ExeSwap.Stage`): extract `OsbManager.exe` from the zip to `OsbManager.new.exe` next to the running exe.
3. **Close windows**: close every game window and wait up to 20 seconds.
4. **Prepare** (`AssemblyPreload.LoadReferenceClosure`): load every assembly the app references, directly or through other assemblies.
5. **Swap** (`ExeSwap.Swap`): rename the running exe to `OsbManager.prev.exe` and `OsbManager.new.exe` to `OsbManager.exe`.
6. **Start** (`UpdateRelaunch.StartAsync`): start the new exe with the same arguments plus `--updated-from <pid>` and wait up to 30 seconds for its named event. The new process signals as soon as it starts, waits for the old one to exit, then takes the data folder lock and deletes `OsbManager.prev.exe`.

If the new exe does not signal, or any step after the swap fails, `ExeSwap.RollBack` puts the previous exe back. The notice is shown again, and the dialog offers the release page.

A failure names its step and never adds a file path, for example `The update to 1.2.0 failed while starting the new version: FileNotFoundException without a message`. When the exception has a message, the message replaces the type name. The log line carries the step and the exception type.

## Why the assemblies are loaded before the swap

The release exe is a self-contained single-file bundle (`PublishSingleFile`, `IncludeNativeLibrariesForSelfExtract`, `EnableCompressionInSingleFile`). The runtime reads the bundle's file list once at start, but it reads an assembly's bytes only when the assembly is first used. To do that, it opens the exe again **by its path**, at the offset that the file list gave at start.

The swap renames the running exe away and puts the new exe at that path. Assemblies already in memory keep working. An assembly first used after the swap is read from the new exe at the old exe's offsets. The bytes there belong to something else, and the load fails with a `FileNotFoundException` whose message is empty. The runtime then remembers the failure for that assembly for the rest of the process, so a second attempt fails too, even after the rollback.

OSB Manager 1.0.2 to 1.2.0 hit this: `UpdateRelaunch.StartAsync` was the first code in the session to use `System.Diagnostics.Process`, and it ran after the swap. Compression does not cause the problem. Without compression, a load after the swap still fails as soon as the new exe's layout differs from the old one's, and it fails whenever the path is empty.

The prepare step loads every assembly the app references, so nothing that runs after the swap needs the exe file again: the relaunch, the rollback, the log, the error dialog and the shutdown. It loads about 120 assemblies. In the end-to-end check, the stage, prepare and swap steps took about one second together. References that are not in the app (one in the current build) are counted and skipped.

Keep the prepare step directly before the swap. Do not add code after the swap that loads assemblies by name (`Assembly.Load`, `Type.GetType` with a string), because the closure only follows static references.

A fix can only help from the first fixed version on, because the running (old) version does the install. Installs older than the fix can update by hand, or by using **File > Open data folder** once before **Install and restart** (any `Process.Start` loads `System.Diagnostics.Process` while the old exe is still in place).

## The end-to-end check

`scripts/test-self-update.ps1` runs the real install between two real single-file exes on this PC, without the network:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\test-self-update.ps1 -Work <new folder outside the repository>
```

It takes 3 to 5 minutes and prints `Result : PASS` (exit code 0) or the failed checks (exit code 1). What it does:

1. Publishes an "old" exe (version 1.0.1) and a "new" exe (version 9.9.9) with the flags of `scripts/package-windows.ps1`, plus `-p:OsbUpdateE2E=true`.
2. Reads both bundles and stops if `System.Diagnostics.Process.dll` sits at the same offset in both. At the same offset, the run could not show a late load from the swapped exe.
3. Signs the new zip with a throw-away key made and deleted inside the run (`new-update-key.ps1`, `sign-update.ps1`). The key and the feed live under `-Work`.
4. Starts the old exe with its own `--data` folder and `--osb-url http://127.0.0.1:9/osb.user.js`, so the first-start OSB install fails locally. The test feed answers the update check after 3 seconds, and the app installs at once.
5. Passes when the old exe logs that the new version signalled and exits, the new exe runs with `--updated-from <old pid>` and removes the previous exe, `OsbManager.exe` is the new exe, and no `.prev.exe` or `.new.exe` is left.
6. Fails if an app process holds a TCP connection to an address other than this computer.
7. Publishes the Release exe without the switch and checks the `OsbManager.dll` inside its bundle: the test feed must be in the test exe and must not be in the Release exe. Pass `-ReleaseExe <zip or exe>` to check a package made by `package-windows.ps1` instead, or `-SkipReleaseCheck` to skip this step.

It stops every `OsbManager.exe` it started under `-Work`, and only those. `-Source <folder>` builds both exes from another source tree, for example to show that older code fails.

Run it before tagging a release that changes anything in the install path, the publish flags or the .NET version.

### The test switch

`OsbUpdateE2E=true` defines `UPDATE_E2E`. That symbol, like `DEBUG`, compiles in `UpdateTestFeed`, which answers the updater's GitHub requests from a local folder. The app reads these environment variables only in such a build:

| Variable | Meaning |
| --- | --- |
| `OSBMANAGER_TEST_UPDATE_FEED` | Folder with `latest.json`, the zip, the manifest and its signature |
| `OSBMANAGER_TEST_UPDATE_KEY` | Public key that verifies the test manifest |
| `OSBMANAGER_TEST_UPDATE_VERSION` | Version the app claims to be (optional) |
| `OSBMANAGER_TEST_UPDATE_DELAY_SECONDS` | Delay of the first update check |
| `OSBMANAGER_TEST_UPDATE_INSTALL` | `1` installs an offered update without a click |

`package-windows.ps1` and `release.yml` never set `OsbUpdateE2E`, so the Release exe has neither the feed nor the variables. Step 7 of the check proves this for the exe it checks.
