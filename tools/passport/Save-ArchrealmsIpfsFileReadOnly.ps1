param(
    [Parameter(Mandatory = $true)]
    [string]$Cid,
    [string]$RelativePath,
    [string]$WorkspaceRoot,
    [string]$DestinationPath,
    [string]$IpfsRepoPath
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

if (-not $WorkspaceRoot) {
    $WorkspaceRoot = (Get-Location).Path
}
elseif (Test-Path -LiteralPath $WorkspaceRoot) {
    $WorkspaceRoot = (Resolve-Path -LiteralPath $WorkspaceRoot).Path
}
else {
    $WorkspaceRoot = [System.IO.Path]::GetFullPath($WorkspaceRoot)
}

$normalizedRelativePath = if ([string]::IsNullOrWhiteSpace($RelativePath)) {
    "root-object.txt"
}
else {
    $RelativePath.Replace("/", "\").TrimStart("\")
}

if (-not $DestinationPath) {
    $DestinationPath = Join-Path $WorkspaceRoot (Join-Path "records\ipfs-readonly" (Join-Path $Cid $normalizedRelativePath))
}
elseif (Test-Path -LiteralPath $DestinationPath) {
    $DestinationPath = (Resolve-Path -LiteralPath $DestinationPath).Path
}
else {
    $DestinationPath = [System.IO.Path]::GetFullPath($DestinationPath)
}

$destinationDirectory = Split-Path -Parent $DestinationPath
if ($destinationDirectory) {
    New-Item -ItemType Directory -Force -Path $destinationDirectory | Out-Null
}

$bytes = Read-ArchrealmsIpfsBytes -Cid $Cid -RelativePath $RelativePath -IpfsRepoPath $IpfsRepoPath
[System.IO.File]::WriteAllBytes($DestinationPath, $bytes)
(Get-Item -LiteralPath $DestinationPath).IsReadOnly = $true

$metadataPath = $DestinationPath + ".metadata.json"
$metadata = [ordered]@{
    cid = $Cid
    relative_path = $RelativePath
    ipfs_path = Get-ArchrealmsIpfsPathSpec -Cid $Cid -RelativePath $RelativePath
    destination_path = $DestinationPath
    byte_count = $bytes.Length
    sha256 = Get-Sha256Hex -Bytes $bytes
    fetched_utc = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    read_only = $true
}

Write-ArchrealmsUtf8Json -Path $metadataPath -InputObject $metadata
$metadata | Add-Member -NotePropertyName metadata_path -NotePropertyValue $metadataPath
$metadata | ConvertTo-Json -Depth 6 -Compress
