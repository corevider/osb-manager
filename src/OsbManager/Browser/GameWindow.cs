using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text.Json;
using Microsoft.Web.WebView2.Core;
using Microsoft.Web.WebView2.WinForms;
using OsbManager.Core;
using OsbManager.Core.Accounts;
using OsbManager.Core.Rendering;
using OsbManager.Core.Status;
using OsbManager.Core.Telemetry;
using OsbManager.UI;

namespace OsbManager.Browser;

internal sealed record PageMemory(long? JsHeapUsed, long? JsHeapTotal, long? WasmBytes, int WasmMemories);

/// <summary>One account's game page in its own WebView2 profile.</summary>
internal sealed class GameWindow : Form
{
    private static readonly TimeSpan StatusTimeout = TimeSpan.FromSeconds(5);

    private readonly AppServices services;
    private readonly WebView2 view = new() { Dock = DockStyle.Fill, DefaultBackgroundColor = Color.Black };
    private readonly ToolStripMenuItem lightItem = new("Light mode");
    private readonly ToolStripMenuItem muteItem = new("Mute");
    private readonly List<string> scriptIds = [];
    private CoreWebView2? core;
    private BotStatus? status;
    private DateTime statusAt;
    private const string GameOrigin = "https://opensro.online/";

    private readonly CredentialGate credentialGate = new();
    private readonly RendererRecovery recovery;
    private string? failure;
    private bool skipClosePrompt;

    public GameWindow(AppServices services, Account account, bool light, RendererRecovery recovery)
    {
        this.services = services;
        this.recovery = recovery;
        Account = account;
        Light = light;
        Text = account.Name + " · " + AppIdentity.Name;
        Icon = AppIcon.Instance;
        ClientSize = new Size(1280, 800);
        RestorePlacement(account.Window);

        lightItem.Checked = light;
        lightItem.Click += (_, _) => SetLight(!Light);
        muteItem.Click += (_, _) => { muteItem.Checked = !muteItem.Checked; ApplyAudio(); };
        var menu = new MenuStrip { Dock = DockStyle.Top };
        menu.Items.Add(new ToolStripMenuItem("Reload", null, (_, _) => ReloadPage()));
        menu.Items.Add(lightItem);
        menu.Items.Add(muteItem);
        menu.Items.Add(new ToolStripMenuItem("Dev tools", null, (_, _) => core?.OpenDevToolsWindow()));
        Controls.Add(view);
        Controls.Add(menu);
        MainMenuStrip = menu;
    }

    public Account Account { get; }
    public bool Light { get; private set; }

    /// <summary>Raised when the renderer could not start after a reload and the window should be opened again.</summary>
    public event EventHandler? RestartRequested;

    /// <summary>The last report from the page, or null when it is older than a few seconds.</summary>
    public BotStatus? Status => status is not null && DateTime.UtcNow - statusAt < StatusTimeout ? status : null;

    public bool InGame => Status?.InWorld == true;

    public string StateText
    {
        get
        {
            if (failure is not null)
            {
                return failure;
            }
            var normal = NormalStateText();
            return recovery.StateText(Status, services.Renderers.IsWaiting(Account.Id), normal) ?? normal;
        }
    }

    private string NormalStateText()
    {
        if (Status is not { } current)
        {
            return core is null ? "Starting" : status is null ? "Loading" : "Not responding";
        }
        var light = current.Light ? " (light)" : current.LightWaiting ? " (light after loading)" : "";
        if (current.InWorld)
        {
            return (current.Dead ? "Dead" : "In game") + light;
        }
        var login = current.LoginStage switch
        {
            "title" or "server" or "credentials" or "connecting" or "retry" or "character" or "entering" => "Logging in",
            "choose" => "Choose a character",
            "failed" => "Auto login stopped",
            _ => null,
        };
        if (login is not null)
        {
            return login + light;
        }
        return (current.Phase switch
        {
            null => "Loading",
            "signed-out" => "Login",
            "character-select" => "Character select",
            "world" => "Entering world",
            _ => current.Phase,
        }) + light;
    }

