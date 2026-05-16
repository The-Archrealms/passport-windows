param(
    [string]$PacketRoot = "artifacts\release\staging-readiness-evidence",
    [string]$OperationalDrillId = "staging-operational-drill-001",
    [string]$RollbackDrillId = "staging-rollback-drill-001",
    [string]$PromotionApprovalId = "staging-promotion-approval-001",
    [string]$EngineeringSignoffId,
    [string]$SecurityPrivacySignoffId,
    [string]$CrownMonetaryAuthoritySignoffId,
    [string]$ApiBaseUrl,
    [string]$AiGatewayUrl,
    [string]$LedgerNamespace = "archrealms-passport-staging",
    [string]$TelemetryDestination,
    [string]$PackageVersion,
    [string]$PolicyVersion = "passport-token-ready-mvp-v1",
    [string]$Operator,
    [string]$IncidentResponseOwner,
    [string[]]$OperationalEvidenceReference,
    [string]$RollbackReasonCode,
    [string[]]$RollbackApprover,
    [string[]]$AffectedServiceClass = @("identity", "wallet", "storage", "ai", "ledger-export"),
    [string[]]$AffectedAsset = @("ARCH", "CC"),
    [string]$RollbackUserFacingStatus,
    [string]$PreMvpReportPath = "artifacts\release\pre-mvp-internal-verification-report.json",
    [string]$PreMvpReportSha256,
    [string]$StagingArtifactValidationReportPath = "artifacts\release\staging-artifact-validation-report.json",
    [string]$StagingArtifactValidationReportSha256,
    [string]$ValidationOutputPath,
    [switch]$ConfirmOperationalDrillCompleted,
    [switch]$ConfirmProductionCandidateUpgradeValidated,
    [switch]$ConfirmEndpointFailoverValidated,
    [switch]$ConfirmSigningVerificationValidated,
    [switch]$ConfirmLedgerExportReplayValidated,
    [switch]$ConfirmRecoveryRevocationValidated,
    [switch]$ConfirmStorageProofValidationCompleted,
    [switch]$ConfirmStorageRedemptionDryRunCompleted,
    [switch]$ConfirmConversionDisclosureDryRunCompleted,
    [switch]$ConfirmTelemetryPrivacyValidated,
    [switch]$ConfirmIncidentResponseValidated,
    [switch]$ConfirmSupportAccessControlsValidated,
    [switch]$ConfirmAiGatewayAuthPrivacyValidated,
    [switch]$ConfirmProhibitedClaimsBlocked,
    [switch]$ConfirmRollbackDrillCompleted,
    [switch]$ConfirmNewOperationsDisabledOrRouted,
    [switch]$ConfirmLedgerEventsPreserved,
    [switch]$ConfirmNoDeletionMutationOrBackdating,
    [switch]$ConfirmPendingEscrowResolvedByPolicy,
    [switch]$ConfirmExportAccessPreserved,
    [switch]$ConfirmProductionRecordsUntouched,
    [switch]$ConfirmCanaryOrProductionReleaseApproved,
    [switch]$ConfirmProductApprovalSigned,
    [switch]$ConfirmEngineeringSignoffSigned,
    [switch]$ConfirmSecurityPrivacySignoffSigned,
    [switch]$ConfirmCrownMonetaryAuthoritySignoffSigned,
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

function Assert-Sha256 {
    param(
        [string]$Name,
        [string]$Value
    )

    Assert-Value -Name $Name -Value $Value
    if ($Value -notmatch '^[0-9a-fA-F]{64}$') {
        throw "$Name must be a SHA-256 hex string."
    }
}

function Assert-Confirmation {
    param(
        [string]$Name,
        [bool]$Value
    )

    if (-not $Value) {
        throw "$Name confirmation is required to generate a passing staging evidence packet."
    }
}

function Assert-StringArray {
    param(
        [string]$Name,
        [string[]]$Value,
        [int]$MinimumCount = 1
    )

    $items = @(
        $Value | ForEach-Object {
            $raw = ([string]$_).Trim()
            if ([string]::IsNullOrWhiteSpace($raw)) {
                return
            }

            $raw -split ';' | ForEach-Object { ([string]$_).Trim() }
        } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    )
    if ($items.Count -lt $MinimumCount) {
        throw "$Name requires at least $MinimumCount value(s)."
    }

    foreach ($item in $items) {
        Assert-Value -Name $Name -Value $item
    }

    return @($items)
}

function Write-JsonFile {
    param(
        [string]$Path,
        [object]$Value
    )

    if ((Test-Path -LiteralPath $Path -PathType Leaf) -and -not $Force) {
        throw "Refusing to overwrite existing staging evidence file without -Force: $Path"
    }

    $parent = Split-Path -Parent $Path
    if ($parent) {
        New-Item -ItemType Directory -Force -Path $parent | Out-Null
    }

    $Value | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $Path -Encoding UTF8
}

$resolvedPacketRoot = Resolve-RepoPath -Path $PacketRoot
New-Item -ItemType Directory -Force -Path $resolvedPacketRoot | Out-Null

$existingOperational = Read-JsonFile -Path (Join-Path $resolvedPacketRoot "staging-operational-drill-report.json")
$existingRollback = Read-JsonFile -Path (Join-Path $resolvedPacketRoot "staging-rollback-drill-report.json")
$existingPromotion = Read-JsonFile -Path (Join-Path $resolvedPacketRoot "staging-promotion-approval-record.json")

if ([string]::IsNullOrWhiteSpace($OperationalDrillId)) {
    $OperationalDrillId = Read-ObjectString -Object $existingOperational -Name "operational_drill_id"
}

if ([string]::IsNullOrWhiteSpace($RollbackDrillId)) {
    $RollbackDrillId = Read-ObjectString -Object $existingRollback -Name "rollback_drill_id"
}

if ([string]::IsNullOrWhiteSpace($PromotionApprovalId)) {
    $PromotionApprovalId = Read-ObjectString -Object $existingPromotion -Name "promotion_approval_id"
}

foreach ($entry in ([ordered]@{
    OperationalDrillId = $OperationalDrillId
    RollbackDrillId = $RollbackDrillId
    PromotionApprovalId = $PromotionApprovalId
    EngineeringSignoffId = $EngineeringSignoffId
    SecurityPrivacySignoffId = $SecurityPrivacySignoffId
    CrownMonetaryAuthoritySignoffId = $CrownMonetaryAuthoritySignoffId
    ApiBaseUrl = $ApiBaseUrl
    AiGatewayUrl = $AiGatewayUrl
    LedgerNamespace = $LedgerNamespace
    TelemetryDestination = $TelemetryDestination
    PackageVersion = $PackageVersion
    PolicyVersion = $PolicyVersion
    Operator = $Operator
    IncidentResponseOwner = $IncidentResponseOwner
    RollbackReasonCode = $RollbackReasonCode
    RollbackUserFacingStatus = $RollbackUserFacingStatus
}).GetEnumerator()) {
    Assert-Value -Name $entry.Key -Value ([string]$entry.Value)
}

$normalizedOperationalEvidence = Assert-StringArray -Name "OperationalEvidenceReference" -Value $OperationalEvidenceReference -MinimumCount 3
$normalizedRollbackApprovers = Assert-StringArray -Name "RollbackApprover" -Value $RollbackApprover -MinimumCount 2
$normalizedAffectedServiceClasses = Assert-StringArray -Name "AffectedServiceClass" -Value $AffectedServiceClass -MinimumCount 1
$normalizedAffectedAssets = Assert-StringArray -Name "AffectedAsset" -Value $AffectedAsset -MinimumCount 1

Assert-Confirmation -Name "ConfirmOperationalDrillCompleted" -Value ([bool]$ConfirmOperationalDrillCompleted)
Assert-Confirmation -Name "ConfirmProductionCandidateUpgradeValidated" -Value ([bool]$ConfirmProductionCandidateUpgradeValidated)
Assert-Confirmation -Name "ConfirmEndpointFailoverValidated" -Value ([bool]$ConfirmEndpointFailoverValidated)
Assert-Confirmation -Name "ConfirmSigningVerificationValidated" -Value ([bool]$ConfirmSigningVerificationValidated)
Assert-Confirmation -Name "ConfirmLedgerExportReplayValidated" -Value ([bool]$ConfirmLedgerExportReplayValidated)
Assert-Confirmation -Name "ConfirmRecoveryRevocationValidated" -Value ([bool]$ConfirmRecoveryRevocationValidated)
Assert-Confirmation -Name "ConfirmStorageProofValidationCompleted" -Value ([bool]$ConfirmStorageProofValidationCompleted)
Assert-Confirmation -Name "ConfirmStorageRedemptionDryRunCompleted" -Value ([bool]$ConfirmStorageRedemptionDryRunCompleted)
Assert-Confirmation -Name "ConfirmConversionDisclosureDryRunCompleted" -Value ([bool]$ConfirmConversionDisclosureDryRunCompleted)
Assert-Confirmation -Name "ConfirmTelemetryPrivacyValidated" -Value ([bool]$ConfirmTelemetryPrivacyValidated)
Assert-Confirmation -Name "ConfirmIncidentResponseValidated" -Value ([bool]$ConfirmIncidentResponseValidated)
Assert-Confirmation -Name "ConfirmSupportAccessControlsValidated" -Value ([bool]$ConfirmSupportAccessControlsValidated)
Assert-Confirmation -Name "ConfirmAiGatewayAuthPrivacyValidated" -Value ([bool]$ConfirmAiGatewayAuthPrivacyValidated)
Assert-Confirmation -Name "ConfirmProhibitedClaimsBlocked" -Value ([bool]$ConfirmProhibitedClaimsBlocked)
Assert-Confirmation -Name "ConfirmRollbackDrillCompleted" -Value ([bool]$ConfirmRollbackDrillCompleted)
Assert-Confirmation -Name "ConfirmNewOperationsDisabledOrRouted" -Value ([bool]$ConfirmNewOperationsDisabledOrRouted)
Assert-Confirmation -Name "ConfirmLedgerEventsPreserved" -Value ([bool]$ConfirmLedgerEventsPreserved)
Assert-Confirmation -Name "ConfirmNoDeletionMutationOrBackdating" -Value ([bool]$ConfirmNoDeletionMutationOrBackdating)
Assert-Confirmation -Name "ConfirmPendingEscrowResolvedByPolicy" -Value ([bool]$ConfirmPendingEscrowResolvedByPolicy)
Assert-Confirmation -Name "ConfirmExportAccessPreserved" -Value ([bool]$ConfirmExportAccessPreserved)
Assert-Confirmation -Name "ConfirmProductionRecordsUntouched" -Value ([bool]$ConfirmProductionRecordsUntouched)
Assert-Confirmation -Name "ConfirmCanaryOrProductionReleaseApproved" -Value ([bool]$ConfirmCanaryOrProductionReleaseApproved)
Assert-Confirmation -Name "ConfirmProductApprovalSigned" -Value ([bool]$ConfirmProductApprovalSigned)
Assert-Confirmation -Name "ConfirmEngineeringSignoffSigned" -Value ([bool]$ConfirmEngineeringSignoffSigned)
Assert-Confirmation -Name "ConfirmSecurityPrivacySignoffSigned" -Value ([bool]$ConfirmSecurityPrivacySignoffSigned)
Assert-Confirmation -Name "ConfirmCrownMonetaryAuthoritySignoffSigned" -Value ([bool]$ConfirmCrownMonetaryAuthoritySignoffSigned)

$resolvedPreMvpReportPath = Resolve-RepoPath -Path $PreMvpReportPath
if ([string]::IsNullOrWhiteSpace($PreMvpReportSha256)) {
    $PreMvpReportSha256 = Get-Sha256Hex -Path $resolvedPreMvpReportPath
}
Assert-Sha256 -Name "PreMvpReportSha256" -Value $PreMvpReportSha256

$resolvedStagingArtifactValidationReportPath = Resolve-RepoPath -Path $StagingArtifactValidationReportPath
if ([string]::IsNullOrWhiteSpace($StagingArtifactValidationReportSha256)) {
    $StagingArtifactValidationReportSha256 = Get-Sha256Hex -Path $resolvedStagingArtifactValidationReportPath
}
Assert-Sha256 -Name "StagingArtifactValidationReportSha256" -Value $StagingArtifactValidationReportSha256

$createdUtc = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")

$operational = [pscustomobject][ordered]@{
    schema = "archrealms.passport.staging_operational_drill.v1"
    created_utc = $createdUtc
    lane = "staging"
    operational_drill_id = $OperationalDrillId
    completed = $true
    package_version = $PackageVersion
    policy_version = $PolicyVersion
    api_base_url = $ApiBaseUrl
    ai_gateway_url = $AiGatewayUrl
    ledger_namespace = $LedgerNamespace
    telemetry_destination = $TelemetryDestination
    operator = $Operator
    incident_response_owner = $IncidentResponseOwner
    evidence_references = @($normalizedOperationalEvidence)
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

$rollback = [pscustomobject][ordered]@{
    schema = "archrealms.passport.staging_rollback_drill.v1"
    created_utc = $createdUtc
    lane = "staging"
    rollback_drill_id = $RollbackDrillId
    completed = $true
    package_version = $PackageVersion
    policy_version = $PolicyVersion
    reason_code = $RollbackReasonCode
    approvers = @($normalizedRollbackApprovers)
    affected_service_classes = @($normalizedAffectedServiceClasses)
    affected_assets = @($normalizedAffectedAssets)
    user_facing_status = $RollbackUserFacingStatus
    new_operations_disabled_or_routed = $true
    ledger_events_preserved = $true
    no_deletion_mutation_or_backdating = $true
    pending_escrow_resolved_by_policy = $true
    export_access_preserved = $true
    production_records_untouched = $true
}

$operationalPath = Join-Path $resolvedPacketRoot "staging-operational-drill-report.json"
$rollbackPath = Join-Path $resolvedPacketRoot "staging-rollback-drill-report.json"
Write-JsonFile -Path $operationalPath -Value $operational
Write-JsonFile -Path $rollbackPath -Value $rollback

$operationalHash = Get-Sha256Hex -Path $operationalPath
$rollbackHash = Get-Sha256Hex -Path $rollbackPath

$promotion = [pscustomobject][ordered]@{
    schema = "archrealms.passport.staging_promotion_approval.v1"
    created_utc = $createdUtc
    lane = "staging"
    promotion_approval_id = $PromotionApprovalId
    engineering_signoff_id = $EngineeringSignoffId
    security_privacy_signoff_id = $SecurityPrivacySignoffId
    crown_monetary_authority_signoff_id = $CrownMonetaryAuthoritySignoffId
    rollback_drill_id = $RollbackDrillId
    pre_mvp_report_sha256 = $PreMvpReportSha256.ToLowerInvariant()
    staging_artifact_validation_report_sha256 = $StagingArtifactValidationReportSha256.ToLowerInvariant()
    operational_drill_report_sha256 = $operationalHash
    rollback_drill_report_sha256 = $rollbackHash
    approve_canary_or_production_release = $true
    product_approval_signed = $true
    engineering_signoff_signed = $true
    security_privacy_signoff_signed = $true
    crown_monetary_authority_signoff_signed = $true
}

$promotionPath = Join-Path $resolvedPacketRoot "staging-promotion-approval-record.json"
Write-JsonFile -Path $promotionPath -Value $promotion

if ([string]::IsNullOrWhiteSpace($ValidationOutputPath)) {
    $ValidationOutputPath = Join-Path (Split-Path -Parent $resolvedPacketRoot) "staging-readiness-evidence-final-validation-report.json"
}

$resolvedValidationOutputPath = Resolve-RepoPath -Path $ValidationOutputPath
$validatorPath = Join-Path $scriptRoot "Test-PassportStagingReadinessEvidencePacket.ps1"
$validationOutput = & powershell -NoProfile -ExecutionPolicy Bypass -File $validatorPath -PacketRoot $resolvedPacketRoot -RequireNoPlaceholders -OutputPath $resolvedValidationOutputPath 2>&1
if ($LASTEXITCODE -ne 0) {
    throw "Filled staging readiness evidence packet validation failed: $($validationOutput -join [Environment]::NewLine)"
}

$validationReport = Read-JsonFile -Path $resolvedValidationOutputPath
if ($null -eq $validationReport -or -not [bool]$validationReport.passed) {
    throw "Filled staging readiness evidence packet validation did not pass: $resolvedValidationOutputPath"
}

[pscustomobject][ordered]@{
    schema = "archrealms.passport.staging_readiness_evidence_fill_result.v1"
    packet_root = $resolvedPacketRoot
    validation_report_path = $resolvedValidationOutputPath
    validation_report_sha256 = Get-Sha256Hex -Path $resolvedValidationOutputPath
    source_reports = @(
        [pscustomobject][ordered]@{ id = "pre_mvp_internal_verification"; path = $resolvedPreMvpReportPath; sha256 = $PreMvpReportSha256.ToLowerInvariant() }
        [pscustomobject][ordered]@{ id = "staging_artifact_validation"; path = $resolvedStagingArtifactValidationReportPath; sha256 = $StagingArtifactValidationReportSha256.ToLowerInvariant() }
    )
    evidence_files = @(
        [pscustomobject][ordered]@{ id = "staging_operational_drill_report"; path = $operationalPath; sha256 = Get-Sha256Hex -Path $operationalPath }
        [pscustomobject][ordered]@{ id = "staging_rollback_drill_report"; path = $rollbackPath; sha256 = Get-Sha256Hex -Path $rollbackPath }
        [pscustomobject][ordered]@{ id = "staging_promotion_approval_record"; path = $promotionPath; sha256 = Get-Sha256Hex -Path $promotionPath }
    )
    next_step = "Run Complete-PassportStagingReadinessEvidencePacket.ps1 against the filled packet root to generate the staging readiness report and downstream report hashes."
} | ConvertTo-Json -Depth 10
