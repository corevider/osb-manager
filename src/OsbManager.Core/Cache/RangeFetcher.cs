using System.Net;
using System.Net.Http.Headers;

namespace OsbManager.Core.Cache;

public sealed record FetchedRange(byte[] Bytes, long Total);

public interface IRangeFetcher
{
    Task<FetchedRange> FetchAsync(string url, ByteRange range, CancellationToken cancellation);
}

/// <summary>Downloads one byte range and accepts only an exact 206 answer for it.</summary>
public sealed class HttpRangeFetcher : IRangeFetcher, IDisposable
{
    private readonly HttpClient client;

    public HttpRangeFetcher(string userAgent)
    {
        var handler = new SocketsHttpHandler
        {
            AutomaticDecompression = DecompressionMethods.None,
            PooledConnectionLifetime = TimeSpan.FromMinutes(10),
            ConnectTimeout = TimeSpan.FromSeconds(15),
            EnableMultipleHttp2Connections = true,
        };
        client = new HttpClient(handler)
        {
            Timeout = TimeSpan.FromSeconds(90),
            DefaultRequestVersion = HttpVersion.Version20,
            DefaultVersionPolicy = HttpVersionPolicy.RequestVersionOrLower,
        };
        client.DefaultRequestHeaders.UserAgent.ParseAdd(userAgent);
    }

    public async Task<FetchedRange> FetchAsync(string url, ByteRange range, CancellationToken cancellation)
    {
        using var request = new HttpRequestMessage(HttpMethod.Get, url);
        request.Headers.Range = new RangeHeaderValue(range.Start, range.End);
        using var response = await client.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, cancellation).ConfigureAwait(false);
        var contentRange = response.Content.Headers.ContentRange;
        if (response.StatusCode != HttpStatusCode.PartialContent
            || contentRange is not { From: { } from, To: { } to, Length: { } total }
            || from != range.Start
            || to != range.End
            || response.Content.Headers.ContentEncoding.Count > 0)
        {
            throw new HttpRequestException($"Unexpected answer {(int)response.StatusCode} for {range.Start}-{range.End}.");
        }
        var bytes = new byte[range.Length];
        await using var stream = await response.Content.ReadAsStreamAsync(cancellation).ConfigureAwait(false);
        var read = 0;
        while (read < bytes.Length)
        {
            var count = await stream.ReadAsync(bytes.AsMemory(read), cancellation).ConfigureAwait(false);
            if (count == 0)
            {
                throw new HttpRequestException("The download ended early.");
            }
            read += count;
        }
        return new FetchedRange(bytes, total);
    }

    public void Dispose() => client.Dispose();
}
