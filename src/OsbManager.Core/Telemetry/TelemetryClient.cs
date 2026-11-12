using System.Net;
using System.Net.Http.Headers;
using System.Net.Sockets;
using System.Text.Json;

namespace OsbManager.Core.Telemetry;

public enum ApiOutcome
{
    Success,
    HttpError,
    NetworkError,
    Timeout,
    Busy,
    Cancelled,
}

public sealed record ApiResponse(ApiOutcome Outcome, int StatusCode, string? Code, TimeSpan? RetryAfter, byte[] Body)
{
    public static ApiResponse Of(ApiOutcome outcome) => new(outcome, 0, null, null, []);

    public bool Succeeded => Outcome == ApiOutcome.Success;

    public bool IsStatus(int status) => Outcome == ApiOutcome.HttpError && StatusCode == status;
}

/// <summary>
/// The only code that talks to api.osb.lol. Every call is asynchronous, bounded to 15 s, never follows a redirect,
/// keeps no cookies and never throws for a network problem. One request runs at a time.
/// </summary>
public sealed class TelemetryClient : IDisposable
{
    private readonly HttpClient http;
    private readonly Uri baseUrl;
    private readonly TimeProvider time;
    private readonly SemaphoreSlim gate = new(1, 1);

    public TelemetryClient(Uri baseUrl, string userAgent, HttpMessageHandler handler, TimeProvider time)
    {
        if (baseUrl.Scheme != Uri.UriSchemeHttps && !(baseUrl.Scheme == Uri.UriSchemeHttp && baseUrl.IsLoopback))
        {
            throw new ArgumentException("The API address must use https.", nameof(baseUrl));
        }
        this.baseUrl = new Uri(baseUrl.AbsoluteUri.TrimEnd('/') + "/");
        this.time = time;
        http = new HttpClient(handler, disposeHandler: true)
        {
            Timeout = TelemetryLimits.RequestTimeout,
        };
        http.DefaultRequestHeaders.UserAgent.ParseAdd(userAgent);
        http.DefaultRequestHeaders.Accept.Add(new MediaTypeWithQualityHeaderValue("application/json"));
    }

    public static TelemetryClient Create(Uri baseUrl, string userAgent, TimeProvider? time = null)
    {
        var handler = new SocketsHttpHandler
        {
            UseCookies = false,
            AllowAutoRedirect = false,
            ConnectTimeout = TimeSpan.FromSeconds(5),
            PooledConnectionLifetime = TimeSpan.FromMinutes(10),
        };
        return new TelemetryClient(baseUrl, userAgent, handler, time ?? TimeProvider.System);
    }

    public Task<ApiResponse> GetConfigAsync(string version, bool background, CancellationToken ct) =>
        SendAsync(() => new HttpRequestMessage(HttpMethod.Get, Endpoint($"config?app={TelemetryLimits.AppName}&version={Uri.EscapeDataString(version)}")), background, ct);

    public Task<ApiResponse> RegisterAsync(InstallCredentials credentials, string version, string locale, bool characters, bool background, CancellationToken ct) =>
        SendAsync(() => Json(HttpMethod.Post, "installs", new
        {
            install_id = credentials.Id,
            install_key = credentials.Key,
            app = TelemetryLimits.AppName,
            app_version = version,
            os = TelemetryLimits.OsName,
            locale,
            consent = new { usage_version = TelemetryLimits.ConsentVersion, characters },
        }, null), background, ct);

    public Task<ApiResponse> UpdateConsentAsync(InstallCredentials credentials, bool characters, bool background, CancellationToken ct) =>
        SendAsync(() => Json(HttpMethod.Put, "installs/me/consent", new { usage_version = TelemetryLimits.ConsentVersion, characters }, credentials), background, ct);

    public Task<ApiResponse> SendTelemetryAsync(InstallCredentials credentials, byte[] body, CancellationToken ct) =>
        SendBodyAsync("telemetry", credentials, body, ct);

    public Task<ApiResponse> SendDiagnosticsAsync(InstallCredentials credentials, byte[] body, CancellationToken ct) =>
        SendBodyAsync("diagnostics", credentials, body, ct);

    private Task<ApiResponse> SendBodyAsync(string relative, InstallCredentials credentials, byte[] body, CancellationToken ct) =>
        SendAsync(() =>
        {
            var request = Authorized(HttpMethod.Post, relative, credentials);
            request.Content = new ByteArrayContent(body);
            request.Content.Headers.ContentType = new MediaTypeHeaderValue("application/json");
            return request;
        }, background: true, ct);

    public Task<ApiResponse> SendReportAsync(InstallCredentials? credentials, byte[] reportJson, byte[]? screenshot, CancellationToken ct) =>
        SendAsync(() =>
        {
            var request = Authorized(HttpMethod.Post, "reports", credentials);
            var form = new MultipartFormDataContent();
            var report = new ByteArrayContent(reportJson);
            report.Headers.ContentType = new MediaTypeHeaderValue("application/json");
            form.Add(report, "report");
            if (screenshot is not null)
            {
                var image = new ByteArrayContent(screenshot);
                image.Headers.ContentType = new MediaTypeHeaderValue("image/png");
                form.Add(image, "screenshot", "screenshot.png");
            }
            request.Content = form;
            return request;
        }, background: false, ct);

