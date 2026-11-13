param(
    [Parameter(Mandatory = $true)]
    [string]$Work,
    [string]$Source = '',
    [string]$ReleaseExe = '',
    [switch]$SkipReleaseCheck,
    [int]$TimeoutSeconds = 120
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$root = Split-Path -Parent $PSScriptRoot
if ($Source -eq '') {
    $Source = $root
}
$Work = [IO.Path]::GetFullPath($Work)
$Source = [IO.Path]::GetFullPath($Source)
$repositoryRoot = $root.TrimEnd('\') + '\'
if ($Work.StartsWith($repositoryRoot, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Choose a work folder outside the repository ($root)."
}
if (Test-Path -LiteralPath $Work) {
    throw "$Work already exists. Use a new folder."
}
New-Item -ItemType Directory -Path $Work | Out-Null

$oldVersion = '1.0.1'
$newVersion = '9.9.9'
$zipName = 'OSB-Manager-windows-x64.zip'

Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.IO;
using System.IO.Compression;
using System.Text;

public sealed class OsbBundleEntry
{
    public long Offset;
    public long Size;
    public long CompressedSize;
    public string Path;
}

public static class OsbBundle
{
    private static readonly byte[] Signature = {
        0x8b, 0x12, 0x02, 0xb9, 0x6a, 0x61, 0x20, 0x38, 0x72, 0x7b, 0x93, 0x02, 0x14, 0xd7, 0xa0, 0x32,
        0x13, 0xf5, 0xb9, 0xe6, 0xef, 0xae, 0x33, 0x18, 0xee, 0x3b, 0x2d, 0xce, 0x24, 0xb3, 0x6a, 0xae };

    public static int IndexOf(byte[] data, byte[] pattern, int start)
    {
        for (int i = start; i + pattern.Length <= data.Length; i++)
        {
            int j = 0;
            while (j < pattern.Length && data[i + j] == pattern[j])
            {
                j++;
            }
            if (j == pattern.Length)
            {
                return i;
            }
        }
        return -1;
    }

    public static List<OsbBundleEntry> ReadEntries(string exePath)
    {
        byte[] data = File.ReadAllBytes(exePath);
        int at = IndexOf(data, Signature, 8);
        if (at < 0)
        {
            throw new InvalidDataException("The exe is not a single-file bundle.");
        }
        long headerOffset = BitConverter.ToInt64(data, at - 8);
        if (headerOffset <= 0 || headerOffset >= data.Length)
        {
            throw new InvalidDataException("The exe is not a single-file bundle.");
        }
        var entries = new List<OsbBundleEntry>();
        using (var reader = new BinaryReader(new MemoryStream(data), Encoding.UTF8))
        {
            reader.BaseStream.Position = headerOffset;
            uint major = reader.ReadUInt32();
            reader.ReadUInt32();
            int count = reader.ReadInt32();
            reader.ReadString();
            if (major >= 2)
            {
                reader.ReadInt64();
                reader.ReadInt64();
                reader.ReadInt64();
                reader.ReadInt64();
                reader.ReadUInt64();
            }
            for (int i = 0; i < count; i++)
            {
                var entry = new OsbBundleEntry();
                entry.Offset = reader.ReadInt64();
                entry.Size = reader.ReadInt64();
                entry.CompressedSize = major >= 6 ? reader.ReadInt64() : 0;
                reader.ReadByte();
                entry.Path = reader.ReadString();
                entries.Add(entry);
            }
        }
        return entries;
    }

    public static byte[] ReadEntry(string exePath, OsbBundleEntry entry)
    {
        using (var file = File.OpenRead(exePath))
        {
            file.Position = entry.Offset;
            long stored = entry.CompressedSize > 0 ? entry.CompressedSize : entry.Size;
            var raw = new byte[stored];
            int read = 0;
            while (read < raw.Length)
            {
                int n = file.Read(raw, read, raw.Length - read);
                if (n <= 0)
                {
                    throw new EndOfStreamException();
                }
                read += n;
            }
            if (entry.CompressedSize <= 0)
            {
                return raw;
            }
            var result = new byte[entry.Size];
            using (var inflate = new DeflateStream(new MemoryStream(raw), CompressionMode.Decompress))
            {
                int done = 0;
                while (done < result.Length)
                {
                    int n = inflate.Read(result, done, result.Length - done);
                    if (n <= 0)
                    {
                        throw new EndOfStreamException();
                    }
                    done += n;
                }
            }
            return result;
        }
    }

    public static bool Contains(byte[] data, string text, bool utf16)
    {
        byte[] pattern = utf16 ? Encoding.Unicode.GetBytes(text) : Encoding.UTF8.GetBytes(text);
        return IndexOf(data, pattern, 0) >= 0;
    }
}
'@

function Publish-App([string]$name, [string]$version, [bool]$testSwitch) {
    $output = Join-Path $Work "publish-$name"
    $arguments = @(
        'publish', (Join-Path $Source 'src\OsbManager\OsbManager.csproj'),
        '-c', 'Release',
        '-r', 'win-x64',
        '--self-contained', 'true',
        '-p:PublishSingleFile=true',
        '-p:IncludeNativeLibrariesForSelfExtract=true',
        '-p:EnableCompressionInSingleFile=true',
        '-p:DebugType=none',
        '-p:DebugSymbols=false',
        '-o', $output,
        '--artifacts-path', (Join-Path $Work "artifacts-$name"),
        '-nologo', '-v', 'q'
    )
    if ($version -ne '') {
        $arguments += "-p:Version=$version"
    }
    if ($testSwitch) {
        $arguments += '-p:OsbUpdateE2E=true'
    }
    & dotnet @arguments | Out-Host
    if ($LASTEXITCODE -ne 0) {
        throw "dotnet publish of the $name exe failed with exit code $LASTEXITCODE."
    }
    return Join-Path $output 'OsbManager.exe'
}

function Get-AppAssembly([string]$exe) {
    $entry = [OsbBundle]::ReadEntries($exe) | Where-Object { $_.Path -eq 'OsbManager.dll' }
    if ($null -eq $entry) {
        throw "$exe has no OsbManager.dll in its bundle."
    }
    return , [OsbBundle]::ReadEntry($exe, $entry)
}

function Test-HasTestSwitch([string]$exe) {
    $assembly = Get-AppAssembly $exe
    return [OsbBundle]::Contains($assembly, 'OSBMANAGER_TEST_UPDATE_FEED', $true) -or [OsbBundle]::Contains($assembly, 'UpdateTestFeed', $false)
}

function Get-OwnProcesses {
    return @(Get-CimInstance Win32_Process -Filter "Name = 'OsbManager.exe'" | Where-Object { $_.ExecutablePath -and $_.ExecutablePath.StartsWith($Work, [StringComparison]::OrdinalIgnoreCase) })
}

function Hide-Work([string]$text) {
    return $text.Replace($Work, '<work>')
}

$result = [ordered]@{}
$failures = New-Object Collections.Generic.List[string]

Write-Host "Publishing the old ($oldVersion) and the new ($newVersion) exe with the package flags and the test switch..."
$oldExe = Publish-App 'old' $oldVersion $true
$newExe = Publish-App 'new' $newVersion $true

$oldEntries = [OsbBundle]::ReadEntries($oldExe)
$newEntries = [OsbBundle]::ReadEntries($newExe)
$oldProcess = $oldEntries | Where-Object { $_.Path -eq 'System.Diagnostics.Process.dll' }
$newProcess = $newEntries | Where-Object { $_.Path -eq 'System.Diagnostics.Process.dll' }
$result.BundleEntries = $oldEntries.Count
$result.ProcessDllOffsetOld = $oldProcess.Offset
$result.ProcessDllOffsetNew = $newProcess.Offset
$result.ProcessDllCompressed = $oldProcess.CompressedSize -gt 0
if ($oldProcess.Offset -eq $newProcess.Offset) {
    throw 'System.Diagnostics.Process.dll sits at the same offset in both exes, so this run could not show a late load from the swapped exe. Change the new version string and run again.'
}

$app = Join-Path $Work 'app'
$feed = Join-Path $Work 'feed'
$data = Join-Path $Work 'data'
$keyFolder = Join-Path $Work 'key'
$stage = Join-Path $Work 'stage'
New-Item -ItemType Directory -Path $app, $feed, $data, $stage | Out-Null
Copy-Item -LiteralPath $oldExe -Destination $app
Copy-Item -LiteralPath $newExe -Destination $stage
Compress-Archive -Path (Join-Path $stage 'OsbManager.exe') -DestinationPath (Join-Path $feed $zipName)
$publicKey = (& (Join-Path $root 'scripts\new-update-key.ps1') -KeyPath (Join-Path $keyFolder 'e2e.pem') | Select-Object -Last 1)
& (Join-Path $root 'scripts\sign-update.ps1') -KeyPath (Join-Path $keyFolder 'e2e.pem') -Zip (Join-Path $feed $zipName) -Version $newVersion 3>$null | Out-Null
Remove-Item -LiteralPath $keyFolder -Recurse -Force
[IO.File]::WriteAllText((Join-Path $feed 'latest.json'), '{"tag_name":"v' + $newVersion + '","name":"OSB Manager ' + $newVersion + ' (self-update test)","draft":false,"prerelease":false,"assets":[{"name":"' + $zipName + '"},{"name":"OSB-Manager-windows-x64.update.json"},{"name":"OSB-Manager-windows-x64.update.json.sig"}]}')

$exe = Join-Path $app 'OsbManager.exe'
$env:OSBMANAGER_TEST_UPDATE_FEED = $feed
$env:OSBMANAGER_TEST_UPDATE_KEY = $publicKey
$env:OSBMANAGER_TEST_UPDATE_DELAY_SECONDS = '3'
$env:OSBMANAGER_TEST_UPDATE_INSTALL = '1'
Remove-Item Env:\OSBMANAGER_TEST_UPDATE_VERSION -ErrorAction SilentlyContinue

$first = $null
$log = ''
$remote = New-Object Collections.Generic.HashSet[string]
try {
    Write-Host 'Starting the old exe; it finds the update after 3 seconds and installs it...'
    $first = Start-Process -FilePath $exe -ArgumentList @('--data', "`"$data`"", '--osb-url', 'http://127.0.0.1:9/osb.user.js') -PassThru
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 250
        foreach ($process in Get-OwnProcesses) {
            foreach ($connection in @(Get-NetTCPConnection -OwningProcess $process.ProcessId -ErrorAction SilentlyContinue)) {
                if ($connection.RemoteAddress -notin @('127.0.0.1', '::1', '0.0.0.0', '::')) {
                    [void]$remote.Add("$($connection.RemoteAddress):$($connection.RemotePort)")
                }
            }
        }
        $files = @(Get-ChildItem -LiteralPath (Join-Path $data 'logs') -Filter 'app-*.log' -ErrorAction SilentlyContinue)
        if ($files.Count -eq 0) {
            continue
        }
        $log = Get-Content -LiteralPath $files[0].FullName -Raw -Encoding UTF8
        if ($log -match 'error: The update (to \S+ )?failed') {
            Start-Sleep -Seconds 1
            $log = Get-Content -LiteralPath $files[0].FullName -Raw -Encoding UTF8
            break
        }
        if ($first.HasExited -and $log.Contains('Removed the previous version left by an update.')) {
            break
        }
    }

    $second = @(Get-OwnProcesses | Where-Object { $_.ProcessId -ne $first.Id })
    $result.OldProcessExited = $first.HasExited
    $result.NewProcessRunning = $second.Count -eq 1
    $result.NewProcessArguments = if ($second.Count -eq 1) { Hide-Work ($second[0].CommandLine) } else { $null }
    $result.InstalledExeVersion = (Get-Item -LiteralPath $exe).VersionInfo.ProductVersion
    $result.InstalledExeIsNew = (Get-FileHash -LiteralPath $exe).Hash -eq (Get-FileHash -LiteralPath $newExe).Hash
    $result.PrevExeLeft = Test-Path -LiteralPath (Join-Path $app 'OsbManager.prev.exe')
    $result.NewExeLeft = Test-Path -LiteralPath (Join-Path $app 'OsbManager.new.exe')
    $result.RemoteConnections = if ($remote.Count -eq 0) { 'none' } else { ($remote | Sort-Object) -join ', ' }

    if (-not $log.Contains("Updated to $newVersion; the new version is starting.")) { $failures.Add('The old exe did not report that the new version signalled.') }
    if (-not $first.HasExited) { $failures.Add('The old exe did not exit.') }
    if ($second.Count -ne 1 -or -not $second[0].CommandLine.Contains("--updated-from $($first.Id)")) { $failures.Add('The new exe is not running with --updated-from.') }
    if (-not $result.InstalledExeIsNew) { $failures.Add('OsbManager.exe is not the new exe.') }
    if (-not $log.Contains('Removed the previous version left by an update.')) { $failures.Add('The new exe did not clean up the previous exe.') }
    if ($result.PrevExeLeft -or $result.NewExeLeft) { $failures.Add('An exe from the swap was left behind.') }
    if ($remote.Count -gt 0) { $failures.Add('An app process connected to a host other than this computer.') }
}
finally {
    foreach ($process in Get-OwnProcesses) {
        Stop-Process -Id $process.ProcessId -Force -ErrorAction SilentlyContinue
    }
    foreach ($name in 'FEED', 'KEY', 'DELAY_SECONDS', 'INSTALL') {
        Remove-Item "Env:\OSBMANAGER_TEST_UPDATE_$name" -ErrorAction SilentlyContinue
    }
}

if (-not $SkipReleaseCheck) {
    if ($ReleaseExe -eq '') {
        Write-Host 'Publishing the Release exe with the package flags and without the test switch...'
        $ReleaseExe = Publish-App 'release' '' $false
    }
    elseif ($ReleaseExe.EndsWith('.zip', [StringComparison]::OrdinalIgnoreCase)) {
        $unpacked = Join-Path $Work 'release-zip'
        Expand-Archive -LiteralPath $ReleaseExe -DestinationPath $unpacked
        $ReleaseExe = Join-Path $unpacked 'OsbManager.exe'
    }
    $result.TestExeHasTestSwitch = Test-HasTestSwitch $oldExe
    $result.ReleaseExeHasTestSwitch = Test-HasTestSwitch $ReleaseExe
    if (-not $result.TestExeHasTestSwitch) { $failures.Add('The scan did not find the test switch in the test exe, so it cannot vouch for the Release exe.') }
    if ($result.ReleaseExeHasTestSwitch) { $failures.Add('The Release exe contains the test update feed.') }
}

$result.Result = if ($failures.Count -eq 0) { 'PASS' } else { 'FAIL' }
[pscustomobject]$result | Format-List | Out-String | Write-Output
foreach ($failure in $failures) {
    Write-Output "FAIL: $failure"
}
Write-Output '--- app log ---'
Write-Output (Hide-Work $log)
if ($failures.Count -gt 0) {
    exit 1
}