    public void CloseWithoutPrompt()
    {
        skipClosePrompt = true;
        Close();
    }

    /// <summary>Sends the account's current login settings to the page; the password is sent only when the page asks.</summary>
    public void SendAutoLogin()
    {
        if (core is null || !IsGamePage(core.Source))
        {
            return;
        }
        core.PostWebMessageAsJson(JsonSerializer.Serialize(new
        {
            type = "auto-login",
            enabled = Account.AutoLogin && Account.HasCredentials,
            character = Account.Character,
            server = Account.Server,
        }));
    }

    public void SetLight(bool on)
    {
        Light = on;
        lightItem.Checked = on;
        ApplyLight();
    }

    public async void ReloadPage()
    {
        if (core is null)
        {
            return;
        }
        try
        {
            failure = null;
            await RegisterScriptsAsync();
            core.Reload();
        }
        catch (Exception e)
        {
            Fail("Reload failed", e);
        }
    }

    protected override async void OnLoad(EventArgs e)
    {
        base.OnLoad(e);
        try
        {
            await StartAsync();
        }
        catch (Exception exception)
        {
            Fail("Could not start the browser", exception);
        }
    }

    protected override void OnFormClosing(FormClosingEventArgs e)
    {
        if (!skipClosePrompt && e.CloseReason == CloseReason.UserClosing && InGame)
        {
            var answer = MessageBox.Show(this, $"Close {Account.Name}? The character leaves the game.", AppIdentity.Name, MessageBoxButtons.YesNo, MessageBoxIcon.Question);
            if (answer != DialogResult.Yes)
            {
                e.Cancel = true;
                return;
            }
        }
        SavePlacement();
        base.OnFormClosing(e);
    }

    protected override void OnFormClosed(FormClosedEventArgs e)
    {
        services.Renderers.Forget(Account.Id);
        services.Telemetry.Statuses.Remove(Account.Id);
        base.OnFormClosed(e);
    }

    public async Task<byte[]?> CaptureScreenshotAsync()
    {
        if (core is null)
        {
            return null;
        }
        using var stream = new MemoryStream();
        await core.CapturePreviewAsync(CoreWebView2CapturePreviewImageFormat.Png, stream);
        return ScreenshotEncoder.Fit(stream.ToArray());
    }

    public WindowDiagnostics Diagnostics() => WindowDiagnostics.From(Status, Light);

    private async Task StartAsync()
    {
        var environment = await services.Browser.EnvironmentAsync();
        var options = environment.CreateCoreWebView2ControllerOptions();
        options.ProfileName = Account.ProfileName;
        await view.EnsureCoreWebView2Async(environment, options);
        core = view.CoreWebView2;

        var settings = core.Settings;
        settings.AreBrowserAcceleratorKeysEnabled = false;
        settings.AreDefaultContextMenusEnabled = false;
        settings.IsZoomControlEnabled = false;
        settings.IsPinchZoomEnabled = false;
        settings.IsSwipeNavigationEnabled = false;
        settings.IsStatusBarEnabled = false;
        settings.IsPasswordAutosaveEnabled = false;
        settings.IsGeneralAutofillEnabled = false;

        new AssetInterceptor(environment, services.Cache, services.Log).Attach(core);
        core.WebMessageReceived += OnWebMessageReceived;
        core.NewWindowRequested += OnNewWindowRequested;
        core.NavigationStarting += (_, _) => services.Renderers.Forget(Account.Id);
        core.NavigationCompleted += (_, _) =>
        {
            ApplyLight();
            ApplyFrameLimit();
            SendAutoLogin();
        };
        core.ProcessFailed += OnProcessFailed;
        await RegisterScriptsAsync();
        ApplyAudio();
        core.Navigate(BrowserHost.GameUrl);
        services.Log.Info($"{Account.Name}: browser started (profile {Account.ProfileName}).");
    }

