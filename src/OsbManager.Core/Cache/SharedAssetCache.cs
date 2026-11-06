using System.Collections.Concurrent;

namespace OsbManager.Core.Cache;

public sealed record CachedRange(byte[] Bytes, long Total, bool FromDisk);

public sealed record CacheCounters(long DiskBytes, int Packs, long ServedFromDisk, long Downloaded, long Failures);

/// <summary>
/// Pack byte ranges shared by every account. A hit is read from disk; a miss is downloaded once,
/// stored and served. Any failure returns null so the browser falls back to its own request.
/// </summary>
public sealed class SharedAssetCache : IDisposable
{
    private readonly string directory;
    private readonly IRangeFetcher fetcher;
    private readonly Action<string> log;
    private readonly ConcurrentDictionary<string, PackStore> packs = new(StringComparer.Ordinal);
    private readonly ConcurrentDictionary<(string Pack, long Start, long End), Lazy<Task<CachedRange?>>> downloads = new();
    private readonly ConcurrentDictionary<string, byte> verifying = new(StringComparer.Ordinal);
    private readonly SemaphoreSlim downloadSlots = new(12);
    private readonly object packLock = new();
    private readonly Timer flushTimer;
    private long servedFromDisk;
    private long downloaded;
    private long failures;
    private long lastFailureLog;
    private bool disposed;

    public SharedAssetCache(string directory, IRangeFetcher fetcher, Action<string> log)
    {
        this.directory = directory;
        this.fetcher = fetcher;
        this.log = log;
        Directory.CreateDirectory(directory);
        foreach (var index in Directory.EnumerateFiles(directory, "*.bin.index"))
        {
            var name = Path.GetFileName(index)[..^".index".Length];
            if (AssetUrl.TryGetPackName("https://" + AssetUrl.Host + "/assets/packs/" + name, out _)
                && PackStore.TryOpen(directory, name) is { } pack)
            {
                packs[name] = pack;
            }
        }
        flushTimer = new Timer(_ => FlushAll(), null, TimeSpan.FromSeconds(2), TimeSpan.FromSeconds(2));
    }

    public CacheCounters Counters => new(
        packs.Values.Sum(p => p.StoredBytes),
        packs.Count,
        Interlocked.Read(ref servedFromDisk),
        Interlocked.Read(ref downloaded),
        Interlocked.Read(ref failures));

    public async Task<CachedRange?> GetAsync(string url, string packName, ByteRange range)
    {
        if (disposed)
        {
            return null;
        }
        if (packs.TryGetValue(packName, out var pack) && pack.Has(range))
        {
            var bytes = await Task.Run(() => ReadOrNull(pack, range)).ConfigureAwait(false);
            if (bytes is not null)
            {
                Interlocked.Add(ref servedFromDisk, bytes.Length);
                return new CachedRange(bytes, pack.Total, FromDisk: true);
            }
        }
        var key = (packName, range.Start, range.End);
        var download = downloads.GetOrAdd(key, k => new Lazy<Task<CachedRange?>>(() => DownloadAsync(url, k.Pack, range)));
        try
        {
            return await download.Value.ConfigureAwait(false);
        }
        finally
        {
            downloads.TryRemove(new KeyValuePair<(string, long, long), Lazy<Task<CachedRange?>>>(key, download));
        }
    }

    /// <summary>Deletes every stored pack. Call only while no game window is open.</summary>
    public void Clear()
    {
        lock (packLock)
        {
            foreach (var name in packs.Keys.ToList())
            {
                if (packs.TryRemove(name, out var pack))
                {
                    pack.Dispose();
                    PackStore.Delete(directory, name);
                }
            }
        }
        Interlocked.Exchange(ref servedFromDisk, 0);
        Interlocked.Exchange(ref downloaded, 0);
    }

    public void FlushAll()
    {
        foreach (var pack in packs.Values)
        {
            try
            {
                pack.Flush();
            }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException or ObjectDisposedException)
            {
                LogFailure($"Could not save the cache index for {pack.Name}: {e.Message}");
            }
        }
    }

    public void Dispose()
    {
        if (disposed)
        {
            return;
        }
        disposed = true;
        flushTimer.Dispose();
        lock (packLock)
        {
            foreach (var pack in packs.Values)
            {
                try
                {
                    pack.Dispose();
                }
                catch (IOException e)
                {
                    log($"Could not close the cache file {pack.Name}: {e.Message}");
                }
            }
            packs.Clear();
        }
    }

    private async Task<CachedRange?> DownloadAsync(string url, string packName, ByteRange range)
    {
        await downloadSlots.WaitAsync().ConfigureAwait(false);
        try
        {
            var fetched = await fetcher.FetchAsync(url, range, CancellationToken.None).ConfigureAwait(false);
            if (range.End >= fetched.Total)
            {
                throw new HttpRequestException("The range lies outside the pack.");
            }
            Interlocked.Add(ref downloaded, fetched.Bytes.Length);
            Store(packName, range, fetched);
            return new CachedRange(fetched.Bytes, fetched.Total, FromDisk: false);
        }
        catch (Exception) when (disposed)
        {
            Interlocked.Increment(ref failures);
            return null;
        }
        catch (Exception e)
        {
            Interlocked.Increment(ref failures);
            LogFailure($"Asset download failed, the browser loads it instead ({packName} {range.Start}-{range.End}): {e.Message}");
            return null;
        }
        finally
        {
            downloadSlots.Release();
        }
    }

    private void Store(string packName, ByteRange range, FetchedRange fetched)
    {
        try
        {
            PackStore pack;
            lock (packLock)
            {
                if (disposed)
                {
                    return;
                }
                if (!packs.TryGetValue(packName, out pack!) || pack.Total != fetched.Total)
                {
                    if (pack is not null)
                    {
                        packs.TryRemove(packName, out _);
                        pack.Dispose();
                    }
                    pack = PackStore.Create(directory, packName, fetched.Total);
                    packs[packName] = pack;
                }
            }
            pack.Write(range, fetched.Bytes);
            if (!pack.Verified && pack.IsComplete && verifying.TryAdd(packName, 0))
            {
                _ = Task.Run(() => Verify(pack));
            }
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or ObjectDisposedException)
        {
            LogFailure($"Could not store {packName} in the shared cache: {e.Message}");
        }
    }

    private void Verify(PackStore pack)
    {
        try
        {
            if (pack.VerifyComplete())
            {
                return;
            }
            log($"Cached pack {pack.Name} did not match its hash and was removed.");
            lock (packLock)
            {
                if (packs.TryGetValue(pack.Name, out var current) && current == pack)
                {
                    packs.TryRemove(pack.Name, out _);
                    pack.Dispose();
                    PackStore.Delete(directory, pack.Name);
                }
            }
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or ObjectDisposedException)
        {
            LogFailure($"Could not verify {pack.Name}: {e.Message}");
        }
        finally
        {
            verifying.TryRemove(pack.Name, out _);
        }
    }

    private byte[]? ReadOrNull(PackStore pack, ByteRange range)
    {
        try
        {
            return pack.TryRead(range);
        }
        catch (Exception e) when (e is IOException or ObjectDisposedException)
        {
            LogFailure($"Could not read {pack.Name} from the shared cache: {e.Message}");
            return null;
        }
    }

    private void LogFailure(string message)
    {
        var now = Environment.TickCount64;
        var last = Interlocked.Read(ref lastFailureLog);
        if (now - last >= 10_000 && Interlocked.CompareExchange(ref lastFailureLog, now, last) == last)
        {
            log(message);
        }
    }
}
