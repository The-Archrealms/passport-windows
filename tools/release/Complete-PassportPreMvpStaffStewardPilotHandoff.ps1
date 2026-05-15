param(
    [string]$HandoffRoot = "artifacts\release\pre-mvp-staff-steward-pilot-handoff",
    [string]$OutputDirectory = "artifacts\release\pre-mvp-staff-steward-pilot-closeout",
    [string]$PilotReportPath = "artifacts\release\pre-mvp-staff-steward-pilot-report.json",
    [string]$PreMvpReportPath = "artifacts\release\pre-mvp-internal-verification-report.json",
    [string]$SimulationRunReportPath,
    [string]$SimulationRunReportSha256,
    [switch]$SkipPreMvpRerun,
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

function Read-ObjectInt {
    param(
        [object]$Object,
        [string]$Name,
        [int]$DefaultValue = 0
    )

    if ($null -eq $Object -or -not $Object.PSObject.Properties[$Name]) {
        return $DefaultValue
    }

    try {
        return [int]$Object.$Name
    }
    catch {
        return $DefaultValue
    }
}

function Get-Sha256Hex {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return ""
    }

    return (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant()
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

function Invoke-Tool {
    param(
        [string]$FilePath,
        [string[]]$Arguments,
        [string]$LogPath
    )

    $started = [DateTimeOffset]::UtcNow
    $output = & powershell -NoProfile -ExecutionPolicy Bypass -File $FilePath @Arguments 2>&1
    $exitCode = $LASTEXITCODE
    $ended = [DateTimeOffset]::UtcNow

    $logDirectory = Split-Path -Parent $LogPath
    if ($logDirectory) {
        New-Item -ItemType Directory -Force -Path $logDirectory | Out-Null
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
        exit_code = $exitCode
        passed = ($exitCode -eq 0)
        log_path = [System.IO.Path]::GetFullPath($LogPath)
        log_sha256 = Get-Sha256Hex -Path $LogPath
    }
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
        failed_requirement_count = $(if ($null -ne $json -and $json.PSObject.Properties["failed_requirement_count"]) { [int]$json.failed_requirement_count } else { $null })
    }
}

function New-FilledPilotEvidencePacket {
    param(
        [string]$PacketRoot,
        [string]$PilotId,
        [string]$PilotOwner,
        [string]$PolicyVersion,
        [int]$ParticipantCount
    )

    New-Item -ItemType Directory -Force -Path $PacketRoot | Out-Null
    $createdUtc = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
    $scenarios = @(
        "identity_create_or_recover",
        "device_authorization",
        "wallet_key_binding",
        "recovery_revocation",
        "storage_contribution_opt_in_revocation",
        "ledger_export_verification",
        "hosted_ai_privacy",
        "production_blocker_review"
    )

    $session = [pscustomobject][ordered]@{
        schema = "archrealms.passport.pre_mvp_staff_steward_pilot_session.v1"
        created_utc = $createdUtc
        lane = "internal-verification"
        pilot_id = $PilotId
        pilot_owner = $PilotOwner
        policy_version = $PolicyVersion
        app_commit = Get-CurrentCommit
        artifact_manifest_path = ""
        artifact_manifest_sha256 = ""
        session_started_utc = $createdUtc
        session_ended_utc = $createdUtc
        pilot_participant_count = $ParticipantCount
        crown_owned_device_ids = @("crown-owned-device-closeout-001")
        synthetic_or_fake_balances_used = $true
        no_citizen_production_tokens_used = $true
        no_production_records_created = $true
        scenarios = @($scenarios | ForEach-Object {
            [pscustomobject][ordered]@{
                id = $_
                passed = $true
                evidence_reference = "controlled-evidence://$PilotId/$($_)"
            }
        })
    }

    $signoff = [pscustomobject][ordered]@{
        schema = "archrealms.passport.pre_mvp_staff_steward_participant_signoff.v1"
        created_utc = $createdUtc
        lane = "internal-verification"
        pilot_id = $PilotId
        pilot_owner = $PilotOwner
        policy_version = $PolicyVersion
        signoffs = @(
            [pscustomobject][ordered]@{
                participant_id = "staff-steward-closeout-001"
                participant_role = "staff-steward-validator"
                staff_or_steward_participant = $true
                crown_owned_device_used = $true
                no_citizen_production_tokens_used = $true
                no_production_records_created = $true
                signed_utc = $createdUtc
                signoff_reference = "controlled-signoff://$PilotId/staff-steward-closeout-001"
            }
        )
    }

    $issueReview = [pscustomobject][ordered]@{
        schema = "archrealms.passport.pre_mvp_staff_steward_pilot_issue_review.v1"
        created_utc = $createdUtc
        lane = "internal-verification"
        pilot_id = $PilotId
        pilot_owner = $PilotOwner
        policy_version = $PolicyVersion
        production_readiness_report_path = ""
        production_readiness_report_sha256 = ""
        production_readiness_blockers_reviewed = $true
        pilot_signoff_signed = $true
        no_pilot_blocking_defects = $true
        no_production_records_created = $true
        pilot_blockers = @()
        remaining_production_blockers = @("controlled-production-readiness-values-still-required")
        review_signoff_reference = "controlled-review://$PilotId/issue-review"
    }

    Write-JsonFile -Path (Join-Path $PacketRoot "pilot-session-record.json") -Value $session
    Write-JsonFile -Path (Join-Path $PacketRoot "participant-signoff.json") -Value $signoff
    Write-JsonFile -Path (Join-Path $PacketRoot "pilot-issue-review.json") -Value $issueReview
}

if ($UseGeneratedFixture) {
    $fixtureRoot = Resolve-RepoPath -Path "artifacts\release\pre-mvp-staff-steward-pilot-closeout-fixture"
    $HandoffRoot = Join-Path $fixtureRoot "handoff"
    $OutputDirectory = Join-Path $fixtureRoot "closeout"
    $PilotReportPath = Join-Path $fixtureRoot "pre-mvp-staff-steward-pilot-report.json"
    $PreMvpReportPath = Join-Path $fixtureRoot "pre-mvp-internal-verification-report.json"
    $SkipPreMvpRerun = $true
    $Force = $true

    $handoffGenerator = Join-Path $scriptRoot "New-PassportPreMvpStaffStewardPilotHandoff.ps1"
    $handoffGenerationLog = Join-Path $fixtureRoot "handoff-generation.log"
    $handoffGeneration = Invoke-Tool -FilePath $handoffGenerator -Arguments @(
        "-OutputDirectory", $HandoffRoot,
        "-PilotId", "pre-mvp-staff-steward-pilot-closeout-validation",
        "-PilotOwner", "pre-mvp-closeout-validation-owner",
        "-ParticipantCount", "1",
        "-Force"
    ) -LogPath $handoffGenerationLog

    if ($handoffGeneration.exit_code -ne 0) {
        throw "Generated closeout fixture handoff failed. See $handoffGenerationLog"
    }

    $fixtureManifest = Read-JsonFile -Path (Join-Path $HandoffRoot "pilot-handoff.manifest.json")
    $fixturePacketRoot = Read-ObjectString -Object $fixtureManifest -Name "evidence_packet_directory"
    New-FilledPilotEvidencePacket `
        -PacketRoot $fixturePacketRoot `
        -PilotId "pre-mvp-staff-steward-pilot-closeout-validation" `
        -PilotOwner "pre-mvp-closeout-validation-owner" `
        -PolicyVersion "token-ready-passport-mvp-pre-mvp-internal-verification-v1" `
        -ParticipantCount 1
}

$resolvedHandoffRoot = Resolve-RepoPath -Path $HandoffRoot
$resolvedOutput = Resolve-RepoPath -Path $OutputDirectory
if ((Test-Path -LiteralPath $resolvedOutput -PathType Container) -and -not $Force) {
    $existing = @(Get-ChildItem -LiteralPath $resolvedOutput -Force)
    if ($existing.Count -gt 0) {
        throw "Refusing to overwrite existing closeout directory without -Force: $resolvedOutput"
    }
}

New-Item -ItemType Directory -Force -Path $resolvedOutput | Out-Null

$handoffManifestPath = Join-Path $resolvedHandoffRoot "pilot-handoff.manifest.json"
$handoffManifest = Read-JsonFile -Path $handoffManifestPath
$failures = @()
if ($null -eq $handoffManifest) {
    $failures += "Pilot handoff manifest is missing or unreadable: $handoffManifestPath"
}

$pilotId = Read-ObjectString -Object $handoffManifest -Name "pilot_id"
$pilotOwner = Read-ObjectString -Object $handoffManifest -Name "pilot_owner"
$policyVersion = Read-ObjectString -Object $handoffManifest -Name "policy_version"
$participantCount = Read-ObjectInt -Object $handoffManifest -Name "participant_count" -DefaultValue 1
$evidencePacketRoot = Read-ObjectString -Object $handoffManifest -Name "evidence_packet_directory"
if ([string]::IsNullOrWhiteSpace($evidencePacketRoot)) {
    $evidencePacketRoot = Join-Path $resolvedHandoffRoot "pilot-evidence"
}

if ([string]::IsNullOrWhiteSpace($SimulationRunReportPath)) {
    $SimulationRunReportPath = Read-ObjectString -Object $handoffManifest.source_inputs.simulation_report -Name "path"
}

if ([string]::IsNullOrWhiteSpace($SimulationRunReportSha256)) {
    $SimulationRunReportSha256 = Read-ObjectString -Object $handoffManifest.source_inputs.simulation_report -Name "sha256"
}

$resolvedPilotReportPath = Resolve-RepoPath -Path $PilotReportPath
$resolvedPreMvpReportPath = Resolve-RepoPath -Path $PreMvpReportPath
$evidencePacketValidationPath = Join-Path $resolvedOutput "pilot-evidence-final-validation-report.json"
$pilotReportGenerationLog = Join-Path $resolvedOutput "pilot-report-generation.log"
$pilotReportValidationPath = Join-Path $resolvedOutput "pilot-report-validation-report.json"
$preMvpRerunLog = Join-Path $resolvedOutput "pre-mvp-internal-verification-rerun.log"

$handoffValidation = Invoke-Tool `
    -FilePath (Join-Path $scriptRoot "Test-PassportPreMvpStaffStewardPilotHandoff.ps1") `
    -Arguments @("-HandoffRoot", $resolvedHandoffRoot, "-AllowFilledEvidencePacket", "-OutputPath", (Join-Path $resolvedOutput "pilot-handoff-validation-report.json")) `
    -LogPath (Join-Path $resolvedOutput "pilot-handoff-validation.log")

if ($handoffValidation.exit_code -ne 0) {
    $failures += "Pilot handoff validation failed."
}

$packetValidation = Invoke-Tool `
    -FilePath (Join-Path $scriptRoot "Test-PassportPreMvpStaffStewardPilotEvidencePacket.ps1") `
    -Arguments @("-PacketRoot", $evidencePacketRoot, "-RequireNoPlaceholders", "-NoFail", "-OutputPath", $evidencePacketValidationPath) `
    -LogPath (Join-Path $resolvedOutput "pilot-evidence-final-validation.log")

$packetValidationState = Get-ToolReportState -Id "pilot_evidence_final_validation" -Path $evidencePacketValidationPath
if ($packetValidation.exit_code -ne 0 -or -not [bool]$packetValidationState.passed) {
    $failures += "Filled pilot evidence packet did not pass -RequireNoPlaceholders validation."
}

$reportGeneration = $null
$pilotReportSha256 = ""
if ([bool]$packetValidationState.passed) {
    $reportGeneration = Invoke-Tool `
        -FilePath (Join-Path $scriptRoot "New-PassportPreMvpStaffStewardPilotReport.ps1") `
        -Arguments @(
            "-OutputPath", $resolvedPilotReportPath,
            "-PilotId", $pilotId,
            "-PilotOwner", $pilotOwner,
            "-PolicyVersion", $policyVersion,
            "-ParticipantCount", ([string]$participantCount),
            "-EvidencePacketPath", $evidencePacketRoot,
            "-ConfirmCompleted",
            "-ConfirmStaffOrStewardParticipants",
            "-ConfirmCrownOwnedDevices",
            "-ConfirmNoCitizenProductionTokens",
            "-ConfirmRecoveryRevocationValidated",
            "-ConfirmStorageContributionValidated",
            "-ConfirmLedgerExportValidated",
            "-ConfirmHostedAiPrivacyValidated",
            "-ConfirmProductionReadinessBlockersReviewed",
            "-ConfirmPilotSignoffSigned",
            "-ConfirmNoProductionRecordsCreated"
        ) `
        -LogPath $pilotReportGenerationLog

    if ($reportGeneration.exit_code -ne 0) {
        $failures += "Pilot report generation failed."
    }
    else {
        $pilotReportSha256 = Get-Sha256Hex -Path $resolvedPilotReportPath
    }
}
else {
    $reportGeneration = [pscustomobject][ordered]@{
        command = "skipped"
        started_utc = ""
        ended_utc = ""
        exit_code = $null
        passed = $false
        log_path = ""
        log_sha256 = ""
    }
}

$pilotReportValidation = $null
$pilotReportValidationState = $null
if (-not [string]::IsNullOrWhiteSpace($pilotReportSha256)) {
    $pilotReportValidation = Invoke-Tool `
        -FilePath (Join-Path $scriptRoot "Test-PassportPreMvpStaffStewardPilotReport.ps1") `
        -Arguments @("-ReportPath", $resolvedPilotReportPath, "-ReportSha256", $pilotReportSha256, "-OutputPath", $pilotReportValidationPath) `
        -LogPath (Join-Path $resolvedOutput "pilot-report-validation.log")

    $pilotReportValidationState = Get-ToolReportState -Id "pilot_report_validation" -Path $pilotReportValidationPath
    if ($pilotReportValidation.exit_code -ne 0 -or -not [bool]$pilotReportValidationState.passed) {
        $failures += "Pilot report validation failed."
    }
}
else {
    $pilotReportValidation = [pscustomobject][ordered]@{
        command = "skipped"
        started_utc = ""
        ended_utc = ""
        exit_code = $null
        passed = $false
        log_path = ""
        log_sha256 = ""
    }
    $pilotReportValidationState = [pscustomobject][ordered]@{
        passed = $false
        failed_check_count = $null
    }
}

$preMvpRerun = $null
$preMvpRerunState = $null
if ($SkipPreMvpRerun) {
    $preMvpRerun = [pscustomobject][ordered]@{
        command = "skipped"
        started_utc = ""
        ended_utc = ""
        exit_code = $null
        passed = $false
        log_path = ""
        log_sha256 = ""
        skipped = $true
    }
    $preMvpRerunState = [pscustomobject][ordered]@{
        passed = $false
        failed_check_count = $null
        failed_requirement_count = $null
    }
}
elseif (-not [bool]$pilotReportValidationState.passed) {
    $failures += "Pre-MVP umbrella rerun was not attempted because pilot report validation did not pass."
}
else {
    if ([string]::IsNullOrWhiteSpace($SimulationRunReportPath) -or -not (Test-Path -LiteralPath (Resolve-RepoPath -Path $SimulationRunReportPath) -PathType Leaf)) {
        $failures += "SimulationRunReportPath is required for the final pre-MVP rerun."
    }

    if ($SimulationRunReportSha256 -notmatch '^[0-9a-fA-F]{64}$') {
        $failures += "SimulationRunReportSha256 is required for the final pre-MVP rerun."
    }

    if ($failures.Count -eq 0) {
        $preMvpRerun = Invoke-Tool `
            -FilePath (Join-Path $scriptRoot "Test-PassportPreMvpInternalVerification.ps1") `
            -Arguments @(
                "-SimulationRunReportPath", (Resolve-RepoPath -Path $SimulationRunReportPath),
                "-SimulationRunReportSha256", $SimulationRunReportSha256,
                "-StaffStewardPilotReportPath", $resolvedPilotReportPath,
                "-StaffStewardPilotReportSha256", $pilotReportSha256,
                "-OutputPath", $resolvedPreMvpReportPath
            ) `
            -LogPath $preMvpRerunLog

        $preMvpRerunState = Get-ToolReportState -Id "pre_mvp_internal_verification_rerun" -Path $resolvedPreMvpReportPath
        if ($preMvpRerun.exit_code -ne 0 -or -not [bool]$preMvpRerunState.passed) {
            $failures += "Pre-MVP umbrella rerun did not pass."
        }
    }
}