    private async Task RegisterScriptsAsync()
    {
        if (core is null)
        {
            return;
        }
        foreach (var id in scriptIds)
        {
            core.RemoveScriptToExecuteOnDocumentCreated(id);
        }
        scriptIds.Clear();
        scriptIds.Add(await core.AddScriptToExecuteOnDocumentCreatedAsync(Bridge.WasmProbe));
        scriptIds.Add(await core.AddScriptToExecuteOnDocumentCreatedAsync(Bridge.Build(services.Settings.FrameLimit)));
        foreach (var injection in services.Scripts.EnabledInjections)
        {
            scriptIds.Add(await core.AddScriptToExecuteOnDocumentCreatedAsync(injection));
        }
    }

    private void ApplyLight()
    {
        if (core is null)
        {
            return;
        }
        ApplyAudio();
        core.PostWebMessageAsJson(JsonSerializer.Serialize(new { type = "light", on = Light }));
    }

    /// <summary>Sends the app's frame rate limit to the page; new pages also start with it.</summary>
    public void ApplyFrameLimit()
    {
        if (core is not null && IsGamePage(core.Source))
        {
            core.PostWebMessageAsJson(JsonSerializer.Serialize(new { type = "frame-limit", fps = services.Settings.FrameLimit }));
        }
    }

    /// <summary>
    /// A minimised window hides its page, so the game switches to its hidden-tab path and stops drawing.
    /// Timers are not throttled (see BrowserHost), so the game and the bot keep running.
    /// </summary>
    protected override void OnResize(EventArgs e)
    {
        base.OnResize(e);
        var visible = WindowState != FormWindowState.Minimized;
        if (view.Visible != visible)
        {
            view.Visible = visible;
        }
        ApplyMemoryLevel();
    }

    public bool Hidden => WindowState == FormWindowState.Minimized;

    public uint? MainFrameId => core?.FrameId;

    public void ApplyMemoryLevel()
    {
        if (core is null)
        {
            return;
        }
        var low = status?.Light == true || services.Settings.LowMemoryWhenHidden && Hidden;
        var level = low ? CoreWebView2MemoryUsageTargetLevel.Low : CoreWebView2MemoryUsageTargetLevel.Normal;
        if (core.MemoryUsageTargetLevel != level)
        {
            core.MemoryUsageTargetLevel = level;
        }
    }

    /// <summary>The page's own memory numbers, read through the DevTools protocol. Fields stay null when the page does not answer.</summary>
    public async Task<PageMemory> ReadPageMemoryAsync()
    {
        if (core is null)
        {
            return new PageMemory(null, null, null, 0);
        }
        var heap = await CallAsync("Runtime.getHeapUsage", "{}");
        var wasm = await CallAsync("Runtime.evaluate", """{"expression":"JSON.stringify(self.__osbWasm ? self.__osbWasm() : null)","returnByValue":true}""");
        long? used = null, total = null, wasmBytes = null;
        var wasmCount = 0;
        try
        {
            if (heap is not null)
            {
                using var document = JsonDocument.Parse(heap);
                used = Number(document.RootElement, "usedSize");
                total = Number(document.RootElement, "totalSize");
            }
            if (wasm is not null)
            {
                using var document = JsonDocument.Parse(wasm);
                if (document.RootElement.TryGetProperty("result", out var result) && result.TryGetProperty("value", out var value) && value.ValueKind == JsonValueKind.String)
                {
                    using var probe = JsonDocument.Parse(value.GetString()!, new JsonDocumentOptions { MaxDepth = 4 });
                    wasmBytes = Number(probe.RootElement, "bytes") is { } bytes and >= 0 ? bytes : null;
                    wasmCount = (int)Math.Clamp(Number(probe.RootElement, "count") ?? 0, 0, 10_000);
                }
            }
        }
        catch (Exception e) when (e is JsonException or InvalidOperationException)
        {
            wasmBytes = null;
            wasmCount = 0;
        }
        return new PageMemory(used, total, wasmBytes, wasmCount);
    }

    private static long? Number(JsonElement element, string name) =>
        element.ValueKind == JsonValueKind.Object && element.TryGetProperty(name, out var value) && value.TryGetInt64(out var number) ? number : null;

