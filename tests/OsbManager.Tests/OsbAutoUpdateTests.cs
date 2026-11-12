using System.Collections.Concurrent;
using System.Net;
using System.Net.Sockets;
using System.Text;
using OsbManager.Core;
using OsbManager.Core.Scripts;

namespace OsbManager.Tests;

public class OsbAutoUpdateTests
{
    private const string ThirdPartyUrl = "https://example.com/tool.user.js";

    private static string Source(string version, string name = "OSB", string ns = BotScripts.OsbNamespace, string marker = "") => $"""
        // ==UserScript==
        // @name         {name}
        // @namespace    {ns}
        // @version      {version}
        // @match        https://opensro.online/play*
        // @run-at       document-start
        // @grant        none
        // ==/UserScript==
        window.osbLoaded = "{version}{marker}";
        """;

    private static string Header(string version, string name = "OSB", string ns = BotScripts.OsbNamespace) =>
        Source(version, name, ns).Split("// ==/UserScript==")[0] + "// ==/UserScript==\n";

    private sealed class LoopbackOsbServer : IDisposable
    {
        private readonly HttpListener listener = new();
        private readonly Task serving;
        private readonly ConcurrentDictionary<string, int> counts = new();
        private volatile string metaBody;
        private volatile string scriptBody;

        public LoopbackOsbServer(string version)
        {
            metaBody = Header(version);
            scriptBody = Source(version);
            var probe = new TcpListener(IPAddress.Loopback, 0);
            probe.Start();
            Port = ((IPEndPoint)probe.LocalEndpoint).Port;
            probe.Stop();
            listener.Prefixes.Add($"http://127.0.0.1:{Port}/");
            listener.Start();
            serving = Task.Run(Loop);
        }

        public int Port { get; }

        public string ScriptUrl => $"http://127.0.0.1:{Port}/osb.user.js";

        public int Metas => counts.GetValueOrDefault("/osb.meta.js");

        public int Downloads => counts.GetValueOrDefault("/osb.user.js");

        public TaskCompletionSource? HoldScript { get; set; }

        public void Serve(string announced, string script)
        {
            metaBody = Header(announced);
            scriptBody = script;
        }

        public void ServeMeta(string meta) => metaBody = meta;

        public void Dispose()
        {
            listener.Close();
            serving.Wait(TimeSpan.FromSeconds(5));
        }

        private async Task Loop()
        {
            while (listener.IsListening)
            {
                HttpListenerContext context;
                try
                {
                    context = await listener.GetContextAsync();
                }
                catch (Exception e) when (e is HttpListenerException or ObjectDisposedException)
                {
                    return;
                }
                var path = context.Request.Url!.AbsolutePath;
                counts.AddOrUpdate(path, 1, (_, count) => count + 1);
                if (path == "/osb.user.js" && HoldScript is { } hold)
                {
                    await hold.Task;
                }
                var body = path == "/osb.meta.js" ? metaBody : path == "/osb.user.js" ? scriptBody : null;
                if (body is null)
                {
                    context.Response.StatusCode = 404;
                    context.Response.Close();
                    continue;
                }
                var bytes = Encoding.UTF8.GetBytes(body);
                await context.Response.OutputStream.WriteAsync(bytes);
                context.Response.Close();
            }
        }
    }

    private sealed class Rig(TempDirectory temp, string url, bool enabled = true) : IDisposable
    {
        private readonly HttpClient http = new() { Timeout = TimeSpan.FromSeconds(10) };

        public ScriptStore Scripts { get; } = new(temp.File("scripts"), _ => { });

        public ScriptJobs Jobs { get; } = new();

        public bool Enabled { get; set; } = enabled;

        public OsbAutoUpdate Updater => field ??= new OsbAutoUpdate(Scripts, http, Jobs, () => Enabled, url);

        public InstalledScript InstallOsb(string version, bool on = true)
        {
            var installed = Scripts.Install(Source(version), url);
            Scripts.SetEnabled(installed, on);
            return Scripts.Scripts.Single(s => s.Id == installed.Id);
        }

        public void Dispose() => http.Dispose();
    }

    [Fact]
    public async Task ANewerVersionUpdatesOsbOnceAndKeepsItOn()
    {
        using var temp = new TempDirectory();
        using var server = new LoopbackOsbServer("2.0.13");
        using var rig = new Rig(temp, server.ScriptUrl);
        rig.InstallOsb("2.0.13");
        server.Serve("2.0.14", Source("2.0.14", marker: "new"));

        var first = await rig.Updater.CheckAsync();
        var second = await rig.Updater.CheckAsync();

        Assert.Equal(OsbUpdateOutcome.Updated, first.Outcome);
        Assert.Equal("2.0.13", first.OldVersion);
        Assert.Equal("2.0.14", first.NewVersion);
        Assert.Equal(OsbUpdateOutcome.UpToDate, second.Outcome);
        Assert.Equal(1, server.Downloads);
        Assert.Equal(2, server.Metas);
        var osb = Assert.Single(rig.Scripts.Scripts);
        Assert.Equal("2.0.14", osb.Meta.Version);
        Assert.True(osb.Enabled);
        Assert.Contains("2.0.14new", osb.Injection);
    }

