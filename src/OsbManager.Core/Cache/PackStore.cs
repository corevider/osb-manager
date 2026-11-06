using System.Security.Cryptography;
using Microsoft.Win32.SafeHandles;

namespace OsbManager.Core.Cache;

/// <summary>
/// One pack file kept as a sparse local copy plus an index of the byte ranges already stored.
/// The index is written only after the data it lists has been flushed, so a crash never lists missing bytes.
/// </summary>
internal sealed class PackStore : IDisposable
{
    private const uint IndexMagic = 0x49504D53;
    private const int IndexVersion = 1;

    private readonly object sync = new();
    private readonly IntervalSet stored = new();
    private readonly SafeFileHandle handle;
    private readonly string indexPath;
    private bool dirty;

    private PackStore(string name, long total, SafeFileHandle handle, string dataPath, string indexPath)
    {
        Name = name;
        Total = total;
        this.handle = handle;
        DataPath = dataPath;
        this.indexPath = indexPath;
    }

    public string Name { get; }
    public long Total { get; }
    public string DataPath { get; }
    public bool Verified { get; private set; }

    public long StoredBytes
    {
        get { lock (sync) { return stored.CoveredBytes; } }
    }

    public bool IsComplete
    {
        get { lock (sync) { return stored.Contains(0, Total); } }
    }

    public static PackStore Create(string directory, string name, long total)
    {
        var (dataPath, indexPath) = Paths(directory, name);
        File.Delete(indexPath);
        var handle = File.OpenHandle(dataPath, FileMode.Create, FileAccess.ReadWrite, FileShare.Read, FileOptions.RandomAccess);
        if (NativeFile.TryMakeSparse(handle))
        {
            RandomAccess.SetLength(handle, total);
        }
        return new PackStore(name, total, handle, dataPath, indexPath);
    }

    /// <summary>
    /// Opens a stored pack. Files that do not agree are deleted; files another process holds are left alone.
    /// Returns null in both cases.
    /// </summary>
    public static PackStore? TryOpen(string directory, string name)
    {
        var (dataPath, indexPath) = Paths(directory, name);
        SafeFileHandle handle;
        long total;
        bool verified;
        List<(long Start, long End)> ranges;
        try
        {
            (total, verified, ranges) = ReadIndex(indexPath);
            handle = File.OpenHandle(dataPath, FileMode.Open, FileAccess.ReadWrite, FileShare.Read, FileOptions.RandomAccess);
        }
        catch (Exception e) when (e is InvalidDataException or EndOfStreamException or FileNotFoundException)
        {
            TryDelete(directory, name);
            return null;
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            return null;
        }
        var end = ranges.Count == 0 ? 0 : ranges[^1].End;
        if (RandomAccess.GetLength(handle) < end)
        {
            handle.Dispose();
            TryDelete(directory, name);
            return null;
        }
        var pack = new PackStore(name, total, handle, dataPath, indexPath) { Verified = verified };
        foreach (var (start, stop) in ranges)
        {
            pack.stored.Add(start, stop);
        }
        return pack;
    }

    public static void Delete(string directory, string name)
    {
        var (dataPath, indexPath) = Paths(directory, name);
        File.Delete(indexPath);
        File.Delete(dataPath);
    }

    private static void TryDelete(string directory, string name)
    {
        try
        {
            Delete(directory, name);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
        }
    }

    public bool Has(ByteRange range)
    {
        lock (sync)
        {
            return range.End < Total && stored.Contains(range.Start, range.EndExclusive);
        }
    }

    public byte[]? TryRead(ByteRange range)
    {
        if (!Has(range))
        {
            return null;
        }
        var buffer = new byte[range.Length];
        var read = 0;
        while (read < buffer.Length)
        {
            var count = RandomAccess.Read(handle, buffer.AsSpan(read), range.Start + read);
            if (count == 0)
            {
                return null;
            }
            read += count;
        }
        return buffer;
    }

