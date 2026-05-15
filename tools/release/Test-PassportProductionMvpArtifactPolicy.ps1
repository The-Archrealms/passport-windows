param(
    [string]$OutputPath = "artifacts\release\production-mvp-artifact-policy-validation-report.json"
)

$ErrorActionPreference = "Stop"

function New-Sha256 {
    param([string]$Path)

    return (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant()
}

function New-RequiredFile {
    param(
        [string]$Root,
        [string]$RelativePath
    )

    $path = Join-Path $Root ($RelativePath -replace '/', '\')
    $directory = Split-Path -Parent $path
    if ($directory) {
        New-Item -ItemType Directory -Force -Path $directory | Out-Null
    }

    Set-Content -LiteralPath $path -Value "artifact-policy-fixture" -Encoding UTF8
    return [pscustomobject][ordered]@{
        path = $RelativePath
        size_bytes = (Get-Item -LiteralPath $path).Length
        sha256 = New-Sha256 -Path $path
    }
}

function New-ProductionArtifactFixture {
    param(
        [string]$Root,
        [string]$Name,
        [Nullable[bool]]$GateRequired,
        [Nullable[bool]]$GateSkipped,
        [Nullable[bool]]$GatePassed,
        [Nullable[bool]]$ReadyForProductionTesting,
        [string]$BypassReason = ""
    )

    $artifactRoot = Join-Path $Root $Name
    New-Item -ItemType Directory -Force -Path $artifactRoot | Out-Null

    $laneManifest = [pscustomobject][ordered]@{
        schema = "archrealms.passport.release_lane.v1"
        lane = "production-mvp"
        ledger_namespace = "archrealms-passport-production-mvp"
        telemetry_environment = "production-mvp"
        issuer_key_scope = "production"
        policy_version = "passport-production-mvp"
        production_ledger = $true
        allow_production_token_records = $true
        allow_staging_records = $false
    }
    $laneManifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $artifactRoot "passport-release-lane.json") -Encoding UTF8

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

    $files = @()
    foreach ($relativePath in $requiredFiles) {
        if ($relativePath -eq "passport-release-lane.json") {
            $path = Join-Path $artifactRoot $relativePath
            $files += [pscustomobject][ordered]@{
                path = $relativePath
                size_bytes = (Get-Item -LiteralPath $path).Length
                sha256 = New-Sha256 -Path $path
            }
            continue
        }

        $files += New-RequiredFile -Root $artifactRoot -RelativePath $relativePath
    }

    $manifest = [ordered]@{
        created_utc = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
        lane = "production-mvp"
        release_lane_manifest_path = Join-Path $artifactRoot "passport-release-lane.json"
        ledger_namespace = "archrealms-passport-production-mvp"
        telemetry_environment = "production-mvp"
        issuer_key_scope = "production"
        publish_dir = $artifactRoot
        git_commit = "artifact-policy-fixture"
        files = $files
    }

    if ($null -ne $GateRequired) {
        $manifest.production_mvp_readiness_gate_required = [bool]$GateRequired
    }
    if ($null -ne $GateSkipped) {
        $manifest.production_mvp_readiness_gate_skipped = [bool]$GateSkipped
    }
    if ($null -ne $GatePassed) {
        $manifest.production_mvp_readiness_gate_passed = [bool]$GatePassed
    }
    if ($null -ne $ReadyForProductionTesting) {
        $manifest.production_mvp_ready_for_production_testing = [bool]$ReadyForProductionTesting
    }
    if (-not [string]::IsNullOrWhiteSpace($BypassReason)) {
        $manifest.production_mvp_readiness_bypass_reason = $BypassReason
    }

    $manifestPath = Join-Path $artifactRoot "release-manifest.json"
    [pscustomobject]$manifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $manifestPath -Encoding UTF8
    return $manifestPath
}

function Invoke-ArtifactValidator {
    param(
        [string]$ManifestPath,
        [string]$ReportPath
    )

    $validator = Join-Path $PSScriptRoot "Test-PassportWindowsReleaseArtifact.ps1"
    $output = ""
    $threw = $false
    try {
        $output = (& powershell -NoProfile -ExecutionPolicy Bypass -File $validator -ManifestPath $ManifestPath -SkipExecutableChecks -OutputPath $ReportPath 2>&1 | Out-String)
        $exitCode = $LASTEXITCODE
    }
    catch {
        $threw = $true
        $exitCode = 1
        $output = $_.Exception.Message
    }

    $report = $null
    if (Test-Path -LiteralPath $ReportPath -PathType Leaf) {
        $report = Get-Content -LiteralPath $ReportPath -Raw | ConvertFrom-Json
    }

    return [pscustomobject][ordered]@{
        exit_code = $exitCode
        threw = $threw
        output_excerpt = ($output.Trim() -replace "\s+", " ").Substring(0, [Math]::Min(500, ($output.Trim() -replace "\s+", " ").Length))
        report = $report
    }
}

function Add-Check {
    param(
        [string]$Id,
        [string]$Description,
        [bool]$Passed,
        [string[]]$Failures = @()
    )

    return [pscustomobject][ordered]@{
        id = $Id
        description = $Description
        passed = $Passed
        failures = @($Failures)
    }
}

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$scratchRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("passport-production-mvp-artifact-policy-" + [Guid]::NewGuid().ToString("N"))
$checks = @()

try {
    New-Item -ItemType Directory -Force -Path $scratchRoot | Out-Null

    $missingManifest = New-ProductionArtifactFixture -Root $scratchRoot -Name "missing-readiness-fields" -GateRequired $null -GateSkipped $null -GatePassed $null -ReadyForProductionTesting $null
    $missingResult = Invoke-ArtifactValidator -ManifestPath $missingManifest -ReportPath (Join-Path $scratchRoot "missing-report.json")
    $missingFailures = if ($missingResult.report) { @($missingResult.report.failures) } else { @("validator did not write a report") }
    $checks += Add-Check `
        -Id "production_artifact_missing_readiness_fields_rejected" `
        -Description "ProductionMvp artifacts without readiness manifest fields are rejected." `
        -Passed (($missingResult.exit_code -ne 0) -and (($missingFailures -join "`n") -match "production_mvp_readiness_gate_passed")) `
        -Failures $(if (($missingResult.exit_code -ne 0) -and (($missingFailures -join "`n") -match "production_mvp_readiness_gate_passed")) { @() } else { $missingFailures })

    $skippedManifest = New-ProductionArtifactFixture -Root $scratchRoot -Name "skipped-readiness-gate" -GateRequired $true -GateSkipped $true -GatePassed $false -ReadyForProductionTesting $false -BypassReason "fixture bypass"
    $skippedResult = Invoke-ArtifactValidator -ManifestPath $skippedManifest -ReportPath (Join-Path $scratchRoot "skipped-report.json")
    $skippedFailures = if ($skippedResult.report) { @($skippedResult.report.failures) } else { @("validator did not write a report") }
    $checks += Add-Check `
        -Id "production_artifact_skipped_readiness_rejected" `
        -Description "ProductionMvp artifacts that skipped readiness are rejected even when the bypass is documented." `
        -Passed (($skippedResult.exit_code -ne 0) -and (($skippedFailures -join "`n") -match "skipped the readiness gate")) `
        -Failures $(if (($skippedResult.exit_code -ne 0) -and (($skippedFailures -join "`n") -match "skipped the readiness gate")) { @() } else { $skippedFailures })

    $passedManifest = New-ProductionArtifactFixture -Root $scratchRoot -Name "passed-readiness-gate" -GateRequired $true -GateSkipped $false -GatePassed $true -ReadyForProductionTesting $true
    $passedResult = Invoke-ArtifactValidator -ManifestPath $passedManifest -ReportPath (Join-Path $scratchRoot "passed-report.json")
    $passedFailures = if ($passedResult.report) { @($passedResult.report.failures) } else { @("validator did not write a report") }
    $checks += Add-Check `
        -Id "production_artifact_passed_readiness_accepted" `
        -Description "ProductionMvp artifacts that record a passing readiness gate are accepted by artifact validation." `
        -Passed (($passedResult.exit_code -eq 0) -and $passedResult.report -and $passedResult.report.passed -eq $true) `
        -Failures $(if (($passedResult.exit_code -eq 0) -and $passedResult.report -and $passedResult.report.passed -eq $true) { @() } else { $passedFailures })
}
finally {
    if (Test-Path -LiteralPath $scratchRoot) {
        Remove-Item -Recurse -Force -LiteralPath $scratchRoot
    }
}

$failedChecks = @($checks | Where-Object { -not $_.passed })
$report = [pscustomobject][ordered]@{
    schema = "archrealms.passport.production_mvp_artifact_policy_validation.v1"
    created_utc = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
    repo_root = $repoRoot
    passed = ($failedChecks.Count -eq 0)
    failed_check_count = $failedChecks.Count
    checks = $checks
}

$outputDirectory = Split-Path -Parent ([System.IO.Path]::GetFullPath($OutputPath))
if ($outputDirectory) {
    New-Item -ItemType Directory -Force -Path $outputDirectory | Out-Null
}

$report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $OutputPath -Encoding UTF8
$report | ConvertTo-Json -Depth 8

if ($failedChecks.Count -gt 0) {
    throw "ProductionMvp artifact policy validation failed."
}
