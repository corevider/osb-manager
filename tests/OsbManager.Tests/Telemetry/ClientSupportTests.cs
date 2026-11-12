using System.Drawing;
using System.Drawing.Imaging;
using System.Globalization;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Text.Json.Nodes;
using OsbManager.Core;
using OsbManager.Core.Status;
using OsbManager.Core.Telemetry;
using OsbManager.UI;

namespace OsbManager.Tests.Telemetry;

public class ClientSupportTests
{
    private static TelemetryConfig? Parse(string json) => TelemetryConfig.TryParse(Encoding.UTF8.GetBytes(json));

    [Fact]
    public void AGoodConfigIsParsedAndItsIntervalClamped()
    {
        var config = Parse(FakeServer.ConfigEnabled)!;

        Assert.True(config.TelemetryEnabled);
        Assert.True(config.ReportsEnabled);
        Assert.True(config.ScreenshotsEnabled);
        Assert.True(config.ClientOk);
        Assert.Equal(600, config.IntervalSeconds);
        Assert.Equal(300, Parse("""{"schema":1,"telemetry":{"enabled":true,"interval_s":1},"reports":{"enabled":true},"client_ok":true}""")!.IntervalSeconds);
        Assert.Equal(86400, Parse("""{"schema":1,"telemetry":{"enabled":true,"interval_s":99999999},"reports":{"enabled":true},"client_ok":true}""")!.IntervalSeconds);
    }

    [Theory]
    [InlineData("")]
    [InlineData("[]")]
    [InlineData("{}")]
    [InlineData("""{"schema":2,"telemetry":{"enabled":true,"interval_s":600},"reports":{"enabled":true},"client_ok":true}""")]
    [InlineData("""{"schema":1,"telemetry":{"enabled":"yes","interval_s":600},"reports":{"enabled":true},"client_ok":true}""")]
    [InlineData("""{"schema":1,"telemetry":{"enabled":true},"reports":{"enabled":true},"client_ok":true}""")]
    [InlineData("""{"schema":1,"telemetry":{"enabled":true,"interval_s":600},"reports":{"enabled":true}}""")]
    [InlineData("not json")]
    public void AMalformedConfigIsNull(string json) => Assert.Null(Parse(json));

    [Fact]
    public void TheServerMessageIsPlainTextOfAtMostTwoHundredCharacters()
    {
        var message = "<b>hi</b>\u0007" + new string('x', 400);

        var config = Parse($$"""{"schema":1,"telemetry":{"enabled":true,"interval_s":600},"reports":{"enabled":true},"client_ok":true,"message":"{{message.Replace("\u0007", "\\u0007")}}"}""")!;

        Assert.Equal(200, config.Message!.Length);
        Assert.DoesNotContain('\u0007', config.Message);
    }

    [Fact]
    public void TheBackoffIsFullJitterWithAFloorOfSixtySecondsAndACapOfSixHours()
    {
        Assert.Equal(TimeSpan.FromSeconds(60), Backoff.Next(1, 0.0));
        Assert.Equal(TimeSpan.FromSeconds(60), Backoff.Next(1, 0.4));
        Assert.Equal(TimeSpan.FromSeconds(120), Backoff.Next(1, 1.0));
        Assert.Equal(TimeSpan.FromSeconds(480), Backoff.Next(3, 1.0));
        Assert.Equal(TimeSpan.FromHours(6), Backoff.Next(50, 1.0));
        Assert.All(Enumerable.Range(1, 40), n => Assert.InRange(Backoff.Next(n, 0.73), TimeSpan.FromSeconds(60), TimeSpan.FromHours(6)));
    }

    [Fact]
    public void RetryAfterIsClampedBetweenSixtySecondsAndOneDay()
    {
        Assert.Equal(TimeSpan.FromSeconds(60), Backoff.RetryAfter(TimeSpan.FromSeconds(5), 0.5, 1));
        Assert.Equal(TimeSpan.FromSeconds(120), Backoff.RetryAfter(TimeSpan.FromSeconds(120), 0.5, 1));
        Assert.Equal(TimeSpan.FromHours(24), Backoff.RetryAfter(TimeSpan.FromDays(30), 0.5, 1));
    }

