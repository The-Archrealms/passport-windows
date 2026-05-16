param(
    [string]$PacketRoot = "artifacts\release\canary-mvp-readiness-evidence",
    [string]$PolicyId = "canary-policy-001",
    [string]$IncidentReviewId = "canary-incident-review-001",
    [string]$BalanceReconciliationId = "canary-balance-reconciliation-001",
    [string]$ServiceDeliveryReconciliationId = "canary-service-delivery-reconciliation-001",
    [string]$SupportReadinessId = "canary-support-readiness-001",
    [string]$ProductionApprovalId = "canary-production-approval-001",
    [string]$ProductionLedgerNamespace = "archrealms-passport-production-mvp",
    [int]$MaxCitizens = 25,
    [Int64]$MaxArchPerCitizenBaseUnits = 100000000,
    [Int64]$MaxCcOutstandingBaseUnits = 250000000,
    [Int64]$MaxConversionQuoteBaseUnits = 10000000,
    [string[]]$AllowedServiceClass = @("storage_standard"),
    [string]$SupportOwner,
    [string]$IncidentResponseOwner,
    [string]$RollbackPolicyId,
    [string]$EngineeringSignoffId,
    [string]$SecurityPrivacySignoffId,
    [string]$CrownMonetaryAuthoritySignoffId,
    [string[]]$PolicyEvidenceReference,
    [string[]]$IncidentEvidenceReference,
    [string[]]$BalanceEvidenceReference,
    [string[]]$ServiceDeliveryEvidenceReference,
    [string[]]$SupportEvidenceReference,
    [string]$ApprovalNotes,
    [string]$StagingReadinessReportPath = "artifacts\release\staging-readiness-report.json",
    [string]$StagingReadinessReportSha256,
    [string]$CanaryArtifactValidationReportPath = "artifacts\release\canary-artifact-validation-report.json",
    [string]$CanaryArtifactValidationReportSha256,
    [string]$ValidationOutputPath,
    [switch]$ConfirmProductionIntended,
    [switch]$ConfirmProductionLedger,
    [switch]$ConfirmAllowlistedCitizensOnly,
    [switch]$ConfirmIncidentReviewCompleted,
    [switch]$ConfirmNoUnresolvedCriticalIncidents,
    [switch]$ConfirmNoUnresolvedHighIncidents,
    [switch]$ConfirmBalancesReconciled,
    [switch]$ConfirmEscrowReconciled,
    [switch]$ConfirmBurnRefundRecreditReconciled,
    [switch]$ConfirmCrownReserveReconciled,
    [switch]$ConfirmNoNegativeBalances,
    [switch]$ConfirmNoUnapprovedIssuance,
    [switch]$ConfirmNoStagingRecordsDetected,
    [switch]$ConfirmServiceDeliveryReconciled,
    [switch]$ConfirmStorageRedemptionsReconciled,
    [switch]$ConfirmStorageProofsReconciled,
    [switch]$ConfirmBurnsMatchVerifiedEpochs,
    [switch]$ConfirmRefundsRecreditsExtensionsReconciled,
    [switch]$ConfirmSupportReady,
    [switch]$ConfirmSupportQueueReviewed,
    [switch]$ConfirmRecoverySupportReady,
    [switch]$ConfirmEscalationPathReady,
    [switch]$ConfirmSupportAccessControlsValidated,
    [switch]$ConfirmProductionMvpReleaseApproved,
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
    param([object]$Object, [string]$Name)

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
    param([string]$Name, [string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        throw "$Name is required."
    }

    if ($Value -match '<[^>]+>' -or $Value -match '^\s*set value\s*$') {
        throw "$Name contains a placeholder value."
    }
}

function Assert-Sha256 {
    param([string]$Name, [string]$Value)

    Assert-Value -Name $Name -Value $Value
    if ($Value -notmatch '^[0-9a-fA-F]{64}$') {
        throw "$Name must be a SHA-256 hex string."
    }
}

function Assert-PositiveInt {
    param([string]$Name, [Int64]$Value)

    if ($Value -le 0) {
        throw "$Name must be greater than zero."
    }
}

function Assert-Confirmation {
    param([string]$Name, [bool]$Value)

    if (-not $Value) {
        throw "$Name confirmation is required to generate a passing canary evidence packet."
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
    param([string]$Path, [object]$Value)

    if ((Test-Path -LiteralPath $Path -PathType Leaf) -and -not $Force) {
        throw "Refusing to overwrite existing canary evidence file without -Force: $Path"
    }

    $parent = Split-Path -Parent $Path
    if ($parent) {
        New-Item -ItemType Directory -Force -Path $parent | Out-Null
    }

    $Value | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $Path -Encoding UTF8
}

$resolvedPacketRoot = Resolve-RepoPath -Path $PacketRoot
New-Item -ItemType Directory -Force -Path $resolvedPacketRoot | Out-Null

$existingPolicy = Read-JsonFile -Path (Join-Path $resolvedPacketRoot "canary-policy.json")
$existingIncident = Read-JsonFile -Path (Join-Path $resolvedPacketRoot "canary-incident-review.json")
$existingBalance = Read-JsonFile -Path (Join-Path $resolvedPacketRoot "canary-balance-reconciliation.json")
$existingService = Read-JsonFile -Path (Join-Path $resolvedPacketRoot "canary-service-delivery-reconciliation.json")
$existingSupport = Read-JsonFile -Path (Join-Path $resolvedPacketRoot "canary-support-readiness.json")
$existingApproval = Read-JsonFile -Path (Join-Path $resolvedPacketRoot "canary-production-approval-record.json")

if ([string]::IsNullOrWhiteSpace($PolicyId)) { $PolicyId = Read-ObjectString -Object $existingPolicy -Name "policy_id" }
if ([string]::IsNullOrWhiteSpace($IncidentReviewId)) { $IncidentReviewId = Read-ObjectString -Object $existingIncident -Name "incident_review_id" }
if ([string]::IsNullOrWhiteSpace($BalanceReconciliationId)) { $BalanceReconciliationId = Read-ObjectString -Object $existingBalance -Name "balance_reconciliation_id" }
if ([string]::IsNullOrWhiteSpace($ServiceDeliveryReconciliationId)) { $ServiceDeliveryReconciliationId = Read-ObjectString -Object $existingService -Name "service_delivery_reconciliation_id" }
if ([string]::IsNullOrWhiteSpace($SupportReadinessId)) { $SupportReadinessId = Read-ObjectString -Object $existingSupport -Name "support_readiness_id" }
if ([string]::IsNullOrWhiteSpace($ProductionApprovalId)) { $ProductionApprovalId = Read-ObjectString -Object $existingApproval -Name "production_approval_id" }

foreach ($entry in ([ordered]@{
    PolicyId = $PolicyId
    IncidentReviewId = $IncidentReviewId
    BalanceReconciliationId = $BalanceReconciliationId
    ServiceDeliveryReconciliationId = $ServiceDeliveryReconciliationId
    SupportReadinessId = $SupportReadinessId
    ProductionApprovalId = $ProductionApprovalId
    ProductionLedgerNamespace = $ProductionLedgerNamespace
    SupportOwner = $SupportOwner
    IncidentResponseOwner = $IncidentResponseOwner
    RollbackPolicyId = $RollbackPolicyId
    EngineeringSignoffId = $EngineeringSignoffId
    SecurityPrivacySignoffId = $SecurityPrivacySignoffId
    CrownMonetaryAuthoritySignoffId = $CrownMonetaryAuthoritySignoffId
    ApprovalNotes = $ApprovalNotes
}).GetEnumerator()) {
    Assert-Value -Name $entry.Key -Value ([string]$entry.Value)
}

Assert-PositiveInt -Name "MaxCitizens" -Value $MaxCitizens
Assert-PositiveInt -Name "MaxArchPerCitizenBaseUnits" -Value $MaxArchPerCitizenBaseUnits
Assert-PositiveInt -Name "MaxCcOutstandingBaseUnits" -Value $MaxCcOutstandingBaseUnits
Assert-PositiveInt -Name "MaxConversionQuoteBaseUnits" -Value $MaxConversionQuoteBaseUnits

$normalizedAllowedServiceClasses = Assert-StringArray -Name "AllowedServiceClass" -Value $AllowedServiceClass -MinimumCount 1
$normalizedPolicyEvidence = Assert-StringArray -Name "PolicyEvidenceReference" -Value $PolicyEvidenceReference -MinimumCount 1
$normalizedIncidentEvidence = Assert-StringArray -Name "IncidentEvidenceReference" -Value $IncidentEvidenceReference -MinimumCount 1
$normalizedBalanceEvidence = Assert-StringArray -Name "BalanceEvidenceReference" -Value $BalanceEvidenceReference -MinimumCount 1
$normalizedServiceEvidence = Assert-StringArray -Name "ServiceDeliveryEvidenceReference" -Value $ServiceDeliveryEvidenceReference -MinimumCount 1
$normalizedSupportEvidence = Assert-StringArray -Name "SupportEvidenceReference" -Value $SupportEvidenceReference -MinimumCount 1

Assert-Confirmation -Name "ConfirmProductionIntended" -Value ([bool]$ConfirmProductionIntended)
Assert-Confirmation -Name "ConfirmProductionLedger" -Value ([bool]$ConfirmProductionLedger)
Assert-Confirmation -Name "ConfirmAllowlistedCitizensOnly" -Value ([bool]$ConfirmAllowlistedCitizensOnly)
Assert-Confirmation -Name "ConfirmIncidentReviewCompleted" -Value ([bool]$ConfirmIncidentReviewCompleted)
Assert-Confirmation -Name "ConfirmNoUnresolvedCriticalIncidents" -Value ([bool]$ConfirmNoUnresolvedCriticalIncidents)
Assert-Confirmation -Name "ConfirmNoUnresolvedHighIncidents" -Value ([bool]$ConfirmNoUnresolvedHighIncidents)
Assert-Confirmation -Name "ConfirmBalancesReconciled" -Value ([bool]$ConfirmBalancesReconciled)
Assert-Confirmation -Name "ConfirmEscrowReconciled" -Value ([bool]$ConfirmEscrowReconciled)
Assert-Confirmation -Name "ConfirmBurnRefundRecreditReconciled" -Value ([bool]$ConfirmBurnRefundRecreditReconciled)
Assert-Confirmation -Name "ConfirmCrownReserveReconciled" -Value ([bool]$ConfirmCrownReserveReconciled)
Assert-Confirmation -Name "ConfirmNoNegativeBalances" -Value ([bool]$ConfirmNoNegativeBalances)
Assert-Confirmation -Name "ConfirmNoUnapprovedIssuance" -Value ([bool]$ConfirmNoUnapprovedIssuance)
Assert-Confirmation -Name "ConfirmNoStagingRecordsDetected" -Value ([bool]$ConfirmNoStagingRecordsDetected)
Assert-Confirmation -Name "ConfirmServiceDeliveryReconciled" -Value ([bool]$ConfirmServiceDeliveryReconciled)
Assert-Confirmation -Name "ConfirmStorageRedemptionsReconciled" -Value ([bool]$ConfirmStorageRedemptionsReconciled)
Assert-Confirmation -Name "ConfirmStorageProofsReconciled" -Value ([bool]$ConfirmStorageProofsReconciled)
Assert-Confirmation -Name "ConfirmBurnsMatchVerifiedEpochs" -Value ([bool]$ConfirmBurnsMatchVerifiedEpochs)
Assert-Confirmation -Name "ConfirmRefundsRecreditsExtensionsReconciled" -Value ([bool]$ConfirmRefundsRecreditsExtensionsReconciled)
Assert-Confirmation -Name "ConfirmSupportReady" -Value ([bool]$ConfirmSupportReady)
Assert-Confirmation -Name "ConfirmSupportQueueReviewed" -Value ([bool]$ConfirmSupportQueueReviewed)
Assert-Confirmation -Name "ConfirmRecoverySupportReady" -Value ([bool]$ConfirmRecoverySupportReady)
Assert-Confirmation -Name "ConfirmEscalationPathReady" -Value ([bool]$ConfirmEscalationPathReady)
Assert-Confirmation -Name "ConfirmSupportAccessControlsValidated" -Value ([bool]$ConfirmSupportAccessControlsValidated)
Assert-Confirmation -Name "ConfirmProductionMvpReleaseApproved" -Value ([bool]$ConfirmProductionMvpReleaseApproved)

$resolvedStagingReadinessReportPath = Resolve-RepoPath -Path $StagingReadinessReportPath
if ([string]::IsNullOrWhiteSpace($StagingReadinessReportSha256)) {
    $StagingReadinessReportSha256 = Get-Sha256Hex -Path $resolvedStagingReadinessReportPath
}
Assert-Sha256 -Name "StagingReadinessReportSha256" -Value $StagingReadinessReportSha256

$resolvedCanaryArtifactValidationReportPath = Resolve-RepoPath -Path $CanaryArtifactValidationReportPath
if ([string]::IsNullOrWhiteSpace($CanaryArtifactValidationReportSha256)) {
    $CanaryArtifactValidationReportSha256 = Get-Sha256Hex -Path $resolvedCanaryArtifactValidationReportPath
}
Assert-Sha256 -Name "CanaryArtifactValidationReportSha256" -Value $CanaryArtifactValidationReportSha256

$createdUtc = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")

$policy = [pscustomobject][ordered]@{
    schema = "archrealms.passport.canary_policy.v1"
    created_utc = $createdUtc
    lane = "canary-mvp"
    policy_id = $PolicyId
    production_intended = $true
    production_ledger = $true
    allowlisted_citizens_only = $true
    production_ledger_namespace = $ProductionLedgerNamespace
    max_citizens = $MaxCitizens
    max_arch_per_citizen_base_units = $MaxArchPerCitizenBaseUnits
    max_cc_outstanding_base_units = $MaxCcOutstandingBaseUnits
    max_conversion_quote_base_units = $MaxConversionQuoteBaseUnits
    allowed_service_classes = @($normalizedAllowedServiceClasses)
    external_wallet_transfers_enabled = $false
    fiat_rails_enabled = $false
    unrestricted_cc_payments_enabled = $false
    guaranteed_conversion_claims_enabled = $false
    stable_value_claims_enabled = $false
    yield_or_staking_enabled = $false
    token_governance_enabled = $false
    support_owner = $SupportOwner
    incident_response_owner = $IncidentResponseOwner
    rollback_policy_id = $RollbackPolicyId
    evidence_refs = @($normalizedPolicyEvidence)
}

$incident = [pscustomobject][ordered]@{
    schema = "archrealms.passport.canary_incident_review.v1"
    created_utc = $createdUtc
    lane = "canary-mvp"
    incident_review_id = $IncidentReviewId
    completed = $true
    incident_review_completed = $true
    no_unresolved_critical_incidents = $true
    no_unresolved_high_incidents = $true
    incident_response_owner = $IncidentResponseOwner
    incident_count = 0
    unresolved_critical_incident_count = 0
    unresolved_high_incident_count = 0
    evidence_refs = @($normalizedIncidentEvidence)
}

$balance = [pscustomobject][ordered]@{
    schema = "archrealms.passport.canary_balance_reconciliation.v1"
    created_utc = $createdUtc
    lane = "canary-mvp"
    balance_reconciliation_id = $BalanceReconciliationId
    completed = $true
    production_ledger_namespace = $ProductionLedgerNamespace
    arch_balances_reconciled = $true
    cc_balances_reconciled = $true
    escrow_reconciled = $true
    burn_refund_recredit_reconciled = $true
    crown_reserve_reconciled = $true
    no_negative_balances = $true
    no_unapproved_issuance = $true
    no_staging_records_detected = $true
    evidence_refs = @($normalizedBalanceEvidence)
}

$service = [pscustomobject][ordered]@{
    schema = "archrealms.passport.canary_service_delivery_reconciliation.v1"
    created_utc = $createdUtc
    lane = "canary-mvp"
    service_delivery_reconciliation_id = $ServiceDeliveryReconciliationId
    completed = $true
    service_delivery_reconciled = $true
    storage_redemptions_reconciled = $true
    storage_proofs_reconciled = $true
    burns_match_verified_epochs = $true
    refunds_recredits_extensions_reconciled = $true
    unresolved_failed_epoch_count = 0
    evidence_refs = @($normalizedServiceEvidence)
}

$support = [pscustomobject][ordered]@{
    schema = "archrealms.passport.canary_support_readiness.v1"
    created_utc = $createdUtc
    lane = "canary-mvp"
    support_readiness_id = $SupportReadinessId
    completed = $true
    support_ready = $true
    support_queue_reviewed = $true
    recovery_support_ready = $true
    escalation_path_ready = $true
    support_access_controls_validated = $true
    support_owner = $SupportOwner
    incident_response_owner = $IncidentResponseOwner
    evidence_refs = @($normalizedSupportEvidence)
}

$files = [ordered]@{
    "canary-policy.json" = $policy
    "canary-incident-review.json" = $incident
    "canary-balance-reconciliation.json" = $balance
    "canary-service-delivery-reconciliation.json" = $service
    "canary-support-readiness.json" = $support
}

$fileRecords = @()
foreach ($entry in $files.GetEnumerator()) {
    $path = Join-Path $resolvedPacketRoot $entry.Key
    Write-JsonFile -Path $path -Value $entry.Value
    $fileRecords += [pscustomobject][ordered]@{
        id = [System.IO.Path]::GetFileNameWithoutExtension($path)
        path = $path
        sha256 = Get-Sha256Hex -Path $path
    }
}

$hashById = @{}
foreach ($record in $fileRecords) {
    $hashById[$record.id] = $record.sha256
}

$approval = [pscustomobject][ordered]@{
    schema = "archrealms.passport.canary_production_approval.v1"
    created_utc = $createdUtc
    lane = "canary-mvp"
    production_approval_id = $ProductionApprovalId
    approve_production_mvp_release = $true
    product_approval_id = $ProductionApprovalId
    engineering_signoff_id = $EngineeringSignoffId
    security_privacy_signoff_id = $SecurityPrivacySignoffId
    crown_monetary_authority_signoff_id = $CrownMonetaryAuthoritySignoffId
    staging_readiness_report_sha256 = $StagingReadinessReportSha256.ToLowerInvariant()
    canary_artifact_validation_report_sha256 = $CanaryArtifactValidationReportSha256.ToLowerInvariant()
    canary_policy_report_sha256 = $hashById["canary-policy"]
    canary_incident_review_report_sha256 = $hashById["canary-incident-review"]
    canary_balance_reconciliation_report_sha256 = $hashById["canary-balance-reconciliation"]
    canary_service_delivery_reconciliation_report_sha256 = $hashById["canary-service-delivery-reconciliation"]
    canary_support_readiness_report_sha256 = $hashById["canary-support-readiness"]
    approval_notes = $ApprovalNotes
}

$approvalPath = Join-Path $resolvedPacketRoot "canary-production-approval-record.json"
Write-JsonFile -Path $approvalPath -Value $approval
$fileRecords += [pscustomobject][ordered]@{
    id = [System.IO.Path]::GetFileNameWithoutExtension($approvalPath)
    path = $approvalPath
    sha256 = Get-Sha256Hex -Path $approvalPath
}

if ([string]::IsNullOrWhiteSpace($ValidationOutputPath)) {
    $ValidationOutputPath = Join-Path (Split-Path -Parent $resolvedPacketRoot) "canary-mvp-readiness-evidence-final-validation-report.json"
}

$resolvedValidationOutputPath = Resolve-RepoPath -Path $ValidationOutputPath
$validatorPath = Join-Path $scriptRoot "Test-PassportCanaryMvpReadinessEvidencePacket.ps1"
$validationOutput = & powershell -NoProfile -ExecutionPolicy Bypass -File $validatorPath -PacketRoot $resolvedPacketRoot -RequireNoPlaceholders -OutputPath $resolvedValidationOutputPath 2>&1
if ($LASTEXITCODE -ne 0) {
    throw "Filled canary MVP readiness evidence packet validation failed: $($validationOutput -join [Environment]::NewLine)"
}

$validationReport = Read-JsonFile -Path $resolvedValidationOutputPath
if ($null -eq $validationReport -or -not [bool]$validationReport.passed) {
    throw "Filled canary MVP readiness evidence packet validation did not pass: $resolvedValidationOutputPath"
}

[pscustomobject][ordered]@{
    schema = "archrealms.passport.canary_mvp_readiness_evidence_fill_result.v1"
    packet_root = $resolvedPacketRoot
    validation_report_path = $resolvedValidationOutputPath
    validation_report_sha256 = Get-Sha256Hex -Path $resolvedValidationOutputPath
    source_reports = @(
        [pscustomobject][ordered]@{ id = "staging_readiness"; path = $resolvedStagingReadinessReportPath; sha256 = $StagingReadinessReportSha256.ToLowerInvariant() }
        [pscustomobject][ordered]@{ id = "canary_artifact_validation"; path = $resolvedCanaryArtifactValidationReportPath; sha256 = $CanaryArtifactValidationReportSha256.ToLowerInvariant() }
    )
    evidence_files = $fileRecords
    next_step = "Run Complete-PassportCanaryMvpReadinessEvidencePacket.ps1 against the filled packet root to generate the canary readiness report and downstream report hashes."
} | ConvertTo-Json -Depth 10