    private async Task<string?> CallAsync(string method, string parameters)
    {
        try
        {
            return await core!.CallDevToolsProtocolMethodAsync(method, parameters).WaitAsync(StatusTimeout);
        }
        catch (Exception e) when (e is TimeoutException or InvalidOperationException or COMException or ArgumentException or JsonException)
        {
            return null;
        }
    }

    private void ApplyAudio()
    {
        if (core is not null)
        {
            core.IsMuted = Light || muteItem.Checked;
        }
    }

    private void OnWebMessageReceived(object? sender, CoreWebView2WebMessageReceivedEventArgs e)
    {
#if DEBUG
        using var probe = LatencyProbe.Message(Account.Id);
#endif
        if (!IsGamePage(e.Source))
        {
            return;
        }
        var json = e.WebMessageAsJson;
        if (RendererSlotMessage.TryParse(json) is { } slot)
        {
            OnRendererSlot(slot);
            return;
        }
        if (BotStatus.MessageType(json) == "credentials-request")
        {
            SendCredentials();
            return;
        }
        if (BotStatus.TryParse(json) is not { } report)
        {
            return;
        }
        if (report.LoginStage != status?.LoginStage && report.LoginStage == "failed")
        {
            services.Log.Warn($"{Account.Name}: auto login stopped. {report.LoginMessage}");
        }
        if (report.Linked && status?.Linked != true)
        {
            services.Log.Info($"{Account.Name}: linked to the game.");
        }
        LogRenderer(report);
        if (report.Character is { } character)
        {
            services.Characters[Account.Id] = character;
        }
        foreach (var drop in report.Drops)
        {
            if (services.Sox.Add(drop, Account.Name, services.OurCharacters()) is { Ours: true } ours)
            {
                services.Log.Info($"SoX drop: {ours.Character} got {ours.Item} (Seal of {ours.Seal}){(ours.Monster.Length > 0 ? " from " + ours.Monster : "")}.");
            }
        }
        foreach (var receipt in report.Received)
        {
            var result = services.Sox.Receive(receipt, report.Character);
            if (result.Drop is { } matched)
            {
                services.Log.Info($"SoX drop: {matched.Item} (Seal of {matched.Seal}) went to {matched.ReceivedBy}.");
            }
            if (result.Log)
            {
                services.Log.Info($"{Account.Name}: item notice {receipt.Key} [{receipt.Item}, {receipt.Count?.ToString() ?? "-"}, {receipt.Member}] in party {receipt.InParty}, {result.Outcome}.");
            }
        }
        var step = recovery.Observe(status, report, services.Settings.RestartAfterRendererFailure);
        status = report;
        statusAt = DateTime.UtcNow;
        services.Telemetry.Statuses.Publish(Account.Id, Account.Server, report, services.Time.GetUtcNow());
        ApplyMemoryLevel();
        failure = null;
        Text = Account.Name + (report.Character is { } name ? $" ({name})" : "") + " · " + AppIdentity.Name;
        Recover(step);
    }

    private void LogRenderer(BotStatus report)
    {
        if (report.GpuRetries > 0 && report.GpuRetries != (status?.GpuRetries ?? 0) && report.GpuFailed is null)
        {
            services.Log.Warn(RendererTexts.Retrying(Account.Name, report.GpuRetries, report.GpuRetryLimit, report.GpuRetryIn));
        }
        if (report.GpuFailed is not null && status?.GpuFailed is null)
        {
            services.Log.Error(RendererTexts.Failed(Account.Name, report.GpuFailed));
        }
    }

    private void Recover(RendererStep step)
    {
        if (step == RendererStep.None)
        {
            return;
        }
        var line = RendererTexts.Step(Account.Name, step, recovery.Restarted);
        if (step == RendererStep.GiveUp)
        {
            services.Log.Error(line);
            return;
        }
        services.Log.Warn(line);
        if (step == RendererStep.Reload)
        {
            ReloadPage();
        }
        else
        {
            RestartRequested?.Invoke(this, EventArgs.Empty);
        }
    }

