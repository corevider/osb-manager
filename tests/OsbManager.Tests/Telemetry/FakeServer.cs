using System.Net;
using System.Text;

namespace OsbManager.Tests.Telemetry;

internal sealed record SeenRequest(
    DateTimeOffset At,
    string Method,
    string Path,
    string Query,
    string? Authorization,
    string? UserAgent,
    string ContentType,
    byte[] Body,
    int ThreadId,
    bool HadSynchronizationContext)
{
    public string BodyText => Encoding.UTF8.GetString(Body);

    public string Endpoint => $"{Method} {Path}";
}

internal sealed class FakeServer : HttpMessageHandler
{
    public const string ConfigEnabled = """{"schema":1,"telemetry":{"enabled":true,"interval_s":600},"reports":{"enabled":true,"screenshots":true},"client_ok":true,"message":null}""";

    private readonly TimeProvider time;
    private readonly object sync = new();
    private readonly List<SeenRequest> seen = [];
    private readonly Dictionary<string, Func<SeenRequest, CancellationToken, Task<HttpResponseMessage>>> routes = new();
    private int inFlight;

    public FakeServer(TimeProvider time)
    {
        this.time = time;
        Route("GET /v1/config", _ => Json(HttpStatusCode.OK, ConfigEnabled));
        Route("POST /v1/installs", _ => Json(HttpStatusCode.Created, """{"install_id":"x","status":"quarantined"}"""));
        Route("PUT /v1/installs/me/consent", _ => new HttpResponseMessage(HttpStatusCode.NoContent));
        Route("POST /v1/telemetry", _ => Json(HttpStatusCode.Accepted, """{"accepted":1,"next_after_s":600}"""));
        Route("POST /v1/reports", _ => Json(HttpStatusCode.Created, """{"code":"R-7K3Q9XAB","screenshot":"none"}"""));
        Route("DELETE /v1/installs/me", _ => new HttpResponseMessage(HttpStatusCode.NoContent));
        Route("GET /v1/installs/me/export", _ => Json(HttpStatusCode.OK, """{"install":{}}"""));
    }

    public int InFlight => Volatile.Read(ref inFlight);

    public IReadOnlyList<SeenRequest> Requests
    {
        get { lock (sync) { return [.. seen]; } }
    }

    public IReadOnlyList<SeenRequest> To(string endpoint) => Requests.Where(r => r.Endpoint == endpoint).ToList();

    public void Route(string endpoint, Func<SeenRequest, HttpResponseMessage> respond) =>
        routes[endpoint] = (request, _) => Task.FromResult(respond(request));

    public void RouteAsync(string endpoint, Func<SeenRequest, CancellationToken, Task<HttpResponseMessage>> respond) => routes[endpoint] = respond;

    public void RouteSequence(string endpoint, params Func<HttpResponseMessage>[] responses)
    {
        var index = 0;
        routes[endpoint] = (_, _) =>
        {
            var current = responses[Math.Min(Interlocked.Increment(ref index) - 1, responses.Length - 1)];
            return Task.FromResult(current());
        };
    }

    public void Hang(string endpoint) => routes[endpoint] = async (_, ct) =>
    {
        await Task.Delay(Timeout.InfiniteTimeSpan, ct);
        return new HttpResponseMessage(HttpStatusCode.OK);
    };

    public void HangEverything()
    {
        foreach (var key in routes.Keys.ToList())
        {
            Hang(key);
        }
    }

    public void FailEverything(HttpStatusCode status)
    {
        foreach (var key in routes.Keys.ToList())
        {
            Route(key, _ => new HttpResponseMessage(status));
        }
    }

    public static HttpResponseMessage Json(HttpStatusCode status, string body) =>
        new(status) { Content = new StringContent(body, Encoding.UTF8, "application/json") };

    public static HttpResponseMessage Problem(HttpStatusCode status, string code, int? retryAfterSeconds = null)
    {
        var response = Json(status, $$"""{"type":"https://osb.lol/errors/{{code}}","title":"x","status":{{(int)status}},"code":"{{code}}"}""");
        if (retryAfterSeconds is { } seconds)
        {
            response.Headers.RetryAfter = new System.Net.Http.Headers.RetryConditionHeaderValue(TimeSpan.FromSeconds(seconds));
        }
        return response;
    }

    protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
    {
        var body = request.Content is null ? [] : await request.Content.ReadAsByteArrayAsync(cancellationToken);
        var entry = new SeenRequest(
            time.GetUtcNow(),
            request.Method.Method,
            request.RequestUri!.AbsolutePath,
            request.RequestUri.Query,
            request.Headers.Authorization is { } auth ? auth.ToString() : request.Headers.TryGetValues("Authorization", out var values) ? values.First() : null,
            request.Headers.UserAgent.ToString(),
            request.Content?.Headers.ContentType?.MediaType ?? "",
            body,
            Environment.CurrentManagedThreadId,
            SynchronizationContext.Current is not null);
        lock (sync)
        {
            seen.Add(entry);
        }
        Interlocked.Increment(ref inFlight);
        try
        {
            if (!routes.TryGetValue(entry.Endpoint, out var route))
            {
                return new HttpResponseMessage(HttpStatusCode.NotFound);
            }
            return await route(entry, cancellationToken);
        }
        finally
        {
            Interlocked.Decrement(ref inFlight);
        }
    }
}
