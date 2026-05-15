param(
    [string]$OutputDirectory = "artifacts\release\pre-mvp-staff-steward-pilot-dry-run",
    [string]$PilotId = "pre-mvp-staff-steward-pilot-001",
    [string]$PilotOwner = "<pilot-owner>",
    [string]$PolicyVersion = "token-ready-passport-mvp-pre-mvp-internal-verification-v1",
    [string]$HandoffRoot,
    [string]$SimulationRunReportPath = "artifacts\release\pre-mvp-simulation-run-report.json",
    [string]$PreMvpReportPath = "artifacts\release\pre-mvp-internal-verification-report.json",
    [string]$ProductionReadinessReportPath = "artifacts\release\production-mvp-readiness-report.json",
    [string]$InternalVerificationManifestPath,
    [string]$ExecutablePath,
    [switch]$RunInstalledArtifactValidation,
    [switch]$RunUiSmoke,
    [switch]$SkipDaemon,
    [switch]$Force
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

    return "<passport-windows-commit>"
}

function Read-JsonFile {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $null
    }

    return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
}

function Get-Sha256Hex {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return ""
    }

    return (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant()
}

function Get-FileRecord {
    param(
        [string]$Id,
        [string]$Path,
        [bool]$Required = $true
    )

    $resolved = Resolve-RepoPath -Path $Path
    $exists = (-not [string]::IsNullOrWhiteSpace($resolved)) -and (Test-Path -LiteralPath $resolved -PathType Leaf)
    return [pscustomobject][ordered]@{
        id = $Id
        path = $resolved
        required = $Required
        exists = $exists
        sha256 = $(if ($exists) { Get-Sha256Hex -Path $resolved } else { "" })
    }
}

function Copy-EvidenceFile {
    param(
        [string]$Id,
        [string]$SourcePath,
        [string]$EvidenceRoot,
        [bool]$Required = $false
    )

    $resolvedSource = Resolve-RepoPath -Path $SourcePath
    if ([string]::IsNullOrWhiteSpace($resolvedSource) -or -not (Test-Path -LiteralPath $resolvedSource -PathType Leaf)) {
        return [pscustomobject][ordered]@{
            id = $Id
            source_path = $resolvedSource
            path = ""
            required = $Required
            exists = $false
            sha256 = ""
        }
    }

    New-Item -ItemType Directory -Force -Path $EvidenceRoot | Out-Null
    $extension = [System.IO.Path]::GetExtension($resolvedSource)
    if ([string]::IsNullOrWhiteSpace($extension)) {
        $extension = ".evidence"
    }

    $destination = Join-Path $EvidenceRoot ($Id + $extension)
    Copy-Item -LiteralPath $resolvedSource -Destination $destination -Force
    return [pscustomobject][ordered]@{
        id = $Id
        source_path = $resolvedSource
        path = [System.IO.Path]::GetFullPath($destination)
        required = $Required
        exists = $true
        sha256 = Get-Sha256Hex -Path $destination
    }
}

function Get-ReportState {
    param(
        [string]$Id,
        [string]$Path
    )

    $record = Get-FileRecord -Id $Id -Path $Path -Required:$false
    $json = $null
    if ($record.exists) {
        $json = Read-JsonFile -Path $record.path
    }

    $failedCheckIds = @()
    $failedRequirementIds = @()
    $failedGateIds = @()
    if ($null -ne $json) {
        $failedCheckIds = @($json.checks | Where-Object { -not [bool]$_.passed } | ForEach-Object { $_.id })
        $failedRequirementIds = @($json.requirements | Where-Object { -not [bool]$_.passed } | ForEach-Object { $_.id })
        $failedGateIds = @($json.gates | Where-Object { -not [bool]$_.passed } | ForEach-Object { $_.id })
    }

    return [pscustomobject][ordered]@{
        id = $record.id
        path = $record.path
        exists = $record.exists
        sha256 = $record.sha256
        passed = $(if ($null -ne $json -and $json.PSObject.Properties["passed"]) { [bool]$json.passed } else { $null })
        ready = $(if ($null -ne $json -and $json.PSObject.Properties["ready"]) { [bool]$json.ready } else { $null })
        failed_check_ids = $failedCheckIds
        failed_requirement_ids = $failedRequirementIds
        failed_gate_ids = $failedGateIds
    }
}

