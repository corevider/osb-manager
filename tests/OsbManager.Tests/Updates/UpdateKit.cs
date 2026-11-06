using System.Net;
using System.Security.Cryptography;
using System.Text;
using OsbManager.Core.Updates;

namespace OsbManager.Tests.Updates;

internal sealed class TestKey : IDisposable
{
    private readonly ECDsa key = ECDsa.Create(ECCurve.NamedCurves.nistP256);

    public string PublicKey => Convert.ToBase64String(key.ExportSubjectPublicKeyInfo());

    public byte[] Sign(byte[] data) => Encoding.ASCII.GetBytes(Convert.ToBase64String(key.SignData(data, HashAlgorithmName.SHA256)) + "\n");

    public void Dispose() => key.Dispose();
}

internal sealed record SeenUpdateRequest(Uri Url, string? UserAgent, string? Cookie, string? Authorization, string Accept);

/// <summary>A stand-in for GitHub: answers by full URL and records every request.</summary>
internal sealed class FakeGitHub : HttpMessageHandler
{
    public const string Tag = "v1.0.3";
    public const string ApiUrl = "https://api.github.com/repos/corevider/osb-manager/releases/latest";

    private readonly Dictionary<string, Func<CancellationToken, Task<HttpResponseMessage>>> routes = new(StringComparer.Ordinal);
    private readonly List<SeenUpdateRequest> seen = [];
    private readonly object sync = new();

    public IReadOnlyList<SeenUpdateRequest> Seen
    {
        get { lock (sync) { return [.. seen]; } }
    }

    public static string AssetUrl(string name, string tag = Tag) => $"https://github.com/corevider/osb-manager/releases/download/{tag}/{name}";

    public static string StorageUrl(string name) => $"https://release-assets.githubusercontent.com/github-production-release-asset/1/{name}?sig=x";

    public void Route(string url, Func<CancellationToken, Task<HttpResponseMessage>> answer) => routes[url] = answer;

    public void Route(string url, Func<HttpResponseMessage> answer) => routes[url] = _ => Task.FromResult(answer());

    public void Bytes(string url, byte[] body) => Route(url, () => Ok(body));

    public void Redirect(string from, string to, HttpStatusCode status = HttpStatusCode.Found) => Route(from, () =>
    {
        var response = new HttpResponseMessage(status);
        response.Headers.Location = new Uri(to, UriKind.RelativeOrAbsolute);
        return response;
    });

    /// <summary>Publishes an asset the way GitHub does: the github.com address redirects to the storage host.</summary>
    public void Asset(string name, byte[] body, string tag = Tag)
    {
        Redirect(AssetUrl(name, tag), StorageUrl(name));
        Bytes(StorageUrl(name), body);
    }

    public void Release(string tag, string title, params string[] assets)
    {
        var list = string.Join(",", assets.Select(a => $$"""{"name":"{{a}}","browser_download_url":"https://evil.example/{{a}}","size":1}"""));
        Bytes(ApiUrl, Encoding.UTF8.GetBytes($$"""{"tag_name":"{{tag}}","name":{{System.Text.Json.JsonSerializer.Serialize(title)}},"draft":false,"prerelease":false,"assets":[{{list}}]}"""));
    }

    public static HttpResponseMessage Ok(byte[] body) => new(HttpStatusCode.OK) { Content = new ByteArrayContent(body) };

    protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
    {
        var url = request.RequestUri!;
        lock (sync)
        {
            seen.Add(new SeenUpdateRequest(
                url,
                request.Headers.UserAgent.ToString(),
                request.Headers.TryGetValues("Cookie", out var cookie) ? string.Join(";", cookie) : null,
                request.Headers.Authorization?.ToString(),
                request.Headers.Accept.ToString()));
        }
        return routes.TryGetValue(url.AbsoluteUri, out var answer)
            ? answer(cancellationToken)
            : Task.FromResult(new HttpResponseMessage(HttpStatusCode.NotFound));
    }
}

/// <summary>A signed release for one platform, published to a <see cref="FakeGitHub"/>.</summary>
internal sealed class FakeRelease
{
    public FakeRelease(string version = "1.0.3", int zipBytes = 4096, UpdatePlatform? platform = null)
    {
        Platform = platform ?? UpdatePlatform.WindowsX64;
        Version = version;
        Zip = new byte[zipBytes];
        new Random(7).NextBytes(Zip);
    }

    public UpdatePlatform Platform { get; }

    public string Version { get; set; }

    public byte[] Zip { get; set; }

    public byte[] Manifest() => Manifest(Version, Zip.Length, Convert.ToHexStringLower(SHA256.HashData(Zip)));

    public byte[] Manifest(string version, long size, string sha256, string? platform = null, string? asset = null) => Encoding.UTF8.GetBytes(
        $$"""{"format":1,"product":"osb-manager","platform":"{{platform ?? Platform.Name}}","version":"{{version}}","asset":"{{asset ?? Platform.ZipName}}","size":{{size}},"sha256":"{{sha256}}"}""" + "\n");

    public void Publish(FakeGitHub github, TestKey key, byte[]? manifest = null, byte[]? signature = null, string title = "OSB Manager 1.0.3")
    {
        manifest ??= Manifest();
        github.Release(FakeGitHub.Tag, title, Platform.ZipName, Platform.ManifestName, Platform.SignatureName);
        github.Asset(Platform.ManifestName, manifest);
        github.Asset(Platform.SignatureName, signature ?? key.Sign(manifest));
        github.Asset(Platform.ZipName, Zip);
    }
}

internal static class UpdateKit
{
    public static UpdateChecker Checker(FakeGitHub github, string current = "1.0.2", UpdatePlatform? platform = null, params string[] keys) =>
        new(new UpdateHttp(github, UpdateHosts.GitHub, "OSBManager/1.0.2 (Windows)"), platform ?? UpdatePlatform.WindowsX64,
            UpdateVersion.TryParse(current, out var version) ? version : throw new ArgumentException(current), new UpdateSignature(keys))
        {
            MetadataLimit = TimeSpan.FromSeconds(5),
            DownloadLimit = TimeSpan.FromSeconds(5),
        };

    public static string RepositoryRoot()
    {
        var directory = new DirectoryInfo(AppContext.BaseDirectory);
        while (directory is not null && !File.Exists(Path.Combine(directory.FullName, "OsbManager.slnx")))
        {
            directory = directory.Parent;
        }
        return directory?.FullName ?? throw new InvalidOperationException("The repository root was not found.");
    }
}