    [Fact]
    public void TheStartDelayIsBetweenSixtyAndOneHundredEightySecondsAndTheIntervalJitterIsTenPercent()
    {
        Assert.Equal(TimeSpan.FromSeconds(60), Backoff.StartDelay(0));
        Assert.Equal(TimeSpan.FromSeconds(180), Backoff.StartDelay(1));
        Assert.Equal(TimeSpan.FromSeconds(540), Backoff.Jitter(TimeSpan.FromSeconds(600), 0));
        Assert.Equal(TimeSpan.FromSeconds(660), Backoff.Jitter(TimeSpan.FromSeconds(600), 1));
    }

    [Fact]
    public void TheUserAgentNamesTheAppTheVersionAndTheOs() =>
        Assert.Equal("OSBManager/1.0.0 (Windows)", AppIdentity.UserAgent("1.0.0"));

    [Fact]
    public void TheAppAndTheOtherDownloadsShareOneUserAgent()
    {
        Assert.Equal(AppIdentity.UserAgent(OsbManager.AppServices.AppVersion), OsbManager.AppServices.UserAgent);
        Assert.StartsWith("OSBManager/", OsbManager.AppServices.UserAgent);
        Assert.EndsWith(" (Windows)", OsbManager.AppServices.UserAgent);
        Assert.DoesNotContain("+", OsbManager.AppServices.UserAgent);
    }

    [Fact]
    public void ThePublicAddressIsHttpsAndPlainHttpIsOnlyAllowedOnTheLoopback()
    {
        Assert.StartsWith("https://", OsbManager.AppServices.ApiBaseUrl);
        Assert.Throws<ArgumentException>(() => TelemetryClient.Create(new Uri("http://api.osb.lol/v1"), "x"));
        Assert.Throws<ArgumentException>(() => TelemetryClient.Create(new Uri("http://192.168.1.5/v1"), "x"));
        TelemetryClient.Create(new Uri("http://127.0.0.1:9/v1"), "x").Dispose();
        TelemetryClient.Create(new Uri("https://api.osb.lol/v1"), "x").Dispose();
    }

    [Fact]
    public async Task C17_TheRealHandlerDoesNotFollowARedirectOrKeepACookie()
    {
        using var listener = new TcpListener(IPAddress.Loopback, 0);
        listener.Start();
        var port = ((IPEndPoint)listener.LocalEndpoint).Port;
        var seen = new List<string>();
        var server = Task.Run(async () =>
        {
            for (var i = 0; i < 2; i++)
            {
                using var connection = await listener.AcceptTcpClientAsync();
                var stream = connection.GetStream();
                var buffer = new byte[8192];
                var read = await stream.ReadAsync(buffer);
                lock (seen)
                {
                    seen.Add(Encoding.ASCII.GetString(buffer, 0, read));
                }
                var response = $"HTTP/1.1 302 Found\r\nLocation: http://127.0.0.1:{port}/collect\r\nSet-Cookie: session=abc\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
                await stream.WriteAsync(Encoding.ASCII.GetBytes(response));
            }
        });
        using var client = TelemetryClient.Create(new Uri($"http://127.0.0.1:{port}/v1"), AppIdentity.UserAgent("1.2.0"));

        var first = await client.GetConfigAsync("1.2.0", background: false, CancellationToken.None);
        var second = await client.GetConfigAsync("1.2.0", background: false, CancellationToken.None);
        await server;

        Assert.True(first.IsStatus(302));
        Assert.True(second.IsStatus(302));
        Assert.False(first.Succeeded);
        lock (seen)
        {
            Assert.Equal(2, seen.Count);
            Assert.All(seen, request => Assert.StartsWith("GET /v1/config?app=manager-win&version=1.2.0 ", request));
            Assert.All(seen, request => Assert.DoesNotContain("/collect", request.Split("\r\n")[0]));
            Assert.All(seen, request => Assert.DoesNotContain("cookie:", request, StringComparison.OrdinalIgnoreCase));
            Assert.All(seen, request => Assert.Contains("User-Agent: OSBManager/1.2.0 (Windows)", request));
        }
    }

