namespace OsbManager.Core;

public sealed record LogEntry(DateTime Time, string Level, string Message)
{
    public override string ToString() => $"[{Time:HH:mm:ss}] {Level}: {Message}";
}

/// <summary>Keeps recent lines in memory for the Log tab and appends every line to a daily file.</summary>
public sealed class AppLog
{
    private const int Capacity = 1000;

    private readonly string directory;
    private readonly Queue<LogEntry> recent = new();
    private readonly object sync = new();

    public AppLog(string directory)
    {
        this.directory = directory;
        Directory.CreateDirectory(directory);
    }

    /// <summary>Raised on the thread that logged; UI subscribers must marshal to their own thread.</summary>
    public event Action<LogEntry>? Added;

    public IReadOnlyList<LogEntry> Recent
    {
        get { lock (sync) { return [.. recent]; } }
    }

    public void Info(string message) => Write("info", message);

    public void Warn(string message) => Write("warn", message);

    public void Error(string message, Exception? exception = null) =>
        Write("error", exception is null ? message : $"{message} ({exception.GetType().Name}: {exception.Message})");

    private void Write(string level, string message)
    {
        var entry = new LogEntry(DateTime.Now, level, message);
        lock (sync)
        {
            recent.Enqueue(entry);
            while (recent.Count > Capacity)
            {
                recent.Dequeue();
            }
            try
            {
                File.AppendAllText(Path.Combine(directory, $"app-{entry.Time:yyyyMMdd}.log"), entry + Environment.NewLine);
            }
            catch (IOException)
            {
            }
        }
        Added?.Invoke(entry);
    }
}
