param(
    [string]$OutputDirectory = "artifacts\release\canary-mvp-readiness-evidence",
    [string]$PolicyId = "canary-policy-001",
    [string]$IncidentReviewId = "canary-incident-review-001",
    [string]$BalanceReconciliationId = "canary-balance-reconciliation-001",
    [string]$ServiceDeliveryReconciliationId = "canary-service-delivery-reconciliation-001",
    [string]$SupportReadinessId = "canary-support-readiness-001",
    [string]$ProductionApprovalId = "canary-production-approval-001",
    [string]$ProductionLedgerNamespace = "archrealms-passport-production-mvp",
    [string]$SupportOwner = "<support-owner-or-rotation>",
    [string]$IncidentResponseOwner = "<incident-owner-or-rotation>",
    [string]$RollbackPolicyId = "<rollback-policy-id>",
    [string]$EngineeringSignoffId = "<engineering-signoff-id>",
    [string]$SecurityPrivacySignoffId = "<security-privacy-signoff-id>",
    [string]$CrownMonetaryAuthoritySignoffId = "<crown-monetary-authority-signoff-id>",
    [string]$StagingReadinessReportSha256 = "<ARCHREALMS_PASSPORT_STAGING_READINESS_REPORT_SHA256>",
    [string]$CanaryArtifactValidationReportSha256 = "<ARCHREALMS_PASSPORT_CANARY_ARTIFACT_VALIDATION_REPORT_SHA256>",
    [switch]$Force
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

function Write-JsonFile {
    param(
        [string]$Path,
        [object]$Value
    )

    if ((Test-Path -LiteralPath $Path -PathType Leaf) -and -not $Force) {
        throw "Refusing to overwrite existing canary evidence file without -Force: $Path"
    }

    $Value | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $Path -Encoding UTF8
}

$resolvedOutput = Resolve-RepoPath -Path $OutputDirectory
New-Item -ItemType Directory -Force -Path $resolvedOutput | Out-Null
$createdUtc = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")

$policy = [pscustomobject][ordered]@{
    schema = "archrealms.passport.canary_policy.v1"
    created_utc = $createdUtc
    lane = "canary-mvp"
    policy_id = $PolicyId
    production_intended = $false
    production_ledger = $false
    allowlisted_citizens_only = $false
    production_ledger_namespace = $ProductionLedgerNamespace
    max_citizens = 25
    max_arch_per_citizen_base_units = 100000000
    max_cc_outstanding_base_units = 250000000
    max_conversion_quote_base_units = 10000000
    allowed_service_classes = @("storage_standard")
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
    evidence_refs = @("<controlled-policy-document-id>")
}

$incident = [pscustomobject][ordered]@{
    schema = "archrealms.passport.canary_incident_review.v1"
    created_utc = $createdUtc
    lane = "canary-mvp"
    incident_review_id = $IncidentReviewId
    completed = $false
    incident_review_completed = $false
    no_unresolved_critical_incidents = $false
    no_unresolved_high_incidents = $false
    incident_response_owner = $IncidentResponseOwner
    incident_count = 0
    unresolved_critical_incident_count = 0
    unresolved_high_incident_count = 0
    evidence_refs = @("<incident-review-record-id>")
}

$balance = [pscustomobject][ordered]@{
    schema = "archrealms.passport.canary_balance_reconciliation.v1"
    created_utc = $createdUtc
    lane = "canary-mvp"
    balance_reconciliation_id = $BalanceReconciliationId
    completed = $false
    production_ledger_namespace = $ProductionLedgerNamespace
    arch_balances_reconciled = $false
    cc_balances_reconciled = $false
    escrow_reconciled = $false
    burn_refund_recredit_reconciled = $false
    crown_reserve_reconciled = $false
    no_negative_balances = $false
    no_unapproved_issuance = $false
    no_staging_records_detected = $false
    evidence_refs = @("<ledger-export-root-or-reconciliation-report-id>")
}

$service = [pscustomobject][ordered]@{
    schema = "archrealms.passport.canary_service_delivery_reconciliation.v1"
    created_utc = $createdUtc
    lane = "canary-mvp"
    service_delivery_reconciliation_id = $ServiceDeliveryReconciliationId
    completed = $false
    service_delivery_reconciled = $false
    storage_redemptions_reconciled = $false
    storage_proofs_reconciled = $false
    burns_match_verified_epochs = $false
    refunds_recredits_extensions_reconciled = $false
    unresolved_failed_epoch_count = 0
    evidence_refs = @("<service-delivery-reconciliation-report-id>")
}

$support = [pscustomobject][ordered]@{
    schema = "archrealms.passport.canary_support_readiness.v1"
    created_utc = $createdUtc
    lane = "canary-mvp"
    support_readiness_id = $SupportReadinessId
    completed = $false
    support_ready = $false
    support_queue_reviewed = $false
    recovery_support_ready = $false
    escalation_path_ready = $false
    support_access_controls_validated = $false
    support_owner = $SupportOwner
    incident_response_owner = $IncidentResponseOwner
    evidence_refs = @("<support-readiness-record-id>")
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
    $path = Join-Path $resolvedOutput $entry.Key
    Write-JsonFile -Path $path -Value $entry.Value
    $fileRecords += [pscustomobject][ordered]@{
        id = [System.IO.Path]::GetFileNameWithoutExtension($path)
        path = $path
        sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $path).Hash.ToLowerInvariant()
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
    approve_production_mvp_release = $false
    product_approval_id = $ProductionApprovalId
    engineering_signoff_id = $EngineeringSignoffId
    security_privacy_signoff_id = $SecurityPrivacySignoffId
    crown_monetary_authority_signoff_id = $CrownMonetaryAuthoritySignoffId
    staging_readiness_report_sha256 = $StagingReadinessReportSha256
    canary_artifact_validation_report_sha256 = $CanaryArtifactValidationReportSha256
    canary_policy_report_sha256 = $hashById["canary-policy"]
    canary_incident_review_report_sha256 = $hashById["canary-incident-review"]
    canary_balance_reconciliation_report_sha256 = $hashById["canary-balance-reconciliation"]
    canary_service_delivery_reconciliation_report_sha256 = $hashById["canary-service-delivery-reconciliation"]
    canary_support_readiness_report_sha256 = $hashById["canary-support-readiness"]
    approval_notes = "<controlled-approval-notes>"
}

$approvalPath = Join-Path $resolvedOutput "canary-production-approval-record.json"
Write-JsonFile -Path $approvalPath -Value $approval
$fileRecords += [pscustomobject][ordered]@{
    id = [System.IO.Path]::GetFileNameWithoutExtension($approvalPath)
    path = $approvalPath
    sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $approvalPath).Hash.ToLowerInvariant()
}

