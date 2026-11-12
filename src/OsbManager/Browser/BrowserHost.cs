using Microsoft.Web.WebView2.Core;
using OsbManager.Core;

namespace OsbManager.Browser;

/// <summary>
/// One WebView2 environment for every account: each account is a separate profile (own cookies, storage
/// and cache) while the browser, GPU and network processes are shared.
/// </summary>
internal sealed class BrowserHost
{
    public const string GameUrl = "https://opensro.online/play";

    private const string Arguments =
        "--disable-background-timer-throttling --disable-renderer-backgrounding --disable-backgrounding-occluded-windows " +
        "--disable-features=CalculateNativeWinOcclusion,IntensiveWakeUpThrottling";

    private readonly AppPaths paths;
    private readonly int? debugPort;
    private Task<CoreWebView2Environment>? environment;

    public BrowserProcessCache ProcessCache { get; } = new();

    public BrowserHost(AppPaths paths, int? debugPort)
    {
        this.paths = paths;
        this.debugPort = debugPort;
    }

    public static string? RuntimeVersion()
    {
        try
        {
            return CoreWebView2Environment.GetAvailableBrowserVersionString();
        }
        catch (WebView2RuntimeNotFoundException)
        {
            return null;
        }
    }

    /// <summary>The environment if a window already started one; never starts a browser.</summary>
    public Task<CoreWebView2Environment>? StartedEnvironment => environment is { IsCompletedSuccessfully: true } ? environment : null;

    public Task<CoreWebView2Environment> EnvironmentAsync()
    {
        if (environment is { IsFaulted: true } or { IsCanceled: true })
        {
            environment = null;
        }
        return environment ??= Create();
    }

    /// <summary>Forgets the environment after its browser process exited, so the next window starts a new one.</summary>
    public void Reset()
    {
        environment = null;
        ProcessCache.Forget();
    }

    /// <summary>Marks a profile for deletion; WebView2 removes its folder once nothing uses it.</summary>
    public async Task DeleteProfileAsync(IntPtr parentWindow, string profileName)
    {
        var current = await EnvironmentAsync();
        var options = current.CreateCoreWebView2ControllerOptions();
        options.ProfileName = profileName;
        var controller = await current.CreateCoreWebView2ControllerAsync(parentWindow, options);
        controller.IsVisible = false;
        controller.CoreWebView2.Profile.Delete();
    }

    private async Task<CoreWebView2Environment> Create()
    {
        var arguments = debugPort is { } port ? $"{Arguments} --remote-debugging-port={port}" : Arguments;
        var options = new CoreWebView2EnvironmentOptions(arguments) { AreBrowserExtensionsEnabled = false };
        var created = await CoreWebView2Environment.CreateAsync(null, paths.WebViewData, options);
        ProcessCache.Attach(created);
        return created;
    }
}
