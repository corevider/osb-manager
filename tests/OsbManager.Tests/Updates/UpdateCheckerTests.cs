using System.Net;
using System.Text;
using OsbManager.Core.Updates;

namespace OsbManager.Tests.Updates;

public class UpdateCheckerTests
{
    [Fact]
    public async Task OffersANewerSignedReleaseAndDownloadsTheVerifiedZip()
    {
        using var key = new TestKey();
        using var github = new FakeGitHub();
        using var temp = new TempDirectory();
        var release = new FakeRelease();
        release.Publish(github, key, title: "OSB Manager 1.0.3\n‮with fixes");

        var checker = UpdateKit.Checker(github, keys: key.PublicKey);
        var result = await checker.CheckAsync(CancellationToken.None);

        Assert.Equal(UpdateCheckStatus.Available, result.Status);
        var offer = Assert.IsType<UpdateOffer>(result.Offer);
        Assert.Equal("1.0.3", offer.Version.ToString());
        Assert.Equal("OSB Manager 1.0.3 with fixes", offer.Title);
        Assert.Equal(FakeGitHub.AssetUrl("OSB-Manager-windows-x64.zip"), offer.ZipUrl.AbsoluteUri);
        Assert.Equal("https://github.com/corevider/osb-manager/releases/tag/v1.0.3", offer.ReleasePage.AbsoluteUri);

        var zip = await checker.DownloadAsync(offer, temp.Path, CancellationToken.None);
        Assert.Equal(release.Zip, File.ReadAllBytes(zip));
        Assert.DoesNotContain(github.Seen, r => r.Url.Host == "evil.example");
    }

    [Fact]
    public async Task RefusesATamperedManifest()
    {
        using var key = new TestKey();
        using var github = new FakeGitHub();
        var release = new FakeRelease();
        var manifest = release.Manifest();
        var tampered = Encoding.UTF8.GetBytes(Encoding.UTF8.GetString(manifest).Replace("1.0.3", "9.0.0"));
        release.Publish(github, key, manifest: tampered, signature: key.Sign(manifest));

        var result = await UpdateKit.Checker(github, keys: key.PublicKey).CheckAsync(CancellationToken.None);

        Assert.Equal(UpdateCheckStatus.Failed, result.Status);
        Assert.Null(result.Offer);
        Assert.Contains("signature", result.Message);
        Assert.DoesNotContain(github.Seen, r => r.Url.AbsoluteUri.Contains(".zip", StringComparison.Ordinal) && !r.Url.AbsoluteUri.Contains(".update.json", StringComparison.Ordinal));
    }

    [Fact]
    public async Task RefusesAManifestSignedWithAnotherKey()
    {
        using var key = new TestKey();
        using var other = new TestKey();
        using var github = new FakeGitHub();
        new FakeRelease().Publish(github, other);

        var result = await UpdateKit.Checker(github, keys: key.PublicKey).CheckAsync(CancellationToken.None);

        Assert.Equal(UpdateCheckStatus.Failed, result.Status);
    }

    [Fact]
    public async Task AcceptsTheSecondRotatedKey()
    {
        using var old = new TestKey();
        using var rotated = new TestKey();
        using var github = new FakeGitHub();
        new FakeRelease().Publish(github, rotated);

        var result = await UpdateKit.Checker(github, "1.0.2", null, old.PublicKey, rotated.PublicKey).CheckAsync(CancellationToken.None);

        Assert.Equal(UpdateCheckStatus.Available, result.Status);
    }

    [Fact]
    public async Task TreatsAReleaseWithoutSignatureAsNotSigned()
    {
        using var key = new TestKey();
        using var github = new FakeGitHub();
        var release = new FakeRelease();
        github.Release(FakeGitHub.Tag, "OSB Manager 1.0.3", release.Platform.ZipName, release.Platform.ZipName + ".sha256", release.Platform.ManifestName);
        github.Asset(release.Platform.ManifestName, release.Manifest());

        var result = await UpdateKit.Checker(github, keys: key.PublicKey).CheckAsync(CancellationToken.None);

        Assert.Equal(UpdateCheckStatus.NotSigned, result.Status);
        Assert.Single(github.Seen);
    }

