param(
    [string]$SubmissionPath,
    [string]$PackagePath,
    [string]$WorkspaceRoot,
    [string]$OutputPath,
    [string]$CarPath,
    [string]$IpfsRepoPath,
    [switch]$ExportCar,
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"

if (-not $WorkspaceRoot) {
    $WorkspaceRoot = (Get-Location).Path
}
elseif (Test-Path -LiteralPath $WorkspaceRoot) {
    $WorkspaceRoot = (Resolve-Path -LiteralPath $WorkspaceRoot).Path
}
else {
    $WorkspaceRoot = [System.IO.Path]::GetFullPath($WorkspaceRoot)
}

$submissionsRoot = Join-Path $WorkspaceRoot "records\registry\submissions"

function Resolve-PackageRoot {
    param(
        [string]$SubmissionPath,
        [string]$PackagePath,
        [string]$DefaultRoot
    )

    if ($PackagePath) {
        return (Resolve-Path $PackagePath).Path
    }

    if ($SubmissionPath) {
        $resolvedSubmissionPath = (Resolve-Path $SubmissionPath).Path
        if ((Get-Item -LiteralPath $resolvedSubmissionPath).PSIsContainer) {
            return $resolvedSubmissionPath
        }

        return Split-Path -Parent $resolvedSubmissionPath
    }

    if (-not (Test-Path -LiteralPath $DefaultRoot)) {
        throw "No registry submission packages were found."
    }

    $latestPackage = Get-ChildItem -LiteralPath $DefaultRoot -Directory |
        Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName "submission.json") } |
        Sort-Object Name -Descending |
        Select-Object -First 1

    if (-not $latestPackage) {
        throw "No registry submission packages were found."
    }

    return $latestPackage.FullName
}

$resolvedPackageRoot = Resolve-PackageRoot -SubmissionPath $SubmissionPath -PackagePath $PackagePath -DefaultRoot $submissionsRoot

if (-not $OutputPath) {
    $OutputPath = Join-Path $resolvedPackageRoot "ipfs-publication.json"
}

if (-not $CarPath -and $ExportCar) {
    $packageName = Split-Path -Leaf $resolvedPackageRoot
    $CarPath = Join-Path $resolvedPackageRoot ($packageName + ".car")
}

& (Join-Path $PSScriptRoot "..\ipfs\Publish-ArchrealmsArchiveToIpfs.ps1") `
    -TargetName ("passport-registry-submission-" + (Split-Path -Leaf $resolvedPackageRoot)) `
    -TargetPath $resolvedPackageRoot `
    -OutputPath $OutputPath `
    -CarPath $CarPath `
    -IpfsRepoPath $IpfsRepoPath `
    -ExportCar:$ExportCar `
    -DryRun:$DryRun
