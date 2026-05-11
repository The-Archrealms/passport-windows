param(
    [string]$WorkspaceRoot,
    [string]$OutputRoot,
    [string]$ChainName,
    [string]$ChainId,
    [string]$NetworkType,
    [string]$NativeAsset,
    [string]$CandidateSettlementAssetOrCredit,
    [string]$FinalityModel,
    [int]$ConfirmationsRequired = 0,
    [int]$ExpectedTimeToFinalitySeconds = 0,
    [string]$ReorgOrReversalRisk,
    [string]$FinalityRuleSummary,
    [string]$AverageBatchTransactionCostEstimate,
    [string]$CostVolatilityRisk,
    [string]$ExpectedEpochBatchCapacity,
    [string]$ThroughputNotes,
    [int]$SupportsEvidenceRootCommitment = 0,
    [int]$SupportsHandoffIdDeduplication = 0,
    [int]$SupportsParticipantOutputs = 0,
    [int]$SupportsCorrectionBatches = 0,
    [int]$SupportsPauseControls = 0,
    [int]$SupportsEventsOrIndexableRecords = 0,
    [string]$UpgradeabilityModel,
    [int]$PublicRpcAvailable = 0,
    [int]$IndexerAvailable = 0,
    [int]$PassportCanVerifyFinalityWithoutCustody = 0,
    [string]$ReadPathNotes,
    [int]$MultisigOrThresholdSigningAvailable = 0,
    [int]$RegistrarTreasurySeparationSupported = 0,
    [int]$KeyRotationSupported = 0,
    [int]$EmergencyPauseSupported = 0,
    [string]$CustodyNotes,
    [string]$LegalReviewStatus = "not_started",
    [string]$TaxReviewStatus = "not_started",
    [string]$TreasuryReviewStatus = "not_started",
    [string]$GovernanceReviewStatus = "not_started",
    [string]$KnownBlockersCsv,
    [string]$RpcProviderRisk,
    [string]$IndexerProviderRisk,
    [string]$BridgeOrDependencyRisk,
    [int]$MigrationPlanRequired = 1,
    [string]$ContinuityNotes,
    [string]$Recommendation = "undecided",
    [string]$RequiredConditionsCsv,
    [string]$RejectionReasonsCsv,
    [string]$Reviewer,
    [string]$Summary
)

$ErrorActionPreference = "Stop"

