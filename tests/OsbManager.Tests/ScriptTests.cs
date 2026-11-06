using System.Text.RegularExpressions;
using OsbManager.Core.Scripts;

namespace OsbManager.Tests;

public class UserScriptMetaTests
{
    internal const string BotHeader = """
        // ==UserScript==
        // @name         nixxane bot
        // @namespace    https://opensro.online/
        // @version      1.2.172
        // @updateURL    https://raw.githubusercontent.com/nixxane/opensro-bot-lean/main/bot.lean.meta.js
        // @downloadURL  https://raw.githubusercontent.com/nixxane/opensro-bot-lean/main/bot.lean.user.js
        // @match        https://opensro.online/play*
        // @run-at       document-start
        // @grant        none
        // @inject-into  page
        // @noframes
        // ==/UserScript==
        window.botLoaded = true;
        """;

    [Fact]
    public void ReadsTheBotHeader()
    {
        var meta = UserScriptMeta.Parse(BotHeader);

        Assert.Equal("nixxane bot", meta.Name);
        Assert.Equal("1.2.172", meta.Version);
        Assert.Equal("document-start", meta.RunAt);
        Assert.True(meta.NoFrames);
        Assert.Equal(["https://opensro.online/play*"], meta.Matches);
        Assert.Equal(["none"], meta.Grants);
        Assert.Empty(meta.UnsupportedGrants);
        Assert.EndsWith("bot.lean.user.js", meta.DownloadUrl);
    }

    [Fact]
    public void DefaultsToDocumentIdleAndListsUnsupportedGrants()
    {
        var meta = UserScriptMeta.Parse("""
            // ==UserScript==
            // @name   other
            // @include https://opensro.online/*
            // @grant  GM_xmlhttpRequest
            // @grant  GM_getValue
            // @require https://example.com/lib.js
            // ==/UserScript==
            """);

        Assert.Equal("document-idle", meta.RunAt);
        Assert.False(meta.NoFrames);
        Assert.Equal(["GM_xmlhttpRequest"], meta.UnsupportedGrants);
        Assert.Equal(["https://example.com/lib.js"], meta.Requires);
    }

    [Theory]
    [InlineData("console.log(1);")]
    [InlineData("// ==UserScript==\n// @match https://a.example/*\n// ==/UserScript==")]
    [InlineData("// ==UserScript==\n// @name no targets\n// ==/UserScript==")]
    [InlineData("// ==UserScript==\n// @name unterminated\n// @match https://a.example/*")]
    public void RejectsIncompleteHeaders(string source)
    {
        Assert.Throws<FormatException>(() => UserScriptMeta.Parse(source));
    }
}

public class UrlPatternTests
{
    [Theory]
    [InlineData("https://opensro.online/play*", "https://opensro.online/play", true)]
    [InlineData("https://opensro.online/play*", "https://opensro.online/play?server=1", true)]
    [InlineData("https://opensro.online/play*", "https://opensro.online/", false)]
    [InlineData("https://opensro.online/play*", "http://opensro.online/play", false)]
    [InlineData("https://opensro.online/play*", "https://opensro.online.evil.example/play", false)]
    [InlineData("*://*.example.com/*", "https://example.com/a", true)]
    [InlineData("*://*.example.com/*", "http://a.b.example.com/", true)]
    [InlineData("*://*.example.com/*", "https://badexample.com/", false)]
    [InlineData("<all_urls>", "https://anything.example/x", true)]
    public void MatchPatterns(string pattern, string url, bool expected)
    {
        Assert.Equal(expected, Regex.IsMatch(url, UrlPattern.FromMatch(pattern)));
    }

    [Theory]
    [InlineData("https://opensro.online/*", "https://opensro.online/play", true)]
    [InlineData("https://opensro.online/*", "https://opensro.online.example/", false)]
    [InlineData("/^https:\\/\\/opensro\\.online\\/play/", "https://opensro.online/play", true)]
    public void IncludeGlobsAndRegexes(string glob, string url, bool expected)
    {
        Assert.Equal(expected, Regex.IsMatch(url, UrlPattern.FromGlob(glob)));
    }

    [Fact]
    public void RejectsMalformedMatchPatterns()
    {
        Assert.Throws<FormatException>(() => UrlPattern.FromMatch("opensro.online/play"));
    }
}

public class ScriptInjectionTests
{
    [Fact]
    public void WrapsTheSourceWithItsTargetsAndRunTime()
    {
        var meta = UserScriptMeta.Parse(UserScriptMetaTests.BotHeader);

        var injection = ScriptInjection.Build(meta, UserScriptMetaTests.BotHeader);

        Assert.StartsWith("(() => {", injection);
        Assert.Contains("window.botLoaded = true;", injection);
        Assert.Contains("\"runAt\":\"document-start\"", injection);
        Assert.Contains("\"noFrames\":true", injection);
        Assert.Contains(System.Text.Json.JsonSerializer.Serialize(UrlPattern.FromMatch("https://opensro.online/play*")), injection);
        Assert.EndsWith("})();\n", injection);
    }
}

public class ScriptStoreTests
{
    [Fact]
    public void InstallsReplacesByNameAndReloads()
    {
        using var temp = new TempDirectory();
        var store = new ScriptStore(temp.Path, _ => { });
        var first = store.Install(UserScriptMetaTests.BotHeader, "https://example.com/bot.user.js");
        store.SetEnabled(first, false);

        var updated = store.Install(UserScriptMetaTests.BotHeader.Replace("1.2.172", "1.2.173"), null);
        var reloaded = new ScriptStore(temp.Path, _ => { });

        Assert.Equal(first.Id, updated.Id);
        var script = Assert.Single(reloaded.Scripts);
        Assert.Equal("1.2.173", script.Meta.Version);
        Assert.False(script.Enabled);
        Assert.Equal("https://example.com/bot.user.js", script.SourceUrl);
        Assert.Empty(reloaded.EnabledInjections);
    }

    [Fact]
    public void RemovesTheScriptFile()
    {
        using var temp = new TempDirectory();
        var store = new ScriptStore(temp.Path, _ => { });
        var script = store.Install(UserScriptMetaTests.BotHeader, null);

        store.Remove(script);

        Assert.Empty(store.Scripts);
        Assert.False(File.Exists(temp.File(script.Id + ".user.js")));
    }

    [Fact]
    public void SkipsBrokenEntriesOnLoad()
    {
        using var temp = new TempDirectory();
        File.WriteAllText(temp.File("scripts.json"), """[{"id":"../../evil","enabled":true},{"id":"aaaaaaaaaaaa","enabled":true}]""");
        File.WriteAllText(temp.File("aaaaaaaaaaaa.user.js"), "no header");
        var messages = new List<string>();

        var store = new ScriptStore(temp.Path, messages.Add);

        Assert.Empty(store.Scripts);
        Assert.Single(messages);
    }

    [Fact]
    public async Task RefusesPlainHttpAddresses()
    {
        using var temp = new TempDirectory();
        var store = new ScriptStore(temp.Path, _ => { });
        using var http = new HttpClient();

        await Assert.ThrowsAsync<FormatException>(() => store.InstallFromUrlAsync("http://example.com/x.user.js", http));
    }
}
