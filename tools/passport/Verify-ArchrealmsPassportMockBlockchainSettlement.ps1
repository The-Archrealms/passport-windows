param(
    [string]$BatchPath,
    [string]$StatusPath,
    [string]$HandoffPath,
    [string]$OutputPath
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

if (-not $BatchPath) { throw "BatchPath is required." }
if (-not $StatusPath) { throw "StatusPath is required." }
if (-not $HandoffPath) { throw "HandoffPath is required." }

$resolvedBatchPath = (Resolve-Path -LiteralPath $BatchPath).Path
$resolvedStatusPath = (Resolve-Path -LiteralPath $StatusPath).Path
$resolvedHandoffPath = (Resolve-Path -LiteralPath $HandoffPath).Path
$batch = Get-Content -LiteralPath $resolvedBatchPath -Raw | ConvertFrom-Json
$status = Get-Content -LiteralPath $resolvedStatusPath -Raw | ConvertFrom-Json
$handoff = Get-Content -LiteralPath $resolvedHandoffPath -Raw | ConvertFrom-Json
$reasons = New-Object System.Collections.Generic.List[string]

if ($batch.record_type -ne "blockchain_settlement_batch_record") { $reasons.Add("batch_record_type_mismatch") }
if ($status.record_type -ne "blockchain_settlement_status_record") { $reasons.Add("status_record_type_mismatch") }
if ($handoff.record_type -ne "passport_metering_settlement_handoff_record") { $reasons.Add("handoff_record_type_mismatch") }
if ($batch.target_settlement_layer.settlement_rail -ne "blockchain") { $reasons.Add("batch_settlement_rail_not_blockchain") }
if ($status.chain_status.settlement_rail -ne "blockchain") { $reasons.Add("status_settlement_rail_not_blockchain") }
if ($batch.settlement_batch_id -ne $status.settlement_batch_id) { $reasons.Add("settlement_batch_id_mismatch") }
if ($batch.chain_submission.settlement_tx_hash -ne $status.chain_status.settlement_tx_hash) { $reasons.Add("settlement_tx_hash_mismatch") }
if ($batch.chain_submission.settlement_finality_status -ne $status.chain_status.settlement_finality_status) { $reasons.Add("finality_status_mismatch") }
if ($batch.chain_submission.settlement_finality_status -ne "final") { $reasons.Add("settlement_not_final") }
if (-not @($batch.source_handoff_record_ids).Contains($handoff.record_id)) { $reasons.Add("handoff_id_not_in_batch") }

$expectedEvidenceRoot = Get-Sha256 -Path $resolvedHandoffPath
if (-not $expectedEvidenceRoot.Equals([string]$batch.evidence_root_sha256, [System.StringComparison]::OrdinalIgnoreCase)) {
    $reasons.Add("evidence_root_mismatch")
}

$verified = $reasons.Count -eq 0
$report = [pscustomobject]@{
    verified_utc = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
    batch_path = $resolvedBatchPath
    status_path = $resolvedStatusPath
    handoff_path = $resolvedHandoffPath
    verified = $verified
    simulated_only = $true
    settlement_batch_id = $batch.settlement_batch_id
    settlement_finality_status = $batch.chain_submission.settlement_finality_status
    evidence_root_valid = $expectedEvidenceRoot.Equals([string]$batch.evidence_root_sha256, [System.StringComparison]::OrdinalIgnoreCase)
    reasons = $reasons
}

if (-not $OutputPath) {
    $OutputPath = Join-Path (Split-Path -Parent $resolvedBatchPath) "mock-blockchain-settlement-verification-report.json"
}

$outputDirectory = Split-Path -Parent $OutputPath
if ($outputDirectory) {
    New-Item -ItemType Directory -Force $outputDirectory | Out-Null
}

$report | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $OutputPath -Encoding UTF8
Get-Content -LiteralPath $OutputPath
