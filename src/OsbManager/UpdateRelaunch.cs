using System.Diagnostics;

namespace OsbManager;

/// <summary>
/// Starts the new version after an update and waits for it to say it is running. The new process signals a named
/// event as soon as it starts and then waits for this process to exit before it takes the data folder lock.
/// </summary>
internal static class UpdateRelaunch
{
    public const string Option = "--updated-from";

    public static readonly TimeSpan StartTimeout = TimeSpan.FromSeconds(30);

    public static readonly TimeSpan PreviousExitTimeout = TimeSpan.FromSeconds(60);

    public static string EventName(int processId) => $@"Local\OsbManager.Updated.{processId}";

    public static IReadOnlyList<string> ArgumentsForRestart(IEnumerable<string> arguments)
    {
        var result = new List<string>();
        var list = arguments.ToList();
        for (var i = 0; i < list.Count; i++)
        {
            if (list[i] == Option)
            {
                i++;
                continue;
            }
            result.Add(list[i]);
        }
        return result;
    }

    /// <summary>Starts the exe and returns true once it signalled; otherwise stops it and returns false.</summary>
    public static async Task<bool> StartAsync(string exePath, IReadOnlyList<string> arguments, TimeSpan timeout)
    {
        using var ready = new EventWaitHandle(false, EventResetMode.ManualReset, EventName(Environment.ProcessId));
        var start = new ProcessStartInfo(exePath)
        {
            UseShellExecute = false,
            WorkingDirectory = Path.GetDirectoryName(exePath) ?? "",
        };
        foreach (var argument in arguments)
        {
            start.ArgumentList.Add(argument);
        }
        start.ArgumentList.Add(Option);
        start.ArgumentList.Add(Environment.ProcessId.ToString(System.Globalization.CultureInfo.InvariantCulture));
        Process? process;
        try
        {
            process = Process.Start(start);
        }
        catch (Exception e) when (e is System.ComponentModel.Win32Exception or InvalidOperationException)
        {
            return false;
        }
        if (process is null)
        {
            return false;
        }
        using (process)
        {
            var deadline = DateTime.UtcNow + timeout;
            while (DateTime.UtcNow < deadline)
            {
                if (await Task.Run(() => ready.WaitOne(200)).ConfigureAwait(true))
                {
                    return true;
                }
                if (process.HasExited)
                {
                    return false;
                }
            }
            try
            {
                process.Kill(entireProcessTree: true);
                process.WaitForExit(TimeSpan.FromSeconds(10));
            }
            catch (Exception e) when (e is InvalidOperationException or System.ComponentModel.Win32Exception)
            {
            }
            return false;
        }
    }

    /// <summary>Called by the new version: tells the previous one it started, then waits for it to exit.</summary>
    public static void AnnounceAndWait(int previousProcessId)
    {
        if (EventWaitHandle.TryOpenExisting(EventName(previousProcessId), out var ready))
        {
            using (ready)
            {
                ready.Set();
            }
        }
        try
        {
            using var previous = Process.GetProcessById(previousProcessId);
            previous.WaitForExit(PreviousExitTimeout);
        }
        catch (Exception e) when (e is ArgumentException or InvalidOperationException)
        {
        }
    }
}
