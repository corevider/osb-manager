using System.Net;
using System.Net.Http.Headers;

namespace OsbManager.Core.Updates;

/// <summary>
/// GET requests for the updater: HTTPS to allowed hosts only, redirects followed by hand and checked one by one,
/// no cookies, no credentials, a fixed User-Agent, a time limit and a size limit on every request.
/// </summary>
public sealed class UpdateHttp : IDisposable
{
    public const int MaxRedirects = 5;

    private readonly HttpClient client;
    private readonly UpdateHosts hosts;
    private readonly string userAgent;

    public UpdateHttp(HttpMessageHandler handler, UpdateHosts hosts, string userAgent)
    {
        client = new HttpClient(handler, disposeHandler: true) { Timeout = Timeout.InfiniteTimeSpan };
        this.hosts = hosts;
        this.userAgent = userAgent;
    }

    public static UpdateHttp Create(string userAgent) => new(CreateHandler(), UpdateHosts.GitHub, userAgent);

    public static SocketsHttpHandler CreateHandler() => new()
    {
        AllowAutoRedirect = false,
        UseCookies = false,
        Credentials = null,
        PreAuthenticate = false,
        AutomaticDecompression = DecompressionMethods.None,
        ConnectTimeout = TimeSpan.FromSeconds(15),
        PooledConnectionLifetime = TimeSpan.FromMinutes(5),
    };

    public async Task<byte[]> GetBytesAsync(Uri url, long limit, TimeSpan timeout, string accept, CancellationToken cancellation)
    {
        using var buffer = new MemoryStream();
        await DownloadAsync(url, buffer, limit, timeout, accept, cancellation).ConfigureAwait(false);
        return buffer.ToArray();
    }

    public async Task<long> DownloadAsync(Uri url, Stream destination, long limit, TimeSpan timeout, string accept, CancellationToken cancellation)
    {
        using var timer = new CancellationTokenSource(timeout);
        using var linked = CancellationTokenSource.CreateLinkedTokenSource(cancellation, timer.Token);
        try
        {
            using var response = await SendAsync(url, accept, linked.Token).ConfigureAwait(false);
            if (response.Content.Headers.ContentLength is { } length && length > limit)
            {
                throw new UpdateException($"{url.Host} offered {length} bytes, more than the {limit} allowed.");
            }
            await using var body = await response.Content.ReadAsStreamAsync(linked.Token).ConfigureAwait(false);
            return await CopyLimitedAsync(body, destination, limit, url, linked.Token).ConfigureAwait(false);
        }
        catch (OperationCanceledException) when (timer.IsCancellationRequested && !cancellation.IsCancellationRequested)
        {
            throw new UpdateException($"The request to {url.Host} timed out after {timeout.TotalSeconds:0} s.");
        }
        catch (HttpRequestException e)
        {
            throw new UpdateException($"The request to {url.Host} failed: {e.Message}", e);
        }
        catch (IOException e) when (e is not FileNotFoundException)
        {
            throw new UpdateException($"Reading from {url.Host} failed: {e.Message}", e);
        }
    }

    private async Task<HttpResponseMessage> SendAsync(Uri url, string accept, CancellationToken cancellation)
    {
        var current = url;
        for (var hop = 0; ; hop++)
        {
            if (!hosts.Allows(current))
            {
                throw new UpdateException(hop == 0 ? $"Refused to contact {Describe(current)}." : $"Refused a redirect to {Describe(current)}.");
            }
            using var request = new HttpRequestMessage(HttpMethod.Get, current);
            request.Headers.UserAgent.ParseAdd(userAgent);
            request.Headers.Accept.Add(MediaTypeWithQualityHeaderValue.Parse(accept));
            if (current.IdnHost == "api.github.com")
            {
                request.Headers.Add("X-GitHub-Api-Version", "2022-11-28");
            }
            var response = await client.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, cancellation).ConfigureAwait(false);
            if (IsRedirect(response.StatusCode))
            {
                var location = response.Headers.Location;
                response.Dispose();
                if (location is null)
                {
                    throw new UpdateException($"{current.Host} sent a redirect without a target.");
                }
                if (hop >= MaxRedirects)
                {
                    throw new UpdateException($"Too many redirects from {url.Host}.");
                }
                current = location.IsAbsoluteUri ? location : new Uri(current, location);
                continue;
            }
            if (response.StatusCode != HttpStatusCode.OK)
            {
                var status = (int)response.StatusCode;
                response.Dispose();
                throw new UpdateException($"{current.Host} answered HTTP {status}.");
            }
            return response;
        }
    }

    private static async Task<long> CopyLimitedAsync(Stream body, Stream destination, long limit, Uri url, CancellationToken cancellation)
    {
        var buffer = new byte[81920];
        long total = 0;
        while (true)
        {
            var read = await body.ReadAsync(buffer, cancellation).ConfigureAwait(false);
            if (read == 0)
            {
                return total;
            }
            total += read;
            if (total > limit)
            {
                throw new UpdateException($"{url.Host} sent more than the {limit} bytes allowed.");
            }
            await destination.WriteAsync(buffer.AsMemory(0, read), cancellation).ConfigureAwait(false);
        }
    }

    private static bool IsRedirect(HttpStatusCode status) => status is HttpStatusCode.MovedPermanently or HttpStatusCode.Found
        or HttpStatusCode.SeeOther or HttpStatusCode.TemporaryRedirect or HttpStatusCode.PermanentRedirect;

    private static string Describe(Uri url) => url.IsAbsoluteUri ? $"{url.Scheme}://{url.Authority}" : "a relative address";

    public void Dispose() => client.Dispose();
}
