using System.Collections.Concurrent;
using System.Security.Cryptography;
using OsbManager.Core.Cache;

namespace OsbManager.Tests;

public class IntervalSetTests
{
    [Fact]
    public void MergesOverlappingAndAdjacentIntervals()
    {
        var set = new IntervalSet();
        set.Add(10, 20);
        set.Add(30, 40);
        set.Add(20, 25);
        set.Add(0, 5);
        set.Add(24, 31);

        Assert.Equal([(0L, 5L), (10L, 40L)], set.Items);
        Assert.Equal(35, set.CoveredBytes);
    }

    [Fact]
    public void ContainsOnlyFullyStoredRanges()
    {
        var set = new IntervalSet();
        set.Add(100, 200);
        set.Add(300, 400);

        Assert.True(set.Contains(100, 200));
        Assert.True(set.Contains(150, 160));
        Assert.False(set.Contains(99, 150));
        Assert.False(set.Contains(150, 301));
        Assert.False(set.Contains(200, 300));
        Assert.False(set.Contains(0, 1));
    }

    [Fact]
    public void IgnoresEmptyIntervals()
    {
        var set = new IntervalSet();
        set.Add(5, 5);
        set.Add(9, 3);

        Assert.Equal(0, set.Count);
    }
}

public class ByteRangeTests
{
    [Theory]
    [InlineData("bytes=0-15", 0, 15)]
    [InlineData("bytes= 100-199 ", 100, 199)]
    [InlineData("BYTES=7-7", 7, 7)]
    public void ParsesSingleClosedRanges(string header, long start, long end)
    {
        Assert.True(ByteRange.TryParseHeader(header, out var range));
        Assert.Equal(new ByteRange(start, end), range);
    }

    [Theory]
    [InlineData(null)]
    [InlineData("")]
    [InlineData("bytes=10-")]
    [InlineData("bytes=-500")]
    [InlineData("bytes=0-1,5-9")]
    [InlineData("bytes=9-3")]
    [InlineData("bytes=a-9")]
    [InlineData("items=0-9")]
    [InlineData("bytes=0-67108864")]
    public void RejectsEverythingElse(string? header)
    {
        Assert.False(ByteRange.TryParseHeader(header, out _));
    }
}

public class AssetUrlTests
{
    [Fact]
    public void AcceptsContentHashedPacks()
    {
        Assert.True(AssetUrl.TryGetPackName("https://opensro.online/assets/packs/equipment-models-001-1f20cbd1ac41.bin", out var name));
        Assert.Equal("equipment-models-001-1f20cbd1ac41.bin", name);
        Assert.Equal("1f20cbd1ac41", AssetUrl.HashPrefix(name));
    }

    [Theory]
    [InlineData("http://opensro.online/assets/packs/a-001-1f20cbd1ac41.bin")]
    [InlineData("https://evil.example/assets/packs/a-001-1f20cbd1ac41.bin")]
    [InlineData("https://opensro.online:8443/assets/packs/a-001-1f20cbd1ac41.bin")]
    [InlineData("https://opensro.online/assets/packs/a-001-1f20cbd1ac41.bin?v=2")]
    [InlineData("https://opensro.online/assets/packs/manifest.json")]
    [InlineData("https://opensro.online/assets/packs/../packs/a-001-1F20CBD1AC41.bin")]
    [InlineData("https://opensro.online/assets/packs/sub/a-001-1f20cbd1ac41.bin")]
    [InlineData("https://opensro.online/assets/entry-C_ANlq-Y.js")]
    [InlineData("not a url")]
    public void RejectsOtherUrls(string url)
    {
        Assert.False(AssetUrl.TryGetPackName(url, out _));
    }
}

public class PackStoreTests
{
    [Fact]
    public void StoresRangesAndReopensThemAfterFlush()
    {
        using var temp = new TempDirectory();
        using (var pack = PackStore.Create(temp.Path, "p-001-000000000000.bin", 1000))
        {
            pack.Write(new ByteRange(100, 103), [1, 2, 3, 4]);
            Assert.Equal([2, 3], pack.TryRead(new ByteRange(101, 102)));
            Assert.Null(pack.TryRead(new ByteRange(99, 101)));
        }

        using var reopened = PackStore.TryOpen(temp.Path, "p-001-000000000000.bin");

        Assert.NotNull(reopened);
        Assert.Equal(1000, reopened.Total);
        Assert.Equal([1, 2, 3, 4], reopened.TryRead(new ByteRange(100, 103)));
    }