    public void Write(ByteRange range, ReadOnlySpan<byte> data)
    {
        if (data.Length != range.Length || range.End >= Total)
        {
            throw new ArgumentException("The data does not fit the pack.", nameof(data));
        }
        RandomAccess.Write(handle, data, range.Start);
        lock (sync)
        {
            stored.Add(range.Start, range.EndExclusive);
            dirty = true;
        }
    }

    /// <summary>Hashes the complete pack and compares it with the hash prefix in its name.</summary>
    public bool VerifyComplete()
    {
        if (!IsComplete)
        {
            return false;
        }
        using var stream = new FileStream(DataPath, FileMode.Open, FileAccess.Read, FileShare.ReadWrite, 1 << 20);
        var hash = Convert.ToHexStringLower(SHA256.HashData(stream));
        var valid = hash.StartsWith(AssetUrl.HashPrefix(Name), StringComparison.Ordinal);
        if (valid)
        {
            lock (sync)
            {
                Verified = true;
                dirty = true;
            }
        }
        return valid;
    }

    public void Flush()
    {
        (long Start, long End)[] snapshot;
        bool verified;
        lock (sync)
        {
            if (!dirty)
            {
                return;
            }
            snapshot = [.. stored.Items];
            verified = Verified;
            dirty = false;
        }
        try
        {
            NativeFile.Flush(handle);
            WriteIndex(indexPath, Total, verified, snapshot);
        }
        catch
        {
            lock (sync)
            {
                dirty = true;
            }
            throw;
        }
    }

    public void Dispose()
    {
        try
        {
            Flush();
        }
        finally
        {
            handle.Dispose();
        }
    }

    private static (string Data, string Index) Paths(string directory, string name) =>
        (Path.Combine(directory, name), Path.Combine(directory, name + ".index"));

    private static void WriteIndex(string path, long total, bool verified, IReadOnlyList<(long Start, long End)> ranges)
    {
        using var body = new MemoryStream();
        using (var writer = new BinaryWriter(body, System.Text.Encoding.UTF8, leaveOpen: true))
        {
            writer.Write(IndexMagic);
            writer.Write(IndexVersion);
            writer.Write(total);
            writer.Write(verified);
            writer.Write(ranges.Count);
            foreach (var (start, end) in ranges)
            {
                writer.Write(start);
                writer.Write(end);
            }
        }
        var content = body.ToArray();
        var temporary = path + ".tmp";
        using (var file = new FileStream(temporary, FileMode.Create, FileAccess.Write, FileShare.None))
        {
            file.Write(content);
            file.Write(SHA256.HashData(content));
            file.Flush(flushToDisk: true);
        }
        File.Move(temporary, path, overwrite: true);
    }

    private static (long Total, bool Verified, List<(long Start, long End)> Ranges) ReadIndex(string path)
    {
        var bytes = File.ReadAllBytes(path);
        if (bytes.Length < 32 + 21)
        {
            throw new InvalidDataException("The cache index is too short.");
        }
        var content = bytes.AsSpan(0, bytes.Length - 32);
        if (!SHA256.HashData(content).AsSpan().SequenceEqual(bytes.AsSpan(bytes.Length - 32)))
        {
            throw new InvalidDataException("The cache index checksum does not match.");
        }
        using var reader = new BinaryReader(new MemoryStream(content.ToArray()));
        if (reader.ReadUInt32() != IndexMagic || reader.ReadInt32() != IndexVersion)
        {
            throw new InvalidDataException("Unknown cache index format.");
        }
        var total = reader.ReadInt64();
        var verified = reader.ReadBoolean();
        var count = reader.ReadInt32();
        if (total <= 0 || total > ByteRange.MaxLength * 4 || count < 0 || count > 1_000_000)
        {
            throw new InvalidDataException("The cache index header is out of range.");
        }
        var ranges = new List<(long Start, long End)>(count);
        long previousEnd = -1;
        for (var i = 0; i < count; i++)
        {
            var start = reader.ReadInt64();
            var end = reader.ReadInt64();
            if (start <= previousEnd || end <= start || end > total)
            {
                throw new InvalidDataException("The cache index ranges are invalid.");
            }
            ranges.Add((start, end));
            previousEnd = end;
        }
        return (total, verified, ranges);
    }
}
