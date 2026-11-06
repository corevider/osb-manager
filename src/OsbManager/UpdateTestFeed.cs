#if DEBUG
using System.Net;
using System.Net.Http.Headers;
using OsbManager.Core.Updates;

namespace OsbManager;

/// <summary>
/// Debug builds only: answers the updater's GitHub requests from a local folder, so the whole update flow can be run
/// without the network. The asset download answers with a redirect to the release asset host first, as GitHub does.
/// </summary>
internal sealed class UpdateTestFeed(string folder) : HttpMessageHandler
{
    private const string AssetPrefix = "/" + UpdateSource.Repository + "/releases/download/";

    public int Requests { get; private set; }

    protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
    {
        Requests++;
        var url = request.RequestUri!;
        if (url.Host == "api.github.com" && url.AbsolutePath == $"/repos/{UpdateSource.Repository}/releases/latest")
        {
            return Task.FromResult(File(Path.Combine(folder, "latest.json")));
        }
        if (url.Host == "github.com" && url.AbsolutePath.StartsWith(AssetPrefix, StringComparison.Ordinal))
        {
            var response = new HttpResponseMessage(HttpStatusCode.Found);
            response.Headers.Location = new Uri("https://release-assets.githubusercontent.com/test/" + url.AbsolutePath[AssetPrefix.Length..]);
            return Task.FromResult(response);
        }
        if (url.Host == "release-assets.githubusercontent.com" && url.AbsolutePath.StartsWith("/test/", StringComparison.Ordinal))
        {
            return Task.FromResult(File(Path.Combine(folder, Path.GetFileName(url.AbsolutePath))));
        }
        return Task.FromResult(new HttpResponseMessage(HttpStatusCode.NotFound));
    }

    private static HttpResponseMessage File(string path)
    {
        if (!System.IO.File.Exists(path))
        {
            return new HttpResponseMessage(HttpStatusCode.NotFound);
        }
        var content = new StreamContent(System.IO.File.OpenRead(path));
        content.Headers.ContentType = new MediaTypeHeaderValue("application/octet-stream");
        return new HttpResponseMessage(HttpStatusCode.OK) { Content = content };
    }
}

internal static class UpdateTestSwitches
{
    public static string? Feed { get; } = Environment.GetEnvironmentVariable("OSBMANAGER_TEST_UPDATE_FEED");

    public static string? Key { get; } = Environment.GetEnvironmentVariable("OSBMANAGER_TEST_UPDATE_KEY");

    public static string? Version { get; } = Environment.GetEnvironmentVariable("OSBMANAGER_TEST_UPDATE_VERSION");

    public static TimeSpan? FirstDelay { get; } = int.TryParse(Environment.GetEnvironmentVariable("OSBMANAGER_TEST_UPDATE_DELAY_SECONDS"), out var seconds) && seconds >= 0 ? TimeSpan.FromSeconds(seconds) : null;

    public static bool InstallWhenOffered { get; } = Environment.GetEnvironmentVariable("OSBMANAGER_TEST_UPDATE_INSTALL") == "1";
}
#endif
