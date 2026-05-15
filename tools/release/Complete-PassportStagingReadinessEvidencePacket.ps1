param(
    [string]$PacketRoot = "artifacts\release\staging-readiness-evidence",
    [string]$OutputDirectory = "artifacts\release\staging-readiness-closeout",
    [string]$StagingReadinessReportPath = "artifacts\release\staging-readiness-report.json",
    [string]$EnvironmentFile,
    [string]$PreMvpReportPath,
    [string]$PreMvpReportSha256,
    [string]$StagingArtifactValidationReportPath,
    [string]$StagingArtifactValidationReportSha256,
    [switch]$UseGeneratedFixture,
    [switch]$Force,
    [switch]$NoFail
)

$ErrorActionPreference = "Stop"
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $scriptRoot "..\.."))

function Resolve-RepoPath {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return ""
    }

    if ([System.IO.Path]::IsPathRooted($Path)) {
        return [System.IO.Path]::GetFullPath($Path)
    }

    return [System.IO.Path]::GetFullPath((Join-Path $repoRoot $Path))
}

function Read-JsonFile {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $null
    }

    return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
}

function Write-JsonFile {
    param(
        [string]$Path,
        [object]$Value
    )

    $parent = Split-Path -Parent $Path
    if ($parent) {
        New-Item -ItemType Directory -Force -Path $parent | Out-Null
    }

    $Value | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $Path -Encoding UTF8
}

function Read-ObjectString {
    param(
        [object]$Object,
        [string]$Name
    )

    if ($null -eq $Object -or -not $Object.PSObject.Properties[$Name]) {
        return ""
    }

    return ([string]$Object.$Name).Trim()
}

function Get-Sha256Hex {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return ""
    }

    return (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant()
}

function Get-CurrentCommit {
    Push-Location $repoRoot
    try {
        $commit = (& git rev-parse --short HEAD 2>$null)
        if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($commit)) {
            return ([string]$commit).Trim()
        }
    }
    finally {
        Pop-Location
    }

    return "passport-windows-commit-unavailable"
}

function Find-EvidenceFile {
    param(
        [string]$Root,
        [string]$BaseName
    )

    $candidate = Join-Path $Root "$BaseName.json"
    if (Test-Path -LiteralPath $candidate -PathType Leaf) {
        return [System.IO.Path]::GetFullPath($candidate)
    }

    $templateCandidate = Join-Path $Root "$BaseName.template.json"
    if (Test-Path -LiteralPath $templateCandidate -PathType Leaf) {
        return [System.IO.Path]::GetFullPath($templateCandidate)
    }

    return [System.IO.Path]::GetFullPath($candidate)
}

function New-FileRecord {
    param(
        [string]$Id,
        [string]$Path
    )

    $resolved = Resolve-RepoPath -Path $Path
    $exists = (-not [string]::IsNullOrWhiteSpace($resolved)) -and (Test-Path -LiteralPath $resolved -PathType Leaf)
    return [pscustomobject][ordered]@{
        id = $Id
        path = $resolved
        exists = $exists
        sha256 = $(if ($exists) { Get-Sha256Hex -Path $resolved } else { "" })
    }
}

function Read-EnvironmentFile {
    param([string]$Path)

    $values = [ordered]@{}
    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $values
    }

    $resolved = Resolve-RepoPath -Path $Path
    if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) {
        throw "Environment file was not found: $resolved"
    }

    foreach ($line in Get-Content -LiteralPath $resolved) {
        $trimmed = $line.Trim()
        if ([string]::IsNullOrWhiteSpace($trimmed) -or $trimmed.StartsWith("#")) {
            continue
        }

        $separator = $trimmed.IndexOf("=")
        if ($separator -le 0) {
            continue
        }

        $name = $trimmed.Substring(0, $separator).Trim()
        $value = $trimmed.Substring($separator + 1).Trim()
        if (($value.StartsWith('"') -and $value.EndsWith('"')) -or ($value.StartsWith("'") -and $value.EndsWith("'"))) {
            $value = $value.Substring(1, $value.Length - 2)
        }

        if (-not [string]::IsNullOrWhiteSpace($name)) {
            $values[$name] = $value
        }
    }

    return $values
}