$closeoutPassed = ($failures.Count -eq 0)
$preMvpPassed = (-not [bool]$SkipPreMvpRerun) -and ($null -ne $preMvpRerunState) -and [bool]$preMvpRerunState.passed
$manifest = [pscustomobject][ordered]@{
    schema = "archrealms.passport.pre_mvp_staff_steward_pilot_closeout.v1"
    created_utc = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
    lane = "internal-verification"
    app_commit = Get-CurrentCommit
    generated_fixture = [bool]$UseGeneratedFixture
    skip_pre_mvp_rerun = [bool]$SkipPreMvpRerun
    pre_mvp_passed = $preMvpPassed
    passed = $closeoutPassed
    failures = @($failures)
    handoff_root = $resolvedHandoffRoot
    output_directory = $resolvedOutput
    evidence_packet_root = Resolve-RepoPath -Path $evidencePacketRoot
    pilot_report = New-FileRecord -Id "staff_steward_pilot_report" -Path $resolvedPilotReportPath
    pilot_report_sha256 = $pilotReportSha256
    pre_mvp_report = New-FileRecord -Id "pre_mvp_internal_verification_report" -Path $resolvedPreMvpReportPath
    simulation_run_report = New-FileRecord -Id "simulation_run_report" -Path $SimulationRunReportPath
    simulation_run_report_sha256 = $SimulationRunReportSha256
    steps = [pscustomobject][ordered]@{
        handoff_validation = $handoffValidation
        evidence_packet_validation = [pscustomobject][ordered]@{
            command = $packetValidation
            report = $packetValidationState
        }
        pilot_report_generation = $reportGeneration
        pilot_report_validation = [pscustomobject][ordered]@{
            command = $pilotReportValidation
            report = $pilotReportValidationState
        }
        pre_mvp_rerun = [pscustomobject][ordered]@{
            command = $preMvpRerun
            report = $preMvpRerunState
        }
    }
    production_readiness_env_values = [pscustomobject][ordered]@{
        ARCHREALMS_PASSPORT_PRE_MVP_SIMULATION_RUN_REPORT_PATH = Resolve-RepoPath -Path $SimulationRunReportPath
        ARCHREALMS_PASSPORT_PRE_MVP_SIMULATION_RUN_REPORT_SHA256 = $SimulationRunReportSha256
        ARCHREALMS_PASSPORT_PRE_MVP_STAFF_STEWARD_PILOT_REPORT_PATH = $resolvedPilotReportPath
        ARCHREALMS_PASSPORT_PRE_MVP_STAFF_STEWARD_PILOT_REPORT_SHA256 = $pilotReportSha256
        ARCHREALMS_PASSPORT_PRE_MVP_VERIFICATION_REPORT_PATH = $resolvedPreMvpReportPath
        ARCHREALMS_PASSPORT_PRE_MVP_VERIFICATION_REPORT_SHA256 = Get-Sha256Hex -Path $resolvedPreMvpReportPath
    }
}

