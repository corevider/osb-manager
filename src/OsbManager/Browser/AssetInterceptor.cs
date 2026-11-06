using Microsoft.Web.WebView2.Core;
using OsbManager.Core;
using OsbManager.Core.Cache;

namespace OsbManager.Browser;

/// <summary>
/// Answers the game's pack range requests from the shared cache. Requests it does not recognise, and any
/// failure, are left alone so the browser loads them itself.
/// </summary>
internal sealed class AssetInterceptor
{
    private readonly CoreWebView2Environment environment;
    private readonly SharedAssetCache cache;
    private readonly AppLog log;
    private long lastWarning;

    public AssetInterceptor(CoreWebView2Environment environment, SharedAssetCache cache, AppLog log)
    {
        this.environment = environment;
        this.cache = cache;
        this.log = log;
    }

    public void Attach(CoreWebView2 core)
    {
        core.AddWebResourceRequestedFilter(AssetUrl.PackFilter, CoreWebView2WebResourceContext.All, CoreWebView2WebResourceRequestSourceKinds.All);
        core.WebResourceRequested += OnWebResourceRequested;
    }

    private async void OnWebResourceRequested(object? sender, CoreWebView2WebResourceRequestedEventArgs e)
    {
        CoreWebView2Deferral? deferral = null;
        try
        {
            var request = e.Request;
            if (request.Method != "GET"
                || !AssetUrl.TryGetPackName(request.Uri, out var pack)
                || !request.Headers.Contains("Range")
                || !ByteRange.TryParseHeader(request.Headers.GetHeader("Range"), out var range))
            {
                return;
            }
            deferral = e.GetDeferral();
            var cached = await cache.GetAsync(request.Uri, pack, range);
            if (cached is null)
            {
                return;
            }
            var headers = string.Join("\r\n",
                "Content-Type: application/octet-stream",
                $"Content-Length: {range.Length}",
                $"Content-Range: bytes {range.Start}-{range.End}/{cached.Total}",
                "Accept-Ranges: bytes",
                "Cache-Control: no-store");
            e.Response = environment.CreateWebResourceResponse(new MemoryStream(cached.Bytes, writable: false), 206, "Partial Content", headers);
        }
        catch (Exception exception)
        {
            Warn(exception);
        }
        finally
        {
            try
            {
                deferral?.Complete();
            }
            catch (Exception exception)
            {
                Warn(exception);
            }
        }
    }

    private void Warn(Exception exception)
    {
        var now = Environment.TickCount64;
        if (now - lastWarning > 10_000)
        {
            lastWarning = now;
            log.Warn($"Shared cache skipped a request: {exception.Message}");
        }
    }
}
