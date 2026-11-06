using System.Net;
using OsbManager.Core;
using OsbManager.Core.Scripts;

namespace OsbManager.Tests;

public class BotScriptsTests
{
    private const string NixxaneUrl = "https://raw.githubusercontent.com/nixxane/opensro-bot-lean/main/bot.lean.user.js";

    private const string OsbSource = """
        // ==UserScript==
        // @name         OSB
        // @namespace    https://github.com/corevider/osb
        // @version      2.0.0
        // @downloadURL  https://raw.githubusercontent.com/corevider/osb/main/osb.user.js
        // @match        https://opensro.online/play*
        // @run-at       document-start
        // @grant        none
        // ==/UserScript==
        window.osbLoaded = true;
        """;

    private const string OtherSource = """
        // ==UserScript==
        // @name         other
        // @namespace    https://example.com/
        // @match        https://opensro.online/*
        // ==/UserScript==
        """;

    private static readonly string NixxaneSource = UserScriptMetaTests.BotHeader;

    private sealed class StubHandler(HttpStatusCode status, string body) : HttpMessageHandler
    {
        public List<Uri> Requests { get; } = [];

        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            Requests.Add(request.RequestUri!);
            return Task.FromResult(new HttpResponseMessage(status) { Content = new StringContent(body) });
        }
    }

    private static ScriptStore NewStore(TempDirectory temp) => new(temp.File("scripts"), _ => { });

    [Theory]
    [InlineData(NixxaneUrl, true)]
    [InlineData("https://raw.githubusercontent.com/nixxane/opensro-bot-lean/main/bot.lean.meta.js", true)]
    [InlineData("https://RAW.githubusercontent.com/Nixxane/OpenSRO-Bot-Lean/main/bot.lean.user.js", true)]
    [InlineData("https://github.com/nixxane/opensro-bot-lean/raw/main/bot.lean.user.js", true)]
    [InlineData("https://raw.githubusercontent.com/corevider/osb/main/osb.user.js", false)]
    [InlineData("https://raw.githubusercontent.com/nixxane/another-repo/main/bot.js", false)]
    [InlineData("https://raw.githubusercontent.com/someone/nixxane/opensro-bot-lean/main/bot.js", false)]
    [InlineData("https://example.com/nixxane/opensro-bot-lean/main/bot.js", false)]
    [InlineData("nixxane/opensro-bot-lean", false)]
    [InlineData("", false)]
    [InlineData(null, false)]
    public void RecognisesTheNixxaneBotByItsAddress(string? url, bool expected)
    {
        Assert.Equal(expected, BotScripts.IsNixxaneUrl(url));
    }

    [Theory]
    [InlineData(BotScripts.OsbUrl, true)]
    [InlineData("https://raw.githubusercontent.com/corevider/osb/main/osb.meta.js", true)]
    [InlineData(NixxaneUrl, false)]
    [InlineData(null, false)]
    public void RecognisesOsbByItsAddress(string? url, bool expected)
    {
        Assert.Equal(expected, BotScripts.IsOsbUrl(url));
    }

    [Fact]
    public void TheDefaultOsbAddressIsTheOneTheSiteGives()
    {
        Assert.Equal("https://raw.githubusercontent.com/corevider/osb/main/osb.user.js", BotScripts.OsbUrl);
    }

    [Fact]
    public void FindsTheNixxaneBotByItsSourceAddress()
    {
        using var temp = new TempDirectory();
        var store = NewStore(temp);
        var nixxane = store.Install(OtherSource, NixxaneUrl);
        var other = store.Install(OtherSource.Replace("other", "third"), "https://example.com/third.user.js");

        Assert.True(BotScripts.IsNixxane(nixxane));
        Assert.False(BotScripts.IsNixxane(other));
    }

    [Fact]
    public void FindsTheNixxaneBotByItsUpdateAddressWhenInstalledFromAFile()
    {
        using var temp = new TempDirectory();
        var fromFile = NewStore(temp).Install(NixxaneSource, null);

        Assert.Null(fromFile.SourceUrl);
        Assert.True(BotScripts.IsNixxane(fromFile));
    }

    [Fact]
    public void FindsOsbByItsNamespaceOrAddress()
    {
        using var temp = new TempDirectory();
        var store = NewStore(temp);

        Assert.True(BotScripts.IsOsb(store.Install(OsbSource, null)));
        Assert.True(BotScripts.IsOsb(store.Install(OtherSource, BotScripts.OsbUrl)));
        Assert.False(BotScripts.IsOsb(store.Install(OtherSource.Replace("other", "third"), "https://example.com/third.user.js")));
    }

    [Fact]
    public void OffersTheReplacementOnlyWhileUndecided()
    {
        using var temp = new TempDirectory();
        var store = NewStore(temp);
        store.Install(NixxaneSource, NixxaneUrl);

        Assert.True(BotScripts.ShouldOfferReplacement(store.Scripts, BotNoticeChoice.Undecided));
        Assert.False(BotScripts.ShouldOfferReplacement(store.Scripts, BotNoticeChoice.Kept));
        Assert.False(BotScripts.ShouldOfferReplacement(store.Scripts, BotNoticeChoice.Replaced));
    }

    [Fact]
    public void OffersNothingWithoutTheNixxaneBot()
    {
        using var temp = new TempDirectory();
        var store = NewStore(temp);

        Assert.False(BotScripts.ShouldOfferReplacement(store.Scripts, BotNoticeChoice.Undecided));
        store.Install(OsbSource, BotScripts.OsbUrl);
        store.Install(OtherSource, "https://example.com/other.user.js");
        Assert.False(BotScripts.ShouldOfferReplacement(store.Scripts, BotNoticeChoice.Undecided));
    }

    [Fact]
    public void WarnsOnlyWhenBothBotsAreEnabled()
    {
        using var temp = new TempDirectory();
        var store = NewStore(temp);
        var nixxane = store.Install(NixxaneSource, NixxaneUrl);
        Assert.False(BotScripts.BothEnabled(store.Scripts));

        var osb = store.Install(OsbSource, BotScripts.OsbUrl);
        Assert.True(BotScripts.BothEnabled(store.Scripts));

        store.SetEnabled(nixxane, false);
        Assert.False(BotScripts.BothEnabled(store.Scripts));

        store.SetEnabled(nixxane, true);
        store.SetEnabled(osb, false);
        Assert.False(BotScripts.BothEnabled(store.Scripts));
    }

    [Fact]
    public async Task ReplaceInstallsOsbAndTurnsTheNixxaneBotOffWithoutDeletingIt()
    {
        using var temp = new TempDirectory();
        var store = NewStore(temp);
        var nixxane = store.Install(NixxaneSource, NixxaneUrl);
        var settings = AppSettings.Load(temp.File("settings.json"));
        var handler = new StubHandler(HttpStatusCode.OK, OsbSource);
        using var http = new HttpClient(handler);

        var osb = await BotScripts.ReplaceWithOsbAsync(store, http, settings, BotScripts.OsbUrl);

        Assert.Equal(BotScripts.OsbUrl, Assert.Single(handler.Requests).ToString());
        Assert.Equal("OSB", osb.Meta.Name);
        Assert.True(store.Scripts.Single(s => s.Id == osb.Id).Enabled);
        var kept = store.Scripts.Single(s => s.Id == nixxane.Id);
        Assert.False(kept.Enabled);
        Assert.True(File.Exists(Path.Combine(temp.File("scripts"), nixxane.Id + ".user.js")));
        Assert.False(BotScripts.BothEnabled(store.Scripts));
        Assert.Equal(BotNoticeChoice.Replaced, AppSettings.Load(temp.File("settings.json")).BotNotice);
        Assert.False(BotScripts.ShouldOfferReplacement(store.Scripts, settings.BotNotice));
    }

    [Fact]
    public async Task ReplaceRaisesOneChangeAndNeverShowsBothBotsOn()
    {
        using var temp = new TempDirectory();
        var store = NewStore(temp);
        store.Install(NixxaneSource, NixxaneUrl);
        var settings = AppSettings.Load(temp.File("settings.json"));
        using var http = new HttpClient(new StubHandler(HttpStatusCode.OK, OsbSource));
        var bothOn = new List<bool>();
        store.Changed += () => bothOn.Add(BotScripts.BothEnabled(store.Scripts));

        await BotScripts.ReplaceWithOsbAsync(store, http, settings, BotScripts.OsbUrl);

        Assert.Equal([false], bothOn);
    }

    [Fact]
    public async Task ReplaceChangesNothingWhenOsbCannotBeInstalled()
    {
        using var temp = new TempDirectory();
        var store = NewStore(temp);
        var nixxane = store.Install(NixxaneSource, NixxaneUrl);
        var settings = AppSettings.Load(temp.File("settings.json"));
        using var http = new HttpClient(new StubHandler(HttpStatusCode.NotFound, "not found"));

        await Assert.ThrowsAsync<HttpRequestException>(() => BotScripts.ReplaceWithOsbAsync(store, http, settings, BotScripts.OsbUrl));

        Assert.Equal(nixxane.Id, Assert.Single(store.Scripts).Id);
        Assert.True(store.Scripts[0].Enabled);
        Assert.Equal(BotNoticeChoice.Undecided, settings.BotNotice);
        Assert.False(File.Exists(temp.File("settings.json")));
    }

    [Fact]
    public async Task ReplaceRefusesAnInsecureAddressUnlessLoopbackIsAllowed()
    {
        using var temp = new TempDirectory();
        var store = NewStore(temp);
        store.Install(NixxaneSource, NixxaneUrl);
        var settings = AppSettings.Load(temp.File("settings.json"));
        using var http = new HttpClient(new StubHandler(HttpStatusCode.OK, OsbSource));

        await Assert.ThrowsAsync<FormatException>(() => BotScripts.ReplaceWithOsbAsync(store, http, settings, "http://127.0.0.1:9/osb.user.js"));
        await Assert.ThrowsAsync<FormatException>(() => BotScripts.ReplaceWithOsbAsync(store, http, settings, "http://example.com/osb.user.js", allowLoopbackHttp: true));
        Assert.True(store.Scripts.Single().Enabled);

        var osb = await BotScripts.ReplaceWithOsbAsync(store, http, settings, "http://127.0.0.1:9/osb.user.js", allowLoopbackHttp: true);
        Assert.Equal("OSB", osb.Meta.Name);
    }

    [Fact]
    public void KeepStoresTheChoiceAndItSurvivesARestart()
    {
        using var temp = new TempDirectory();
        var settings = AppSettings.Load(temp.File("settings.json"));
        settings.FrameLimit = 30;
        settings.Save();

        BotScripts.KeepNixxane(settings);

        var reloaded = AppSettings.Load(temp.File("settings.json"));
        Assert.Equal(BotNoticeChoice.Kept, reloaded.BotNotice);
        Assert.Equal(30, reloaded.FrameLimit);
        Assert.Contains("\"botNotice\": \"Kept\"", File.ReadAllText(temp.File("settings.json")));
    }

    [Fact]
    public void ReadsASettingsFileFromBeforeTheNotice()
    {
        using var temp = new TempDirectory();
        File.WriteAllText(temp.File("settings.json"), """{"frameLimit":120}""");

        var settings = AppSettings.Load(temp.File("settings.json"));

        Assert.Equal(120, settings.FrameLimit);
        Assert.Equal(BotNoticeChoice.Undecided, settings.BotNotice);
    }

    [Fact]
    public void KeepsAScriptsFileFromTheOldAppReadable()
    {
        using var temp = new TempDirectory();
        var scripts = temp.File("scripts");
        Directory.CreateDirectory(scripts);
        File.WriteAllText(Path.Combine(scripts, "0123456789ab.user.js"), NixxaneSource);
        File.WriteAllText(Path.Combine(scripts, "scripts.json"), $$"""[{ "id": "0123456789ab", "enabled": true, "sourceUrl": "{{NixxaneUrl}}" }]""");

        var store = new ScriptStore(scripts, _ => { });

        var script = Assert.Single(store.Scripts);
        Assert.True(BotScripts.IsNixxane(script));
        Assert.True(BotScripts.ShouldOfferReplacement(store.Scripts, BotNoticeChoice.Undecided));
    }
}
