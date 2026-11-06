using System.Net;
using OsbManager.Core.Updates;

namespace OsbManager.Tests.Updates;

public class UpdateHttpTests
{
    private const string Asset = "https://github.com/corevider/osb-manager/releases/download/v1.0.3/a.bin";

    private static UpdateHttp Http(FakeGitHub github) => new(github, UpdateHosts.GitHub, "OSBManager/1.0.2 (Windows)");

    private static Task<byte[]> Get(UpdateHttp http, string url, long limit = 1000, int timeoutMs = 5000) =>
        http.GetBytesAsync(new Uri(url), limit, TimeSpan.FromMilliseconds(timeoutMs), "application/octet-stream", CancellationToken.None);

    [Theory]
    [InlineData("https://api.github.com/x", true)]
    [InlineData("https://github.com/x", true)]
    [InlineData("https://release-assets.githubusercontent.com/x", true)]
    [InlineData("https://objects.githubusercontent.com/x", true)]
    [InlineData("https://GitHub.com/x", true)]
    [InlineData("http://github.com/x", false)]
    [InlineData("https://github.com:8443/x", false)]
    [InlineData("https://user:pass@github.com/x", false)]
    [InlineData("https://raw.githubusercontent.com/x", false)]
    [InlineData("https://github.com.evil.example/x", false)]
    [InlineData("https://evilgithub.com/x", false)]
    [InlineData("https://github.com./x", false)]
    [InlineData("ftp://github.com/x", false)]
    [InlineData("file:///C:/x", false)]
    public void AllowsOnlyGitHubOverHttps(string url, bool allowed)
    {
        Assert.Equal(allowed, UpdateHosts.GitHub.Allows(new Uri(url)));
    }

    [Fact]
    public async Task RefusesAnotherHostWithoutContactingIt()
    {
        using var github = new FakeGitHub();
        using var http = Http(github);

        var error = await Assert.ThrowsAsync<UpdateException>(() => Get(http, "https://evil.example/a.bin"));

        Assert.Contains("Refused", error.Message);
        Assert.Empty(github.Seen);
    }

    [Theory]
    [InlineData("https://evil.example/a.bin")]
    [InlineData("http://release-assets.githubusercontent.com/a.bin")]
    [InlineData("https://release-assets.githubusercontent.com:444/a.bin")]
    [InlineData("//evil.example/a.bin")]
    public async Task RefusesARedirectOffTheAllowlist(string target)
    {
        using var github = new FakeGitHub();
        github.Redirect(Asset, target);
        using var http = Http(github);

        var error = await Assert.ThrowsAsync<UpdateException>(() => Get(http, Asset));

        Assert.Contains("Refused a redirect", error.Message);
        Assert.Single(github.Seen);
    }

    [Theory]
    [InlineData(HttpStatusCode.MovedPermanently)]
    [InlineData(HttpStatusCode.Found)]
    [InlineData(HttpStatusCode.SeeOther)]
    [InlineData(HttpStatusCode.TemporaryRedirect)]
    [InlineData(HttpStatusCode.PermanentRedirect)]
    public async Task FollowsAllowedRedirects(HttpStatusCode status)
    {
        using var github = new FakeGitHub();
        github.Redirect(Asset, FakeGitHub.StorageUrl("a.bin"), status);
        github.Bytes(FakeGitHub.StorageUrl("a.bin"), [1, 2, 3]);
        using var http = Http(github);

        Assert.Equal([1, 2, 3], await Get(http, Asset));
        Assert.Equal(2, github.Seen.Count);
    }

    [Fact]
    public async Task ResolvesARelativeRedirectOnTheSameHost()
    {
        using var github = new FakeGitHub();
        github.Redirect(Asset, "/corevider/osb-manager/b.bin");
        github.Bytes("https://github.com/corevider/osb-manager/b.bin", [9]);
        using var http = Http(github);

        Assert.Equal([9], await Get(http, Asset));
    }

    [Fact]
    public async Task StopsAfterTooManyRedirects()
    {
        using var github = new FakeGitHub();
        github.Redirect("https://github.com/a", "https://github.com/b");
        github.Redirect("https://github.com/b", "https://github.com/a");
        using var http = Http(github);

        var error = await Assert.ThrowsAsync<UpdateException>(() => Get(http, "https://github.com/a"));

        Assert.Contains("Too many redirects", error.Message);
        Assert.Equal(UpdateHttp.MaxRedirects + 1, github.Seen.Count);
    }

    [Fact]
    public async Task RefusesARedirectWithoutTarget()
    {
        using var github = new FakeGitHub();
        github.Route(Asset, () => new HttpResponseMessage(HttpStatusCode.Found));
        using var http = Http(github);

        await Assert.ThrowsAsync<UpdateException>(() => Get(http, Asset));
    }