    [Fact]
    public async Task ANewerVersionKeepsOsbOff()
    {
        using var temp = new TempDirectory();
        using var server = new LoopbackOsbServer("2.0.13");
        using var rig = new Rig(temp, server.ScriptUrl);
        rig.InstallOsb("2.0.13", on: false);
        server.Serve("2.1.0", Source("2.1.0"));

        var result = await rig.Updater.CheckAsync();

        Assert.Equal(OsbUpdateOutcome.Updated, result.Outcome);
        Assert.False(Assert.Single(rig.Scripts.Scripts).Enabled);
        Assert.Equal("2.1.0", rig.Scripts.Scripts.Single().Meta.Version);
    }

    [Fact]
    public async Task VersionsAreComparedAsNumbersNotText()
    {
        using var temp = new TempDirectory();
        using var server = new LoopbackOsbServer("2.0.9");
        using var rig = new Rig(temp, server.ScriptUrl);
        rig.InstallOsb("2.0.9");
        server.Serve("2.0.10", Source("2.0.10"));

        var result = await rig.Updater.CheckAsync();

        Assert.Equal(OsbUpdateOutcome.Updated, result.Outcome);
        Assert.Equal("2.0.10", rig.Scripts.Scripts.Single().Meta.Version);
    }

    [Fact]
    public async Task TheSameVersionNeverDownloadsTheScript()
    {
        using var temp = new TempDirectory();
        using var server = new LoopbackOsbServer("2.0.13");
        using var rig = new Rig(temp, server.ScriptUrl);
        rig.InstallOsb("2.0.13");

        var result = await rig.Updater.CheckAsync();

        Assert.Equal(OsbUpdateOutcome.UpToDate, result.Outcome);
        Assert.Equal(1, server.Metas);
        Assert.Equal(0, server.Downloads);
    }

    [Fact]
    public async Task AnOlderAnnouncedVersionLeavesOsbUnchanged()
    {
        using var temp = new TempDirectory();
        using var server = new LoopbackOsbServer("2.0.13");
        using var rig = new Rig(temp, server.ScriptUrl);
        rig.InstallOsb("2.0.13");
        server.Serve("2.0.2", Source("2.0.2"));

        var result = await rig.Updater.CheckAsync();

        Assert.Equal(OsbUpdateOutcome.UpToDate, result.Outcome);
        Assert.Equal(0, server.Downloads);
        Assert.Equal("2.0.13", rig.Scripts.Scripts.Single().Meta.Version);
    }

    [Fact]
    public async Task ADownloadOlderThanAnnouncedIsNotKept()
    {
        using var temp = new TempDirectory();
        using var server = new LoopbackOsbServer("2.0.13");
        using var rig = new Rig(temp, server.ScriptUrl);
        rig.InstallOsb("2.0.13");
        server.Serve("2.0.14", Source("2.0.12"));

        var result = await rig.Updater.CheckAsync();

        Assert.Equal(OsbUpdateOutcome.Failed, result.Outcome);
        Assert.Equal(1, server.Downloads);
        Assert.Equal("2.0.13", Assert.Single(rig.Scripts.Scripts).Meta.Version);
    }

    [Fact]
    public async Task ADownloadWithAnotherNamespaceIsNotInstalled()
    {
        using var temp = new TempDirectory();
        using var server = new LoopbackOsbServer("2.0.13");
        using var rig = new Rig(temp, server.ScriptUrl);
        rig.InstallOsb("2.0.13");
        server.Serve("2.0.14", Source("2.0.14", ns: "https://example.com/other"));

        var result = await rig.Updater.CheckAsync();

        Assert.Equal(OsbUpdateOutcome.Failed, result.Outcome);
        var osb = Assert.Single(rig.Scripts.Scripts);
        Assert.Equal("2.0.13", osb.Meta.Version);
        Assert.Equal(BotScripts.OsbNamespace, osb.Meta.Namespace);
    }

    [Fact]
    public async Task AMetaFileWithAnotherNamespaceDownloadsNothing()
    {
        using var temp = new TempDirectory();
        using var server = new LoopbackOsbServer("2.0.13");
        using var rig = new Rig(temp, server.ScriptUrl);
        rig.InstallOsb("2.0.13");
        server.ServeMeta(Header("9.0.0", ns: "https://example.com/other"));

        var result = await rig.Updater.CheckAsync();

        Assert.Equal(OsbUpdateOutcome.Failed, result.Outcome);
        Assert.Equal(0, server.Downloads);
        Assert.Equal("2.0.13", rig.Scripts.Scripts.Single().Meta.Version);
    }

