using System.Text.Json;
using System.Text.Json.Nodes;
using OsbManager.Core.Telemetry;

namespace OsbManager.Tests.Telemetry;

public class GoldenPayloadTests
{
    private const string GoldenRegister = """
        {
          "install_id": "3f0b2c1e-7d4a-4c55-9a51-2b8f7e4c9d10",
          "install_key": "kq3Vt3N1rA8b0bq3QyU2sQj3XcYw8m3cXzq8b6F0wJs",
          "app": "osb",
          "app_version": "2.0.4",
          "os": "windows",
          "locale": "en",
          "consent": { "usage_version": 2, "characters": false }
        }
        """;

    private const string GoldenTelemetry = """
        {
          "schema": 1,
          "app_version": "1.2.0",
          "accounts": [
            {
              "slot": "9c41e0a7b2d3f615",
              "state": "hunting",
              "level": 87,
              "gold": "123456789",
              "hp_pct": 92,
              "mp_pct": 70,
              "scrolls": { "return": 12, "reverse": 3 },
              "bot_version": "2.0.4",
              "session": { "key": "a1b2c3d4e5f60718", "ms": 5400000, "kills": 812, "deaths": 1, "xp": "48211933", "gold": "2210450", "sox": 0 }
            },
            {
              "slot": "07d2be6a91c4f033",
              "state": "offline",
              "bot_version": null
            }
          ]
        }
        """;

    private const string GoldenTelemetryWithCharacter = """
        {
          "schema": 1,
          "app_version": "2.0.4",
          "accounts": [
            {
              "slot": "5e8a1c0f9b7d2346",
              "state": "town",
              "level": 64,
              "gold": "9800000",
              "hp_pct": 100,
              "mp_pct": 100,
              "scrolls": { "return": 4, "reverse": 0 },
              "bot_version": "2.0.4",
              "character": { "name": "ExampleHero", "server": "ExampleServer" },
              "session": { "key": "0f1e2d3c4b5a6978", "ms": 1200000, "kills": 95, "deaths": 0, "xp": "3100200", "gold": "410000", "sox": 1 }
            }
          ]
        }
        """;

    private const string GoldenReport = """
        {
          "schema": 1,
          "kind": "bug",
          "app": "manager-mac",
          "app_version": "1.0.0",
          "os": "macos",
          "locale": "tr",
          "description": "Auto login stops at the server list.",
          "diagnostics": { "app": "OSB Manager", "windows": 3, "login": { "stage": "server-list", "message": "timeout" } }
        }
        """;

    private static void AssertSameShape(JsonNode golden, JsonNode actual, string path)
    {
        if (golden is null || actual is null)
        {
            return;
        }
        Assert.Equal(golden.GetValueKind() is JsonValueKind.True or JsonValueKind.False ? JsonValueKind.True : golden.GetValueKind(),
            actual.GetValueKind() is JsonValueKind.True or JsonValueKind.False ? JsonValueKind.True : actual.GetValueKind());
        if (golden is JsonObject goldenObject)
        {
            var actualObject = (JsonObject)actual;
            foreach (var (name, value) in actualObject)
            {
                Assert.True(goldenObject.ContainsKey(name), $"{path}.{name} is not in the golden payload");
                if (value is not null && goldenObject[name] is { } expected)
                {
                    AssertSameShape(expected, value, $"{path}.{name}");
                }
            }
            foreach (var (name, value) in goldenObject)
            {
                if (value is not null)
                {
                    Assert.True(actualObject.ContainsKey(name) && actualObject[name] is not null, $"{path}.{name} is missing");
                }
            }
        }
    }

    [Fact]
    public async Task C15_RegisterBodyMatchesAppendixC1()
    {
        using var kit = new TelemetryKit();
        kit.Store.Grant(false);
        kit.Publish("account-a", TelemetryKit.Hunting());

        await kit.RunFor(TimeSpan.FromMinutes(5));

        var body = JsonNode.Parse(kit.Server.To("POST /v1/installs")[0].BodyText)!;
        AssertSameShape(JsonNode.Parse(GoldenRegister)!, body, "register");
        Assert.Equal("manager-win", (string)body["app"]!);
        Assert.Equal("windows", (string)body["os"]!);
        Assert.Equal(43, ((string)body["install_key"]!).Length);
        Assert.Equal(2, (int)body["consent"]!["usage_version"]!);
        Assert.True(Guid.TryParseExact((string)body["install_id"]!, "D", out var id) && id.ToString()[14] == '4');
    }

