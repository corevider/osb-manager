using System.Net;
using System.Net.Sockets;
using System.Text;
using OsbManager.Core;
using OsbManager.Core.Scripts;

namespace OsbManager.Tests;

public class OsbFirstInstallTests
{
    private const string NixxaneUrl = "https://raw.githubusercontent.com/nixxane/opensro-bot-lean/main/bot.lean.user.js";

    private const string OsbSource = """
        // ==UserScript==
        // @name         OSB
        // @namespace    https://github.com/corevider/osb
        // @version      2.0.0
        // @match        https://opensro.online/play*
        // @run-at       document-start
        // @grant        none
        // ==/UserScript==
        window.osbLoaded = true;
        """;

    private sealed class LoopbackScriptServer : IDisposable
    {
        private readonly HttpListener listener = new();
        private readonly Task serving;
        private int requestCount;

        public LoopbackScriptServer(string body)
        {
            Port = FreePort();
            listener.Prefixes.Add($"http://127.0.0.1:{Port}/");
            listener.Start();
            serving = Task.Run(async () =>
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
                    Interlocked.Increment(ref requestCount);
                    var bytes = Encoding.UTF8.GetBytes(body);
                    context.Response.ContentType = "text/javascript";
                    await context.Response.OutputStream.WriteAsync(bytes);
                    context.Response.Close();
                }
            });
        }

        public int Port { get; }

        public string Url => $"http://127.0.0.1:{Port}/osb.user.js";

        public int Requests => Volatile.Read(ref requestCount);

        public void Dispose()
        {
            listener.Close();
            serving.Wait(TimeSpan.FromSeconds(5));
        }

        public static int FreePort()
        {
            var probe = new TcpListener(IPAddress.Loopback, 0);
            probe.Start();
            var port = ((IPEndPoint)probe.LocalEndpoint).Port;
            probe.Stop();
            return port;
        }
    }

    private sealed class DataFolder(TempDirectory temp)
    {
        public string SettingsFile => temp.File("settings.json");

        public ScriptStore Scripts() => new(temp.File("scripts"), _ => { });

        public AppSettings Settings() => AppSettings.Load(SettingsFile);

        public async Task<FirstInstallResult> StartAsync(string url, ScriptStore? scripts = null, AppSettings? settings = null)
        {
            using var http = new HttpClient { Timeout = TimeSpan.FromSeconds(10) };
            return await OsbFirstInstall.RunAsync(scripts ?? Scripts(), http, settings ?? Settings(), url, allowLoopbackHttp: true);
        }
    }

    [Fact]
    public async Task AFreshDataFolderInstallsOsbOnceAndTurnsItOn()
    {
        using var temp = new TempDirectory();
        using var server = new LoopbackScriptServer(OsbSource);
        var folder = new DataFolder(temp);

        var first = await folder.StartAsync(server.Url);

        Assert.Equal(FirstInstallOutcome.Installed, first.Outcome);
        Assert.Equal(1, server.Requests);
        var installed = Assert.Single(folder.Scripts().Scripts);
        Assert.True(installed.Enabled);
        Assert.True(BotScripts.IsOsb(installed));
        Assert.Equal(server.Url, installed.SourceUrl);
        Assert.Equal(OsbFirstInstallState.Done, folder.Settings().OsbFirstInstall);
        Assert.Contains("\"osbFirstInstall\": \"Done\"", File.ReadAllText(folder.SettingsFile));

        var second = await folder.StartAsync(server.Url);

        Assert.Equal(FirstInstallOutcome.NotDue, second.Outcome);
        Assert.Equal(1, server.Requests);
    }

    [Fact]
    public async Task AnExistingDataFolderWithASettingsFileAndNoScriptsMakesNoRequest()
    {
        using var temp = new TempDirectory();
        using var server = new LoopbackScriptServer(OsbSource);
        File.WriteAllText(temp.File("settings.json"), """{"frameLimit":60}""");
        var folder = new DataFolder(temp);

        var result = await folder.StartAsync(server.Url);

        Assert.Equal(FirstInstallOutcome.NotDue, result.Outcome);
        Assert.Equal(0, server.Requests);
        Assert.Empty(folder.Scripts().Scripts);
        Assert.Equal(OsbFirstInstallState.Skipped, folder.Settings().OsbFirstInstall);
    }

    [Fact]
    public async Task ThePreviousBotBlocksTheInstallAndTheNoticeStillShows()
    {
        using var temp = new TempDirectory();
        using var server = new LoopbackScriptServer(OsbSource);
        var folder = new DataFolder(temp);
        var scripts = folder.Scripts();
        scripts.Install(UserScriptMetaTests.BotHeader, NixxaneUrl);

        var result = await folder.StartAsync(server.Url, scripts);

        Assert.Equal(FirstInstallOutcome.Skipped, result.Outcome);
        Assert.Equal(0, server.Requests);
        var reloaded = folder.Settings();
        Assert.Equal(OsbFirstInstallState.Skipped, reloaded.OsbFirstInstall);
        Assert.True(BotScripts.ShouldOfferReplacement(folder.Scripts().Scripts, reloaded.BotNotice));
        Assert.Single(folder.Scripts().Scripts);
    }

    [Fact]
    public async Task OsbAlreadyInstalledByHandBlocksTheInstall()
    {
        using var temp = new TempDirectory();
        using var server = new LoopbackScriptServer(OsbSource);
        var folder = new DataFolder(temp);
        var scripts = folder.Scripts();
        scripts.Install(OsbSource, null);

        var result = await folder.StartAsync(server.Url, scripts);

        Assert.Equal(FirstInstallOutcome.Skipped, result.Outcome);
        Assert.Equal(0, server.Requests);
    }

    [Fact]
    public async Task OfflineAtTheFirstStartStaysPendingAndTheNextStartInstalls()
    {
        using var temp = new TempDirectory();
        var folder = new DataFolder(temp);
        var offlineUrl = $"http://127.0.0.1:{LoopbackScriptServer.FreePort()}/osb.user.js";

        var offline = await folder.StartAsync(offlineUrl);

        Assert.Equal(FirstInstallOutcome.Failed, offline.Outcome);
        Assert.NotNull(offline.Error);
        Assert.Empty(folder.Scripts().Scripts);
        Assert.Equal(OsbFirstInstallState.Pending, folder.Settings().OsbFirstInstall);

        using var server = new LoopbackScriptServer(OsbSource);
        var next = await folder.StartAsync(server.Url);

        Assert.Equal(FirstInstallOutcome.Installed, next.Outcome);
        Assert.Equal(1, server.Requests);
        Assert.True(Assert.Single(folder.Scripts().Scripts).Enabled);
        Assert.Equal(OsbFirstInstallState.Done, folder.Settings().OsbFirstInstall);
    }

    [Fact]
    public async Task AFailureKeepsPendingInASavedSettingsFile()
    {
        using var temp = new TempDirectory();
        var settings = AppSettings.Load(temp.File("settings.json"));
        settings.FrameLimit = 30;
        settings.Save();
        var folder = new DataFolder(temp);

        var failed = await folder.StartAsync($"http://127.0.0.1:{LoopbackScriptServer.FreePort()}/osb.user.js", settings: settings);

        Assert.Equal(FirstInstallOutcome.Failed, failed.Outcome);
        Assert.Equal(OsbFirstInstallState.Pending, settings.OsbFirstInstall);
    }

    [Fact]
    public async Task AnyBotInstalledByHandAfterAFailureEndsTheAttempts()
    {
        using var temp = new TempDirectory();
        var folder = new DataFolder(temp);
        await folder.StartAsync($"http://127.0.0.1:{LoopbackScriptServer.FreePort()}/osb.user.js");
        folder.Scripts().Install(UserScriptMetaTests.BotHeader, NixxaneUrl);
        using var server = new LoopbackScriptServer(OsbSource);

        var next = await folder.StartAsync(server.Url);

        Assert.Equal(FirstInstallOutcome.Skipped, next.Outcome);
        Assert.Equal(0, server.Requests);
        Assert.Equal(OsbFirstInstallState.Skipped, folder.Settings().OsbFirstInstall);
    }

    [Fact]
    public async Task RemovingOsbAfterTheFirstInstallNeverInstallsItAgain()
    {
        using var temp = new TempDirectory();
        using var server = new LoopbackScriptServer(OsbSource);
        var folder = new DataFolder(temp);
        await folder.StartAsync(server.Url);
        var scripts = folder.Scripts();
        scripts.Remove(scripts.Scripts.Single());

        var next = await folder.StartAsync(server.Url);

        Assert.Equal(FirstInstallOutcome.NotDue, next.Outcome);
        Assert.Equal(1, server.Requests);
        Assert.Empty(folder.Scripts().Scripts);
    }

    [Fact]
    public async Task TurningOsbOffAfterTheFirstInstallKeepsItOff()
    {
        using var temp = new TempDirectory();
        using var server = new LoopbackScriptServer(OsbSource);
        var folder = new DataFolder(temp);
        await folder.StartAsync(server.Url);
        var scripts = folder.Scripts();
        scripts.SetEnabled(scripts.Scripts.Single(), false);

        var next = await folder.StartAsync(server.Url);

        Assert.Equal(FirstInstallOutcome.NotDue, next.Outcome);
        Assert.False(Assert.Single(folder.Scripts().Scripts).Enabled);
        Assert.Equal(1, server.Requests);
    }

    [Fact]
    public async Task AnAddressOutsideTheFixedHttpsOneIsRefusedWithoutARequest()
    {
        using var temp = new TempDirectory();
        using var server = new LoopbackScriptServer(OsbSource);
        var scripts = new ScriptStore(temp.File("scripts"), _ => { });
        var settings = AppSettings.Load(temp.File("settings.json"));
        using var http = new HttpClient();

        var result = await OsbFirstInstall.RunAsync(scripts, http, settings, server.Url);

        Assert.Equal(FirstInstallOutcome.Failed, result.Outcome);
        Assert.IsType<FormatException>(result.Error);
        Assert.Equal(0, server.Requests);
        Assert.Equal(OsbFirstInstallState.Pending, settings.OsbFirstInstall);
    }

    [Fact]
    public async Task ADownloadThatIsNotAUserscriptFailsAndStaysPending()
    {
        using var temp = new TempDirectory();
        using var server = new LoopbackScriptServer("<html>not a script</html>");
        var folder = new DataFolder(temp);

        var result = await folder.StartAsync(server.Url);

        Assert.Equal(FirstInstallOutcome.Failed, result.Outcome);
        Assert.Empty(folder.Scripts().Scripts);
        Assert.Equal(OsbFirstInstallState.Pending, folder.Settings().OsbFirstInstall);
    }

    [Fact]
    public void FirstStartIsDetectedByTheMissingSettingsFile()
    {
        using var temp = new TempDirectory();

        Assert.Equal(OsbFirstInstallState.Pending, AppSettings.Load(temp.File("settings.json")).OsbFirstInstall);

        File.WriteAllText(temp.File("settings.json"), """{"frameLimit":60}""");
        Assert.Equal(OsbFirstInstallState.Skipped, AppSettings.Load(temp.File("settings.json")).OsbFirstInstall);

        File.WriteAllText(temp.File("settings.json"), "not json");
        Assert.Equal(OsbFirstInstallState.Skipped, AppSettings.Load(temp.File("settings.json")).OsbFirstInstall);
    }

    [Fact]
    public void LoadingAFreshFolderDoesNotCreateTheSettingsFile()
    {
        using var temp = new TempDirectory();

        AppSettings.Load(temp.File("settings.json"));

        Assert.False(File.Exists(temp.File("settings.json")));
    }
}