function Convert-CsvList {
    param([string]$Value)

    if (-not $Value) {
        return @()
    }

    return @($Value -split "," | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

function Get-SafeIdPart {
    param([string]$Value)

    if (-not $Value) {
        return "chain"
    }

    $clean = ($Value.ToLowerInvariant() -replace "[^a-z0-9]+", "-").Trim("-")
    if (-not $clean) {
        return "chain"
    }

    return $clean
}

if (-not $WorkspaceRoot) { throw "WorkspaceRoot is required." }
if (-not $ChainName) { throw "ChainName is required." }
if (-not $ChainId) { throw "ChainId is required." }

$allowedReviewStatuses = @("not_started", "in_progress", "approved", "blocked", "not_required")
foreach ($reviewStatus in @($LegalReviewStatus, $TaxReviewStatus, $TreasuryReviewStatus, $GovernanceReviewStatus)) {
    if (-not $allowedReviewStatuses.Contains($reviewStatus)) {
        throw "Review status '$reviewStatus' is not allowed."
    }
}

$allowedRecommendations = @("undecided", "dev_only", "conditionally_acceptable", "rejected", "approved")
if (-not $allowedRecommendations.Contains($Recommendation)) {
    throw "Recommendation '$Recommendation' is not allowed."
}

if (-not $NetworkType) { $NetworkType = "mainnet_or_l2_or_appchain_or_private" }
if (-not $NativeAsset) { $NativeAsset = "" }
if (-not $CandidateSettlementAssetOrCredit) { $CandidateSettlementAssetOrCredit = "" }

$resolvedWorkspaceRoot = (Resolve-Path -LiteralPath $WorkspaceRoot).Path
$timestamp = [DateTime]::UtcNow.ToString("yyyyMMddTHHmmssZ")
$createdUtc = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
$safeChainId = Get-SafeIdPart -Value $ChainId

if (-not $OutputRoot) {
    $OutputRoot = Join-Path $resolvedWorkspaceRoot ("records\passport\settlement\chain-evaluations\" + $timestamp + "-" + $safeChainId)
}

$resolvedOutputRoot = [System.IO.Path]::GetFullPath($OutputRoot)
New-Item -ItemType Directory -Force $resolvedOutputRoot | Out-Null

$knownBlockers = Convert-CsvList -Value $KnownBlockersCsv
$requiredConditions = Convert-CsvList -Value $RequiredConditionsCsv
$rejectionReasons = Convert-CsvList -Value $RejectionReasonsCsv
$supportsEvidenceRootCommitmentValue = [bool]$SupportsEvidenceRootCommitment
$supportsHandoffIdDeduplicationValue = [bool]$SupportsHandoffIdDeduplication
$supportsParticipantOutputsValue = [bool]$SupportsParticipantOutputs
$supportsCorrectionBatchesValue = [bool]$SupportsCorrectionBatches
$supportsPauseControlsValue = [bool]$SupportsPauseControls
$supportsEventsOrIndexableRecordsValue = [bool]$SupportsEventsOrIndexableRecords
$publicRpcAvailableValue = [bool]$PublicRpcAvailable
$indexerAvailableValue = [bool]$IndexerAvailable
$passportCanVerifyFinalityWithoutCustodyValue = [bool]$PassportCanVerifyFinalityWithoutCustody
$multisigOrThresholdSigningAvailableValue = [bool]$MultisigOrThresholdSigningAvailable
$registrarTreasurySeparationSupportedValue = [bool]$RegistrarTreasurySeparationSupported
$keyRotationSupportedValue = [bool]$KeyRotationSupported
$emergencyPauseSupportedValue = [bool]$EmergencyPauseSupported
$migrationPlanRequiredValue = [bool]$MigrationPlanRequired

$finalityDocumented = [bool]($FinalityModel -and $ExpectedTimeToFinalitySeconds -gt 0 -and $ReorgOrReversalRisk -and $FinalityRuleSummary)
$contractCapabilityComplete = $supportsEvidenceRootCommitmentValue -and
    $supportsHandoffIdDeduplicationValue -and
    $supportsParticipantOutputsValue -and
    $supportsCorrectionBatchesValue -and
    $supportsPauseControlsValue -and
    $supportsEventsOrIndexableRecordsValue
$passportReadOnlyAccessReady = $publicRpcAvailableValue -and $indexerAvailableValue -and $passportCanVerifyFinalityWithoutCustodyValue
$custodyControlsReady = $multisigOrThresholdSigningAvailableValue -and
    $registrarTreasurySeparationSupportedValue -and
    $keyRotationSupportedValue -and
    $emergencyPauseSupportedValue
$reviewApproved = $LegalReviewStatus -eq "approved" -and
    $TaxReviewStatus -eq "approved" -and
    $TreasuryReviewStatus -eq "approved" -and
    $GovernanceReviewStatus -eq "approved"
$noKnownBlockers = @($knownBlockers).Count -eq 0
$releaseGateSatisfied = $Recommendation -eq "approved" -and
    $finalityDocumented -and
    $contractCapabilityComplete -and
    $passportReadOnlyAccessReady -and
    $custodyControlsReady -and
    $reviewApproved -and
    $noKnownBlockers

$recordId = $timestamp + "-" + $safeChainId + "-chain-evaluation"
$record = [pscustomobject]@{
    schema_version = 1
    record_type = "blockchain_settlement_chain_evaluation"
    record_id = $recordId
    created_utc = $createdUtc
    status = if ($Recommendation -eq "approved") { "reviewed" } elseif ($Recommendation -eq "rejected") { "reviewed" } else { "draft" }
    candidate_chain = [pscustomobject]@{
        chain_name = $ChainName
        chain_id = $ChainId
        network_type = $NetworkType
        settlement_rail = "blockchain"
        native_asset = $NativeAsset
        candidate_settlement_asset_or_credit = $CandidateSettlementAssetOrCredit
    }
    finality = [pscustomobject]@{
        finality_model = $FinalityModel
        confirmations_required = $ConfirmationsRequired
        expected_time_to_finality_seconds = $ExpectedTimeToFinalitySeconds
        reorg_or_reversal_risk = $ReorgOrReversalRisk
        finality_rule_summary = $FinalityRuleSummary
    }
    cost_and_throughput = [pscustomobject]@{
        average_batch_transaction_cost_estimate = $AverageBatchTransactionCostEstimate
        cost_volatility_risk = $CostVolatilityRisk
        expected_epoch_batch_capacity = $ExpectedEpochBatchCapacity
        throughput_notes = $ThroughputNotes
    }
    contract_capability = [pscustomobject]@{
        supports_evidence_root_commitment = $supportsEvidenceRootCommitmentValue
        supports_handoff_id_deduplication = $supportsHandoffIdDeduplicationValue
        supports_participant_outputs = $supportsParticipantOutputsValue
        supports_correction_batches = $supportsCorrectionBatchesValue
        supports_pause_controls = $supportsPauseControlsValue
        supports_events_or_indexable_records = $supportsEventsOrIndexableRecordsValue
        upgradeability_model = $UpgradeabilityModel
    }
    passport_read_only_access = [pscustomobject]@{
        public_rpc_available = $publicRpcAvailableValue
        indexer_available = $indexerAvailableValue
        passport_can_verify_finality_without_custody = $passportCanVerifyFinalityWithoutCustodyValue
        read_path_notes = $ReadPathNotes
    }
    custody_and_authority = [pscustomobject]@{
        multisig_or_threshold_signing_available = $multisigOrThresholdSigningAvailableValue
        registrar_treasury_separation_supported = $registrarTreasurySeparationSupportedValue
        key_rotation_supported = $keyRotationSupportedValue
        emergency_pause_supported = $emergencyPauseSupportedValue
        custody_notes = $CustodyNotes
    }
    legal_tax_treasury_review = [pscustomobject]@{
        legal_review_status = $LegalReviewStatus
        tax_review_status = $TaxReviewStatus
        treasury_review_status = $TreasuryReviewStatus
        governance_review_status = $GovernanceReviewStatus
        known_blockers = @($knownBlockers)
    }
    operational_risk = [pscustomobject]@{
        rpc_provider_risk = $RpcProviderRisk
        indexer_provider_risk = $IndexerProviderRisk
        bridge_or_dependency_risk = $BridgeOrDependencyRisk
        migration_plan_required = $migrationPlanRequiredValue
        continuity_notes = $ContinuityNotes
    }
    decision = [pscustomobject]@{
        recommendation = $Recommendation
        required_conditions = @($requiredConditions)
        rejection_reasons = @($rejectionReasons)
        reviewer = $Reviewer
        reviewed_utc = if ($Reviewer) { $createdUtc } else { "" }
    }
    release_gate_assessment = [pscustomobject]@{
        finality_documented = $finalityDocumented
        contract_capability_complete = $contractCapabilityComplete
        passport_read_only_access_ready = $passportReadOnlyAccessReady
        custody_controls_ready = $custodyControlsReady
        legal_tax_treasury_governance_approved = $reviewApproved
        no_known_blockers = $noKnownBlockers
        release_gate_satisfied = $releaseGateSatisfied
    }
    summary = if ($Summary) { $Summary } else { "Passport blockchain settlement chain evaluation. This record does not select a chain unless release_gate_satisfied is true and governance approval is recorded." }
}

$evaluationPath = Join-Path $resolvedOutputRoot "blockchain-settlement-chain-evaluation.json"
$record | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $evaluationPath -Encoding UTF8

[pscustomobject]@{
    evaluation_path = $evaluationPath
    record_id = $recordId
    chain_id = $ChainId
    recommendation = $Recommendation
    release_gate_satisfied = $releaseGateSatisfied
} | ConvertTo-Json -Depth 8 -Compress
