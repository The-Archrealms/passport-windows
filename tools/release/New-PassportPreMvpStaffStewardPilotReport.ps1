param(
    [string]$OutputPath = "artifacts\release\pre-mvp-staff-steward-pilot-report.json",
    [string]$PilotId,
    [string]$PilotOwner,
    [string]$PolicyVersion = "token-ready-passport-mvp-pre-mvp-internal-verification-v1",
    [int]$ParticipantCount,
    [string[]]$EvidenceReference,
    [switch]$ConfirmCompleted,
    [switch]$ConfirmStaffOrStewardParticipants,
    [switch]$ConfirmCrownOwnedDevices,
    [switch]$ConfirmNoCitizenProductionTokens,
    [switch]$ConfirmRecoveryRevocationValidated,
    [switch]$ConfirmStorageContributionValidated,
    [switch]$ConfirmLedgerExportValidated,
    [switch]$ConfirmHostedAiPrivacyValidated,
    [switch]$ConfirmProductionReadinessBlockersReviewed,
    [switch]$ConfirmPilotSignoffSigned,
    [switch]$ConfirmNoProductionRecordsCreated
)

$ErrorActionPreference = "Stop"
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $scriptRoot "..\.."))

function Resolve-RepoPath {
    param([string]$Path)

    if ([System.IO.Path]::IsPathRooted($Path)) {
        return [System.IO.Path]::GetFullPath($Path)
    }

    return [System.IO.Path]::GetFullPath((Join-Path $repoRoot $Path))
}

function Test-NotPlaceholder {
    param(
        [string]$Name,
        [string]$Value
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return "$Name is required"
    }

    $trimmed = $Value.Trim()
    if ($trimmed -match '<[^>]+>' -or $trimmed -match '^\s*set value\s*$') {
        return "$Name contains a placeholder value"
    }

    return ""
}

function Assert-Confirmed {
    param(
        [string]$Name,
        [bool]$Value
    )

    if (-not $Value) {
        throw "$Name must be explicitly confirmed to create a passing staff/steward pilot report."
    }
}

foreach ($field in @(
    @{ Name = "PilotId"; Value = $PilotId },
    @{ Name = "PilotOwner"; Value = $PilotOwner },
    @{ Name = "PolicyVersion"; Value = $PolicyVersion }
)) {
    $failure = Test-NotPlaceholder -Name $field.Name -Value $field.Value
    if ($failure) {
        throw $failure
    }
}

if ($ParticipantCount -lt 1) {
    throw "ParticipantCount must be at least 1."
}

$references = @($EvidenceReference | ForEach-Object { ([string]$_).Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
if ($references.Count -lt 3) {
    throw "At least three EvidenceReference values are required."
}

for ($index = 0; $index -lt $references.Count; $index++) {
    $failure = Test-NotPlaceholder -Name "EvidenceReference[$index]" -Value $references[$index]
    if ($failure) {
        throw $failure
    }
}

Assert-Confirmed -Name "ConfirmCompleted" -Value $ConfirmCompleted
Assert-Confirmed -Name "ConfirmStaffOrStewardParticipants" -Value $ConfirmStaffOrStewardParticipants
Assert-Confirmed -Name "ConfirmCrownOwnedDevices" -Value $ConfirmCrownOwnedDevices
Assert-Confirmed -Name "ConfirmNoCitizenProductionTokens" -Value $ConfirmNoCitizenProductionTokens
Assert-Confirmed -Name "ConfirmRecoveryRevocationValidated" -Value $ConfirmRecoveryRevocationValidated
Assert-Confirmed -Name "ConfirmStorageContributionValidated" -Value $ConfirmStorageContributionValidated
Assert-Confirmed -Name "ConfirmLedgerExportValidated" -Value $ConfirmLedgerExportValidated
Assert-Confirmed -Name "ConfirmHostedAiPrivacyValidated" -Value $ConfirmHostedAiPrivacyValidated
Assert-Confirmed -Name "ConfirmProductionReadinessBlockersReviewed" -Value $ConfirmProductionReadinessBlockersReviewed
Assert-Confirmed -Name "ConfirmPilotSignoffSigned" -Value $ConfirmPilotSignoffSigned
Assert-Confirmed -Name "ConfirmNoProductionRecordsCreated" -Value $ConfirmNoProductionRecordsCreated

$resolvedOutputPath = Resolve-RepoPath -Path $OutputPath
$outputDirectory = Split-Path -Parent $resolvedOutputPath
if ($outputDirectory) {
    New-Item -ItemType Directory -Force -Path $outputDirectory | Out-Null
}

$report = [pscustomobject][ordered]@{
    schema = "archrealms.passport.pre_mvp_staff_steward_pilot.v1"
    created_utc = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
    lane = "internal-verification"
    staff_steward_pilot_id = $PilotId.Trim()
    pilot_owner = $PilotOwner.Trim()
    policy_version = $PolicyVersion.Trim()
    pilot_participant_count = $ParticipantCount
    completed = $true
    staff_or_steward_participants_confirmed = $true
    crown_owned_devices_used = $true
    no_citizen_production_tokens_used = $true
    recovery_revocation_validated = $true
    storage_contribution_validated = $true
    ledger_export_validated = $true
    hosted_ai_privacy_validated = $true
    production_readiness_blockers_reviewed = $true
    pilot_signoff_signed = $true
    no_production_records_created = $true
    evidence_references = $references
}

Set-Content -LiteralPath $resolvedOutputPath -Value ($report | ConvertTo-Json -Depth 8) -Encoding UTF8

$hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $resolvedOutputPath).Hash.ToLowerInvariant()
[pscustomobject][ordered]@{
    report_path = $resolvedOutputPath
    report_sha256 = $hash
    report = $report
} | ConvertTo-Json -Depth 10
