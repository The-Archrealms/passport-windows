param(
    [string]$PacketRoot = "artifacts\release\pre-mvp-staff-steward-pilot-handoff\pilot-evidence",
    [string]$PilotId,
    [string]$PilotOwner,
    [string]$PolicyVersion = "token-ready-passport-mvp-pre-mvp-internal-verification-v1",
    [string]$ParticipantId,
    [string]$ParticipantRole,
    [string[]]$CrownOwnedDeviceId,
    [string]$SessionStartedUtc,
    [string]$SessionEndedUtc,
    [string]$SignedUtc,
    [string]$SignoffReference,
    [string]$ReviewSignoffReference,
    [string]$IdentityCreateOrRecoverEvidenceReference,
    [string]$DeviceAuthorizationEvidenceReference,
    [string]$WalletKeyBindingEvidenceReference,
    [string]$RecoveryRevocationEvidenceReference,
    [string]$StorageContributionOptInRevocationEvidenceReference,
    [string]$LedgerExportVerificationEvidenceReference,
    [string]$HostedAiPrivacyEvidenceReference,
    [string]$ProductionBlockerReviewEvidenceReference,
    [string]$ArtifactManifestPath = "artifacts\release\internal-verification-lane\passport-windows-win-x64\release-manifest.json",
    [string]$ProductionReadinessReportPath = "artifacts\release\production-mvp-readiness-report.json",
    [string[]]$RemainingProductionBlocker,
    [string]$ValidationOutputPath,
    [switch]$ConfirmStaffOrStewardParticipant,
    [switch]$ConfirmCrownOwnedDeviceUsed,
    [switch]$ConfirmSyntheticOrFakeBalancesUsed,
    [switch]$ConfirmNoCitizenProductionTokensUsed,
    [switch]$ConfirmNoProductionRecordsCreated,
    [switch]$ConfirmProductionReadinessBlockersReviewed,
    [switch]$ConfirmNoPilotBlockingDefects,
    [switch]$ConfirmPilotSignoffSigned,
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

    return ""
}

function Get-Sha256Hex {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Referenced file is missing: $Path"
    }

    return (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant()
}

function Assert-Value {
    param(
        [string]$Name,
        [string]$Value
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        throw "$Name is required."
    }

    if ($Value -match '<[^>]+>' -or $Value -match '^\s*set value\s*$') {
        throw "$Name contains a placeholder value."
    }
}

function Assert-UtcTimestamp {
    param(
        [string]$Name,
        [string]$Value
    )

    Assert-Value -Name $Name -Value $Value
    if ($Value -notmatch '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$') {
        throw "$Name must use yyyy-MM-ddTHH:mm:ssZ."
    }
}

function Assert-Confirmation {
    param(
        [string]$Name,
        [bool]$Value
    )

    if (-not $Value) {
        throw "$Name confirmation is required to generate a passing pilot evidence packet."
    }
}

function Write-JsonFile {
    param(
        [string]$Path,
        [object]$Value
    )

    if ((Test-Path -LiteralPath $Path -PathType Leaf) -and -not $Force) {
        throw "Refusing to overwrite existing evidence file without -Force: $Path"
    }

    $parent = Split-Path -Parent $Path
    if ($parent) {
        New-Item -ItemType Directory -Force -Path $parent | Out-Null
    }

    $Value | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $Path -Encoding UTF8
}

$resolvedPacketRoot = Resolve-RepoPath -Path $PacketRoot
New-Item -ItemType Directory -Force -Path $resolvedPacketRoot | Out-Null

$existingSession = Read-JsonFile -Path (Join-Path $resolvedPacketRoot "pilot-session-record.json")
$existingIssueReview = Read-JsonFile -Path (Join-Path $resolvedPacketRoot "pilot-issue-review.json")

if ([string]::IsNullOrWhiteSpace($PilotId)) {
    $PilotId = Read-ObjectString -Object $existingSession -Name "pilot_id"
}

if ([string]::IsNullOrWhiteSpace($PilotOwner)) {
    $PilotOwner = Read-ObjectString -Object $existingSession -Name "pilot_owner"
}

if ([string]::IsNullOrWhiteSpace($PolicyVersion)) {
    $PolicyVersion = Read-ObjectString -Object $existingSession -Name "policy_version"
}

if ([string]::IsNullOrWhiteSpace($SignedUtc)) {
    $SignedUtc = $SessionEndedUtc
}