    public Task<ApiResponse> DeleteInstallAsync(InstallCredentials credentials, CancellationToken ct) =>
        SendAsync(() => Authorized(HttpMethod.Delete, "installs/me", credentials), background: false, ct);

    public Task<ApiResponse> ExportAsync(InstallCredentials credentials, CancellationToken ct) =>
        SendAsync(() => Authorized(HttpMethod.Get, "installs/me/export", credentials), background: false, ct);

    public void Dispose()
    {
        http.Dispose();
        gate.Dispose();
    }

    private Uri Endpoint(string relative) => new(baseUrl, relative);

    private HttpRequestMessage Authorized(HttpMethod method, string relative, InstallCredentials? credentials)
    {
        var request = new HttpRequestMessage(method, Endpoint(relative));
        if (credentials is not null)
        {
            request.Headers.TryAddWithoutValidation("Authorization", "Bearer " + credentials.Bearer);
        }
        return request;
    }

    private HttpRequestMessage Json(HttpMethod method, string relative, object body, InstallCredentials? credentials)
    {
        var request = Authorized(method, relative, credentials);
        request.Content = new ByteArrayContent(JsonSerializer.SerializeToUtf8Bytes(body));
        request.Content.Headers.ContentType = new MediaTypeHeaderValue("application/json");
        return request;
    }

    private async Task<ApiResponse> SendAsync(Func<HttpRequestMessage> build, bool background, CancellationToken ct)
    {
        if (background)
        {
            if (!await gate.WaitAsync(0, CancellationToken.None).ConfigureAwait(false))
            {
                return ApiResponse.Of(ApiOutcome.Busy);
            }
        }
        else
        {
            try
            {
                await gate.WaitAsync(ct).ConfigureAwait(false);
            }
            catch (OperationCanceledException)
            {
                return ApiResponse.Of(ApiOutcome.Cancelled);
            }
        }
        try
        {
            return await ExecuteAsync(build, ct).ConfigureAwait(false);
        }
        finally
        {
            gate.Release();
        }
    }

    private async Task<ApiResponse> ExecuteAsync(Func<HttpRequestMessage> build, CancellationToken ct)
    {
        using var timeout = new CancellationTokenSource(TelemetryLimits.RequestTimeout, time);
        using var linked = CancellationTokenSource.CreateLinkedTokenSource(ct, timeout.Token);
        try
        {
            using var request = build();
            using var response = await http.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, linked.Token).ConfigureAwait(false);
            var body = await ReadBodyAsync(response, linked.Token).ConfigureAwait(false);
            var status = (int)response.StatusCode;
            if (status is >= 200 and < 300)
            {
                return new ApiResponse(ApiOutcome.Success, status, null, null, body);
            }
            return new ApiResponse(ApiOutcome.HttpError, status, ProblemCode(body), RetryAfter(response), body);
        }
        catch (OperationCanceledException)
        {
            return ApiResponse.Of(ct.IsCancellationRequested ? ApiOutcome.Cancelled : ApiOutcome.Timeout);
        }
        catch (Exception e) when (e is HttpRequestException or IOException or SocketException or InvalidOperationException)
        {
            return ApiResponse.Of(ApiOutcome.NetworkError);
        }
    }

    private static async Task<byte[]> ReadBodyAsync(HttpResponseMessage response, CancellationToken ct)
    {
        await using var stream = await response.Content.ReadAsStreamAsync(ct).ConfigureAwait(false);
        using var buffer = new MemoryStream();
        var chunk = new byte[8192];
        int read;
        var limit = response.RequestMessage?.RequestUri?.AbsolutePath.EndsWith("/export", StringComparison.Ordinal) == true
            ? 64 * 1024 * 1024
            : TelemetryLimits.MaxResponseBytes;
        while ((read = await stream.ReadAsync(chunk, ct).ConfigureAwait(false)) > 0)
        {
            if (buffer.Length + read > limit)
            {
                break;
            }
            buffer.Write(chunk, 0, read);
        }
        return buffer.ToArray();
    }

    private static string? ProblemCode(byte[] body)
    {
        if (body.Length == 0)
        {
            return null;
        }
        try
        {
            using var document = JsonDocument.Parse(body, new JsonDocumentOptions { MaxDepth = 4 });
            return document.RootElement.ValueKind == JsonValueKind.Object
                && document.RootElement.TryGetProperty("code", out var code)
                && code.ValueKind == JsonValueKind.String
                && code.GetString() is { Length: <= 40 } text
                    ? text
                    : null;
        }
        catch (JsonException)
        {
            return null;
        }
    }

    private static TimeSpan? RetryAfter(HttpResponseMessage response)
    {
        var header = response.Headers.RetryAfter;
        if (header?.Delta is { } delta)
        {
            return delta;
        }
        if (header?.Date is { } date)
        {
            return date - DateTimeOffset.UtcNow;
        }
        return null;
    }
}
