param(
    [Parameter(Mandatory = $true)]
    [string]$KeyPath,
    [Parameter(Mandatory = $true)]
    [string[]]$Zip,
    [string]$Version = '',
    [string]$OutputDirectory = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$root = Split-Path -Parent $PSScriptRoot
$Zip = @($Zip | ForEach-Object { $_ -split ',' } | Where-Object { $_ -ne '' })
if ($Version -eq '') {
    $Version = ([xml](Get-Content -LiteralPath (Join-Path $root 'src\OsbManager\OsbManager.csproj') -Raw)).Project.PropertyGroup.Version | Where-Object { $_ } | Select-Object -First 1
}
if ($Version -cnotmatch '^(0|[1-9][0-9]{0,5})\.(0|[1-9][0-9]{0,5})\.(0|[1-9][0-9]{0,5})$') {
    throw "The version must look like 1.2.3. Got: $Version"
}
$platforms = @{
    'OSB-Manager-windows-x64.zip' = 'windows-x64'
    'OSB-Manager-macos-arm64.zip' = 'macos-arm64'
}
$maxAssetBytes = 512L * 1024 * 1024

function Read-PrivateKey([string]$path) {
    $text = [IO.File]::ReadAllText([IO.Path]::GetFullPath($path))
    $label = 'PRIVATE' + ' KEY'
    if ($text -cnotmatch "-----BEGIN $label-----([A-Za-z0-9+/=\s]+)-----END $label-----") {
        throw "$path is not a PKCS#8 PEM private key made by new-update-key.ps1."
    }
    $der = [Convert]::FromBase64String(($Matches[1] -replace '\s', ''))
    $text = $null
    try {
        return [Security.Cryptography.CngKey]::Import($der, [Security.Cryptography.CngKeyBlobFormat]::Pkcs8PrivateBlob)
    }
    finally {
        [Array]::Clear($der, 0, $der.Length)
    }
}

function Get-PublicKey([Security.Cryptography.CngKey]$key) {
    $blob = $key.Export([Security.Cryptography.CngKeyBlobFormat]::EccPublicBlob)
    if ($blob.Length -ne 72) {
        throw 'The key is not an ECDSA P-256 key.'
    }
    $prefix = [byte[]](0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01, 0x06, 0x08, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07, 0x03, 0x42, 0x00, 0x04)
    $spki = New-Object byte[] 91
    [Array]::Copy($prefix, 0, $spki, 0, 27)
    [Array]::Copy($blob, 8, $spki, 27, 64)
    return [Convert]::ToBase64String($spki)
}

function Get-Sha256Hex([string]$path) {
    return (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
}

$key = Read-PrivateKey $KeyPath
if ($key.Algorithm.Algorithm -ne 'ECDSA_P256' -and $key.Algorithm.Algorithm -ne 'ECDSA') {
    $key.Dispose()
    throw 'The key is not an ECDSA P-256 key.'
}
$ecdsa = New-Object Security.Cryptography.ECDsaCng($key)
try {
    if ($ecdsa.KeySize -ne 256) {
        throw 'The key is not an ECDSA P-256 key.'
    }
    $publicKey = Get-PublicKey $key
    $embedded = Get-Content -LiteralPath (Join-Path $root 'src\OsbManager.Core\Updates\UpdateKeys.cs') -Raw
    if (-not $embedded.Contains($publicKey)) {
        Write-Warning 'This key is not in src/OsbManager.Core/Updates/UpdateKeys.cs. Released apps will not accept these signatures until its public key is committed there and in UpdateKeys.swift.'
    }

    foreach ($zipPath in $Zip) {
        $zipFull = [IO.Path]::GetFullPath($zipPath)
        $name = [IO.Path]::GetFileName($zipFull)
        if (-not $platforms.ContainsKey($name)) {
            throw "Unknown release file $name. Expected one of: $($platforms.Keys -join ', ')."
        }
        if (-not (Test-Path -LiteralPath $zipFull -PathType Leaf)) {
            throw "$zipFull does not exist."
        }
        $platform = $platforms[$name]
        $size = (Get-Item -LiteralPath $zipFull).Length
        if ($size -le 0 -or $size -gt $maxAssetBytes) {
            throw "$name has $size bytes; the limit is $maxAssetBytes."
        }
        $hash = Get-Sha256Hex $zipFull
        $checksumFile = "$zipFull.sha256"
        if (Test-Path -LiteralPath $checksumFile) {
            $listed = ((Get-Content -LiteralPath $checksumFile -Raw).Trim() -split '\s+')[0].ToLowerInvariant()
            if ($listed -ne $hash) {
                throw "$name does not match $name.sha256. Nothing was signed."
            }
        }
        $target = if ($OutputDirectory -ne '') { [IO.Path]::GetFullPath($OutputDirectory) } else { Split-Path -Parent $zipFull }
        New-Item -ItemType Directory -Force -Path $target | Out-Null

        $manifestName = "OSB-Manager-$platform.update.json"
        $manifest = '{"format":1,"product":"osb-manager","platform":"' + $platform + '","version":"' + $Version + '","asset":"' + $name + '","size":' + $size + ',"sha256":"' + $hash + '"}' + "`n"
        $manifestBytes = (New-Object Text.UTF8Encoding($false)).GetBytes($manifest)
        $signature = $ecdsa.SignData($manifestBytes, [Security.Cryptography.HashAlgorithmName]::SHA256)
        if ($signature.Length -ne 64 -or -not $ecdsa.VerifyData($manifestBytes, $signature, [Security.Cryptography.HashAlgorithmName]::SHA256)) {
            throw 'The new signature does not verify. Nothing was written.'
        }
        $manifestPath = Join-Path $target $manifestName
        [IO.File]::WriteAllBytes($manifestPath, $manifestBytes)
        [IO.File]::WriteAllText("$manifestPath.sig", [Convert]::ToBase64String($signature) + "`n", (New-Object Text.ASCIIEncoding))
        Write-Host "Signed $name $Version ($size bytes, SHA-256 $hash)"
        Write-Host "  $manifestPath"
        Write-Host "  $manifestPath.sig"
    }
}
finally {
    $ecdsa.Dispose()
    $key.Dispose()
}