    [Fact]
    public async Task AMetaFileThatDoesNotParseFailsWithoutChange()
    {
        using var temp = new TempDirectory();
        using var server = new LoopbackOsbServer("2.0.13");
        using var rig = new Rig(temp, server.ScriptUrl);
        rig.InstallOsb("2.0.13");
        server.ServeMeta("<html>not a script</html>");

        var result = await rig.Updater.CheckAsync();

        Assert.Equal(OsbUpdateOutcome.Failed, result.Outcome);
        Assert.Equal(0, server.Downloads);
        Assert.Equal("2.0.13", rig.Scripts.Scripts.Single().Meta.Version);
    }

    [Fact]
    public async Task OfflineLeavesOsbUnchangedWarnsOncePerStreakAndTriesAgain()
    {
        using var temp = new TempDirectory();
        string offlineUrl;
        using (var closed = new LoopbackOsbServer("2.0.13"))
        {
            offlineUrl = closed.ScriptUrl;
        }
        using var rig = new Rig(temp, offlineUrl);
        rig.InstallOsb("2.0.13");

        var first = await rig.Updater.CheckAsync();
        var second = await rig.Updater.CheckAsync();

        Assert.Equal(OsbUpdateOutcome.Failed, first.Outcome);
        Assert.True(first.FirstFailureInStreak);
        Assert.Equal(OsbUpdateOutcome.Failed, second.Outcome);
        Assert.False(second.FirstFailureInStreak);
        Assert.Equal("2.0.13", rig.Scripts.Scripts.Single().Meta.Version);
    }

    [Fact]
    public async Task AfterAFailureTheNextCheckUpdatesAndALaterFailureWarnsAgain()
    {
        using var temp = new TempDirectory();
        var probe = new TcpListener(IPAddress.Loopback, 0);
        probe.Start();
        var port = ((IPEndPoint)probe.LocalEndpoint).Port;
        probe.Stop();
        using var rig = new Rig(temp, $"http://127.0.0.1:{port}/osb.user.js");
        rig.InstallOsb("2.0.13");
        Assert.Equal(OsbUpdateOutcome.Failed, (await rig.Updater.CheckAsync()).Outcome);

        var live = new HttpListener();
        live.Prefixes.Add($"http://127.0.0.1:{port}/");
        live.Start();
        var serving = Task.Run(async () =>
        {
            while (live.IsListening)
            {
                HttpListenerContext context;
                try
                {
                    context = await live.GetContextAsync();
                }
                catch (Exception e) when (e is HttpListenerException or ObjectDisposedException)
                {
                    return;
                }
                var body = context.Request.Url!.AbsolutePath == "/osb.meta.js" ? Header("2.0.14") : Source("2.0.14");
                await context.Response.OutputStream.WriteAsync(Encoding.UTF8.GetBytes(body));
                context.Response.Close();
            }
        });
        var recovered = await rig.Updater.CheckAsync();
        live.Close();
        await serving;
        var failedAgain = await rig.Updater.CheckAsync();

        Assert.Equal(OsbUpdateOutcome.Updated, recovered.Outcome);
        Assert.Equal("2.0.14", rig.Scripts.Scripts.Single().Meta.Version);
        Assert.Equal(OsbUpdateOutcome.Failed, failedAgain.Outcome);
        Assert.True(failedAgain.FirstFailureInStreak);
    }

    [Fact]
    public async Task WithTheSettingOffNoRequestIsMade()
    {
        using var temp = new TempDirectory();
        using var server = new LoopbackOsbServer("2.0.14");
        using var rig = new Rig(temp, server.ScriptUrl, enabled: false);
        rig.InstallOsb("2.0.13");

        var result = await rig.Updater.CheckAsync();

        Assert.Equal(OsbUpdateOutcome.Disabled, result.Outcome);
        Assert.Equal(0, server.Metas);
        Assert.Equal(0, server.Downloads);
        Assert.Equal("2.0.13", rig.Scripts.Scripts.Single().Meta.Version);
    }

