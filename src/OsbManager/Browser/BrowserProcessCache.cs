using Microsoft.Web.WebView2.Core;
using OsbManager.Core.Telemetry.Diagnostics;

namespace OsbManager.Browser;

internal sealed record CachedProcess(int ProcessId, ProcessRole Role);

internal sealed class BrowserProcessCache
{
    private volatile CachedProcess[] processes = [];
    private CoreWebView2Environment? environment;

    public Func<bool> Recording { get; set; } = () => false;

    public IReadOnlyList<CachedProcess> Processes => processes;

    public void Attach(CoreWebView2Environment started)
    {
        environment = started;
        started.ProcessInfosChanged += (_, _) => Refresh();
        Refresh();
    }

    public void Refresh()
    {
        if (environment is not { } started || !Recording())
        {
            return;
        }
        try
        {
            processes = started.GetProcessInfos().Select(info => new CachedProcess(info.ProcessId, RoleOf(info.Kind))).ToArray();
        }
        catch (Exception e) when (e is InvalidOperationException or System.Runtime.InteropServices.COMException or ObjectDisposedException)
        {
            processes = [];
        }
    }

    public void Forget()
    {
        environment = null;
        processes = [];
    }

    private static ProcessRole RoleOf(CoreWebView2ProcessKind kind) => kind switch
    {
        CoreWebView2ProcessKind.Browser => ProcessRole.Browser,
        CoreWebView2ProcessKind.Gpu => ProcessRole.Gpu,
        CoreWebView2ProcessKind.Renderer => ProcessRole.Renderer,
        CoreWebView2ProcessKind.Utility => ProcessRole.Utility,
        _ => ProcessRole.Other,
    };
}