$readmePath = Join-Path $resolvedOutput "README.md"
if ((-not (Test-Path -LiteralPath $readmePath -PathType Leaf)) -or $Force) {
    @(
        '# Canary MVP Readiness Evidence Packet'
        ''
        'Fill these JSON files after the canary lane has real production-intended evidence.'
        ''
        'Do not mark policy, incident, balance, service delivery, support, or production approval fields complete until the supporting evidence exists.'
        'After editing any evidence file, update the matching SHA-256 fields in canary-production-approval-record.json.'
        ''
        '## Evidence Files'
        ''
        '| File | Purpose | Must prove |'
        '|---|---|---|'
        '| `canary-policy.json` | Canary operating policy. | The lane is production-intended, uses the production ledger namespace, is limited to allowlisted citizens, enforces maximum citizen/balance/quote limits, and keeps external wallet transfers, fiat rails, unrestricted CC payments, guaranteed conversion claims, stable-value claims, yield/staking, and token governance disabled. |'
        '| `canary-incident-review.json` | Incident review before production promotion. | Incident review is complete and no unresolved critical or high incidents remain. |'
        '| `canary-balance-reconciliation.json` | Token and ledger balance reconciliation. | ARCH, CC, escrow, burn/refund/re-credit, and Crown reserve balances reconcile; no negative balances, unapproved issuance, or staging records are detected. |'
        '| `canary-service-delivery-reconciliation.json` | Service delivery reconciliation. | Storage redemptions, storage proofs, verified-epoch burns, refunds, re-credits, and extensions reconcile with no unresolved failed epochs. |'
        '| `canary-support-readiness.json` | Support and escalation readiness. | Support queue review, recovery support, escalation path, and support access controls are ready for production-intended users. |'
        '| `canary-production-approval-record.json` | Approval to promote CanaryMvp to ProductionMvp. | Product, engineering, security/privacy, and Crown monetary authority approvals reference the exact staging readiness report, canary artifact validation report, canary policy, incident review, balance reconciliation, service-delivery reconciliation, and support readiness hashes. |'
        ''
        '## Required Evidence References'
        ''
        'Every canary evidence file must include controlled evidence references. Prefer references that cover these groups:'
        ''
        '- Canary allowlist, policy-limit, rollback-policy, and production-ledger namespace evidence.'
        '- Incident review, support queue, recovery support, escalation path, and access-control evidence.'
        '- Ledger export/replay, ARCH/CC balance reconciliation, escrow reconciliation, burn/refund/re-credit reconciliation, Crown reserve reconciliation, and no-staging-record evidence.'
        '- Storage redemption, storage proof, service-delivery, verified-burn, refund/re-credit/extension, and failed-epoch evidence.'
        '- Product, engineering, security/privacy, and Crown monetary authority approval records.'
        ''
        'Prefer the structured helper so hashes and required confirmations are filled consistently:'
        ''
        '```powershell'
        ('.\tools\release\Set-PassportCanaryMvpReadinessEvidencePacket.ps1 -PacketRoot "{0}" -Force' -f $resolvedOutput)
        '```'
        ''
        'Validate with:'
        ''
        '```powershell'
        ('.\tools\release\Test-PassportCanaryMvpReadinessEvidencePacket.ps1 -PacketRoot "{0}" -RequireNoPlaceholders' -f $resolvedOutput)
        '```'
        ''
        'Then load the file paths, IDs, and SHA-256 values into the canary environment before running Test-PassportCanaryMvpReadiness.ps1.'
    ) | Set-Content -LiteralPath $readmePath -Encoding UTF8
}

[pscustomobject][ordered]@{
    packet_root = $resolvedOutput
    evidence_files = $fileRecords
    next_step = "Fill the packet, validate it with Test-PassportCanaryMvpReadinessEvidencePacket.ps1 -RequireNoPlaceholders, then load paths/hashes into the canary readiness environment."
} | ConvertTo-Json -Depth 8
