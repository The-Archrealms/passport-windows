param(
    [string]$OutputDirectory = "artifacts\release\staging-readiness-evidence",
    [string]$OperationalDrillId = "staging-operational-drill-001",
    [string]$RollbackDrillId = "staging-rollback-drill-001",
    [string]$PromotionApprovalId = "staging-promotion-approval-001",
    [string]$EngineeringSignoffId = "<engineering-signoff-id>",
    [string]$SecurityPrivacySignoffId = "<security-privacy-signoff-id>",
    [string]$CrownMonetaryAuthoritySignoffId = "<crown-monetary-authority-signoff-id>",
    [string]$ApiBaseUrl = "<PASSPORT_WINDOWS_STAGING_API_BASE_URL>",
    [string]$AiGatewayUrl = "<PASSPORT_WINDOWS_STAGING_AI_GATEWAY_URL>",
    [string]$LedgerNamespace = "archrealms-passport-staging",
    [string]$TelemetryDestination = "<ARCHREALMS_PASSPORT_STAGING_TELEMETRY_DESTINATION>",
    [string]$PackageVersion = "<staging package version or artifact hash>",
    [string]$PolicyVersion = "passport-token-ready-mvp-v1",
    [string]$Operator = "<staging drill operator>",
    [string]$IncidentResponseOwner = "<staging incident response owner>",
    [string]$PreMvpReportSha256 = "<ARCHREALMS_PASSPORT_PRE_MVP_VERIFICATION_REPORT_SHA256>",
    [string]$StagingArtifactValidationReportSha256 = "<ARCHREALMS_PASSPORT_STAGING_ARTIFACT_VALIDATION_REPORT_SHA256>",
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
        throw "Refusing to overwrite existing staging evidence file without -Force: $Path"
    }

    $Value | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $Path -Encoding UTF8
}

$resolvedOutput = Resolve-RepoPath -Path $OutputDirectory
New-Item -ItemType Directory -Force -Path $resolvedOutput | Out-Null
$createdUtc = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")

$operational = [pscustomobject][ordered]@{
    schema = "archrealms.passport.staging_operational_drill.v1"
    created_utc = $createdUtc
    lane = "staging"
    operational_drill_id = $OperationalDrillId
    completed = $false
    package_version = $PackageVersion
    policy_version = $PolicyVersion
    api_base_url = $ApiBaseUrl
    ai_gateway_url = $AiGatewayUrl
    ledger_namespace = $LedgerNamespace
    telemetry_destination = $TelemetryDestination
    operator = $Operator
    incident_response_owner = $IncidentResponseOwner
    evidence_references = @(
        "<upgrade validation evidence ID or URI>",
        "<endpoint failover evidence ID or URI>",
        "<ledger export replay evidence ID or URI>"
    )
    production_candidate_upgrade_validated = $false
    endpoint_failover_validated = $false
    signing_verification_validated = $false
    ledger_export_replay_validated = $false
    recovery_revocation_validated = $false
    storage_proof_validation_completed = $false
    storage_redemption_dry_run_completed = $false
    conversion_disclosure_dry_run_completed = $false
    telemetry_privacy_validated = $false
    incident_response_validated = $false
    support_access_controls_validated = $false
    ai_gateway_auth_privacy_validated = $false
    prohibited_claims_blocked = $false
}

$rollback = [pscustomobject][ordered]@{
    schema = "archrealms.passport.staging_rollback_drill.v1"
    created_utc = $createdUtc
    lane = "staging"
    rollback_drill_id = $RollbackDrillId
    completed = $false
    package_version = $PackageVersion
    policy_version = $PolicyVersion
    reason_code = "<rollback drill reason code>"
    approvers = @("<engineering approver>", "<security/privacy approver>")
    affected_service_classes = @("identity", "wallet", "storage", "ai", "ledger-export")
    affected_assets = @("ARCH", "CC")
    user_facing_status = "<user-facing status displayed during rollback drill>"
    new_operations_disabled_or_routed = $false
    ledger_events_preserved = $false
    no_deletion_mutation_or_backdating = $false
    pending_escrow_resolved_by_policy = $false
    export_access_preserved = $false
    production_records_untouched = $false
}

$operationalPath = Join-Path $resolvedOutput "staging-operational-drill-report.json"
$rollbackPath = Join-Path $resolvedOutput "staging-rollback-drill-report.json"
Write-JsonFile -Path $operationalPath -Value $operational
Write-JsonFile -Path $rollbackPath -Value $rollback

$operationalHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $operationalPath).Hash.ToLowerInvariant()
$rollbackHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $rollbackPath).Hash.ToLowerInvariant()

$promotion = [pscustomobject][ordered]@{
    schema = "archrealms.passport.staging_promotion_approval.v1"
    created_utc = $createdUtc
    lane = "staging"
    promotion_approval_id = $PromotionApprovalId
    engineering_signoff_id = $EngineeringSignoffId
    security_privacy_signoff_id = $SecurityPrivacySignoffId
    crown_monetary_authority_signoff_id = $CrownMonetaryAuthoritySignoffId
    rollback_drill_id = $RollbackDrillId
    pre_mvp_report_sha256 = $PreMvpReportSha256
    staging_artifact_validation_report_sha256 = $StagingArtifactValidationReportSha256
    operational_drill_report_sha256 = $operationalHash
    rollback_drill_report_sha256 = $rollbackHash
    approve_canary_or_production_release = $false
    product_approval_signed = $false
    engineering_signoff_signed = $false
    security_privacy_signoff_signed = $false
    crown_monetary_authority_signoff_signed = $false
}

$promotionPath = Join-Path $resolvedOutput "staging-promotion-approval-record.json"
Write-JsonFile -Path $promotionPath -Value $promotion

$files = @($operationalPath, $rollbackPath, $promotionPath) | ForEach-Object {
    [pscustomobject][ordered]@{
        id = [System.IO.Path]::GetFileNameWithoutExtension($_)
        path = $_
        sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $_).Hash.ToLowerInvariant()
    }
}

$readmePath = Join-Path $resolvedOutput "README.md"
if ((-not (Test-Path -LiteralPath $readmePath -PathType Leaf)) -or $Force) {
    @(
        '# Staging Readiness Evidence Packet'
        ''
        'Fill the three JSON files in this folder after the staging operational and rollback drills are complete.'
        ''
        'Prefer the structured helper so hashes and required confirmations are filled consistently:'
        ''
        '```powershell'
        ('.\tools\release\Set-PassportStagingReadinessEvidencePacket.ps1 -PacketRoot "{0}" -Force' -f $resolvedOutput)
        '```'
        ''
        'Validate with:'
        ''
        '```powershell'
        ('.\tools\release\Test-PassportStagingReadinessEvidencePacket.ps1 -PacketRoot "{0}" -RequireNoPlaceholders' -f $resolvedOutput)
        '```'
        ''
        'Then load the report paths and SHA-256 values into the staging environment before running Test-PassportStagingReadiness.ps1.'
    ) | Set-Content -LiteralPath $readmePath -Encoding UTF8
}

[pscustomobject][ordered]@{
    packet_root = $resolvedOutput
    evidence_files = $files
    next_step = "Fill the packet, validate it with Test-PassportStagingReadinessEvidencePacket.ps1 -RequireNoPlaceholders, then load paths/hashes into the staging readiness environment."
} | ConvertTo-Json -Depth 8
