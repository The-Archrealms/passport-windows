param(
    [Parameter(Mandatory = $true)]
    [string]$Cid,
    [string]$WorkspaceRoot,
    [string]$OutputRoot,
    [string]$CarPath,
    [string]$RecordPath,
    [string]$IpfsRepoPath,
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"

Import-Module (Join-Path $PSScriptRoot "ArchrealmsIpfs.psm1") -Force

$trimmedCid = $Cid.Trim()
if ([string]::IsNullOrWhiteSpace($trimmedCid)) {
    throw "A CID is required for CAR export."
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

if (-not $OutputRoot) {
    $OutputRoot = Join-Path $WorkspaceRoot "records\ipfs-car-exports"
}
else {
    $OutputRoot = [System.IO.Path]::GetFullPath($OutputRoot)
}

New-Item -ItemType Directory -Force -Path $OutputRoot | Out-Null

$safeCid = $trimmedCid -replace '[^A-Za-z0-9._-]', '-'
if ([string]::IsNullOrWhiteSpace($safeCid)) {
    $safeCid = "cid"
}

$timestamp = (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssZ")
if (-not $CarPath) {
    $CarPath = Join-Path $OutputRoot "$timestamp-$safeCid.car"
}
else {
    $CarPath = [System.IO.Path]::GetFullPath($CarPath)
}

if (-not $RecordPath) {
    $RecordPath = Join-Path $OutputRoot "$timestamp-$safeCid.car-export.json"
}
else {
    $RecordPath = [System.IO.Path]::GetFullPath($RecordPath)
}

$resolvedRepoPath = Get-ArchrealmsResolvedIpfsRepoPath -IpfsRepoPath $IpfsRepoPath
$carSha256 = ""
$carSizeBytes = 0

if (-not $DryRun) {
    $CarPath = Export-ArchrealmsIpfsCar -Cid $trimmedCid -CarPath $CarPath -IpfsRepoPath $resolvedRepoPath
    $carItem = Get-Item -LiteralPath $CarPath
    $carSha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $CarPath).Hash.ToLowerInvariant()
    $carSizeBytes = $carItem.Length
}

$record = [ordered]@{
    record_type = "ipfs_car_export"
    created_utc = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    dry_run = [bool]$DryRun
    cid = $trimmedCid
    car_path = $CarPath
    car_sha256 = $carSha256
    car_size_bytes = $carSizeBytes
    ipfs_repo_path = $resolvedRepoPath
    export_command = "ipfs dag export <cid>"
}

Write-ArchrealmsUtf8Json -Path $RecordPath -InputObject $record

Write-Host ""
Write-Host "Archrealms IPFS CAR export recorded:"
Write-Host "  CID    : $trimmedCid"
Write-Host "  Record : $RecordPath"
Write-Host "  CAR    : $CarPath"
if (-not $DryRun) {
    Write-Host "  SHA256 : $carSha256"
    Write-Host "  Bytes  : $carSizeBytes"
}
