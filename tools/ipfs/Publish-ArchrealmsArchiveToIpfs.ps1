param(
    [Parameter(Mandatory = $true)]
    [string]$TargetName,
    [Parameter(Mandatory = $true)]
    [string]$TargetPath,
    [string]$OutputPath,
    [string]$CarPath,
    [string]$IpfsRepoPath,
    [switch]$ExportCar,
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"

Import-Module (Join-Path $PSScriptRoot "ArchrealmsIpfs.psm1") -Force

$resolvedTargetPath = (Resolve-Path $TargetPath).Path
if (-not $OutputPath) {
    $OutputPath = Join-Path (Split-Path -Parent $resolvedTargetPath) "ipfs-publication.json"
}

if ($DryRun) {
    $stats = Get-ArchrealmsPathStats -TargetPath $resolvedTargetPath
    $record = [ordered]@{
        dry_run = $true
        target_name = $TargetName
        target_path = $resolvedTargetPath
        target_type = $stats.target_type
        file_count = $stats.file_count
        size_bytes = $stats.size_bytes
        ipfs_repo_path = Get-ArchrealmsResolvedIpfsRepoPath -IpfsRepoPath $IpfsRepoPath
        export_car = [bool]$ExportCar
        car_path = $CarPath
    }

    Write-ArchrealmsUtf8Json -Path $OutputPath -InputObject $record
}
else {
    $record = Publish-ArchrealmsPathToIpfs `
        -TargetName $TargetName `
        -TargetPath $resolvedTargetPath `
        -OutputPath $OutputPath `
        -CarPath $CarPath `
        -IpfsRepoPath $IpfsRepoPath `
        -ExportCar:$ExportCar
}

Write-Host ""
Write-Host "Archrealms IPFS publication recorded:"
Write-Host "  Target  : $resolvedTargetPath"
Write-Host "  Record  : $OutputPath"
if (-not $DryRun) {
    Write-Host "  Root CID: $($record.root_cid)"
    if ($record.car_path) {
        Write-Host "  CAR     : $($record.car_path)"
    }
}
