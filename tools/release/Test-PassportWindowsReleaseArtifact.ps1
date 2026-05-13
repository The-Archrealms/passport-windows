param(
    [string[]]$ManifestPath,
    [switch]$RequireBundledIpfs,
    [switch]$SkipExecutableChecks,
    [string]$OutputPath
)

$ErrorActionPreference = "Stop"

function Add-Failure {
    param(
        [System.Collections.Generic.List[string]]$Failures,
        [string]$Message
    )

    $Failures.Add($Message) | Out-Null
}

function Resolve-ArtifactRoot {
    param(
        [pscustomobject]$Manifest,
        [string]$ManifestDirectory,
        [string]$ScratchRoot
    )

    foreach ($propertyName in @("layout_dir", "publish_dir")) {
        if ($Manifest.PSObject.Properties[$propertyName]) {
            $candidate = [string]$Manifest.$propertyName
            if ($candidate -and (Test-Path -LiteralPath $candidate -PathType Container)) {
                return (Resolve-Path -LiteralPath $candidate).Path
            }
        }
    }

    foreach ($propertyName in @("zip_path", "package_path")) {
        if (-not $Manifest.PSObject.Properties[$propertyName]) {
            continue
        }

        $archivePath = [string]$Manifest.$propertyName
        if (-not $archivePath) {
            continue
        }

        if (-not (Test-Path -LiteralPath $archivePath -PathType Leaf)) {
            $archivePath = Join-Path $ManifestDirectory (Split-Path -Leaf $archivePath)
        }

        if (-not (Test-Path -LiteralPath $archivePath -PathType Leaf)) {
            continue
        }

        $extractRoot = Join-Path $ScratchRoot ([System.IO.Path]::GetFileNameWithoutExtension($archivePath))
        if (Test-Path -LiteralPath $extractRoot) {
            Remove-Item -Recurse -Force -LiteralPath $extractRoot
        }

        New-Item -ItemType Directory -Force -Path $extractRoot | Out-Null
        $archiveForExpansion = $archivePath
        if ([System.IO.Path]::GetExtension($archivePath) -ieq ".msix") {
            $archiveForExpansion = Join-Path $ScratchRoot (([System.IO.Path]::GetFileNameWithoutExtension($archivePath)) + ".zip")
            Copy-Item -LiteralPath $archivePath -Destination $archiveForExpansion -Force
        }

        Expand-Archive -LiteralPath $archiveForExpansion -DestinationPath $extractRoot -Force
        return $extractRoot
    }

    return ""
}

