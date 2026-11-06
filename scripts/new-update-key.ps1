param(
    [Parameter(Mandatory = $true)]
    [string]$KeyPath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repositoryRoot = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot)).TrimEnd('\') + '\'
$fullPath = [IO.Path]::GetFullPath($KeyPath)
if ($fullPath.StartsWith($repositoryRoot, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Choose a key path outside the repository ($repositoryRoot), so the key can never be committed."
}
if (Test-Path -LiteralPath $fullPath) {
    throw "$fullPath already exists. This script never overwrites a key."
}
$folder = Split-Path -Parent $fullPath
if (-not (Test-Path -LiteralPath $folder -PathType Container)) {
    New-Item -ItemType Directory -Path $folder | Out-Null
}

$parameters = New-Object Security.Cryptography.CngKeyCreationParameters
$parameters.ExportPolicy = [Security.Cryptography.CngExportPolicies]::AllowPlaintextExport
$key = [Security.Cryptography.CngKey]::Create([Security.Cryptography.CngAlgorithm]::ECDsaP256, [NullString]::Value, $parameters)
if (-not $key.IsEphemeral) {
    $key.Delete()
    throw 'The key was not created in memory only. Nothing was written.'
}
$pkcs8 = $null
try {
    $pkcs8 = $key.Export([Security.Cryptography.CngKeyBlobFormat]::Pkcs8PrivateBlob)
    $publicBlob = $key.Export([Security.Cryptography.CngKeyBlobFormat]::EccPublicBlob)
    if ($publicBlob.Length -ne 72) {
        throw "Unexpected public key blob length $($publicBlob.Length)."
    }
    $prefix = [byte[]](0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01, 0x06, 0x08, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07, 0x03, 0x42, 0x00, 0x04)
    $spki = New-Object byte[] 91
    [Array]::Copy($prefix, 0, $spki, 0, 27)
    [Array]::Copy($publicBlob, 8, $spki, 27, 64)

    $stream = [IO.File]::Open($fullPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    $stream.Dispose()
    $user = [Security.Principal.WindowsIdentity]::GetCurrent().User
    $acl = New-Object Security.AccessControl.FileSecurity
    $acl.SetAccessRuleProtection($true, $false)
    $acl.SetOwner($user)
    $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($user, [Security.AccessControl.FileSystemRights]::FullControl, [Security.AccessControl.AccessControlType]::Allow)))
    Set-Acl -LiteralPath $fullPath -AclObject $acl

    $body = [Convert]::ToBase64String($pkcs8, [Base64FormattingOptions]::InsertLineBreaks)
    $label = 'PRIVATE' + ' KEY'
    $pem = "-----BEGIN $label-----`n" + ($body -replace "`r`n", "`n") + "`n-----END $label-----`n"
    [IO.File]::WriteAllText($fullPath, $pem, (New-Object Text.UTF8Encoding($false)))
    $pem = $null
    $body = $null

    $publicKey = [Convert]::ToBase64String($spki)
    $sha = [Security.Cryptography.SHA256]::Create()
    $fingerprint = ([BitConverter]::ToString($sha.ComputeHash($spki)) -replace '-', '').ToLowerInvariant().Substring(0, 16)
    $sha.Dispose()
    Write-Host "Wrote the private key to $fullPath (readable only by $([Security.Principal.WindowsIdentity]::GetCurrent().Name))."
    Write-Host "Public key fingerprint: $fingerprint"
    Write-Host 'Public key (give this to the coordinator; it goes into UpdateKeys.cs and UpdateKeys.swift):'
    Write-Output $publicKey
}
finally {
    if ($null -ne $pkcs8) {
        [Array]::Clear($pkcs8, 0, $pkcs8.Length)
    }
    $key.Dispose()
}
