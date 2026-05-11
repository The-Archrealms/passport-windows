param(
    [string]$WorkspaceRoot,
    [string]$IpfsRepoPath,
    [string]$RecordPath,
    [string]$ApiMultiaddr = "/ip4/127.0.0.1/tcp/5001",
    [string]$GatewayMultiaddr = "/ip4/127.0.0.1/tcp/8080",
    [int]$SwarmPort = 4001,
    [string]$StorageMax = "1GB",
    [int]$StorageGCWatermark = 85,
    [string]$ProvideStrategy = "pinned",
    [string]$ParticipationMode = "Public archive contributor",
    [string]$CachePolicy = "Balanced pinned archive",
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"

Import-Module (Join-Path $PSScriptRoot "ArchrealmsIpfs.psm1") -Force

$resolvedRepoPath = Get-ArchrealmsResolvedIpfsRepoPath -IpfsRepoPath $IpfsRepoPath
if (-not $WorkspaceRoot) {
    $WorkspaceRoot = (Get-Location).Path
}
elseif (Test-Path -LiteralPath $WorkspaceRoot) {
    $WorkspaceRoot = (Resolve-Path -LiteralPath $WorkspaceRoot).Path
}
else {
    $WorkspaceRoot = [System.IO.Path]::GetFullPath($WorkspaceRoot)
}

if (-not $RecordPath) {
    $RecordPath = Join-Path $WorkspaceRoot "records\passport\ipfs-node.local.json"
}

if ($DryRun) {
    $record = [ordered]@{
        dry_run = $true
        repo_path = $resolvedRepoPath
        api_multiaddr = $ApiMultiaddr
        gateway_multiaddr = $GatewayMultiaddr
        swarm_port = $SwarmPort
        storage_max = $StorageMax
        storage_gc_watermark = $StorageGCWatermark
        provide_strategy = $ProvideStrategy
        participation_mode = $ParticipationMode
        cache_policy = $CachePolicy
    }
}
else {
    $record = Initialize-ArchrealmsIpfsRepo `
        -IpfsRepoPath $resolvedRepoPath `
        -ApiMultiaddr $ApiMultiaddr `
        -GatewayMultiaddr $GatewayMultiaddr `
        -SwarmPort $SwarmPort `
        -StorageMax $StorageMax `
        -StorageGCWatermark $StorageGCWatermark `
        -ProvideStrategy $ProvideStrategy `
        -ParticipationMode $ParticipationMode `
        -CachePolicy $CachePolicy
}

Write-ArchrealmsUtf8Json -Path $RecordPath -InputObject $record

Write-Host ""
Write-Host "Archrealms IPFS node prepared:"
Write-Host "  Repo Path : $resolvedRepoPath"
Write-Host "  Record    : $RecordPath"
if (-not $DryRun) {
    Write-Host "  Peer Id   : $($record.peer_id)"
    Write-Host "  API       : $($record.api_multiaddr)"
    Write-Host "  Gateway   : $($record.gateway_multiaddr)"
    Write-Host "  Profile   : $($record.participation_mode); $($record.cache_policy)"
}