foreach ($entry in ([ordered]@{
    PilotId = $PilotId
    PilotOwner = $PilotOwner
    PolicyVersion = $PolicyVersion
    ParticipantId = $ParticipantId
    ParticipantRole = $ParticipantRole
    SignoffReference = $SignoffReference
    ReviewSignoffReference = $ReviewSignoffReference
    IdentityCreateOrRecoverEvidenceReference = $IdentityCreateOrRecoverEvidenceReference
    DeviceAuthorizationEvidenceReference = $DeviceAuthorizationEvidenceReference
    WalletKeyBindingEvidenceReference = $WalletKeyBindingEvidenceReference
    RecoveryRevocationEvidenceReference = $RecoveryRevocationEvidenceReference
    StorageContributionOptInRevocationEvidenceReference = $StorageContributionOptInRevocationEvidenceReference
    LedgerExportVerificationEvidenceReference = $LedgerExportVerificationEvidenceReference
    HostedAiPrivacyEvidenceReference = $HostedAiPrivacyEvidenceReference
    ProductionBlockerReviewEvidenceReference = $ProductionBlockerReviewEvidenceReference
}).GetEnumerator()) {
    Assert-Value -Name $entry.Key -Value ([string]$entry.Value)
}

Assert-UtcTimestamp -Name "SessionStartedUtc" -Value $SessionStartedUtc
Assert-UtcTimestamp -Name "SessionEndedUtc" -Value $SessionEndedUtc
Assert-UtcTimestamp -Name "SignedUtc" -Value $SignedUtc