$manifestPath = Join-Path $resolvedOutput "pilot-closeout.manifest.json"
Write-JsonFile -Path $manifestPath -Value $manifest
$manifestRecord = New-FileRecord -Id "pilot_closeout_manifest" -Path $manifestPath

$result = [pscustomobject][ordered]@{
    schema = "archrealms.passport.pre_mvp_staff_steward_pilot_closeout_result.v1"
    passed = $closeoutPassed
    failures = @($failures)
    manifest_path = $manifestRecord.path
    manifest_sha256 = $manifestRecord.sha256
    pilot_report_path = $resolvedPilotReportPath
    pilot_report_sha256 = $pilotReportSha256
    pre_mvp_report_path = $resolvedPreMvpReportPath
    pre_mvp_report_sha256 = Get-Sha256Hex -Path $resolvedPreMvpReportPath
    skip_pre_mvp_rerun = [bool]$SkipPreMvpRerun
    next_step = $(if (-not $closeoutPassed) {
            "Resolve the listed failures, then rerun the closeout command."
        }
        elseif ($SkipPreMvpRerun) {
            "Generated closeout validation passed. After real pilot evidence exists, rerun without -SkipPreMvpRerun to produce the passing pre-MVP report."
        }
        else {
            "Load the passing pre-MVP report path and SHA-256 into staging, canary, and production readiness environments."
        })
}

$json = $result | ConvertTo-Json -Depth 8
$json

if (-not $closeoutPassed -and -not $NoFail) {
    exit 1
}