    private void OnRendererSlot(RendererSlotMessage slot)
    {
        if (slot.Done)
        {
            services.Renderers.Release(Account.Id, slot.Id);
            return;
        }
        services.Renderers.Request(Account.Id, slot.Id, () =>
        {
            try
            {
                if (!IsDisposed && core is not null && IsGamePage(core.Source))
                {
                    core.PostWebMessageAsJson(RendererSlotMessage.Grant(slot.Id));
                }
            }
            catch (Exception e) when (e is InvalidOperationException or COMException or ObjectDisposedException)
            {
                services.Renderers.Forget(Account.Id);
            }
        });
    }

    private void SendCredentials()
    {
        if (core is null || !IsGamePage(core.Source))
        {
            return;
        }
        string? reason = null;
        string? password = null;
        if (!Account.AutoLogin || !Account.HasCredentials)
        {
            reason = "No login details are saved for this account.";
        }
        else if (!credentialGate.TryTake())
        {
            reason = "Too many login attempts in a short time; automatic login paused.";
        }
        else if ((password = AccountStore.RevealPassword(Account, services.Protector)) is null)
        {
            reason = "The saved password cannot be read under this Windows user. Enter it again.";
        }
        if (reason is not null)
        {
            core.PostWebMessageAsJson(JsonSerializer.Serialize(new { type = "credentials", reason }));
            return;
        }
        core.PostWebMessageAsJson(JsonSerializer.Serialize(new { type = "credentials", id = Account.LoginId, password }));
        services.Log.Info($"{Account.Name}: typing the saved login into the game.");
    }

    private static bool IsGamePage(string? url) => url?.StartsWith(GameOrigin, StringComparison.Ordinal) == true;

    private void OnNewWindowRequested(object? sender, CoreWebView2NewWindowRequestedEventArgs e)
    {
        e.Handled = true;
        if (Uri.TryCreate(e.Uri, UriKind.Absolute, out var uri) && (uri.Scheme == Uri.UriSchemeHttps || uri.Scheme == Uri.UriSchemeHttp))
        {
            Process.Start(new ProcessStartInfo(uri.ToString()) { UseShellExecute = true });
        }
    }

    private void OnProcessFailed(object? sender, CoreWebView2ProcessFailedEventArgs e)
    {
        switch (e.ProcessFailedKind)
        {
            case CoreWebView2ProcessFailedKind.BrowserProcessExited:
                services.Browser.Reset();
                failure = "Browser closed, start again";
                break;
            case CoreWebView2ProcessFailedKind.RenderProcessExited:
                services.Renderers.Forget(Account.Id);
                failure = "Page crashed, use Reload";
                break;
            default:
                services.Log.Warn($"{Account.Name}: browser process problem ({e.ProcessFailedKind}).");
                return;
        }
        services.Log.Error($"{Account.Name}: {failure} ({e.ProcessFailedKind}, {e.Reason}).");
    }

    private void Fail(string message, Exception exception)
    {
        failure = message;
        services.Log.Error($"{Account.Name}: {message}", exception);
    }

    private void RestorePlacement(WindowPlacement? placement)
    {
        if (placement is null)
        {
            StartPosition = FormStartPosition.WindowsDefaultLocation;
            return;
        }
        var bounds = new Rectangle(placement.X, placement.Y, placement.Width, placement.Height);
        if (bounds.Width < 400 || bounds.Height < 300 || !Screen.AllScreens.Any(s => s.WorkingArea.IntersectsWith(bounds)))
        {
            StartPosition = FormStartPosition.WindowsDefaultLocation;
            return;
        }
        StartPosition = FormStartPosition.Manual;
        Bounds = bounds;
        if (placement.Maximized)
        {
            WindowState = FormWindowState.Maximized;
        }
    }

    private void SavePlacement()
    {
        var bounds = WindowState == FormWindowState.Normal ? Bounds : RestoreBounds;
        Account.Window = new WindowPlacement(bounds.X, bounds.Y, bounds.Width, bounds.Height, WindowState == FormWindowState.Maximized);
        services.Accounts.Save();
    }
}
