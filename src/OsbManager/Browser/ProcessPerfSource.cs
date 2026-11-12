using System.ComponentModel;
using System.Diagnostics;
using OsbManager.Core.Telemetry.Diagnostics;

namespace OsbManager.Browser;

internal sealed class ProcessPerfSource : IPerfSource
{
    private readonly BrowserProcessCache cache;
    private readonly Func<PerfWindows> windows;
    private readonly Action requestRefresh;

    public ProcessPerfSource(BrowserProcessCache cache, Func<PerfWindows> windows, Action requestRefresh)
    {
        this.cache = cache;
        this.windows = windows;
        this.requestRefresh = requestRefresh;
    }

    public PerfSample? Read(DateTimeOffset now)
    {
        var listed = cache.Processes;
        requestRefresh();
        var readings = new List<ProcessReading>(listed.Count);
        foreach (var entry in listed)
        {
            if (ReadProcess(entry.ProcessId, entry.Role) is { } reading)
            {
                readings.Add(reading);
            }
        }
        using var self = Process.GetCurrentProcess();
        return new PerfSample(now, readings, new ProcessReading(self.Id, ProcessRole.Other, self.PrivateMemorySize64, self.TotalProcessorTime.TotalSeconds), windows());
    }

    private static ProcessReading? ReadProcess(int processId, ProcessRole role)
    {
        try
        {
            using var process = Process.GetProcessById(processId);
            return new ProcessReading(processId, role, process.PrivateMemorySize64, process.TotalProcessorTime.TotalSeconds);
        }
        catch (Exception e) when (e is ArgumentException or InvalidOperationException or Win32Exception)
        {
            return null;
        }
    }
}