    [Fact]
    public void ThereIsOneEnglishTextSetAndNoLanguageSwitch()
    {
        Assert.Null(typeof(PrivacyTexts).GetMethod("For"));
        Assert.Null(typeof(PrivacyTexts).GetProperty("Turkish"));
        Assert.Single(typeof(PrivacyTexts).GetProperties(System.Reflection.BindingFlags.Public | System.Reflection.BindingFlags.Static), p => p.PropertyType == typeof(PrivacyTexts));
    }

    [Fact]
    public void EveryTextIsFilledAndEnglish()
    {
        foreach (var property in typeof(PrivacyTexts).GetProperties().Where(p => p.PropertyType == typeof(string)))
        {
            var text = (string?)property.GetValue(PrivacyTexts.English);
            Assert.False(string.IsNullOrWhiteSpace(text), property.Name);
            Assert.DoesNotMatch("[çğıöşüÇĞİÖŞÜ]", text!);
        }
    }

    [Fact]
    public void TheConsentWordingIsThatOfConsentMdVersionTwentyTwentySixElevenTwelveDotOne()
    {
        Assert.Equal("2026-11-12.1", PrivacyTexts.TextVersion);
        Assert.Equal(2, TelemetryLimits.ConsentVersion);
        Assert.Equal("Share usage statistics, error reports and performance data", PrivacyTexts.English.UsageLabel);
        Assert.Equal("Share usage statistics, error reports and performance data with the OSB team?", PrivacyTexts.English.FirstRunTitle);
        Assert.Equal("What OSB Manager shares has changed: it now includes error reports and performance data.", PrivacyTexts.English.FirstRunChangedLead);
        Assert.Equal("Share", PrivacyTexts.English.FirstRunShare);
        Assert.Equal("No thanks", PrivacyTexts.English.FirstRunDecline);
        Assert.Equal("Add screenshot", PrivacyTexts.English.AddScreenshot);
        Assert.Equal("Stop sharing usage statistics, error reports and performance data, and delete them from api.osb.lol? Reports you already sent are deleted too.", PrivacyTexts.English.StopConfirm);
        Assert.Equal("Delete all data for this install from api.osb.lol, including linked reports, error reports and performance data? Sharing is turned off. This cannot be undone.", PrivacyTexts.English.DeleteConfirm);
        Assert.Equal("Sent. Your report code is {0}. Keep it if you want the report deleted later.", PrivacyTexts.English.SentWithCode);
        Assert.Equal("Usage statistics are off, so this report is anonymous. Keep the report code if you want it deleted later.", PrivacyTexts.English.ReportNoticeAnonymous);
        Assert.StartsWith("If you choose Share, OSB Manager sends a short report about every 10 minutes", PrivacyTexts.English.FirstRunText);
        Assert.Contains("We never copy your description or the details into a public GitHub issue.", PrivacyTexts.English.ReportNotice);
        Assert.DoesNotContain("quote", PrivacyTexts.English.ReportNotice);
    }

    [Fact]
    public void TheTextsNameTheServerTheRetentionAndThePolicy()
    {
        var texts = PrivacyTexts.English;
        Assert.Contains("api.osb.lol", texts.UsageHelp);
        Assert.Contains("api.osb.lol", texts.FirstRunText);
        Assert.Contains("api.osb.lol", texts.ReportNotice);
        Assert.Contains("usage data for 45 days, error data for 30 days and performance data for 14 days", texts.UsageHelp);
        Assert.Contains("90 days", texts.UsageHelp);
        Assert.Contains("13 months", texts.UsageHelp);
        Assert.Contains("6 months", texts.ReportNotice);
        Assert.Contains("30 days", texts.ScreenshotNotice);
        Assert.Contains("10", texts.FirstRunText);
        Assert.Equal("https://osb.lol/en/privacy/", texts.PolicyUrl);
        Assert.Contains("osb.lol/privacy", texts.UsageHelp);
    }