    [Fact]
    public async Task RefusesABodyAnnouncedLargerThanTheLimit()
    {
        using var github = new FakeGitHub();
        github.Bytes(Asset, new byte[2000]);
        using var http = Http(github);

        var error = await Assert.ThrowsAsync<UpdateException>(() => Get(http, Asset, limit: 1000));

        Assert.Contains("more than", error.Message);
    }

    [Fact]
    public async Task StopsABodyThatGrowsPastTheLimitWithoutLength()
    {
        using var github = new FakeGitHub();
        github.Route(Asset, () => new HttpResponseMessage(HttpStatusCode.OK) { Content = new StreamContent(new UnknownLengthStream(5000)) });
        using var http = Http(github);

        var error = await Assert.ThrowsAsync<UpdateException>(() => Get(http, Asset, limit: 1000));

        Assert.Contains("more than", error.Message);
    }

    [Fact]
    public async Task TimesOutASlowAnswer()
    {
        using var github = new FakeGitHub();
        github.Route(Asset, async cancellation =>
        {
            await Task.Delay(Timeout.Infinite, cancellation);
            return FakeGitHub.Ok([1]);
        });
        using var http = Http(github);

        var error = await Assert.ThrowsAsync<UpdateException>(() => Get(http, Asset, timeoutMs: 200));

        Assert.Contains("timed out", error.Message);
    }

    [Fact]
    public async Task TimesOutABodyThatStalls()
    {
        using var github = new FakeGitHub();
        github.Route(Asset, () => new HttpResponseMessage(HttpStatusCode.OK) { Content = new StreamContent(new StallingStream()) });
        using var http = Http(github);

        var error = await Assert.ThrowsAsync<UpdateException>(() => Get(http, Asset, timeoutMs: 200));

        Assert.Contains("timed out", error.Message);
    }

    [Fact]
    public async Task ReportsNetworkErrors()
    {
        using var github = new FakeGitHub();
        github.Route(Asset, () => throw new HttpRequestException("Connection refused"));
        using var http = Http(github);

        var error = await Assert.ThrowsAsync<UpdateException>(() => Get(http, Asset));

        Assert.Contains("Connection refused", error.Message);
    }

    [Fact]
    public async Task SendsAFixedUserAgentAndNoCookiesOrCredentials()
    {
        using var github = new FakeGitHub();
        github.Redirect(Asset, FakeGitHub.StorageUrl("a.bin"));
        github.Bytes(FakeGitHub.StorageUrl("a.bin"), [1]);
        using var http = Http(github);

        await Get(http, Asset);

        Assert.All(github.Seen, request =>
        {
            Assert.Equal("OSBManager/1.0.2 (Windows)", request.UserAgent);
            Assert.Null(request.Cookie);
            Assert.Null(request.Authorization);
        });
    }

    [Fact]
    public void TheRealHandlerFollowsNoRedirectsAndKeepsNoCookies()
    {
        using var handler = UpdateHttp.CreateHandler();

        Assert.False(handler.AllowAutoRedirect);
        Assert.False(handler.UseCookies);
        Assert.Null(handler.Credentials);
        Assert.Equal(TimeSpan.FromSeconds(15), handler.ConnectTimeout);
    }

    private sealed class UnknownLengthStream(int length) : Stream
    {
        private int position;

        public override bool CanRead => true;
        public override bool CanSeek => false;
        public override bool CanWrite => false;
        public override long Length => throw new NotSupportedException();
        public override long Position { get => position; set => throw new NotSupportedException(); }

        public override int Read(byte[] buffer, int offset, int count)
        {
            var read = Math.Min(Math.Min(count, 100), length - position);
            position += read;
            return read;
        }

        public override void Flush()
        {
        }

        public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException();
        public override void SetLength(long value) => throw new NotSupportedException();
        public override void Write(byte[] buffer, int offset, int count) => throw new NotSupportedException();
    }

    private sealed class StallingStream : Stream
    {
        public override bool CanRead => true;
        public override bool CanSeek => false;
        public override bool CanWrite => false;
        public override long Length => throw new NotSupportedException();
        public override long Position { get => 0; set => throw new NotSupportedException(); }

        public override int Read(byte[] buffer, int offset, int count) => throw new NotSupportedException();

        public override async ValueTask<int> ReadAsync(Memory<byte> buffer, CancellationToken cancellationToken = default)
        {
            await Task.Delay(Timeout.Infinite, cancellationToken);
            return 0;
        }

        public override void Flush()
        {
        }

        public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException();
        public override void SetLength(long value) => throw new NotSupportedException();
        public override void Write(byte[] buffer, int offset, int count) => throw new NotSupportedException();
    }
}