function Test-RelativeFile {
    param(
        [string]$Root,
        [string]$RelativePath
    )

    return Test-Path -LiteralPath (Join-Path $Root ($RelativePath -replace '/', '\')) -PathType Leaf
}

function Test-ManifestFiles {
    param(
        [pscustomobject]$Manifest,
        [string]$ArtifactRoot,
        [System.Collections.Generic.List[string]]$Failures
    )

    if (-not $Manifest.PSObject.Properties["files"]) {
        return 0
    }

    $verifiedCount = 0
    foreach ($file in @($Manifest.files)) {
        $relativePath = [string]$file.path
        if (-not $relativePath) {
            continue
        }

        $path = Join-Path $ArtifactRoot ($relativePath -replace '/', '\')
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            Add-Failure -Failures $Failures -Message "Manifest file is missing: $relativePath"
            continue
        }

        if ($file.PSObject.Properties["sha256"] -and $file.sha256) {
            $actualHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $path).Hash.ToLowerInvariant()
            if (-not [string]::Equals($actualHash, [string]$file.sha256, [System.StringComparison]::OrdinalIgnoreCase)) {
                Add-Failure -Failures $Failures -Message "Manifest hash mismatch for $relativePath"
                continue
            }
        }

        $verifiedCount++
    }

    return $verifiedCount
}

function Test-IpfsExecutable {
    param(
        [string]$ArtifactRoot,
        [System.Collections.Generic.List[string]]$Failures
    )

    $ipfsPath = Join-Path $ArtifactRoot "tools\ipfs\runtime\ipfs.exe"
    if (-not (Test-Path -LiteralPath $ipfsPath -PathType Leaf)) {
        return ""
    }

    if ($SkipExecutableChecks) {
        return "skipped"
    }

    try {
        $versionOutput = & $ipfsPath --version 2>&1
        if ($LASTEXITCODE -ne 0) {
            Add-Failure -Failures $Failures -Message "Bundled ipfs.exe returned exit code $LASTEXITCODE."
            return ""
        }

        return (($versionOutput | Select-Object -First 1).ToString().Trim())
    }
    catch {
        Add-Failure -Failures $Failures -Message ("Bundled ipfs.exe could not be executed: " + $_.Exception.Message)
        return ""
    }
}

function Test-ReleaseLaneManifest {
    param(
        [pscustomobject]$Manifest,
        [string]$ArtifactRoot,
        [System.Collections.Generic.List[string]]$Failures
    )

    $laneManifestPath = Join-Path $ArtifactRoot "passport-release-lane.json"
    if (-not (Test-Path -LiteralPath $laneManifestPath -PathType Leaf)) {
        Add-Failure -Failures $Failures -Message "Required file is missing: passport-release-lane.json"
        return $null
    }

    $laneManifest = Get-Content -LiteralPath $laneManifestPath -Raw | ConvertFrom-Json
    $lane = [string]$laneManifest.lane
    $allowedLanes = @("dev", "internal-verification", "staging", "canary-mvp", "production-mvp")
    if ($allowedLanes -notcontains $lane) {
        Add-Failure -Failures $Failures -Message "Release lane manifest has unsupported lane: $lane"
        return $laneManifest
    }

    if ($Manifest.PSObject.Properties["lane"] -and $Manifest.lane -and -not [string]::Equals([string]$Manifest.lane, $lane, [System.StringComparison]::Ordinal)) {
        Add-Failure -Failures $Failures -Message "Release manifest lane does not match passport-release-lane.json."
    }

    foreach ($requiredProperty in @("ledger_namespace", "telemetry_environment", "issuer_key_scope", "policy_version")) {
        if (-not $laneManifest.PSObject.Properties[$requiredProperty] -or [string]::IsNullOrWhiteSpace([string]$laneManifest.$requiredProperty)) {
            Add-Failure -Failures $Failures -Message "Release lane manifest is missing $requiredProperty."
        }
    }

    $productionLedger = [bool]$laneManifest.production_ledger
    $allowProductionRecords = [bool]$laneManifest.allow_production_token_records
    $allowStagingRecords = [bool]$laneManifest.allow_staging_records

    if (($lane -eq "dev" -or $lane -eq "internal-verification" -or $lane -eq "staging") -and ($productionLedger -or $allowProductionRecords)) {
        Add-Failure -Failures $Failures -Message "Non-production lane is allowed to write production token records."
    }

    if ($lane -ne "staging" -and $allowStagingRecords) {
        Add-Failure -Failures $Failures -Message "Only the staging lane may allow staging records."
    }

    if (($lane -eq "canary-mvp" -or $lane -eq "production-mvp") -and (-not $productionLedger -or -not $allowProductionRecords)) {
        Add-Failure -Failures $Failures -Message "Production-token lane is not marked for production ledger records."
    }

    return $laneManifest
}

if (-not $ManifestPath -or $ManifestPath.Count -lt 1) {
    $ManifestPath = @(
        "artifacts\release\passport-windows-win-x64\release-manifest.json",
        "artifacts\release\passport-windows-msix-sideload\x64\msix-package-manifest.json",
        "artifacts\release\passport-windows-msix-store\x64\msix-package-manifest.json",
        "artifacts\release\passport-windows-msix\x64\msix-package-manifest.json"
    ) | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf }
}

if (-not $ManifestPath -or $ManifestPath.Count -lt 1) {
    throw "No release manifest paths were supplied or found."
}

$scratchRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("passport-release-validation-" + [Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Force -Path $scratchRoot | Out-Null

$reports = @()
$allFailures = New-Object 'System.Collections.Generic.List[string]'

try {
    foreach ($rawManifestPath in $ManifestPath) {
        $resolvedManifestPath = (Resolve-Path -LiteralPath $rawManifestPath).Path
        $manifestDirectory = Split-Path -Parent $resolvedManifestPath
        $manifest = Get-Content -LiteralPath $resolvedManifestPath -Raw | ConvertFrom-Json
        $failures = New-Object 'System.Collections.Generic.List[string]'
        $artifactRoot = Resolve-ArtifactRoot -Manifest $manifest -ManifestDirectory $manifestDirectory -ScratchRoot $scratchRoot
        $laneManifest = $null

        if (-not $artifactRoot) {
            Add-Failure -Failures $failures -Message "Could not resolve artifact root for manifest $resolvedManifestPath."
        }

        $requiredFiles = @(
            "ArchrealmsPassport.Windows.exe",
            "passport-release-lane.json",
            "tools/ipfs/ArchrealmsIpfs.psm1",
            "tools/ipfs/Export-ArchrealmsIpfsCar.ps1",
            "tools/ipfs/Initialize-ArchrealmsIpfsNode.ps1",
            "tools/passport/Publish-ArchrealmsRegistrySubmissionToIpfs.ps1",
            "tools/passport/Read-ArchrealmsIpfsText.ps1",
            "tools/passport/Save-ArchrealmsIpfsFileReadOnly.ps1",
            "tools/passport/Verify-ArchrealmsRegistrySubmission.ps1",
            "registry/templates/passport-identity-record.template.json"
        )

        $bundledIpfsIncluded = $false
        if ($manifest.PSObject.Properties["bundled_ipfs_cli_included"]) {
            $bundledIpfsIncluded = [bool]$manifest.bundled_ipfs_cli_included
        }

        if ($RequireBundledIpfs -or $bundledIpfsIncluded) {
            $requiredFiles += "tools/ipfs/runtime/ipfs.exe"
        }

        if ($artifactRoot) {
            foreach ($requiredFile in $requiredFiles) {
                if (-not (Test-RelativeFile -Root $artifactRoot -RelativePath $requiredFile)) {
                    Add-Failure -Failures $failures -Message "Required file is missing: $requiredFile"
                }
            }

            $laneManifest = Test-ReleaseLaneManifest -Manifest $manifest -ArtifactRoot $artifactRoot -Failures $failures
        }

        if ($RequireBundledIpfs -and -not $bundledIpfsIncluded) {
            Add-Failure -Failures $failures -Message "Manifest does not report a bundled IPFS runtime."
        }

        $verifiedManifestFileCount = 0
        if ($artifactRoot) {
            $verifiedManifestFileCount = Test-ManifestFiles -Manifest $manifest -ArtifactRoot $artifactRoot -Failures $failures
        }

        $ipfsVersion = ""
        if ($artifactRoot -and ($RequireBundledIpfs -or $bundledIpfsIncluded)) {
            $ipfsVersion = Test-IpfsExecutable -ArtifactRoot $artifactRoot -Failures $failures
        }

        foreach ($failure in $failures) {
            $allFailures.Add((Split-Path -Leaf $resolvedManifestPath) + ": " + $failure) | Out-Null
        }

        $reports += [pscustomobject]@{
            manifest_path = $resolvedManifestPath
            artifact_root = $artifactRoot
            package_path = if ($manifest.PSObject.Properties["package_path"]) { $manifest.package_path } else { "" }
            zip_path = if ($manifest.PSObject.Properties["zip_path"]) { $manifest.zip_path } else { "" }
            bundled_ipfs_cli_included = $bundledIpfsIncluded
            bundled_ipfs_cli_version = $ipfsVersion
            lane = if ($laneManifest) { $laneManifest.lane } elseif ($manifest.PSObject.Properties["lane"]) { $manifest.lane } else { "" }
            ledger_namespace = if ($laneManifest) { $laneManifest.ledger_namespace } else { "" }
            verified_manifest_file_count = $verifiedManifestFileCount
            required_file_count = $requiredFiles.Count
            failures = @($failures)
            passed = ($failures.Count -eq 0)
        }
    }
}
finally {
    if (Test-Path -LiteralPath $scratchRoot) {
        Remove-Item -Recurse -Force -LiteralPath $scratchRoot
    }
}

$report = [pscustomobject]@{
    verified_utc = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
    require_bundled_ipfs = $RequireBundledIpfs.IsPresent
    skip_executable_checks = $SkipExecutableChecks.IsPresent
    passed = ($allFailures.Count -eq 0)
    failures = @($allFailures)
    artifacts = $reports
}

if ($OutputPath) {
    $outputDirectory = Split-Path -Parent ([System.IO.Path]::GetFullPath($OutputPath))
    if ($outputDirectory) {
        New-Item -ItemType Directory -Force -Path $outputDirectory | Out-Null
    }

    $report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $OutputPath -Encoding UTF8
}

$report | ConvertTo-Json -Depth 8

if ($allFailures.Count -gt 0) {
    throw "Passport Windows release artifact validation failed."
}