    [Fact]
    public void TheKvkkLinksAreShownInEnglishAndMarkedTurkish()
    {
        Assert.Equal("KVKK notice (Turkish)", PrivacyTexts.English.KvkkNoticeLink);
        Assert.Equal("KVKK explicit consent (Turkish)", PrivacyTexts.English.KvkkConsentLink);
        Assert.Equal("https://osb.lol/kvkk/aydinlatma-metni/", PrivacyTexts.English.KvkkNoticeUrl);
        Assert.Equal("https://osb.lol/kvkk/acik-riza-metni/", PrivacyTexts.English.KvkkConsentUrl);
    }

    [Fact]
    public void TheMainTextsAreNeverCalledAnonymousAndOnlyAnUnlinkedReportMayBe()
    {
        var withoutAnonymousClaim = new[]
        {
            nameof(PrivacyTexts.UsageLabel), nameof(PrivacyTexts.CharactersLabel), nameof(PrivacyTexts.CharactersHelp),
            nameof(PrivacyTexts.StopConfirm), nameof(PrivacyTexts.DeleteConfirm), nameof(PrivacyTexts.FirstRunTitle), nameof(PrivacyTexts.FirstRunText),
            nameof(PrivacyTexts.FirstRunChangedLead), nameof(PrivacyTexts.NoteAnonymous), nameof(PrivacyTexts.NoteLinked), nameof(PrivacyTexts.ReportNotice),
            nameof(PrivacyTexts.ScreenshotNotice), nameof(PrivacyTexts.ConsentRecord), nameof(PrivacyTexts.NoConsentRecord), nameof(PrivacyTexts.PrivacyTitle),
        };
        foreach (var name in withoutAnonymousClaim)
        {
            var text = (string)typeof(PrivacyTexts).GetProperty(name)!.GetValue(PrivacyTexts.English)!;
            Assert.DoesNotContain("anonymous", text, StringComparison.OrdinalIgnoreCase);
        }
        Assert.DoesNotContain("anonymous", PrivacyTexts.English.UsageHelp.Replace("which cannot identify you", ""), StringComparison.OrdinalIgnoreCase);
        Assert.Contains("not linked to an install", PrivacyTexts.English.NoteAnonymous);
        Assert.Contains("usage statistics are off", PrivacyTexts.English.ReportNoticeAnonymous, StringComparison.OrdinalIgnoreCase);
    }

    [Theory]
    [InlineData("tr-TR")]
    [InlineData("de-DE")]
    [InlineData("en-US")]
    public void TheWindowsLanguageChangesNoTextButStaysTheLocaleData(string culture)
    {
        var previous = CultureInfo.CurrentUICulture;
        try
        {
            CultureInfo.CurrentUICulture = new CultureInfo(culture);
            Assert.Equal("Share usage statistics, error reports and performance data", PrivacyTexts.English.UsageLabel);
            var json = ReportPayload.Build(ReportKind.Bug, "x", ReportDiagnostics.Build("1.2.0", "10", ".NET", [], []), "1.2.0", CultureInfo.CurrentUICulture.TwoLetterISOLanguageName);
            Assert.Equal(culture[..2], (string?)System.Text.Json.Nodes.JsonNode.Parse(json)!["locale"]);
        }
        finally
        {
            CultureInfo.CurrentUICulture = previous;
        }
    }

