using OsbManager.Core.Updates;

namespace OsbManager.Tests.Updates;

public class UpdateNoticeTests
{
    private static UpdateOffer Offer(string version)
    {
        UpdateVersion.TryParse(version, out var parsed);
        var manifest = new UpdateManifest(parsed, "windows-x64", "OSB-Manager-windows-x64.zip", 10, new string('a', 64));
        return new UpdateOffer(manifest, "v" + version, "OSB Manager " + version, new Uri("https://github.com/x"), new Uri("https://github.com/y"));
    }

    [Fact]
    public void ShowsANewOfferUntilLater()
    {
        var notice = new UpdateNotice();

        Assert.True(notice.Offer(Offer("1.0.3"), requestedByUser: false));
        Assert.Equal("1.0.3", notice.Current!.Version.ToString());

        notice.Later();

        Assert.Null(notice.Current);
        Assert.False(notice.Offer(Offer("1.0.3"), requestedByUser: false));
    }

    [Fact]
    public void ShowsAPostponedVersionAgainWhenTheUserAsks()
    {
        var notice = new UpdateNotice();
        notice.Offer(Offer("1.0.3"), requestedByUser: false);
        notice.Later();

        Assert.True(notice.Offer(Offer("1.0.3"), requestedByUser: true));
    }

    [Fact]
    public void ShowsANewerVersionAfterLater()
    {
        var notice = new UpdateNotice();
        notice.Offer(Offer("1.0.3"), requestedByUser: false);
        notice.Later();

        Assert.True(notice.Offer(Offer("1.0.4"), requestedByUser: false));
    }

    [Fact]
    public void KeepsTheNewerOfferShown()
    {
        var notice = new UpdateNotice();
        notice.Offer(Offer("1.0.4"), requestedByUser: false);

        Assert.False(notice.Offer(Offer("1.0.3"), requestedByUser: false));
        Assert.Equal("1.0.4", notice.Current!.Version.ToString());
    }

    [Fact]
    public void InstallsOnlyAfterTheUserChoseIt()
    {
        var notice = new UpdateNotice();
        Assert.Null(notice.BeginInstall());

        notice.Offer(Offer("1.0.3"), requestedByUser: false);
        var offer = notice.BeginInstall();

        Assert.NotNull(offer);
        Assert.True(notice.Installing);
        Assert.Null(notice.BeginInstall());
        Assert.False(notice.Offer(Offer("1.0.4"), requestedByUser: false));

        notice.InstallFailed();

        Assert.False(notice.Installing);
        Assert.NotNull(notice.BeginInstall());
    }
}
