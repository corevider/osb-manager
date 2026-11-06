[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $DataFolder,
    [switch] $Json
)

$ErrorActionPreference = 'Stop'

$data_root = [System.IO.Path]::GetFullPath($DataFolder).TrimEnd('\')
$local_app_data = [Environment]::GetFolderPath('LocalApplicationData')
$protected_folders = @('OSB Manager') | ForEach-Object { [System.IO.Path]::GetFullPath((Join-Path $local_app_data $_)).TrimEnd('\') }
if ($protected_folders -contains $data_root) {
    throw "Refusing to read the installed app's data folder: $data_root"
}

$browser_data = Join-Path $data_root 'WebView2'

function Get-Role([string] $command_line) {
    if ($command_line -match '--type=gpu-process') { return 'gpu' }
    if ($command_line -match '--type=renderer') { return 'renderer' }
    if ($command_line -match '--type=utility') {
        if ($command_line -match '--utility-sub-type=([\w\.]+)') { return 'utility:' + ($Matches[1] -split '\.')[-1] }
        return 'utility'
    }
    if ($command_line -match '--type=crashpad-handler') { return 'crashpad' }
    if ($command_line -match '--type=([\w-]+)') { return $Matches[1] }
    return 'browser'
}

function ConvertTo-Megabytes([double] $bytes) { [math]::Round($bytes / 1MB, 1) }

$rows = foreach ($item in Get-CimInstance Win32_Process -Filter "Name = 'msedgewebview2.exe'") {
    $command_line = [string] $item.CommandLine
    if ($command_line.IndexOf($browser_data, [StringComparison]::OrdinalIgnoreCase) -lt 0) { continue }
    $process = Get-Process -Id $item.ProcessId -ErrorAction SilentlyContinue
    if ($null -eq $process) { continue }
    [pscustomobject]@{
        Role       = Get-Role $command_line
        ProcessId  = $item.ProcessId
        PrivateMB  = ConvertTo-Megabytes $process.PrivateMemorySize64
        WorkingMB  = ConvertTo-Megabytes $process.WorkingSet64
        CpuSeconds = [math]::Round($process.TotalProcessorTime.TotalSeconds, 2)
    }
}
$rows = @($rows)

$groups = $rows | Group-Object Role | ForEach-Object {
    [pscustomobject]@{
        Role      = $_.Name
        Count     = $_.Count
        PrivateMB = [math]::Round(($_.Group | Measure-Object PrivateMB -Sum).Sum, 1)
        WorkingMB = [math]::Round(($_.Group | Measure-Object WorkingMB -Sum).Sum, 1)
        CpuSeconds = [math]::Round(($_.Group | Measure-Object CpuSeconds -Sum).Sum, 2)
    }
} | Sort-Object PrivateMB -Descending

$total = [pscustomobject]@{
    Role      = 'total'
    Count     = $rows.Count
    PrivateMB = [math]::Round(($rows | Measure-Object PrivateMB -Sum).Sum, 1)
    WorkingMB = [math]::Round(($rows | Measure-Object WorkingMB -Sum).Sum, 1)
    CpuSeconds = [math]::Round(($rows | Measure-Object CpuSeconds -Sum).Sum, 2)
}

if ($Json) {
    [pscustomobject]@{ Processes = $rows; Groups = @($groups); Total = $total } | ConvertTo-Json -Depth 4
    return
}

$rows | Sort-Object Role, ProcessId | Format-Table -AutoSize
@($groups) + $total | Format-Table -AutoSize