    [Fact]
    public void ReportDiagnosticsHoldOnlyTheListedFields()
    {
        var windows = new[]
        {
            new WindowDiagnostics("world", "done", new string('m', 200), "2.0.4", true, 2, "adapter lost"),
            WindowDiagnostics.From(null, false),
        };
        var scripts = new[] { new ScriptDiagnostics("OSB", "2.0.4") };

        var json = ReportDiagnostics.Build("1.2.0", "10.0.26300", ".NET 10.0.0", windows, scripts);

        Assert.Equal(2, (int)json["windows"]!);
        var first = json["game_windows"]![0]!;
        Assert.Equal(64, ((string)first["login"]!["message"]!).Length);
        Assert.Equal(2, (int)first["gpu"]!["retries"]!);
        Assert.Equal("OSB", (string)json["scripts"]![0]!["name"]!);
        var keys = AllKeys(json).ToHashSet();
        Assert.Subset(new HashSet<string> { "app", "version", "os", "dotnet", "windows", "game_windows", "phase", "bot_version", "light", "login", "stage", "message", "gpu", "retries", "failed", "scripts", "name" }, keys);
        Assert.DoesNotContain("character", json.ToJsonString().ToLowerInvariant());
        Assert.DoesNotContain("account", json.ToJsonString().ToLowerInvariant());
        Assert.True(json.ToJsonString().Length < 32 * 1024);
    }

    private static IEnumerable<string> AllKeys(JsonNode? node)
    {
        switch (node)
        {
            case JsonObject obj:
                foreach (var (key, value) in obj)
                {
                    yield return key;
                    foreach (var nested in AllKeys(value))
                    {
                        yield return nested;
                    }
                }
                break;
            case JsonArray array:
                foreach (var item in array)
                {
                    foreach (var nested in AllKeys(item))
                    {
                        yield return nested;
                    }
                }
                break;
        }
    }

    [Fact]
    public void ANoisyHugeScreenshotIsScaledToAtMost1920PixelsAndSevenHundredSixtyEightKilobytes()
    {
        using var bitmap = new Bitmap(3840, 2160);
        var random = new Random(7);
        var noise = new byte[3840 * 2160 * 4];
        random.NextBytes(noise);
        var data = bitmap.LockBits(new Rectangle(0, 0, 3840, 2160), ImageLockMode.WriteOnly, PixelFormat.Format32bppArgb);
        System.Runtime.InteropServices.Marshal.Copy(noise, 0, data.Scan0, noise.Length);
        bitmap.UnlockBits(data);
        using var source = new MemoryStream();
        bitmap.Save(source, ImageFormat.Png);

        var fitted = ScreenshotEncoder.Fit(source.ToArray());

        Assert.NotNull(fitted);
        Assert.True(fitted.Length <= ReportPayload.MaxScreenshotBytes);
        using var result = new Bitmap(new MemoryStream(fitted));
        Assert.True(result.Width <= ScreenshotEncoder.MaxWidth);
        Assert.Equal(ImageFormat.Png.Guid, result.RawFormat.Guid);
    }

    [Fact]
    public void ASmallScreenshotKeepsItsSize()
    {
        using var bitmap = new Bitmap(800, 450);
        using (var graphics = Graphics.FromImage(bitmap))
        {
            graphics.Clear(Color.DarkSlateBlue);
        }
        using var source = new MemoryStream();
        bitmap.Save(source, ImageFormat.Png);

        var fitted = ScreenshotEncoder.Fit(source.ToArray());

        using var result = new Bitmap(new MemoryStream(fitted!));
        Assert.Equal(800, result.Width);
        Assert.Equal(450, result.Height);
    }

    [Fact]
    public void ThePrivacyFileAndOutboxLiveInTheDataFolder()
    {
        var paths = new AppPaths(Path.Combine(Path.GetTempPath(), "osbm-paths"));

        Assert.EndsWith("privacy.json", paths.PrivacyFile);
        Assert.StartsWith(paths.Root, paths.PrivacyFile);
        Assert.EndsWith("outbox", paths.Outbox);
        Assert.EndsWith(Path.Combine("outbox", "failed"), paths.OutboxFailed);
        Assert.Contains("OSB Manager", AppPaths.Default().PrivacyFile);
    }
}
