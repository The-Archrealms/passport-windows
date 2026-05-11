param(
    [string]$WorkspaceRoot,
    [string]$HandoffPath,
    [string]$OutputRoot,
    [string]$ChainId,
    [string]$SettlementContract,
    [string]$SettlementMethod,
    [string]$AssetOrCreditId,
    [int]$FinalityConfirmationsRequired = 1,
    [int]$FinalityConfirmationsObserved = 1
)

$ErrorActionPreference = "Stop"

function Get-Sha256 {
    param([string]$Path)

    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $stream = [System.IO.File]::OpenRead($Path)
        try {
            $hash = $sha.ComputeHash($stream)
            return -join ($hash | ForEach-Object { $_.ToString("x2") })
        }
        finally {
            $stream.Dispose()
        }
    }
    finally {
        $sha.Dispose()
    }
}

function Get-Sha256Text {
    param([string]$Value)

    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Value)
        $hash = $sha.ComputeHash($bytes)
        return -join ($hash | ForEach-Object { $_.ToString("x2") })
    }
    finally {
        $sha.Dispose()
    }
}

function Get-WorkspaceRelativePath {
    param(
        [string]$WorkspaceRoot,
        [string]$Path
    )

    $root = [System.IO.Path]::GetFullPath($WorkspaceRoot).TrimEnd('\', '/')
    $full = [System.IO.Path]::GetFullPath($Path)
    if ($full.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $full.Substring($root.Length).TrimStart('\', '/').Replace('\', '/')
    }

    return $full.Replace('\', '/')
}

if (-not $WorkspaceRoot) { throw "WorkspaceRoot is required." }
if (-not $HandoffPath) { throw "HandoffPath is required." }

$resolvedWorkspaceRoot = (Resolve-Path -LiteralPath $WorkspaceRoot).Path
$resolvedHandoffPath = (Resolve-Path -LiteralPath $HandoffPath).Path
$handoff = Get-Content -LiteralPath $resolvedHandoffPath -Raw | ConvertFrom-Json

if ($handoff.record_type -ne "passport_metering_settlement_handoff_record") {
    throw "HandoffPath does not reference a passport_metering_settlement_handoff_record."
}

if ($handoff.settlement_status -ne "not_settled") {
    throw "Handoff record is already marked with a settlement status other than not_settled."
}

if (-not $ChainId) { $ChainId = "mock-chain-local" }
if (-not $SettlementContract) { $SettlementContract = "mock-passport-settlement-v0" }
if (-not $SettlementMethod) { $SettlementMethod = "mock_finality_commitment" }
if (-not $AssetOrCreditId) { $AssetOrCreditId = "mock-service-credit" }

if (-not $OutputRoot) {
    $OutputRoot = Join-Path $resolvedWorkspaceRoot "records\passport\settlement\mock-chain"
}

$resolvedOutputRoot = [System.IO.Path]::GetFullPath($OutputRoot)
New-Item -ItemType Directory -Force $resolvedOutputRoot | Out-Null

$createdUtc = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
$timestamp = [DateTime]::UtcNow.ToString("yyyyMMddTHHmmssZ")
$settlementBatchId = $timestamp + "-" + $handoff.package_id + "-mock-settlement"
$settlementEpochId = "mock-epoch-" + $timestamp
$evidenceRootSha256 = Get-Sha256 -Path $resolvedHandoffPath
$txHash = "mocktx-" + (Get-Sha256Text ($settlementBatchId + "|" + $evidenceRootSha256)).Substring(0, 48)
$finalityStatus = if ($FinalityConfirmationsObserved -ge $FinalityConfirmationsRequired) { "final" } else { "included" }
$settlementStatus = if ($finalityStatus -eq "final") { "final" } else { "not_final" }
$finalMetering = $handoff.final_metering
$meteringUnits = [int64]$finalMetering.verified_replicated_byte_seconds

$participantOutput = [pscustomobject]@{
    archrealms_identity_id = $handoff.archrealms_identity_id
    node_id = ""
    settlement_role = "operator"
    service_class = "stewarded_archive_storage"
    metering_units = $meteringUnits
    settlement_units = $meteringUnits
    asset_or_credit_id = $AssetOrCreditId
    destination_account = $handoff.archrealms_identity_id
    settlement_status = $settlementStatus
}

$batchRecord = [pscustomobject]@{
    schema_version = 1
    record_type = "blockchain_settlement_batch_record"
    record_id = $settlementBatchId
    created_utc = $createdUtc
    effective_utc = $createdUtc
    status = $finalityStatus
    settlement_batch_id = $settlementBatchId
    settlement_epoch_id = $settlementEpochId
    policy_version = "blockchain-settlement-interface-2026-04-30"
    registrar_id = $handoff.registrar_id
    target_settlement_layer = [pscustomobject]@{
        settlement_rail = "blockchain"
        chain_id = $ChainId
        settlement_contract = $SettlementContract
        settlement_method = $SettlementMethod
        finality_rule = "mock_confirmations_ge_required"
    }
    source_handoff_record_ids = @($handoff.record_id)
    source_handoff_record_paths = @((Get-WorkspaceRelativePath -WorkspaceRoot $resolvedWorkspaceRoot -Path $resolvedHandoffPath))
    evidence_root_sha256 = $evidenceRootSha256
    split_rule_id = "mock-one-to-one-metering-units"
    asset_or_credit_id = $AssetOrCreditId
    participant_outputs = @($participantOutput)
    chain_submission = [pscustomobject]@{
        settlement_tx_hash = $txHash
        settlement_block_height = 1
        settlement_finality_status = $finalityStatus
        finality_confirmations_required = $FinalityConfirmationsRequired
        finality_confirmations_observed = $FinalityConfirmationsObserved
        submitted_utc = $createdUtc
        finalized_utc = if ($finalityStatus -eq "final") { $createdUtc } else { "" }
    }
    correction_record_ids = @($handoff.correction_record_ids)
    dispute_record_ids = if ($handoff.dispute_status -eq "none_open") { @() } else { @($handoff.dispute_status) }
    summary = "Mock blockchain settlement batch for Passport read-path testing. This is simulated finality only and is not real chain settlement."
}

$batchPath = Join-Path $resolvedOutputRoot "blockchain-settlement-batch.json"
$batchRecord | ConvertTo-Json -Depth 16 | Set-Content -LiteralPath $batchPath -Encoding UTF8

$statusRecord = [pscustomobject]@{
    schema_version = 1
    record_type = "blockchain_settlement_status_record"
    record_id = $timestamp + "-" + $handoff.package_id + "-mock-settlement-status"
    created_utc = $createdUtc
    effective_utc = $createdUtc
    status = "read_only"
    archrealms_identity_id = $handoff.archrealms_identity_id
    node_id = ""
    settlement_batch_id = $settlementBatchId
    settlement_epoch_id = $settlementEpochId
    source_settlement_batch_record_id = $settlementBatchId
    source_settlement_batch_record_path = (Get-WorkspaceRelativePath -WorkspaceRoot $resolvedWorkspaceRoot -Path $batchPath)
    chain_status = [pscustomobject]@{
        settlement_rail = "blockchain"
        chain_id = $ChainId
        settlement_contract = $SettlementContract
        settlement_tx_hash = $txHash
        settlement_block_height = 1
        settlement_finality_status = $finalityStatus
        finality_confirmations_required = $FinalityConfirmationsRequired
        finality_confirmations_observed = $FinalityConfirmationsObserved
    }
    participant_settlement = $participantOutput
    superseded_by_record_id = ""
    summary = "Read-only mock Passport blockchain settlement status. This displays simulated finality and does not custody assets or create wallet functionality."
}

$statusPath = Join-Path $resolvedOutputRoot "blockchain-settlement-status.json"
$statusRecord | ConvertTo-Json -Depth 16 | Set-Content -LiteralPath $statusPath -Encoding UTF8

[pscustomobject]@{
    batch_record_path = $batchPath
    status_record_path = $statusPath
    settlement_batch_id = $settlementBatchId
    settlement_finality_status = $finalityStatus
    settlement_tx_hash = $txHash
    evidence_root_sha256 = $evidenceRootSha256
    simulated_only = $true
} | ConvertTo-Json -Depth 8 -Compress
