param(
    [string]$OutputDirectory = (Join-Path (Split-Path -Parent $PSScriptRoot) 'dist'),
    [string]$RuntimeIdentifier = 'win-x64'
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$archiveName = 'OSB-Manager-windows-x64.zip'
$work = Join-Path $env:TEMP 'OsbManager-package'
$publishDirectory = Join-Path $work 'publish'
$stagingDirectory = Join-Path $work 'stage'

if (Test-Path -LiteralPath $work) {
    Remove-Item -LiteralPath $work -Recurse -Force
}
New-Item -ItemType Directory -Force -Path $publishDirectory, $stagingDirectory, $OutputDirectory | Out-Null

dotnet publish (Join-Path $root 'src\OsbManager\OsbManager.csproj') `
    -c Release `
    -r $RuntimeIdentifier `
    --self-contained true `
    -p:PublishSingleFile=true `
    -p:IncludeNativeLibrariesForSelfExtract=true `
    -p:EnableCompressionInSingleFile=true `
    -p:DebugType=none `
    -p:DebugSymbols=false `
    -o $publishDirectory `
    --artifacts-path (Join-Path $work 'artifacts')
if ($LASTEXITCODE -ne 0) {
    throw "dotnet publish failed with exit code $LASTEXITCODE."
}

Copy-Item -LiteralPath (Join-Path $publishDirectory 'OsbManager.exe') -Destination $stagingDirectory
Copy-Item -LiteralPath (Join-Path $root 'README.md'), (Join-Path $root 'LICENSE') -Destination $stagingDirectory

$archive = Join-Path $OutputDirectory $archiveName
$checksumFile = "$archive.sha256"
Remove-Item -LiteralPath $archive, $checksumFile -Force -ErrorAction SilentlyContinue
Compress-Archive -Path (Join-Path $stagingDirectory '*') -DestinationPath $archive -CompressionLevel Optimal

$hash = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant()
[IO.File]::WriteAllText($checksumFile, "$hash  $archiveName`n", (New-Object Text.UTF8Encoding($false)))

Remove-Item -LiteralPath $work -Recurse -Force
Write-Host "Wrote $archive"
Write-Host "SHA-256 $hash"