    [Fact]
    public async Task AThirdPartyScriptWithAnUpdateAddressIsNeverUpdatedByItself()
    {
        using var temp = new TempDirectory();
        using var server = new LoopbackOsbServer("9.0.0");
        using var rig = new Rig(temp, server.ScriptUrl);
        var thirdParty = $"""
            // ==UserScript==
            // @name         Other tool
            // @namespace    https://example.com/
            // @version      1.0.0
            // @updateURL    {server.ScriptUrl.Replace("osb.user.js", "osb.meta.js")}
            // @downloadURL  {server.ScriptUrl}
            // @match        https://opensro.online/play*
            // ==/UserScript==
            """;
        rig.Scripts.Install(thirdParty, ThirdPartyUrl);

        var result = await rig.Updater.CheckAsync();

        Assert.Equal(OsbUpdateOutcome.NotApplicable, result.Outcome);
        Assert.Equal(0, server.Metas);
        Assert.Equal(0, server.Downloads);
        Assert.Equal("1.0.0", rig.Scripts.Scripts.Single().Meta.Version);
    }

    [Fact]
    public async Task WithoutOsbInstalledNothingIsRequested()
    {
        using var temp = new TempDirectory();
        using var server = new LoopbackOsbServer("2.0.14");
        using var rig = new Rig(temp, server.ScriptUrl);

        var result = await rig.Updater.CheckAsync();

        Assert.Equal(OsbUpdateOutcome.NotApplicable, result.Outcome);
        Assert.Equal(0, server.Metas);
        Assert.Empty(rig.Scripts.Scripts);
    }

    [Fact]
    public async Task OutsideTheTestAddressOnlyHttpsAddressesInTheOsbRepositoryAreUsed()
    {
        using var temp = new TempDirectory();
        using var server = new LoopbackOsbServer("2.0.14");
        var scripts = new ScriptStore(temp.File("scripts"), _ => { });
        var elsewhere = Source("2.0.13").Replace("// @version      2.0.13", $"""
            // @version      2.0.13
            // @updateURL    {server.ScriptUrl.Replace("osb.user.js", "osb.meta.js")}
            // @downloadURL  {server.ScriptUrl}
            """);
        scripts.Install(elsewhere, null);
        using var http = new HttpClient();
        var updater = new OsbAutoUpdate(scripts, http, new ScriptJobs(), () => true);

        var result = await updater.CheckAsync();

        Assert.Equal(OsbUpdateOutcome.NotApplicable, result.Outcome);
        Assert.Equal(0, server.Metas);
    }

    [Fact]
    public async Task NoUpdateRunsWhileTheFirstStartInstallRuns()
    {
        using var temp = new TempDirectory();
        using var server = new LoopbackOsbServer("2.0.13");
        server.HoldScript = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        using var rig = new Rig(temp, server.ScriptUrl);
        var settings = AppSettings.Load(temp.File("settings.json"));
        using var http = new HttpClient();

        Task<FirstInstallResult> install;
        using (rig.Jobs.Begin())
        {
            install = OsbFirstInstall.RunAsync(rig.Scripts, http, settings, server.ScriptUrl, allowLoopbackHttp: true);
            var during = await rig.Updater.CheckAsync();
            Assert.Equal(OsbUpdateOutcome.Busy, during.Outcome);
            Assert.Equal(0, server.Metas);
        }
        server.HoldScript.SetResult();
        Assert.Equal(FirstInstallOutcome.Installed, (await install).Outcome);

        var after = await rig.Updater.CheckAsync();

        Assert.Equal(OsbUpdateOutcome.UpToDate, after.Outcome);
        Assert.Equal(1, server.Metas);
    }

    [Fact]
    public async Task NoUpdateRunsWhileAManualUpdateRunsAndTwoChecksNeverOverlap()
    {
        using var temp = new TempDirectory();
        using var server = new LoopbackOsbServer("2.0.14");
        server.HoldScript = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        using var rig = new Rig(temp, server.ScriptUrl);
        rig.InstallOsb("2.0.13");

        var running = rig.Updater.CheckAsync();
        while (server.Downloads == 0)
        {
            await Task.Delay(10);
        }
        var overlapping = await rig.Updater.CheckAsync();
        server.HoldScript.SetResult();
        var finished = await running;

        Assert.Equal(OsbUpdateOutcome.Busy, overlapping.Outcome);
        Assert.Equal(OsbUpdateOutcome.Updated, finished.Outcome);
        Assert.Equal(1, server.Downloads);
        Assert.Equal(1, server.Metas);
    }

    [Fact]
    public void TheSettingIsOnByDefaultAndSaved()
    {
        using var temp = new TempDirectory();
        var settings = AppSettings.Load(temp.File("settings.json"));
        Assert.True(settings.UpdateOsbAutomatically);

        settings.UpdateOsbAutomatically = false;
        settings.Save();

        Assert.False(AppSettings.Load(temp.File("settings.json")).UpdateOsbAutomatically);
        File.WriteAllText(temp.File("older.json"), """{"frameLimit":60}""");
        Assert.True(AppSettings.Load(temp.File("older.json")).UpdateOsbAutomatically);
    }
}