    [Fact]
    public void UnflushedRangesAreNotListedAfterACrash()
    {
        using var temp = new TempDirectory();
        using var crashed = new TempDirectory();
        using (var pack = PackStore.Create(temp.Path, "p-001-000000000000.bin", 100))
        {
            pack.Write(new ByteRange(0, 1), [7, 7]);
            pack.Flush();
            pack.Write(new ByteRange(10, 11), [8, 8]);
            foreach (var file in Directory.GetFiles(temp.Path))
            {
                File.Copy(file, crashed.File(Path.GetFileName(file)));
            }
        }

        using var reopened = PackStore.TryOpen(crashed.Path, "p-001-000000000000.bin");

        Assert.NotNull(reopened);
        Assert.True(reopened.Has(new ByteRange(0, 1)));
        Assert.False(reopened.Has(new ByteRange(10, 11)));
    }

    [Fact]
    public void DeletesPacksWithACorruptIndex()
    {
        using var temp = new TempDirectory();
        using (var pack = PackStore.Create(temp.Path, "p-001-000000000000.bin", 100))
        {
            pack.Write(new ByteRange(0, 9), new byte[10]);
        }
        var index = temp.File("p-001-000000000000.bin.index");
        var bytes = File.ReadAllBytes(index);
        bytes[10] ^= 0xFF;
        File.WriteAllBytes(index, bytes);

        Assert.Null(PackStore.TryOpen(temp.Path, "p-001-000000000000.bin"));
        Assert.False(File.Exists(index));
        Assert.False(File.Exists(temp.File("p-001-000000000000.bin")));
    }

    [Fact]
    public void LeavesPacksAloneWhileAnotherHandleHoldsThem()
    {
        using var temp = new TempDirectory();
        using var pack = PackStore.Create(temp.Path, "p-001-000000000000.bin", 100);
        pack.Write(new ByteRange(0, 9), new byte[10]);
        pack.Flush();

        Assert.Null(PackStore.TryOpen(temp.Path, "p-001-000000000000.bin"));
        Assert.True(File.Exists(temp.File("p-001-000000000000.bin.index")));
        Assert.NotNull(pack.TryRead(new ByteRange(0, 9)));
    }

    [Fact]
    public void RejectsWritesThatDoNotFit()
    {
        using var temp = new TempDirectory();
        using var pack = PackStore.Create(temp.Path, "p-001-000000000000.bin", 10);

        Assert.Throws<ArgumentException>(() => pack.Write(new ByteRange(8, 10), new byte[3]));
        Assert.Throws<ArgumentException>(() => pack.Write(new ByteRange(0, 3), new byte[2]));
    }

    [Fact]
    public void VerifiesACompletePackAgainstTheHashInItsName()
    {
        using var temp = new TempDirectory();
        var data = RandomNumberGenerator.GetBytes(4096);
        var good = $"p-001-{Convert.ToHexStringLower(SHA256.HashData(data))[..12]}.bin";
        using var pack = PackStore.Create(temp.Path, good, data.Length);
        using var wrong = PackStore.Create(temp.Path, "p-002-000000000000.bin", data.Length);

        Assert.False(pack.VerifyComplete());
        pack.Write(new ByteRange(0, data.Length - 1), data);
        wrong.Write(new ByteRange(0, data.Length - 1), data);

        Assert.True(pack.VerifyComplete());
        Assert.True(pack.Verified);
        Assert.False(wrong.VerifyComplete());
    }
}

public class SharedAssetCacheTests
{
    private const string Url = "https://opensro.online/assets/packs/";

    [Fact]
    public async Task DownloadsAMissOnceAndServesItFromDiskAfterwards()
    {
        using var temp = new TempDirectory();
        var fetcher = new FakeFetcher(Bytes(1000));
        using var cache = new SharedAssetCache(temp.Path, fetcher, _ => { });
        var name = "p-001-000000000000.bin";

        var first = await cache.GetAsync(Url + name, name, new ByteRange(10, 19));
        var second = await cache.GetAsync(Url + name, name, new ByteRange(12, 15));

        Assert.False(first!.FromDisk);
        Assert.True(second!.FromDisk);
        Assert.Equal(fetcher.Data[12..16], second.Bytes);
        Assert.Equal(1, fetcher.Calls);
        Assert.Equal(new CacheCounters(10, 1, 4, 10, 0), cache.Counters);
    }

    [Fact]
    public async Task SharesOneDownloadBetweenConcurrentRequests()
    {
        using var temp = new TempDirectory();
        var gate = new TaskCompletionSource();
        var fetcher = new FakeFetcher(Bytes(100)) { Gate = gate.Task };
        using var cache = new SharedAssetCache(temp.Path, fetcher, _ => { });
        var name = "p-001-000000000000.bin";

        var requests = Enumerable.Range(0, 5).Select(_ => cache.GetAsync(Url + name, name, new ByteRange(0, 49))).ToList();
        gate.SetResult();
        var results = await Task.WhenAll(requests);

        Assert.All(results, r => Assert.Equal(fetcher.Data[..50], r!.Bytes));
        Assert.Equal(1, fetcher.Calls);
    }