$normalizedDeviceIds = @($CrownOwnedDeviceId | ForEach-Object { ([string]$_).Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
if ($normalizedDeviceIds.Count -lt 1) {
    throw "At least one CrownOwnedDeviceId is required."
}

foreach ($deviceId in $normalizedDeviceIds) {
    Assert-Value -Name "CrownOwnedDeviceId" -Value $deviceId
}

Assert-Confirmation -Name "ConfirmStaffOrStewardParticipant" -Value ([bool]$ConfirmStaffOrStewardParticipant)
Assert-Confirmation -Name "ConfirmCrownOwnedDeviceUsed" -Value ([bool]$ConfirmCrownOwnedDeviceUsed)
Assert-Confirmation -Name "ConfirmSyntheticOrFakeBalancesUsed" -Value ([bool]$ConfirmSyntheticOrFakeBalancesUsed)
Assert-Confirmation -Name "ConfirmNoCitizenProductionTokensUsed" -Value ([bool]$ConfirmNoCitizenProductionTokensUsed)
Assert-Confirmation -Name "ConfirmNoProductionRecordsCreated" -Value ([bool]$ConfirmNoProductionRecordsCreated)
Assert-Confirmation -Name "ConfirmProductionReadinessBlockersReviewed" -Value ([bool]$ConfirmProductionReadinessBlockersReviewed)
Assert-Confirmation -Name "ConfirmNoPilotBlockingDefects" -Value ([bool]$ConfirmNoPilotBlockingDefects)
Assert-Confirmation -Name "ConfirmPilotSignoffSigned" -Value ([bool]$ConfirmPilotSignoffSigned)

$resolvedArtifactManifestPath = Resolve-RepoPath -Path $ArtifactManifestPath
$artifactManifestSha256 = Get-Sha256Hex -Path $resolvedArtifactManifestPath

$resolvedProductionReadinessReportPath = Resolve-RepoPath -Path $ProductionReadinessReportPath
$productionReadinessReportSha256 = Get-Sha256Hex -Path $resolvedProductionReadinessReportPath
$productionReadinessReport = Read-JsonFile -Path $resolvedProductionReadinessReportPath

$normalizedRemainingBlockers = @()
foreach ($blocker in @($RemainingProductionBlocker)) {
    $trimmed = ([string]$blocker).Trim()
    if (-not [string]::IsNullOrWhiteSpace($trimmed)) {
        $normalizedRemainingBlockers += $trimmed
    }
}

if ($normalizedRemainingBlockers.Count -eq 0 -and $null -ne $productionReadinessReport) {
    $normalizedRemainingBlockers = @($productionReadinessReport.gates | Where-Object { -not [bool]$_.passed } | ForEach-Object { [string]$_.id } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
}

if ($normalizedRemainingBlockers.Count -eq 0 -and $null -ne $existingIssueReview) {
    $normalizedRemainingBlockers = @($existingIssueReview.remaining_production_blockers | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) -and $_ -notmatch '<[^>]+>' })
}

$createdUtc = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
$appCommit = Get-CurrentCommit

$scenarioEvidence = [ordered]@{
    identity_create_or_recover = $IdentityCreateOrRecoverEvidenceReference
    device_authorization = $DeviceAuthorizationEvidenceReference
    wallet_key_binding = $WalletKeyBindingEvidenceReference
    recovery_revocation = $RecoveryRevocationEvidenceReference
    storage_contribution_opt_in_revocation = $StorageContributionOptInRevocationEvidenceReference
    ledger_export_verification = $LedgerExportVerificationEvidenceReference
    hosted_ai_privacy = $HostedAiPrivacyEvidenceReference
    production_blocker_review = $ProductionBlockerReviewEvidenceReference
}

$session = [pscustomobject][ordered]@{
    schema = "archrealms.passport.pre_mvp_staff_steward_pilot_session.v1"
    created_utc = $createdUtc
    lane = "internal-verification"
    pilot_id = $PilotId
    pilot_owner = $PilotOwner
    policy_version = $PolicyVersion
    app_commit = $appCommit
    artifact_manifest_path = $resolvedArtifactManifestPath
    artifact_manifest_sha256 = $artifactManifestSha256
    session_started_utc = $SessionStartedUtc
    session_ended_utc = $SessionEndedUtc
    pilot_participant_count = 1
    crown_owned_device_ids = @($normalizedDeviceIds)
    synthetic_or_fake_balances_used = $true
    no_citizen_production_tokens_used = $true
    no_production_records_created = $true
    scenarios = @($scenarioEvidence.GetEnumerator() | ForEach-Object {
        [pscustomobject][ordered]@{
            id = [string]$_.Key
            passed = $true
            evidence_reference = [string]$_.Value
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
            participant_id = $ParticipantId
            participant_role = $ParticipantRole
            staff_or_steward_participant = $true
            crown_owned_device_used = $true
            no_citizen_production_tokens_used = $true
            no_production_records_created = $true
            signed_utc = $SignedUtc
            signoff_reference = $SignoffReference
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
    production_readiness_report_path = $resolvedProductionReadinessReportPath
    production_readiness_report_sha256 = $productionReadinessReportSha256
    production_readiness_blockers_reviewed = $true
    pilot_signoff_signed = $true
    no_pilot_blocking_defects = $true
    no_production_records_created = $true
    pilot_blockers = @()
    remaining_production_blockers = @($normalizedRemainingBlockers)
    review_signoff_reference = $ReviewSignoffReference
}

$sessionPath = Join-Path $resolvedPacketRoot "pilot-session-record.json"
$signoffPath = Join-Path $resolvedPacketRoot "participant-signoff.json"
$issueReviewPath = Join-Path $resolvedPacketRoot "pilot-issue-review.json"

Write-JsonFile -Path $sessionPath -Value $session
Write-JsonFile -Path $signoffPath -Value $signoff
Write-JsonFile -Path $issueReviewPath -Value $issueReview

if ([string]::IsNullOrWhiteSpace($ValidationOutputPath)) {
    $ValidationOutputPath = Join-Path (Split-Path -Parent $resolvedPacketRoot) "pilot-evidence-final-validation-report.json"
}

$resolvedValidationOutputPath = Resolve-RepoPath -Path $ValidationOutputPath
$validatorPath = Join-Path $scriptRoot "Test-PassportPreMvpStaffStewardPilotEvidencePacket.ps1"
$validationOutput = & powershell -NoProfile -ExecutionPolicy Bypass -File $validatorPath -PacketRoot $resolvedPacketRoot -RequireNoPlaceholders -OutputPath $resolvedValidationOutputPath 2>&1
if ($LASTEXITCODE -ne 0) {
    throw "Filled pilot evidence packet validation failed: $($validationOutput -join [Environment]::NewLine)"
}

$validationReport = Read-JsonFile -Path $resolvedValidationOutputPath
if ($null -eq $validationReport -or -not [bool]$validationReport.passed) {
    throw "Filled pilot evidence packet validation did not pass: $resolvedValidationOutputPath"
}

[pscustomobject][ordered]@{
    schema = "archrealms.passport.pre_mvp_staff_steward_pilot_evidence_fill_result.v1"
    packet_root = $resolvedPacketRoot
    validation_report_path = $resolvedValidationOutputPath
    validation_report_sha256 = Get-Sha256Hex -Path $resolvedValidationOutputPath
    evidence_files = @(
        [pscustomobject][ordered]@{ id = "pilot_session_record"; path = $sessionPath; sha256 = Get-Sha256Hex -Path $sessionPath }
        [pscustomobject][ordered]@{ id = "participant_signoff"; path = $signoffPath; sha256 = Get-Sha256Hex -Path $signoffPath }
        [pscustomobject][ordered]@{ id = "pilot_issue_review"; path = $issueReviewPath; sha256 = Get-Sha256Hex -Path $issueReviewPath }
    )
    next_step = "Run Complete-PassportPreMvpStaffStewardPilotHandoff.ps1 against the filled handoff root to generate the pilot report and rerun pre-MVP verification."
} | ConvertTo-Json -Depth 10