function Write-EnvironmentFile {
    param(
        [string]$Path,
        [System.Collections.IDictionary]$Values
    )

    $parent = Split-Path -Parent $Path
    if ($parent) {
        New-Item -ItemType Directory -Force -Path $parent | Out-Null
    }

    $lines = @(
        "# Archrealms Passport staging readiness closeout environment",
        "# Generated from a filled staging readiness evidence packet. Do not commit populated env files.",
        ""
    )

    foreach ($key in $Values.Keys) {
        $lines += "$key=$($Values[$key])"
    }

    Set-Content -LiteralPath $Path -Value ($lines -join [Environment]::NewLine) -Encoding UTF8
}

function Invoke-Tool {
    param(
        [string]$FilePath,
        [string[]]$Arguments,
        [string]$LogPath
    )

    $started = [DateTimeOffset]::UtcNow
    $output = & powershell -NoProfile -ExecutionPolicy Bypass -File $FilePath @Arguments 2>&1
    $exitCode = $LASTEXITCODE
    if ($null -eq $exitCode) {
        $exitCode = 0
    }
    $ended = [DateTimeOffset]::UtcNow

    $parent = Split-Path -Parent $LogPath
    if ($parent) {
        New-Item -ItemType Directory -Force -Path $parent | Out-Null
    }

    $command = "powershell -NoProfile -ExecutionPolicy Bypass -File `"$FilePath`" $($Arguments -join ' ')"
    $lines = @(
        "started_utc=$($started.ToString("yyyy-MM-ddTHH:mm:ssZ"))",
        "ended_utc=$($ended.ToString("yyyy-MM-ddTHH:mm:ssZ"))",
        "exit_code=$exitCode",
        "command=$command",
        ""
    ) + @($output | ForEach-Object { [string]$_ })
    Set-Content -LiteralPath $LogPath -Value ($lines -join [Environment]::NewLine) -Encoding UTF8

    return [pscustomobject][ordered]@{
        command = $command
        started_utc = $started.ToString("yyyy-MM-ddTHH:mm:ssZ")
        ended_utc = $ended.ToString("yyyy-MM-ddTHH:mm:ssZ")
        exit_code = [int]$exitCode
        passed = ($exitCode -eq 0)
        log_path = [System.IO.Path]::GetFullPath($LogPath)
        log_sha256 = Get-Sha256Hex -Path $LogPath
    }
}

function Get-ToolReportState {
    param(
        [string]$Id,
        [string]$Path
    )

    $file = New-FileRecord -Id $Id -Path $Path
    $json = Read-JsonFile -Path $file.path
    return [pscustomobject][ordered]@{
        id = $Id
        file = $file
        passed = $(if ($null -ne $json -and $json.PSObject.Properties["passed"]) { [bool]$json.passed } else { $false })
        ready = $(if ($null -ne $json -and $json.PSObject.Properties["ready"]) { [bool]$json.ready } else { $false })
        failed_check_count = $(if ($null -ne $json -and $json.PSObject.Properties["failed_check_count"]) { [int]$json.failed_check_count } else { $null })
        failed_gate_count = $(if ($null -ne $json -and $json.PSObject.Properties["failed_gate_count"]) { [int]$json.failed_gate_count } else { $null })
    }
}

function New-GeneratedFixture {
    param(
        [string]$FixtureRoot
    )

    New-Item -ItemType Directory -Force -Path $FixtureRoot | Out-Null
    $packetRoot = Join-Path $FixtureRoot "packet"
    New-Item -ItemType Directory -Force -Path $packetRoot | Out-Null
    $createdUtc = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")

    $preMvpPath = Join-Path $FixtureRoot "synthetic-pre-mvp-report.json"
    Write-JsonFile -Path $preMvpPath -Value ([pscustomobject][ordered]@{
        schema = "archrealms.passport.pre_mvp_internal_verification.v1"
        created_utc = $createdUtc
        pre_mvp_testing_is_mvp = $false
        citizen_facing_token_release = $false
        fake_balance_migration_blocked = $true
        passed = $true
    })

    $artifactPath = Join-Path $FixtureRoot "synthetic-staging-artifact-validation-report.json"
    Write-JsonFile -Path $artifactPath -Value ([pscustomobject][ordered]@{
        verified_utc = $createdUtc
        passed = $true
        failures = @()
        artifacts = @(
            [pscustomobject][ordered]@{
                manifest_path = "synthetic-staging-release-manifest.json"
                artifact_root = "synthetic-staging-artifact"
                package_path = ""
                zip_path = "synthetic-staging.zip"
                lane = "staging"
                ledger_namespace = "archrealms-passport-staging-closeout-validation"
                failures = @()
                passed = $true
            }
        )
    })

    $operationalPath = Join-Path $packetRoot "staging-operational-drill-report.json"
    $rollbackPath = Join-Path $packetRoot "staging-rollback-drill-report.json"
    $promotionPath = Join-Path $packetRoot "staging-promotion-approval-record.json"
    $operational = [pscustomobject][ordered]@{
        schema = "archrealms.passport.staging_operational_drill.v1"
        created_utc = $createdUtc
        lane = "staging"
        operational_drill_id = "staging-operational-drill-closeout-validation"
        completed = $true
        package_version = "synthetic-staging-closeout"
        policy_version = "passport-token-ready-mvp-v1"
        api_base_url = "http://127.0.0.1:18080"
        ai_gateway_url = "http://127.0.0.1:18081"
        ledger_namespace = "archrealms-passport-staging-closeout-validation"
        telemetry_destination = "staging-closeout-validation-telemetry"
        operator = "staging-closeout-validation-operator"
        incident_response_owner = "staging-closeout-validation-incident-owner"
        evidence_references = @("controlled-evidence://staging/upgrade", "controlled-evidence://staging/failover", "controlled-evidence://staging/export-replay")
        production_candidate_upgrade_validated = $true
        endpoint_failover_validated = $true
        signing_verification_validated = $true
        ledger_export_replay_validated = $true
        recovery_revocation_validated = $true
        storage_proof_validation_completed = $true
        storage_redemption_dry_run_completed = $true
        conversion_disclosure_dry_run_completed = $true
        telemetry_privacy_validated = $true
        incident_response_validated = $true
        support_access_controls_validated = $true
        ai_gateway_auth_privacy_validated = $true
        prohibited_claims_blocked = $true
    }
    Write-JsonFile -Path $operationalPath -Value $operational

    $rollback = [pscustomobject][ordered]@{
        schema = "archrealms.passport.staging_rollback_drill.v1"
        created_utc = $createdUtc
        lane = "staging"
        rollback_drill_id = "staging-rollback-drill-closeout-validation"
        completed = $true
        package_version = "synthetic-staging-closeout"
        policy_version = "passport-token-ready-mvp-v1"
        reason_code = "staging-closeout-validation"
        approvers = @("staging-closeout-engineering", "staging-closeout-security-privacy")
        affected_service_classes = @("identity", "wallet", "storage", "ai", "ledger-export")
        affected_assets = @("ARCH", "CC")
        user_facing_status = "synthetic staging rollback drill completed"
        new_operations_disabled_or_routed = $true
        ledger_events_preserved = $true
        no_deletion_mutation_or_backdating = $true
        pending_escrow_resolved_by_policy = $true
        export_access_preserved = $true
        production_records_untouched = $true
    }
    Write-JsonFile -Path $rollbackPath -Value $rollback

    Write-JsonFile -Path $promotionPath -Value ([pscustomobject][ordered]@{
        schema = "archrealms.passport.staging_promotion_approval.v1"
        created_utc = $createdUtc
        lane = "staging"
        promotion_approval_id = "staging-promotion-closeout-validation"
        engineering_signoff_id = "staging-engineering-closeout-validation"
        security_privacy_signoff_id = "staging-security-privacy-closeout-validation"
        crown_monetary_authority_signoff_id = "staging-crown-monetary-closeout-validation"
        rollback_drill_id = "staging-rollback-drill-closeout-validation"
        pre_mvp_report_sha256 = Get-Sha256Hex -Path $preMvpPath
        staging_artifact_validation_report_sha256 = Get-Sha256Hex -Path $artifactPath
        operational_drill_report_sha256 = Get-Sha256Hex -Path $operationalPath
        rollback_drill_report_sha256 = Get-Sha256Hex -Path $rollbackPath
        approve_canary_or_production_release = $true
        product_approval_signed = $true
        engineering_signoff_signed = $true
        security_privacy_signoff_signed = $true
        crown_monetary_authority_signoff_signed = $true
    })

    return [pscustomobject][ordered]@{
        packet_root = $packetRoot
        pre_mvp_report_path = $preMvpPath
        pre_mvp_report_sha256 = Get-Sha256Hex -Path $preMvpPath
        staging_artifact_validation_report_path = $artifactPath
        staging_artifact_validation_report_sha256 = Get-Sha256Hex -Path $artifactPath
    }
}

if ($UseGeneratedFixture) {
    $fixtureRoot = Resolve-RepoPath -Path "artifacts\release\staging-readiness-closeout-fixture"
    $fixture = New-GeneratedFixture -FixtureRoot $fixtureRoot
    $PacketRoot = $fixture.packet_root
    $OutputDirectory = Join-Path $fixtureRoot "closeout"
    $StagingReadinessReportPath = Join-Path $fixtureRoot "staging-readiness-report.json"
    $PreMvpReportPath = $fixture.pre_mvp_report_path
    $PreMvpReportSha256 = $fixture.pre_mvp_report_sha256
    $StagingArtifactValidationReportPath = $fixture.staging_artifact_validation_report_path
    $StagingArtifactValidationReportSha256 = $fixture.staging_artifact_validation_report_sha256
    $Force = $true
}

$resolvedPacketRoot = Resolve-RepoPath -Path $PacketRoot
$resolvedOutput = Resolve-RepoPath -Path $OutputDirectory
if ((Test-Path -LiteralPath $resolvedOutput -PathType Container) -and -not $Force) {
    $existing = @(Get-ChildItem -LiteralPath $resolvedOutput -Force)
    if ($existing.Count -gt 0) {
        throw "Refusing to overwrite existing staging closeout directory without -Force: $resolvedOutput"
    }
}

New-Item -ItemType Directory -Force -Path $resolvedOutput | Out-Null

$operationalPath = Find-EvidenceFile -Root $resolvedPacketRoot -BaseName "staging-operational-drill-report"
$rollbackPath = Find-EvidenceFile -Root $resolvedPacketRoot -BaseName "staging-rollback-drill-report"
$promotionPath = Find-EvidenceFile -Root $resolvedPacketRoot -BaseName "staging-promotion-approval-record"
$operational = Read-JsonFile -Path $operationalPath
$rollback = Read-JsonFile -Path $rollbackPath
$promotion = Read-JsonFile -Path $promotionPath

$envValues = Read-EnvironmentFile -Path $EnvironmentFile
if (-not [string]::IsNullOrWhiteSpace($PreMvpReportPath)) {
    $envValues["ARCHREALMS_PASSPORT_PRE_MVP_VERIFICATION_REPORT_PATH"] = Resolve-RepoPath -Path $PreMvpReportPath
}
if (-not [string]::IsNullOrWhiteSpace($PreMvpReportSha256)) {
    $envValues["ARCHREALMS_PASSPORT_PRE_MVP_VERIFICATION_REPORT_SHA256"] = $PreMvpReportSha256
}
if (-not [string]::IsNullOrWhiteSpace($StagingArtifactValidationReportPath)) {
    $envValues["ARCHREALMS_PASSPORT_STAGING_ARTIFACT_VALIDATION_REPORT_PATH"] = Resolve-RepoPath -Path $StagingArtifactValidationReportPath
}
if (-not [string]::IsNullOrWhiteSpace($StagingArtifactValidationReportSha256)) {
    $envValues["ARCHREALMS_PASSPORT_STAGING_ARTIFACT_VALIDATION_REPORT_SHA256"] = $StagingArtifactValidationReportSha256
}

if ($null -ne $operational) {
    $envValues["PASSPORT_WINDOWS_STAGING_API_BASE_URL"] = Read-ObjectString -Object $operational -Name "api_base_url"
    $envValues["PASSPORT_WINDOWS_STAGING_AI_GATEWAY_URL"] = Read-ObjectString -Object $operational -Name "ai_gateway_url"
    $envValues["ARCHREALMS_PASSPORT_STAGING_LEDGER_NAMESPACE"] = Read-ObjectString -Object $operational -Name "ledger_namespace"
    $envValues["ARCHREALMS_PASSPORT_STAGING_TELEMETRY_DESTINATION"] = Read-ObjectString -Object $operational -Name "telemetry_destination"
    $envValues["ARCHREALMS_PASSPORT_STAGING_OPERATIONAL_DRILL_ID"] = Read-ObjectString -Object $operational -Name "operational_drill_id"
    $envValues["ARCHREALMS_PASSPORT_STAGING_OPERATIONAL_DRILL_REPORT_PATH"] = $operationalPath
    $envValues["ARCHREALMS_PASSPORT_STAGING_OPERATIONAL_DRILL_REPORT_SHA256"] = Get-Sha256Hex -Path $operationalPath
}

if ($null -ne $rollback) {
    $envValues["ARCHREALMS_PASSPORT_STAGING_ROLLBACK_DRILL_ID"] = Read-ObjectString -Object $rollback -Name "rollback_drill_id"
    $envValues["ARCHREALMS_PASSPORT_STAGING_ROLLBACK_DRILL_REPORT_PATH"] = $rollbackPath
    $envValues["ARCHREALMS_PASSPORT_STAGING_ROLLBACK_DRILL_REPORT_SHA256"] = Get-Sha256Hex -Path $rollbackPath
}

if ($null -ne $promotion) {
    $envValues["ARCHREALMS_PASSPORT_STAGING_PROMOTION_APPROVAL_ID"] = Read-ObjectString -Object $promotion -Name "promotion_approval_id"
    $envValues["ARCHREALMS_PASSPORT_STAGING_ENGINEERING_SIGNOFF_ID"] = Read-ObjectString -Object $promotion -Name "engineering_signoff_id"
    $envValues["ARCHREALMS_PASSPORT_STAGING_SECURITY_PRIVACY_SIGNOFF_ID"] = Read-ObjectString -Object $promotion -Name "security_privacy_signoff_id"
    $envValues["ARCHREALMS_PASSPORT_STAGING_CROWN_MONETARY_AUTHORITY_SIGNOFF_ID"] = Read-ObjectString -Object $promotion -Name "crown_monetary_authority_signoff_id"
    $envValues["ARCHREALMS_PASSPORT_STAGING_PROMOTION_APPROVAL_RECORD_PATH"] = $promotionPath
    $envValues["ARCHREALMS_PASSPORT_STAGING_PROMOTION_APPROVAL_RECORD_SHA256"] = Get-Sha256Hex -Path $promotionPath
}

$closeoutEnvironmentPath = Join-Path $resolvedOutput "staging-readiness-closeout.env"
Write-EnvironmentFile -Path $closeoutEnvironmentPath -Values $envValues

$packetValidationPath = Join-Path $resolvedOutput "staging-evidence-packet-validation-report.json"
$packetValidation = Invoke-Tool `
    -FilePath (Join-Path $scriptRoot "Test-PassportStagingReadinessEvidencePacket.ps1") `
    -Arguments @("-PacketRoot", $resolvedPacketRoot, "-RequireNoPlaceholders", "-NoFail", "-OutputPath", $packetValidationPath) `
    -LogPath (Join-Path $resolvedOutput "staging-evidence-packet-validation.log")
$packetValidationState = Get-ToolReportState -Id "staging_evidence_packet_validation" -Path $packetValidationPath

$failures = @()
if ($packetValidation.exit_code -ne 0 -or -not [bool]$packetValidationState.passed) {
    $failures += "Filled staging readiness evidence packet did not pass -RequireNoPlaceholders validation."
}

$resolvedStagingReportPath = Resolve-RepoPath -Path $StagingReadinessReportPath
$readinessRun = Invoke-Tool `
    -FilePath (Join-Path $scriptRoot "Test-PassportStagingReadiness.ps1") `
    -Arguments @("-EnvironmentFile", $closeoutEnvironmentPath, "-OutputPath", $resolvedStagingReportPath, "-NoFail") `
    -LogPath (Join-Path $resolvedOutput "staging-readiness-run.log")
$readinessState = Get-ToolReportState -Id "staging_readiness" -Path $resolvedStagingReportPath
if ($readinessRun.exit_code -ne 0 -or -not [bool]$readinessState.ready) {
    $failures += "Staging readiness did not pass."
}

$stagingReportSha256 = Get-Sha256Hex -Path $resolvedStagingReportPath
$closeoutPassed = ($failures.Count -eq 0)
$manifest = [pscustomobject][ordered]@{
    schema = "archrealms.passport.staging_readiness_closeout.v1"
    created_utc = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
    lane = "staging"
    app_commit = Get-CurrentCommit
    generated_fixture = [bool]$UseGeneratedFixture
    passed = $closeoutPassed
    failures = @($failures)
    packet_root = $resolvedPacketRoot
    output_directory = $resolvedOutput
    closeout_environment = New-FileRecord -Id "staging_readiness_closeout_environment" -Path $closeoutEnvironmentPath
    evidence_files = @(
        New-FileRecord -Id "staging_operational_drill_report" -Path $operationalPath
        New-FileRecord -Id "staging_rollback_drill_report" -Path $rollbackPath
        New-FileRecord -Id "staging_promotion_approval_record" -Path $promotionPath
    )
    input_reports = [pscustomobject][ordered]@{
        pre_mvp_internal_verification = New-FileRecord -Id "pre_mvp_internal_verification_report" -Path $envValues["ARCHREALMS_PASSPORT_PRE_MVP_VERIFICATION_REPORT_PATH"]
        staging_artifact_validation = New-FileRecord -Id "staging_artifact_validation_report" -Path $envValues["ARCHREALMS_PASSPORT_STAGING_ARTIFACT_VALIDATION_REPORT_PATH"]
    }
    staging_readiness_report = New-FileRecord -Id "staging_readiness_report" -Path $resolvedStagingReportPath
    staging_readiness_report_sha256 = $stagingReportSha256
    steps = [pscustomobject][ordered]@{
        evidence_packet_validation = [pscustomobject][ordered]@{
            command = $packetValidation
            report = $packetValidationState
        }
        staging_readiness = [pscustomobject][ordered]@{
            command = $readinessRun
            report = $readinessState
        }
    }
    downstream_environment_values = [pscustomobject][ordered]@{
        ARCHREALMS_PASSPORT_STAGING_READINESS_REPORT_PATH = $resolvedStagingReportPath
        ARCHREALMS_PASSPORT_STAGING_READINESS_REPORT_SHA256 = $stagingReportSha256
    }
}

$manifestPath = Join-Path $resolvedOutput "staging-readiness-closeout.manifest.json"
Write-JsonFile -Path $manifestPath -Value $manifest
$manifestRecord = New-FileRecord -Id "staging_readiness_closeout_manifest" -Path $manifestPath

$result = [pscustomobject][ordered]@{
    schema = "archrealms.passport.staging_readiness_closeout_result.v1"
    passed = $closeoutPassed
    failures = @($failures)
    manifest_path = $manifestRecord.path
    manifest_sha256 = $manifestRecord.sha256
    staging_readiness_report_path = $resolvedStagingReportPath
    staging_readiness_report_sha256 = $stagingReportSha256
    next_step = $(if ($closeoutPassed) { "Load the staging readiness report path and SHA-256 into canary and production readiness environments." } else { "Resolve the listed failures, then rerun staging closeout." })
}

$json = $result | ConvertTo-Json -Depth 8
$json

if (-not $closeoutPassed -and -not $NoFail) {
    exit 1
}