    [Fact]
    public void C15_TelemetryBodyMatchesAppendixC2()
    {
        var time = new FakeTimeProvider();
        var builder = new TelemetryPayloadBuilder("1.2.0", time);
        var key = new byte[32];
        var snapshots = new[]
        {
            new AccountSnapshot("account-a", "ExampleServer", TelemetryKit.Hunting(), time.GetUtcNow()),
            new AccountSnapshot("account-b", "", new OsbManager.Core.Status.BotStatus { Phase = "signed-out" }, time.GetUtcNow().AddSeconds(-5)),
        };
        builder.Build(snapshots, key, includeCharacters: false)!.Commit();

        var batch = builder.Build([snapshots[0]], key, includeCharacters: false)!;
        var accounts = JsonNode.Parse(batch.Body)!["accounts"]!.AsArray();

        Assert.Equal(2, accounts.Count);
        var golden = JsonNode.Parse(GoldenTelemetry)!;
        AssertSameShape(golden["accounts"]![0]!, accounts[0]!, "accounts[0]");
        AssertSameShape(golden["accounts"]![1]!, accounts[1]!, "accounts[1]");
        var root = JsonNode.Parse(batch.Body)!;
        Assert.Equal(1, (int)root["schema"]!);
        Assert.Equal("1.2.0", (string)root["app_version"]!);
        Assert.Equal("offline", (string)accounts[1]!["state"]!);
        Assert.All(accounts, account => Assert.Matches("^[0-9a-f]{16}$", (string)account!["slot"]!));
        Assert.Matches("^[0-9a-f]{16}$", (string)accounts[0]!["session"]!["key"]!);
    }

    [Fact]
    public void C15_TelemetryBodyWithCharacterConsentMatchesAppendixC3()
    {
        var time = new FakeTimeProvider();
        var status = TelemetryKit.Hunting("ExampleHero") with { Hunting = false, TownTrip = true };
        var batch = new TelemetryPayloadBuilder("2.0.4", time).Build([new AccountSnapshot("account-a", "ExampleServer", status, time.GetUtcNow())], new byte[32], includeCharacters: true)!;

        var account = JsonNode.Parse(batch.Body)!["accounts"]![0]!;

        AssertSameShape(JsonNode.Parse(GoldenTelemetryWithCharacter)!["accounts"]![0]!, account, "accounts[0]");
        Assert.Equal("town", (string)account["state"]!);
        Assert.Equal("ExampleHero", (string)account["character"]!["name"]!);
        Assert.Equal("ExampleServer", (string)account["character"]!["server"]!);
    }

    [Fact]
    public void C15_NumbersThatTheServerWantsAsStringsAreStrings()
    {
        var time = new FakeTimeProvider();
        var batch = new TelemetryPayloadBuilder("1.2.0", time).Build([new AccountSnapshot("a", "", TelemetryKit.Hunting(), time.GetUtcNow())], new byte[32], false)!;

        var account = JsonNode.Parse(batch.Body)!["accounts"]![0]!;

        Assert.Equal(JsonValueKind.String, account["gold"]!.GetValueKind());
        Assert.Equal(JsonValueKind.String, account["session"]!["xp"]!.GetValueKind());
        Assert.Equal(JsonValueKind.String, account["session"]!["gold"]!.GetValueKind());
        Assert.Equal(JsonValueKind.Number, account["level"]!.GetValueKind());
        Assert.Equal(JsonValueKind.Number, account["session"]!["ms"]!.GetValueKind());
    }

    [Fact]
    public void C15_ReportBodyMatchesAppendixC4()
    {
        var diagnostics = ReportDiagnostics.Build("1.0.0", "10.0.26300", ".NET 10.0.0", [], []);

        var json = ReportPayload.Build(ReportKind.Bug, "Auto login stops at the server list.", diagnostics, "1.0.0", "tr");

        var body = JsonNode.Parse(json)!;
        var golden = JsonNode.Parse(GoldenReport)!;
        foreach (var (name, value) in body.AsObject())
        {
            Assert.True(golden.AsObject().ContainsKey(name), name);
            Assert.Equal(golden[name]!.GetValueKind(), value!.GetValueKind());
        }
        Assert.Equal(golden.AsObject().Count, body.AsObject().Count);
        Assert.Equal("manager-win", (string)body["app"]!);
        Assert.Equal("windows", (string)body["os"]!);
        Assert.Equal("bug", (string)body["kind"]!);
        Assert.Equal(1, (int)body["schema"]!);
    }
}
