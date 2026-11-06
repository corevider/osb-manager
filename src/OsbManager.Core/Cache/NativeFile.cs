using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

namespace OsbManager.Core.Cache;

internal static class NativeFile
{
    private const uint FsctlSetSparse = 0x000900C4;

    /// <summary>Marks the file sparse so unwritten gaps take no disk space. Returns false where unsupported.</summary>
    public static bool TryMakeSparse(SafeFileHandle handle)
    {
        if (!OperatingSystem.IsWindows())
        {
            return false;
        }
        return DeviceIoControl(handle, FsctlSetSparse, IntPtr.Zero, 0, IntPtr.Zero, 0, out _, IntPtr.Zero);
    }

    public static void Flush(SafeFileHandle handle)
    {
        if (OperatingSystem.IsWindows() && !FlushFileBuffers(handle))
        {
            throw new IOException("Could not flush the cache file.", Marshal.GetHRForLastWin32Error());
        }
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool DeviceIoControl(SafeFileHandle device, uint code, IntPtr input, uint inputSize, IntPtr output, uint outputSize, out uint returned, IntPtr overlapped);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool FlushFileBuffers(SafeFileHandle file);
}