    [Theory]
    [InlineData("")]
    [InlineData("not base64!")]
    [InlineData("AAAA")]
    public async Task RefusesAnEmptyOrMalformedSignature(string signature)
    {
        using var key = new TestKey();
        using var github = new FakeGitHub();
        new FakeRelease().Publish(github, key, signature: Encoding.ASCII.GetBytes(signature));

        var result = await UpdateKit.Checker(github, keys: key.PublicKey).CheckAsync(CancellationToken.None);

        Assert.Equal(UpdateCheckStatus.Failed, result.Status);
    }

    [Fact]
    public async Task RefusesATamperedZip()
    {
        using var key = new TestKey();
        using var github = new FakeGitHub();
        using var temp = new TempDirectory();
        var release = new FakeRelease();
        release.Publish(github, key);
        var checker = UpdateKit.Checker(github, keys: key.PublicKey);
        var offer = (await checker.CheckAsync(CancellationToken.None)).Offer!;
        var tampered = (byte[])release.Zip.Clone();
        tampered[100] ^= 0xFF;
        github.Bytes(FakeGitHub.StorageUrl(release.Platform.ZipName), tampered);

        var error = await Assert.ThrowsAsync<UpdateException>(() => checker.DownloadAsync(offer, temp.Path, CancellationToken.None));

        Assert.Contains("SHA-256", error.Message);
        Assert.Empty(Directory.GetFiles(temp.Path));
    }

    [Fact]
    public async Task StopsAZipLargerThanTheSignedSize()
    {
        using var key = new TestKey();
        using var github = new FakeGitHub();
        using var temp = new TempDirectory();
        var release = new FakeRelease();
        release.Publish(github, key);
        var checker = UpdateKit.Checker(github, keys: key.PublicKey);
        var offer = (await checker.CheckAsync(CancellationToken.None)).Offer!;
        github.Bytes(FakeGitHub.StorageUrl(release.Platform.ZipName), [.. release.Zip, .. new byte[100]]);

        var error = await Assert.ThrowsAsync<UpdateException>(() => checker.DownloadAsync(offer, temp.Path, CancellationToken.None));

        Assert.Contains("allowed", error.Message);
        Assert.Empty(Directory.GetFiles(temp.Path));
    }

    [Fact]
    public async Task RefusesAShorterZip()
    {
        using var key = new TestKey();
        using var github = new FakeGitHub();
        using var temp = new TempDirectory();
        var release = new FakeRelease();
        release.Publish(github, key);
        var checker = UpdateKit.Checker(github, keys: key.PublicKey);
        var offer = (await checker.CheckAsync(CancellationToken.None)).Offer!;
        github.Bytes(FakeGitHub.StorageUrl(release.Platform.ZipName), release.Zip[..^1]);

        await Assert.ThrowsAsync<UpdateException>(() => checker.DownloadAsync(offer, temp.Path, CancellationToken.None));
    }

    [Theory]
    [InlineData("1.0.1")]
    [InlineData("1.0.2")]
    [InlineData("0.9.99")]
    public async Task DoesNotOfferAnOlderOrTheSameVersion(string version)
    {
        using var key = new TestKey();
        using var github = new FakeGitHub();
        new FakeRelease(version).Publish(github, key);

        var result = await UpdateKit.Checker(github, "1.0.2", null, key.PublicKey).CheckAsync(CancellationToken.None);

        Assert.Equal(UpdateCheckStatus.UpToDate, result.Status);
        Assert.Null(result.Offer);
    }

    [Theory]
    [InlineData("1.0")]
    [InlineData("1.0.3-beta")]
    [InlineData("01.0.3")]
    [InlineData("1.0.3.4")]
    [InlineData("v1.0.3")]
    [InlineData("")]
    public async Task RefusesAMalformedSignedVersion(string version)
    {
        using var key = new TestKey();
        using var github = new FakeGitHub();
        new FakeRelease(version).Publish(github, key);

        var result = await UpdateKit.Checker(github, keys: key.PublicKey).CheckAsync(CancellationToken.None);

        Assert.Equal(UpdateCheckStatus.Failed, result.Status);
        Assert.Contains("version", result.Message);
    }