    [Fact]
    public async Task ReturnsNullWhenTheDownloadFails()
    {
        using var temp = new TempDirectory();
        var messages = new ConcurrentBag<string>();
        var fetcher = new FakeFetcher(Bytes(100)) { Failure = new HttpRequestException("offline") };
        using var cache = new SharedAssetCache(temp.Path, fetcher, messages.Add);
        var name = "p-001-000000000000.bin";

        Assert.Null(await cache.GetAsync(Url + name, name, new ByteRange(0, 9)));
        Assert.Equal(1, cache.Counters.Failures);
        Assert.Contains(messages, m => m.Contains("offline"));
    }

    [Fact]
    public async Task KeepsStoredRangesForTheNextStart()
    {
        using var temp = new TempDirectory();
        var name = "p-001-000000000000.bin";
        using (var cache = new SharedAssetCache(temp.Path, new FakeFetcher(Bytes(500)), _ => { }))
        {
            await cache.GetAsync(Url + name, name, new ByteRange(0, 99));
        }
        var offline = new FakeFetcher(Bytes(500)) { Failure = new HttpRequestException("offline") };
        using var restarted = new SharedAssetCache(temp.Path, offline, _ => { });

        var hit = await restarted.GetAsync(Url + name, name, new ByteRange(50, 99));

        Assert.True(hit!.FromDisk);
        Assert.Equal(0, offline.Calls);
    }

    [Fact]
    public async Task StartsOverWhenThePackSizeChanges()
    {
        using var temp = new TempDirectory();
        var name = "p-001-000000000000.bin";
        using (var cache = new SharedAssetCache(temp.Path, new FakeFetcher(Bytes(500)), _ => { }))
        {
            await cache.GetAsync(Url + name, name, new ByteRange(0, 99));
        }
        var changed = new FakeFetcher(Bytes(800));
        using var replaced = new SharedAssetCache(temp.Path, changed, _ => { });

        await replaced.GetAsync(Url + name, name, new ByteRange(600, 699));
        var old = await replaced.GetAsync(Url + name, name, new ByteRange(0, 99));

        Assert.Equal(2, changed.Calls);
        Assert.False(old!.FromDisk);
        Assert.Equal(1, replaced.Counters.Packs);
        Assert.Equal(200, replaced.Counters.DiskBytes);
    }

    [Fact]
    public async Task RemovesACompletePackWhoseHashDoesNotMatch()
    {
        using var temp = new TempDirectory();
        var messages = new ConcurrentBag<string>();
        var name = "p-001-000000000000.bin";
        using var cache = new SharedAssetCache(temp.Path, new FakeFetcher(Bytes(256)), messages.Add);

        await cache.GetAsync(Url + name, name, new ByteRange(0, 255));
        for (var i = 0; i < 100 && cache.Counters.Packs > 0; i++)
        {
            await Task.Delay(20);
        }

        Assert.Equal(0, cache.Counters.Packs);
        Assert.Contains(messages, m => m.Contains("did not match"));
    }

    [Fact]
    public async Task ClearDeletesEveryPack()
    {
        using var temp = new TempDirectory();
        var name = "p-001-000000000000.bin";
        using var cache = new SharedAssetCache(temp.Path, new FakeFetcher(Bytes(100)), _ => { });
        await cache.GetAsync(Url + name, name, new ByteRange(0, 9));

        cache.Clear();

        Assert.Equal(new CacheCounters(0, 0, 0, 0, 0), cache.Counters);
        Assert.Empty(Directory.GetFiles(temp.Path));
    }

    private static byte[] Bytes(int length) => Enumerable.Range(0, length).Select(i => (byte)(i * 7)).ToArray();

    private sealed class FakeFetcher(byte[] data) : IRangeFetcher
    {
        private int calls;

        public byte[] Data { get; } = data;
        public int Calls => calls;
        public Task? Gate { get; init; }
        public Exception? Failure { get; init; }

        public async Task<FetchedRange> FetchAsync(string url, ByteRange range, CancellationToken cancellation)
        {
            Interlocked.Increment(ref calls);
            if (Gate is not null)
            {
                await Gate;
            }
            if (Failure is not null)
            {
                throw Failure;
            }
            return new FetchedRange(Data[(int)range.Start..(int)range.EndExclusive], Data.Length);
        }
    }
}
