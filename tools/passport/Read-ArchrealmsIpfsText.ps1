param(
    [Parameter(Mandatory = $true)]
    [string]$Cid,
    [string]$RelativePath,
    [string]$IpfsRepoPath,
    [int]$MaxBytes = 65536
)

$ErrorActionPreference = "Stop"

Import-Module (Join-Path $PSScriptRoot "..\ipfs\ArchrealmsIpfs.psm1") -Force

function Get-Sha256Hex {
    param(
        [Parameter(Mandatory = $true)]
        [byte[]]$Bytes
    )

    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hash = $sha256.ComputeHash($Bytes)
    }
    finally {
        $sha256.Dispose()
    }

    return ([System.BitConverter]::ToString($hash)).Replace("-", "").ToLowerInvariant()
}

$bytes = Read-ArchrealmsIpfsBytes -Cid $Cid -RelativePath $RelativePath -IpfsRepoPath $IpfsRepoPath
$previewBytes = $bytes
$truncated = $false

if ($bytes.Length -gt $MaxBytes) {
    $previewBytes = $bytes[0..($MaxBytes - 1)]
    $truncated = $true
}

$previewText = [System.Text.Encoding]::UTF8.GetString($previewBytes)
$result = [ordered]@{
    cid = $Cid
    relative_path = $RelativePath
    ipfs_path = Get-ArchrealmsIpfsPathSpec -Cid $Cid -RelativePath $RelativePath
    byte_count = $bytes.Length
    sha256 = Get-Sha256Hex -Bytes $bytes
    preview_text = $previewText
    preview_byte_count = $previewBytes.Length
    truncated = $truncated
}

$result | ConvertTo-Json -Depth 6 -Compress
