param(
    [string]$Destination = (Join-Path $env:LOCALAPPDATA 'Programs\OSB Manager'),
    [string]$ShortcutName = 'OSB Manager',
    [string]$ShortcutDirectory = [Environment]::GetFolderPath('Desktop')
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$exe = Join-Path $Destination 'OsbManager.exe'

if (Get-Process OsbManager -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $exe }) {
    throw "OSB Manager is running from $Destination. Close it, then run this script again."
}

$artifacts = Join-Path $env:TEMP 'OsbManager-install'
dotnet publish (Join-Path $root 'src\OsbManager\OsbManager.csproj') -c Release -o $Destination --artifacts-path $artifacts
if ($LASTEXITCODE -ne 0) {
    throw "dotnet publish failed with exit code $LASTEXITCODE."
}

$link = Join-Path $ShortcutDirectory "$ShortcutName.lnk"
$shortcut = (New-Object -ComObject WScript.Shell).CreateShortcut($link)
$shortcut.TargetPath = $exe
$shortcut.WorkingDirectory = $Destination
$shortcut.IconLocation = "$exe,0"
$shortcut.Description = 'Run several OpenSRO accounts side by side'
$shortcut.Save()

Write-Host "Installed to $Destination"
Write-Host "Shortcut: $link"