function Find-InternalVerificationManifestPath {
    $candidates = @(
        "artifacts\release\internal-verification-lane\passport-windows-win-x64\release-manifest.json",
        "artifacts\release\passport-windows-win-x64\release-manifest.json",
        "artifacts\release\passport-windows-msix-sideload\x64\msix-package-manifest.json",
        "artifacts\release\passport-windows-msix-store\x64\msix-package-manifest.json",
        "artifacts\release\passport-windows-msix\x64\msix-package-manifest.json"
    )

    foreach ($candidate in $candidates) {
        $path = Resolve-RepoPath -Path $candidate
        $json = Read-JsonFile -Path $path
        if ($null -ne $json -and $json.PSObject.Properties["lane"] -and $json.lane -eq "internal-verification") {
            return $path
        }
    }

    return ""
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

    $lines = @(
        "started_utc=$($started.ToString("yyyy-MM-ddTHH:mm:ssZ"))",
        "ended_utc=$($ended.ToString("yyyy-MM-ddTHH:mm:ssZ"))",
        "exit_code=$exitCode",
        "command=powershell -NoProfile -ExecutionPolicy Bypass -File `"$FilePath`" $($Arguments -join ' ')",
        ""
    ) + @($output | ForEach-Object { [string]$_ })
    Set-Content -LiteralPath $LogPath -Value ($lines -join [Environment]::NewLine) -Encoding UTF8

    return [pscustomobject][ordered]@{
        command = "powershell -NoProfile -ExecutionPolicy Bypass -File `"$FilePath`" $($Arguments -join ' ')"
        started_utc = $started.ToString("yyyy-MM-ddTHH:mm:ssZ")
        ended_utc = $ended.ToString("yyyy-MM-ddTHH:mm:ssZ")
        exit_code = $exitCode
        passed = ($exitCode -eq 0)
        log_path = [System.IO.Path]::GetFullPath($LogPath)
        log_sha256 = Get-Sha256Hex -Path $LogPath
    }
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

$resolvedOutput = Resolve-RepoPath -Path $OutputDirectory
if ((Test-Path -LiteralPath $resolvedOutput -PathType Container) -and -not $Force) {
    $existing = @(Get-ChildItem -LiteralPath $resolvedOutput -Force)
    if ($existing.Count -gt 0) {
        throw "Refusing to overwrite existing staff/steward pilot dry-run directory without -Force: $resolvedOutput"
    }
}

New-Item -ItemType Directory -Force -Path $resolvedOutput | Out-Null
$sourceEvidenceRoot = Join-Path $resolvedOutput "source-evidence"

if ([string]::IsNullOrWhiteSpace($InternalVerificationManifestPath)) {
    $InternalVerificationManifestPath = Find-InternalVerificationManifestPath
}

$handoffManifestPath = ""
if (-not [string]::IsNullOrWhiteSpace($HandoffRoot)) {
    $handoffManifestPath = Join-Path (Resolve-RepoPath -Path $HandoffRoot) "pilot-handoff.manifest.json"
}

$artifactManifest = Get-FileRecord -Id "internal_verification_artifact_manifest" -Path $InternalVerificationManifestPath -Required:$false
$handoffManifest = Get-FileRecord -Id "staff_steward_pilot_handoff_manifest" -Path $handoffManifestPath -Required:$false
$simulationReport = Get-ReportState -Id "simulation_run_report" -Path $SimulationRunReportPath
$preMvpReport = Get-ReportState -Id "pre_mvp_internal_verification_report" -Path $PreMvpReportPath
$productionReadinessReport = Get-ReportState -Id "production_mvp_readiness_report" -Path $ProductionReadinessReportPath

$commandResults = @()
$installedArtifactReportPath = Join-Path $resolvedOutput "installed-artifact-validation-report.json"
if ($RunInstalledArtifactValidation) {
    $arguments = @("-OutputPath", $installedArtifactReportPath)
    if ($InternalVerificationManifestPath) {
        $arguments += @("-ManifestPath", (Resolve-RepoPath -Path $InternalVerificationManifestPath))
    }

    if ($SkipDaemon) {
        $arguments += "-SkipDaemon"
    }

    $commandResults += [pscustomobject][ordered]@{
        id = "installed_artifact_validation"
        result = Invoke-Tool -FilePath (Join-Path $scriptRoot "Invoke-PassportWindowsInstalledArtifactValidation.ps1") -Arguments $arguments -LogPath (Join-Path $resolvedOutput "installed-artifact-validation.log")
        report = Get-FileRecord -Id "installed_artifact_validation_report" -Path $installedArtifactReportPath -Required:$false
    }
}

$uiSmokeReportPath = Join-Path $resolvedOutput "ui-smoke-report.json"
if ($RunUiSmoke) {
    if ([string]::IsNullOrWhiteSpace($ExecutablePath) -and $artifactManifest.exists) {
        $manifestJson = Read-JsonFile -Path $artifactManifest.path
        if ($null -ne $manifestJson -and $manifestJson.PSObject.Properties["publish_dir"]) {
            $candidateExecutablePath = Join-Path ([string]$manifestJson.publish_dir) "ArchrealmsPassport.Windows.exe"
            if (Test-Path -LiteralPath $candidateExecutablePath -PathType Leaf) {
                $ExecutablePath = $candidateExecutablePath
            }
        }
    }

    if ([string]::IsNullOrWhiteSpace($ExecutablePath)) {
        throw "RunUiSmoke requires -ExecutablePath or an InternalVerification manifest with a publish_dir."
    }

    $commandResults += [pscustomobject][ordered]@{
        id = "ui_smoke"
        result = Invoke-Tool -FilePath (Join-Path $scriptRoot "Invoke-PassportWindowsUiSmokeTest.ps1") -Arguments @("-ExecutablePath", (Resolve-RepoPath -Path $ExecutablePath), "-StopExisting", "-ExerciseTrayMinimize", "-ExerciseCloseToTaskbar", "-OutputPath", $uiSmokeReportPath) -LogPath (Join-Path $resolvedOutput "ui-smoke.log")
        report = Get-FileRecord -Id "ui_smoke_report" -Path $uiSmokeReportPath -Required:$false
    }
}

$scenarioEvidence = @(
    [pscustomobject][ordered]@{ id = "identity_create_or_recover"; covered_by = @("simulation_run_report", "windows_tests", "passport_smoke_test", "operator_observation_required"); operator_action_required = "Staff/steward participant must create or recover identity on a Crown-owned device and record observation evidence." }
    [pscustomobject][ordered]@{ id = "device_authorization"; covered_by = @("simulation_run_report", "windows_tests", "hosted_service_tests", "operator_observation_required"); operator_action_required = "Staff/steward participant must authorize a device and record device ID evidence." }
    [pscustomobject][ordered]@{ id = "wallet_key_binding"; covered_by = @("simulation_run_report", "core_tests", "windows_tests", "operator_observation_required"); operator_action_required = "Staff/steward participant must bind a wallet key and record wallet key ID evidence without exposing secrets." }
    [pscustomobject][ordered]@{ id = "recovery_revocation"; covered_by = @("simulation_run_report", "windows_tests", "hosted_service_tests", "operator_observation_required"); operator_action_required = "Staff/steward participant must exercise recovery or revocation and record the signed event/export reference." }
    [pscustomobject][ordered]@{ id = "storage_contribution_opt_in_revocation"; covered_by = @("simulation_run_report", "windows_tests", "optional_installed_artifact_validation", "operator_observation_required"); operator_action_required = "Staff/steward participant must opt in to storage contribution, pause or revoke it, and record the local controls and evidence." }
    [pscustomobject][ordered]@{ id = "ledger_export_verification"; covered_by = @("simulation_run_report", "ledger_verifier_build", "windows_tests", "operator_observation_required"); operator_action_required = "Staff/steward participant must export account history, run verifier, and record the verifier output hash." }
    [pscustomobject][ordered]@{ id = "hosted_ai_privacy"; covered_by = @("simulation_run_report", "core_tests", "hosted_service_tests", "operator_observation_required"); operator_action_required = "Staff/steward participant must verify AI disclosure/privacy posture and record hosted AI evidence without submitting secrets." }
    [pscustomobject][ordered]@{ id = "production_blocker_review"; covered_by = @("production_mvp_readiness_report", "operator_signoff_required"); operator_action_required = "Pilot owner must review current production readiness blockers and sign the issue-review record." }
)

$evidenceFiles = @(
    (Copy-EvidenceFile -Id "internal_verification_artifact_manifest" -SourcePath $artifactManifest.path -EvidenceRoot $sourceEvidenceRoot -Required:$false),
    (Copy-EvidenceFile -Id "staff_steward_pilot_handoff_manifest" -SourcePath $handoffManifest.path -EvidenceRoot $sourceEvidenceRoot -Required:$false),
    (Copy-EvidenceFile -Id "simulation_run_report" -SourcePath $simulationReport.path -EvidenceRoot $sourceEvidenceRoot -Required:$false),
    (Copy-EvidenceFile -Id "pre_mvp_internal_verification_report" -SourcePath $preMvpReport.path -EvidenceRoot $sourceEvidenceRoot -Required:$false),
    (Copy-EvidenceFile -Id "production_mvp_readiness_report" -SourcePath $productionReadinessReport.path -EvidenceRoot $sourceEvidenceRoot -Required:$false)
)

foreach ($commandResult in $commandResults) {
    if ($commandResult.result.log_path) {
        $evidenceFiles += Get-FileRecord -Id "$($commandResult.id)_log" -Path $commandResult.result.log_path -Required:$false
    }

    if ($commandResult.report.path) {
        $evidenceFiles += $commandResult.report
    }
}

$failedCommandIds = @($commandResults | Where-Object { -not [bool]$_.result.passed } | ForEach-Object { $_.id })
$reportPath = Join-Path $resolvedOutput "staff-steward-pilot-dry-run-evidence.json"
$report = [pscustomobject][ordered]@{
    schema = "archrealms.passport.pre_mvp_staff_steward_pilot_dry_run.v1"
    created_utc = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
    lane = "internal-verification"
    app_commit = Get-CurrentCommit
    pilot_id = $PilotId
    pilot_owner = $PilotOwner
    policy_version = $PolicyVersion
    not_a_passing_staff_steward_pilot_report = $true
    controlled_staff_steward_signoff_required = $true
    no_citizen_production_tokens_used = $true
    no_production_records_created = $true
    dry_run_passed = ($failedCommandIds.Count -eq 0)
    failed_command_ids = $failedCommandIds
    source_inputs = [pscustomobject][ordered]@{
        artifact_manifest = $artifactManifest
        handoff_manifest = $handoffManifest
        simulation_report = $simulationReport
        pre_mvp_report = $preMvpReport
        production_readiness_report = $productionReadinessReport
    }
    scenario_evidence = $scenarioEvidence
    command_results = $commandResults
    evidence_files = $evidenceFiles
    packet_reference_guidance = "Use this dry-run evidence as supporting evidence_reference material only. The staff/steward pilot packet still requires real operator observations, participant signoff, production-blocker review, and explicit report confirmations."
}

Write-JsonFile -Path $reportPath -Value $report
$reportRecord = Get-FileRecord -Id "staff_steward_pilot_dry_run_evidence" -Path $reportPath

[pscustomobject][ordered]@{
    report_path = $reportRecord.path
    report_sha256 = $reportRecord.sha256
    dry_run_passed = $report.dry_run_passed
    failed_command_ids = $failedCommandIds
    next_step = "Attach this dry-run evidence to the controlled staff/steward pilot packet, then perform and sign the real staff/steward pilot."
} | ConvertTo-Json -Depth 10

if ($failedCommandIds.Count -gt 0) {
    exit 1
}
