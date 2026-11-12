# OSB Manager for Windows: the Memory tab and the memory settings

This page describes how OSB Manager measures what its game windows use, which settings can lower it, and how to measure it yourself.

## The Memory tab

The **Memory** tab is the last tab on the right. It refreshes every 4 seconds, only while the tab is selected and the window is not minimised. The timer is stopped otherwise, so nothing runs when the tab is closed.

| Column | Where it comes from |
| --- | --- |
| Account, State | The account name. State is `normal`, `light`, `hidden` (the window is minimised) or `light, hidden`. |
| Renderer private, Renderer working set | The account's renderer process. The process is found through WebView2 itself: `CoreWebView2Environment.GetProcessExtendedInfosAsync` lists the processes of the app's own environment together with the frames each renderer shows, and the window's `CoreWebView2.FrameId` picks its renderer. No process is found by order or by name. |
| JS heap used, JS heap total | `Runtime.getHeapUsage`, called through `CoreWebView2.CallDevToolsProtocolMethodAsync`. No debug port is needed. It covers the page's main thread; the game's workers have their own heaps. |
| WebAssembly | The size of the `WebAssembly.Memory` objects the page created, or `none`. A small script (`memory.js`, only in the Windows app) wraps `WebAssembly.Memory`, `Instance`, `instantiate` and `instantiateStreaming` at document start and remembers the memories. The tab reads it with `Runtime.evaluate`. It sees the page, not the game's workers. |

Below the table: the game renderers together, the GPU process, all browser processes of the app (the GPU process, the browser process, the renderers and the network, storage and audio utilities; the crashpad process is not in WebView2's list) and the app itself.

**Copy memory report** copies the same numbers as a plain text table, so that they can be pasted into a message.

An empty cell (`—`) means the value could not be read at that moment. It is never shown as 0.

## Settings

It is under **View**, off by default, and saved in `settings.json`.

| Setting | Key | What it does |
| --- | --- | --- |
| Low memory when a window is minimised | `lowMemoryWhenHidden` | Gives a minimised window the same low WebView2 memory target that light mode uses. |

## Measuring from outside

`scripts/measure-memory.ps1 -DataFolder <folder>` is read-only. It lists the `msedgewebview2.exe` processes whose command line holds `<folder>\WebView2`, grouped by role (`browser`, `gpu`, `renderer`, `utility:...`, `crashpad`), with private bytes, working set and CPU seconds. It never reads another process, and it refuses the data folders of an installed OSB Manager. Add `-Json` for machine output.

## Memory and CPU in the performance data

When the user shares usage statistics, error reports and performance data, the app also samples what it uses itself, for development. This is the performance entry of `docs/telemetry.md` ("Capture, run marker and performance sampling").

- **How often:** one local sample every 60 seconds, one entry per 30 minutes. Nothing is sampled while the switch is off.
- **Where the numbers come from:** the same process list as the Memory tab (`CoreWebView2Environment.GetProcessInfos`), cached by `BrowserProcessCache` and refreshed on `ProcessInfosChanged` and once per sample. The sampler reads each process's private bytes and `TotalProcessorTime` on a thread-pool thread. It does not query WebView2 per window and does not touch the UI thread except to copy the process list.
- **What is sent:** memory per role (renderers one value per window, sorted and never tied to an account, GPU, utility, browser total, the app) with median and maximum over the span, and CPU as percent of one core per role. The JS heap and the WebAssembly size per window are read once per entry through the same `ReadPageMemoryAsync` as the Memory tab, when the UI is idle, with a 10 second limit.
- **What is not sent:** account names, the order of the windows, process IDs and the command lines of the processes.
