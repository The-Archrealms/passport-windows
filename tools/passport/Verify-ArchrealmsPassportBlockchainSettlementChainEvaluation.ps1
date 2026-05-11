param(
    [string]$EvaluationPath,
    [string]$OutputPath
)

$ErrorActionPreference = "Stop"

function Test-AllowedValue {
    param(
        [string]$Value,
        [string[]]$Allowed
    )

    return $Allowed.Contains($Value)
}

if (-not $EvaluationPath) { throw "EvaluationPath is required." }

$resolvedEvaluationPath = (Resolve-Path -LiteralPath $EvaluationPath).Path
$evaluation = Get-Content -LiteralPath $resolvedEvaluationPath -Raw | ConvertFrom-Json
$reasons = New-Object System.Collections.Generic.List[string]
$allowedReviewStatuses = @("not_started", "in_progress", "approved", "blocked", "not_required")
$allowedRecommendations = @("undecided", "dev_only", "conditionally_acceptable", "rejected", "approved")

if ($evaluation.record_type -ne "blockchain_settlement_chain_evaluation") { $reasons.Add("record_type_mismatch") }
if (-not $evaluation.record_id) { $reasons.Add("record_id_missing") }
if (-not $evaluation.created_utc) { $reasons.Add("created_utc_missing") }
if (-not $evaluation.candidate_chain.chain_name) { $reasons.Add("chain_name_missing") }
if (-not $evaluation.candidate_chain.chain_id) { $reasons.Add("chain_id_missing") }
if ($evaluation.candidate_chain.settlement_rail -ne "blockchain") { $reasons.Add("settlement_rail_not_blockchain") }
if (-not (Test-AllowedValue -Value ([string]$evaluation.decision.recommendation) -Allowed $allowedRecommendations)) { $reasons.Add("recommendation_invalid") }

foreach ($reviewStatus in @(
    [string]$evaluation.legal_tax_treasury_review.legal_review_status,
    [string]$evaluation.legal_tax_treasury_review.tax_review_status,
    [string]$evaluation.legal_tax_treasury_review.treasury_review_status,
    [string]$evaluation.legal_tax_treasury_review.governance_review_status
)) {
    if (-not (Test-AllowedValue -Value $reviewStatus -Allowed $allowedReviewStatuses)) {
        $reasons.Add("review_status_invalid")
    }
}

$finalityDocumented = [bool]($evaluation.finality.finality_model -and
    [int]$evaluation.finality.expected_time_to_finality_seconds -gt 0 -and
    $evaluation.finality.reorg_or_reversal_risk -and
    $evaluation.finality.finality_rule_summary)
$contractCapabilityComplete = [bool]$evaluation.contract_capability.supports_evidence_root_commitment -and
    [bool]$evaluation.contract_capability.supports_handoff_id_deduplication -and
    [bool]$evaluation.contract_capability.supports_participant_outputs -and
    [bool]$evaluation.contract_capability.supports_correction_batches -and
    [bool]$evaluation.contract_capability.supports_pause_controls -and
    [bool]$evaluation.contract_capability.supports_events_or_indexable_records
$passportReadOnlyAccessReady = [bool]$evaluation.passport_read_only_access.public_rpc_available -and
    [bool]$evaluation.passport_read_only_access.indexer_available -and
    [bool]$evaluation.passport_read_only_access.passport_can_verify_finality_without_custody
$custodyControlsReady = [bool]$evaluation.custody_and_authority.multisig_or_threshold_signing_available -and
    [bool]$evaluation.custody_and_authority.registrar_treasury_separation_supported -and
    [bool]$evaluation.custody_and_authority.key_rotation_supported -and
    [bool]$evaluation.custody_and_authority.emergency_pause_supported
$reviewApproved = $evaluation.legal_tax_treasury_review.legal_review_status -eq "approved" -and
    $evaluation.legal_tax_treasury_review.tax_review_status -eq "approved" -and
    $evaluation.legal_tax_treasury_review.treasury_review_status -eq "approved" -and
    $evaluation.legal_tax_treasury_review.governance_review_status -eq "approved"
$noKnownBlockers = @($evaluation.legal_tax_treasury_review.known_blockers).Count -eq 0
$releaseGateSatisfied = $evaluation.decision.recommendation -eq "approved" -and
    $finalityDocumented -and
    $contractCapabilityComplete -and
    $passportReadOnlyAccessReady -and
    $custodyControlsReady -and
    $reviewApproved -and
    $noKnownBlockers

if ($evaluation.release_gate_assessment) {
    if ([bool]$evaluation.release_gate_assessment.release_gate_satisfied -ne $releaseGateSatisfied) {
        $reasons.Add("release_gate_assessment_mismatch")
    }
}

if ($releaseGateSatisfied -and $evaluation.decision.reviewed_utc -eq "") {
    $reasons.Add("approved_evaluation_missing_reviewed_utc")
}

$verified = $reasons.Count -eq 0
$report = [pscustomobject]@{
    verified_utc = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
    evaluation_path = $resolvedEvaluationPath
    record_id = $evaluation.record_id
    chain_id = $evaluation.candidate_chain.chain_id
    recommendation = $evaluation.decision.recommendation
    verified = $verified
    release_gate_satisfied = $releaseGateSatisfied
    gate_checks = [pscustomobject]@{
        finality_documented = $finalityDocumented
        contract_capability_complete = $contractCapabilityComplete
        passport_read_only_access_ready = $passportReadOnlyAccessReady
        custody_controls_ready = $custodyControlsReady
        legal_tax_treasury_governance_approved = $reviewApproved
        no_known_blockers = $noKnownBlockers
    }
    reasons = @($reasons)
}

if (-not $OutputPath) {
    $OutputPath = Join-Path (Split-Path -Parent $resolvedEvaluationPath) "blockchain-settlement-chain-evaluation-verification-report.json"
}

$outputDirectory = Split-Path -Parent $OutputPath
if ($outputDirectory) {
    New-Item -ItemType Directory -Force $outputDirectory | Out-Null
}

$report | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $OutputPath -Encoding UTF8
Get-Content -LiteralPath $OutputPath