    [Fact]
    public async Task RefusesAManifestForAnotherPlatform()
    {
        using var key = new TestKey();
        using var github = new FakeGitHub();
        var release = new FakeRelease();
        var manifest = release.Manifest("1.0.3", release.Zip.Length, new string('a', 64), platform: "macos-arm64");
        release.Publish(github, key, manifest: manifest);

        var result = await UpdateKit.Checker(github, keys: key.PublicKey).CheckAsync(CancellationToken.None);

        Assert.Equal(UpdateCheckStatus.Failed, result.Status);
        Assert.Contains("platform", result.Message);
    }

    [Theory]
    [InlineData("""{"format":1,"product":"osb-manager","platform":"windows-x64","version":"1.0.3","asset":"OSB-Manager-windows-x64.zip","size":10,"sha256":"ab"}""")]
    [InlineData("""{"format":2,"product":"osb-manager","platform":"windows-x64","version":"1.0.3","asset":"OSB-Manager-windows-x64.zip","size":10,"sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}""")]
    [InlineData("""{"format":1,"product":"osb-manager","platform":"windows-x64","version":"1.0.3","asset":"other.zip","size":10,"sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}""")]
    [InlineData("""{"format":1,"product":"osb-manager","platform":"windows-x64","version":"1.0.3","asset":"OSB-Manager-windows-x64.zip","size":0,"sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}""")]
    [InlineData("""{"format":1,"product":"osb-manager","platform":"windows-x64","version":"1.0.3","asset":"OSB-Manager-windows-x64.zip","size":999999999999,"sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}""")]
    [InlineData("""{"format":1,"product":"osb-manager","platform":"windows-x64","version":"1.0.3","asset":"OSB-Manager-windows-x64.zip","size":10,"sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","url":"https://evil.example"}""")]
    [InlineData("""{"format":1,"product":"osb-manager","platform":"windows-x64","version":"1.0.3","version":"9.9.9","asset":"OSB-Manager-windows-x64.zip","size":10,"sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}""")]
    [InlineData("""[1]""")]
    [InlineData("""not json""")]
    public void RejectsMalformedManifests(string json)
    {
        Assert.Throws<UpdateException>(() => UpdateManifest.Parse(Encoding.UTF8.GetBytes(json), UpdatePlatform.WindowsX64));
    }

    [Fact]
    public async Task ReportsANetworkErrorAsAFailedCheck()
    {
        using var key = new TestKey();
        using var github = new FakeGitHub();
        github.Route(FakeGitHub.ApiUrl, () => throw new HttpRequestException("No such host is known."));

        var result = await UpdateKit.Checker(github, keys: key.PublicKey).CheckAsync(CancellationToken.None);

        Assert.Equal(UpdateCheckStatus.Failed, result.Status);
        Assert.Contains("api.github.com", result.Message);
    }

    [Fact]
    public async Task ReportsAServerErrorAsAFailedCheck()
    {
        using var key = new TestKey();
        using var github = new FakeGitHub();
        github.Route(FakeGitHub.ApiUrl, () => new HttpResponseMessage(HttpStatusCode.ServiceUnavailable));

        var result = await UpdateKit.Checker(github, keys: key.PublicKey).CheckAsync(CancellationToken.None);

        Assert.Equal(UpdateCheckStatus.Failed, result.Status);
        Assert.Contains("503", result.Message);
    }

    [Theory]
    [InlineData("OSB Manager 1.0.3", "OSB Manager 1.0.3")]
    [InlineData("  a\r\n\tb  ", "a b")]
    [InlineData("x‎y‮z", "xyz")]
    [InlineData(null, "")]
    public void CleansTheReleaseTitle(string? title, string expected)
    {
        Assert.Equal(expected, UpdateChecker.CleanTitle(title));
    }

    [Fact]
    public void ShortensALongTitle()
    {
        Assert.Equal(UpdateChecker.MaxTitleLength, UpdateChecker.CleanTitle(new string('a', 500)).Length);
    }

    [Theory]
    [InlineData("1.0.10", "1.0.9", 1)]
    [InlineData("1.10.0", "1.9.99", 1)]
    [InlineData("2.0.0", "10.0.0", -1)]
    [InlineData("1.0.2", "1.0.2", 0)]
    public void ComparesVersionsNumerically(string left, string right, int sign)
    {
        Assert.True(UpdateVersion.TryParse(left, out var a));
        Assert.True(UpdateVersion.TryParse(right, out var b));
        Assert.Equal(sign, Math.Sign(a.CompareTo(b)));
    }
}
