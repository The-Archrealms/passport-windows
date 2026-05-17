param(
    [string]$OutputDirectory = "artifacts\release\pre-mvp-staff-steward-pilot-handoff",
    [string]$PilotId = "pre-mvp-staff-steward-pilot-001",
    [string]$PilotOwner = "<pilot-owner>",
    [string]$PolicyVersion = "token-ready-passport-mvp-pre-mvp-internal-verification-v1",
    [int]$ParticipantCount = 1,
    [string]$EvidencePacketDirectory,
    [string]$SimulationRunReportPath = "artifacts\release\pre-mvp-simulation-run-report.json",
    [string]$PreMvpReportPath = "artifacts\release\pre-mvp-internal-verification-report.json",
    [string]$ProductionReadinessReportPath = "artifacts\release\production-mvp-readiness-report.json",
    [string]$ArtifactManifestPath,
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

function Get-ReportState {
    param(
        [string]$Id,
        [string]$Path
    )

    $record = Get-FileRecord -Id $Id -Path $Path
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

function Invoke-Tool {
    param(
        [string]$FilePath,
        [string[]]$Arguments
    )

    $output = & powershell -NoProfile -ExecutionPolicy Bypass -File $FilePath @Arguments 2>&1
    return [pscustomobject][ordered]@{
        command = ("powershell -NoProfile -ExecutionPolicy Bypass -File `"{0}`" {1}" -f $FilePath, ($Arguments -join " "))
        exit_code = $LASTEXITCODE
        output = @($output | ForEach-Object { [string]$_ })
    }
}

function Assert-ToolSucceeded {
    param(
        [object]$Result,
        [string]$Name
    )

    if ($Result.exit_code -ne 0) {
        throw "$Name failed with exit code $($Result.exit_code): $($Result.output -join [Environment]::NewLine)"
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

if ($ParticipantCount -lt 1) {
    throw "ParticipantCount must be at least 1."
}

$resolvedOutput = Resolve-RepoPath -Path $OutputDirectory
if ((Test-Path -LiteralPath $resolvedOutput -PathType Container) -and -not $Force) {
    $existing = @(Get-ChildItem -LiteralPath $resolvedOutput -Force)
    if ($existing.Count -gt 0) {
        throw "Refusing to overwrite existing pilot handoff directory without -Force: $resolvedOutput"
    }
}

New-Item -ItemType Directory -Force -Path $resolvedOutput | Out-Null

if ([string]::IsNullOrWhiteSpace($EvidencePacketDirectory)) {
    $EvidencePacketDirectory = Join-Path $resolvedOutput "pilot-evidence"
}

$resolvedEvidencePacketDirectory = Resolve-RepoPath -Path $EvidencePacketDirectory
New-Item -ItemType Directory -Force -Path $resolvedEvidencePacketDirectory | Out-Null

if ([string]::IsNullOrWhiteSpace($ArtifactManifestPath)) {
    $ArtifactManifestPath = Find-InternalVerificationManifestPath
}

$artifactManifest = Get-FileRecord -Id "internal_verification_artifact_manifest" -Path $ArtifactManifestPath
$simulationReport = Get-ReportState -Id "simulation_run_report" -Path $SimulationRunReportPath
$preMvpReport = Get-ReportState -Id "pre_mvp_internal_verification_report" -Path $PreMvpReportPath
$productionReadinessReport = Get-ReportState -Id "production_mvp_readiness_report" -Path $ProductionReadinessReportPath

$remainingProductionBlockers = @($productionReadinessReport.failed_gate_ids | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
if ($remainingProductionBlockers.Count -eq 0) {
    $remainingProductionBlockers = @("<known-production-readiness-blocker>")
}
$remainingProductionBlockerArgument = ($remainingProductionBlockers | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }) -join ";"

$packetGenerator = Join-Path $scriptRoot "New-PassportPreMvpStaffStewardPilotEvidencePacket.ps1"
$packetValidator = Join-Path $scriptRoot "Test-PassportPreMvpStaffStewardPilotEvidencePacket.ps1"

$packetArguments = @(
    "-OutputDirectory", $resolvedEvidencePacketDirectory,
    "-PilotId", $PilotId,
    "-PilotOwner", $PilotOwner,
    "-PolicyVersion", $PolicyVersion,
    "-ParticipantCount", ([string]$ParticipantCount),
    "-AppCommit", (Get-CurrentCommit),
    "-ProductionReadinessReportPath", $productionReadinessReport.path,
    "-ProductionReadinessReportSha256", $(if ($productionReadinessReport.exists) { $productionReadinessReport.sha256 } else { "<sha256>" }),
    "-RemainingProductionBlocker", $remainingProductionBlockerArgument
)

if ($artifactManifest.exists) {
    $packetArguments += @("-ArtifactManifestPath", $artifactManifest.path, "-ArtifactManifestSha256", $artifactManifest.sha256)
}

if ($Force) {
    $packetArguments += "-Force"
}

$packetGeneration = Invoke-Tool -FilePath $packetGenerator -Arguments $packetArguments
Assert-ToolSucceeded -Result $packetGeneration -Name "Staff/steward pilot evidence packet generation"

$templateValidationPath = Join-Path $resolvedOutput "pilot-evidence-template-validation-report.json"
$templateValidation = Invoke-Tool -FilePath $packetValidator -Arguments @(
    "-PacketRoot", $resolvedEvidencePacketDirectory,
    "-OutputPath", $templateValidationPath
)
Assert-ToolSucceeded -Result $templateValidation -Name "Staff/steward pilot evidence packet template validation"

$finalPreviewValidationPath = Join-Path $resolvedOutput "pilot-evidence-final-validation-preview-report.json"
$finalPreviewValidation = Invoke-Tool -FilePath $packetValidator -Arguments @(
    "-PacketRoot", $resolvedEvidencePacketDirectory,
    "-RequireNoPlaceholders",
    "-NoFail",
    "-OutputPath", $finalPreviewValidationPath
)
Assert-ToolSucceeded -Result $finalPreviewValidation -Name "Staff/steward pilot evidence packet fail-closed preview"

$templateValidationReport = Read-JsonFile -Path $templateValidationPath
$finalPreviewValidationReport = Read-JsonFile -Path $finalPreviewValidationPath
if ($null -eq $templateValidationReport -or -not [bool]$templateValidationReport.passed) {
    throw "Template validation report did not pass: $templateValidationPath"
}

if ($null -eq $finalPreviewValidationReport -or [bool]$finalPreviewValidationReport.passed) {
    throw "RequireNoPlaceholders preview unexpectedly passed before real pilot evidence was filled."
}

$createdUtc = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
$runbookPath = Join-Path $resolvedOutput "operator-runbook.md"
$staffPilotReportPath = Resolve-RepoPath -Path "artifacts\release\pre-mvp-staff-steward-pilot-report.json"
$staffPilotReportGenerationOutputPath = Join-Path $resolvedOutput "pilot-report-generation-output.json"
$staffPilotReportValidationPath = Join-Path $resolvedOutput "pilot-report-validation-report.json"
$finalPreMvpReportPath = Resolve-RepoPath -Path "artifacts\release\pre-mvp-internal-verification-report.json"
$pilotWorkspaceLaunchPath = Join-Path $resolvedOutput "pilot-workspace-launch.json"

$simulationHashExpression = if ($simulationReport.exists) { $simulationReport.sha256 } else { "<simulation-run-report-sha256>" }
$staffPilotHashPlaceholder = "<staff-steward-pilot-report-sha256>"

$runbookLines = @(
    "# Staff/Steward Pilot Handoff",
    "",
    "Generated: $createdUtc",
    "",
    "This handoff prepares the only remaining pre-MVP external evidence gate. It is not a passing pilot report. It must fail ``-RequireNoPlaceholders`` until the controlled staff/steward pilot has run and the packet is filled with real evidence.",
    "",
    "## Inputs",
    "",
    "- Pilot ID: ``$PilotId``",
    "- Pilot owner: ``$PilotOwner``",
    "- Participant count: ``$ParticipantCount``",
    "- Evidence packet: ``$resolvedEvidencePacketDirectory``",
    "- Current simulation report: ``$($simulationReport.path)``",
    "- Current simulation SHA-256: ``$simulationHashExpression``",
    "- Current pre-MVP report: ``$($preMvpReport.path)``",
    "- Current production readiness report: ``$($productionReadinessReport.path)``",
    "",
    "## Before The Pilot",
    "",
    "1. Confirm the pilot uses only staff/steward participants and Crown-owned devices.",
    "2. Confirm the pilot uses synthetic/fake balances only.",
    "3. Confirm no citizen production ARCH, production CC, Crown reserve balance, citizen production account history, or production service-liability record is created.",
    "4. Confirm no citizen production tokens are used in any pilot step.",
    "5. Review the production readiness blockers in the issue-review record before signing the pilot.",
    "",
    "## Open The Pilot Workspace",
    "",
    "Use this helper on the Crown-owned pilot machine to open the runbook, open the evidence folder, launch the internal-verification Passport artifact, and write a workspace-launch report. This helper is not a passing pilot report and does not replace participant signoff.",
    "",
    '```powershell',
    ".\tools\release\Start-PassportPreMvpStaffStewardPilot.ps1 ``",
    "  -HandoffRoot `"$resolvedOutput`" ``",
    "  -PilotId `"$PilotId`" ``",
    "  -PilotOwner `"$PilotOwner`" ``",
    "  -OutputPath `"$pilotWorkspaceLaunchPath`" ``",
    "  -Force",
    '```',
    "",
    "For non-interactive preparation without opening windows or launching Passport:",
    "",
    '```powershell',
    ".\tools\release\Start-PassportPreMvpStaffStewardPilot.ps1 ``",
    "  -HandoffRoot `"$resolvedOutput`" ``",
    "  -PilotId `"$PilotId`" ``",
    "  -PilotOwner `"$PilotOwner`" ``",
    "  -OutputPath `"$pilotWorkspaceLaunchPath`" ``",
    "  -SkipOpenRunbook ``",
    "  -SkipOpenEvidenceFolder ``",
    "  -SkipLaunchPassport ``",
    "  -Force",
    '```',
    "",
    "## Optional Dry-Run Evidence",
    "",
    "Generate supporting dry-run evidence before or during the controlled pilot. This report is only supporting evidence_reference material and does not replace participant signoff or the final staff/steward pilot report.",
    "",
    '```powershell',
    ".\tools\release\New-PassportPreMvpStaffStewardPilotDryRunEvidence.ps1 ``",
    "  -OutputDirectory `"$resolvedOutput\pilot-dry-run`" ``",
    "  -HandoffRoot `"$resolvedOutput`" ``",
    "  -PilotId `"$PilotId`" ``",
    "  -PilotOwner `"$PilotOwner`" ``",
    "  -RunInstalledArtifactValidation ``",
    "  -RunUiSmoke ``",
    "  -SkipDaemon ``",
    "  -Force",
    "",
    ".\tools\release\Test-PassportPreMvpStaffStewardPilotDryRunEvidence.ps1 ``",
    "  -ReportPath `"$resolvedOutput\pilot-dry-run\staff-steward-pilot-dry-run-evidence.json`" ``",
    "  -OutputPath `"$resolvedOutput\pilot-dry-run-validation-report.json`"",
    '```',
    "",
    "## Fill The Evidence Packet",
    "",
    "Complete these files in the controlled evidence system:",
    "",
    "- ``$resolvedEvidencePacketDirectory\\pilot-session-record.json``",
    "- ``$resolvedEvidencePacketDirectory\\participant-signoff.json``",
    "- ``$resolvedEvidencePacketDirectory\\pilot-issue-review.json``",
    "",
    "Required pilot scenarios:",
    "",
    "- ``identity_create_or_recover``",
    "- ``device_authorization``",
    "- ``wallet_key_binding``",
    "- ``recovery_revocation``",
    "- ``storage_contribution_opt_in_revocation``",
    "- ``ledger_export_verification``",
    "- ``hosted_ai_privacy``",
    "- ``production_blocker_review``",
    "",
    "Evidence reference guidance:",
    "",
    "| Scenario | Evidence reference should prove |",
    "|---|---|",
    "| ``identity_create_or_recover`` | The staff/steward participant created or recovered a Passport identity on the controlled device. |",
    "| ``device_authorization`` | The controlled device was authorized and its device ID was captured. |",
    "| ``wallet_key_binding`` | A wallet key was bound without exposing private key or seed material. |",
    "| ``recovery_revocation`` | Recovery or revocation was exercised and produced signed/exportable evidence. |",
    "| ``storage_contribution_opt_in_revocation`` | Storage contribution was explicitly enabled, then paused or revoked, with local controls observed. |",
    "| ``ledger_export_verification`` | Account history was exported and verifier output or hash was captured. |",
    "| ``hosted_ai_privacy`` | Hosted AI disclosure/privacy behavior was observed without submitting secrets. |",
    "| ``production_blocker_review`` | The pilot owner reviewed current production readiness blockers before signoff. |",
    "",
    "Supporting dry-run reports can be used as evidence references, but they do not replace participant observation, participant signoff, or the final pilot report.",
    "",
    "Prefer the structured helper below after the pilot is complete. It writes the three evidence JSON files, recomputes the current artifact and production-readiness hashes, and immediately validates the filled packet. Replace every evidence reference with the controlled evidence ID or URI captured during the pilot.",
    "",
    '```powershell',
    ".\tools\release\Set-PassportPreMvpStaffStewardPilotEvidencePacket.ps1 ``",
    "  -PacketRoot `"$resolvedEvidencePacketDirectory`" ``",
    "  -PilotId `"$PilotId`" ``",
    "  -PilotOwner `"$PilotOwner`" ``",
    "  -ParticipantId `"<staff-or-steward-id>`" ``",
    "  -ParticipantRole `"<staff-or-steward-role>`" ``",
    "  -CrownOwnedDeviceId `"<controlled-device-id>`" ``",
    "  -SessionStartedUtc `"<yyyy-mm-ddThh:mm:ssZ>`" ``",
    "  -SessionEndedUtc `"<yyyy-mm-ddThh:mm:ssZ>`" ``",
    "  -SignedUtc `"<yyyy-mm-ddThh:mm:ssZ>`" ``",
    "  -SignoffReference `"<signature-or-controlled-approval-id>`" ``",
    "  -ReviewSignoffReference `"<signature-or-controlled-approval-id>`" ``",
    "  -IdentityCreateOrRecoverEvidenceReference `"<evidence-id-or-uri>`" ``",
    "  -DeviceAuthorizationEvidenceReference `"<evidence-id-or-uri>`" ``",
    "  -WalletKeyBindingEvidenceReference `"<evidence-id-or-uri>`" ``",
    "  -RecoveryRevocationEvidenceReference `"<evidence-id-or-uri>`" ``",
    "  -StorageContributionOptInRevocationEvidenceReference `"<evidence-id-or-uri>`" ``",
    "  -LedgerExportVerificationEvidenceReference `"<evidence-id-or-uri>`" ``",
    "  -HostedAiPrivacyEvidenceReference `"<evidence-id-or-uri>`" ``",
    "  -ProductionBlockerReviewEvidenceReference `"<evidence-id-or-uri>`" ``",
    "  -ConfirmStaffOrStewardParticipant ``",
    "  -ConfirmCrownOwnedDeviceUsed ``",
    "  -ConfirmSyntheticOrFakeBalancesUsed ``",
    "  -ConfirmNoCitizenProductionTokensUsed ``",
    "  -ConfirmNoProductionRecordsCreated ``",
    "  -ConfirmProductionReadinessBlockersReviewed ``",
    "  -ConfirmNoPilotBlockingDefects ``",
    "  -ConfirmPilotSignoffSigned ``",
    "  -Force",
    '```',
    "",
    "## Validate And Generate The Pilot Report",
    "",
    '```powershell',
    ".\tools\release\Test-PassportPreMvpStaffStewardPilotEvidencePacket.ps1 ``",
    "  -PacketRoot `"$resolvedEvidencePacketDirectory`" ``",
    "  -RequireNoPlaceholders ``",
    "  -OutputPath `"$finalPreviewValidationPath`"",
    "",
    ".\tools\release\New-PassportPreMvpStaffStewardPilotReport.ps1 ``",
    "  -OutputPath `"$staffPilotReportPath`" ``",
    "  -PilotId `"$PilotId`" ``",
    "  -PilotOwner `"$PilotOwner`" ``",
    "  -ParticipantCount $ParticipantCount ``",
    "  -EvidencePacketPath `"$resolvedEvidencePacketDirectory`" ``",
    "  -ConfirmCompleted ``",
    "  -ConfirmStaffOrStewardParticipants ``",
    "  -ConfirmCrownOwnedDevices ``",
    "  -ConfirmNoCitizenProductionTokens ``",
    "  -ConfirmRecoveryRevocationValidated ``",
    "  -ConfirmStorageContributionValidated ``",
    "  -ConfirmLedgerExportValidated ``",
    "  -ConfirmHostedAiPrivacyValidated ``",
    "  -ConfirmProductionReadinessBlockersReviewed ``",
    "  -ConfirmPilotSignoffSigned ``",
    "  -ConfirmNoProductionRecordsCreated | Tee-Object -FilePath `"$staffPilotReportGenerationOutputPath`"",
    "",
    "`$staffPilotHash = (Get-FileHash -Algorithm SHA256 -LiteralPath `"$staffPilotReportPath`").Hash.ToLowerInvariant()",
    "",
    ".\tools\release\Test-PassportPreMvpStaffStewardPilotReport.ps1 ``",
    "  -ReportPath `"$staffPilotReportPath`" ``",
    "  -ReportSha256 `$staffPilotHash ``",
    "  -OutputPath `"$staffPilotReportValidationPath`"",
    "",
    "`$simulationHash = `"$simulationHashExpression`"",
    "",
    ".\tools\release\Test-PassportPreMvpInternalVerification.ps1 ``",
    "  -SimulationRunReportPath `"$($simulationReport.path)`" ``",
    "  -SimulationRunReportSha256 `$simulationHash ``",
    "  -StaffStewardPilotReportPath `"$staffPilotReportPath`" ``",
    "  -StaffStewardPilotReportSha256 `$staffPilotHash ``",
    "  -OutputPath `"$finalPreMvpReportPath`"",
    '```',
    "",
    "Expected result after real evidence is filled: ``staff_steward_pilot_evidence`` passes and the pre-MVP umbrella report has zero failed checks. Before that, the gate must continue to fail."
)

$runbookLines | Set-Content -LiteralPath $runbookPath -Encoding UTF8

$manifestPath = Join-Path $resolvedOutput "pilot-handoff.manifest.json"
$generatedEvidenceFiles = @()
foreach ($path in @(
    (Join-Path $resolvedEvidencePacketDirectory "pilot-session-record.json"),
    (Join-Path $resolvedEvidencePacketDirectory "participant-signoff.json"),
    (Join-Path $resolvedEvidencePacketDirectory "pilot-issue-review.json"),
    (Join-Path $resolvedEvidencePacketDirectory "README.md")
)) {
    $generatedEvidenceFiles += Get-FileRecord -Id ([System.IO.Path]::GetFileNameWithoutExtension($path)) -Path $path
}

$handoffFiles = @(
    (Get-FileRecord -Id "operator_runbook" -Path $runbookPath),
    (Get-FileRecord -Id "pilot_workspace_launcher_script" -Path (Join-Path $scriptRoot "Start-PassportPreMvpStaffStewardPilot.ps1")),
    (Get-FileRecord -Id "pilot_evidence_fill_helper_script" -Path (Join-Path $scriptRoot "Set-PassportPreMvpStaffStewardPilotEvidencePacket.ps1")),
    (Get-FileRecord -Id "pilot_evidence_template_validation_report" -Path $templateValidationPath),
    (Get-FileRecord -Id "pilot_evidence_final_validation_preview_report" -Path $finalPreviewValidationPath)
)

$manifest = [pscustomobject][ordered]@{
    schema = "archrealms.passport.pre_mvp_staff_steward_pilot_handoff.v1"
    created_utc = $createdUtc
    lane = "internal-verification"
    app_commit = Get-CurrentCommit
    pilot_id = $PilotId
    pilot_owner = $PilotOwner
    policy_version = $PolicyVersion
    participant_count = $ParticipantCount
    output_directory = $resolvedOutput
    evidence_packet_directory = $resolvedEvidencePacketDirectory
    pilot_report_is_required = $true
    citizen_facing_token_release_ready = $false
    production_records_must_not_be_created = $true
    source_inputs = [pscustomobject][ordered]@{
        artifact_manifest = $artifactManifest
        simulation_report = $simulationReport
        pre_mvp_report = $preMvpReport
        production_readiness_report = $productionReadinessReport
    }
    validation = [pscustomobject][ordered]@{
        template_validation_passed = [bool]$templateValidationReport.passed
        template_validation_report = Get-FileRecord -Id "pilot_evidence_template_validation_report" -Path $templateValidationPath
        require_no_placeholders_preview_passed = [bool]$finalPreviewValidationReport.passed
        require_no_placeholders_preview_expected_to_fail = $true
        require_no_placeholders_preview_report = Get-FileRecord -Id "pilot_evidence_final_validation_preview_report" -Path $finalPreviewValidationPath
    }
    generated_evidence_files = $generatedEvidenceFiles
    handoff_files = $handoffFiles
    next_step = "Run the controlled staff/steward pilot, fill the evidence packet, validate it with -RequireNoPlaceholders, generate the pilot report, then rerun Test-PassportPreMvpInternalVerification.ps1 with the pilot report path and SHA-256."
}

Write-JsonFile -Path $manifestPath -Value $manifest
$manifestRecord = Get-FileRecord -Id "pilot_handoff_manifest" -Path $manifestPath

[pscustomObject][ordered]@{
    handoff_root = $resolvedOutput
    evidence_packet_root = $resolvedEvidencePacketDirectory
    manifest_path = $manifestRecord.path
    manifest_sha256 = $manifestRecord.sha256
    runbook_path = $runbookPath
    template_validation_report = $templateValidationPath
    final_validation_preview_report = $finalPreviewValidationPath
    final_validation_preview_passed = [bool]$finalPreviewValidationReport.passed
    next_step = $manifest.next_step
} | ConvertTo-Json -Depth 10
