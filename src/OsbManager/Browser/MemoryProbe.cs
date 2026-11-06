using System.ComponentModel;
using System.Diagnostics;
using Microsoft.Web.WebView2.Core;
using OsbManager.Core.Status;

namespace OsbManager.Browser;

/// <summary>
/// Reads the memory of the browser processes that belong to this app's WebView2 environment. Processes
/// come from the WebView2 process list and each game window finds its renderer through its frame, so
/// nothing here looks at processes of other programs.
/// </summary>
internal static class MemoryProbe
{
    public static async Task<MemoryReport> CaptureAsync(BrowserHost host, IReadOnlyList<GameWindow> windows)
    {
        var infos = host.StartedEnvironment is { } started
            ? await (await started).GetProcessExtendedInfosAsync()
            : [];
        var pages = await Task.WhenAll(windows.Select(window => window.ReadPageMemoryAsync()));

        var accounts = new List<AccountMemory>();
        for (var i = 0; i < windows.Count; i++)
        {
            var window = windows[i];
            var renderer = infos.FirstOrDefault(info => info.ProcessInfo.Kind == CoreWebView2ProcessKind.Renderer
                && window.MainFrameId is { } frameId
                && info.AssociatedFrameInfos.Any(frame => frame.FrameId == frameId));
            accounts.Add(new AccountMemory(
                window.Account.Name,
                window.Light,
                window.Hidden,
                renderer is null ? null : Read(renderer.ProcessInfo.ProcessId),
                pages[i].JsHeapUsed,
                pages[i].JsHeapTotal,
                pages[i].WasmBytes,
                pages[i].WasmMemories));
        }

        var gpu = infos.Where(info => info.ProcessInfo.Kind == CoreWebView2ProcessKind.Gpu)
            .Select(info => Read(info.ProcessInfo.ProcessId)).OfType<ProcessMemory>().ToList();
        var browser = infos.Select(info => Read(info.ProcessInfo.ProcessId)).OfType<ProcessMemory>();
        using var self = Process.GetCurrentProcess();
        return new MemoryReport(
            DateTimeOffset.Now,
            accounts,
            gpu.Count == 0 ? null : ProcessMemory.Sum(gpu),
            ProcessMemory.Sum(browser),
            new ProcessMemory(self.PrivateMemorySize64, self.WorkingSet64));
    }

    private static ProcessMemory? Read(int processId)
    {
        try
        {
            using var process = Process.GetProcessById(processId);
            return new ProcessMemory(process.PrivateMemorySize64, process.WorkingSet64);
        }
        catch (Exception e) when (e is ArgumentException or InvalidOperationException or Win32Exception)
        {
            return null;
        }
    }
}
