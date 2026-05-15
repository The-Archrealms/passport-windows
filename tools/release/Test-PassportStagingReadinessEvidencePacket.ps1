param(
    [string]$PacketRoot = "deploy\staging-readiness",
    [string]$OutputPath = "artifacts\release\staging-readiness-evidence-validation-report.json",
    [switch]$RequireNoPlaceholders,
    [switch]$NoFail
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

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
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

function Read-ObjectBool {
    param([object]$Object, [string]$Name)

    if ($null -eq $Object -or -not $Object.PSObject.Properties[$Name]) {
        return $false
    }

    return [bool]$Object.$Name
}

function Test-NotPlaceholder {
    param([string]$Name, [string]$Value, [bool]$Required = $true)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        if ($Required) {
            return "$Name is required"
        }

        return ""
    }

    if ($RequireNoPlaceholders -and ($Value -match '<[^>]+>' -or $Value -match '^\s*set value\s*$')) {
        return "$Name contains a placeholder value"
    }

    return ""
}

function Test-Sha256 {
    param([string]$Name, [string]$Value)

    $failure = Test-NotPlaceholder -Name $Name -Value $Value
    if ($failure) {
        return $failure
    }

    if ($Value -notmatch '^[0-9a-fA-F]{64}$') {
        if ($RequireNoPlaceholders -or $Value -notmatch '<[^>]+>') {
            return "$Name must be a SHA-256 hex string"
        }
    }

    return ""
}

function Test-RequiredTrue {
    param([object]$Object, [string]$Name, [string]$Description)

    if ($RequireNoPlaceholders -and -not (Read-ObjectBool -Object $Object -Name $Name)) {
        return "$Description must be true"
    }

    if ($null -eq $Object -or -not $Object.PSObject.Properties[$Name]) {
        return "$Description field is required"
    }

    return ""
}

function Find-EvidenceFile {
    param([string]$Root, [string]$BaseName)

    $candidate = Join-Path $Root "$BaseName.json"
    if (Test-Path -LiteralPath $candidate -PathType Leaf) {
        return $candidate
    }

    $templateCandidate = Join-Path $Root "$BaseName.template.json"
    if (Test-Path -LiteralPath $templateCandidate -PathType Leaf) {
        return $templateCandidate
    }

    return $candidate
}

function New-Check {
    param([string]$Id, [string[]]$Failures, [object]$Evidence = $null)

    $cleanFailures = @($Failures | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    return [pscustomobject][ordered]@{
        id = $Id
        passed = ($cleanFailures.Count -eq 0)
        failures = $cleanFailures
        evidence = $Evidence
    }
}

$resolvedPacketRoot = Resolve-RepoPath -Path $PacketRoot
$resolvedOutput = Resolve-RepoPath -Path $OutputPath

$paths = [ordered]@{
    operational = Find-EvidenceFile -Root $resolvedPacketRoot -BaseName "staging-operational-drill-report"
    rollback = Find-EvidenceFile -Root $resolvedPacketRoot -BaseName "staging-rollback-drill-report"
    promotion = Find-EvidenceFile -Root $resolvedPacketRoot -BaseName "staging-promotion-approval-record"
}

$operational = Read-JsonFile -Path $paths.operational
$operationalFailures = @()
if ($null -eq $operational) {
    $operationalFailures += "missing or unreadable staging operational drill report: $($paths.operational)"
}
else {
    if ((Read-ObjectString -Object $operational -Name "schema") -ne "archrealms.passport.staging_operational_drill.v1") {
        $operationalFailures += "staging operational drill report has unexpected schema"
    }

    if ((Read-ObjectString -Object $operational -Name "lane") -ne "staging") {
        $operationalFailures += "staging operational drill report must use staging lane"
    }

    foreach ($field in @("created_utc", "operational_drill_id", "package_version", "policy_version", "api_base_url", "ai_gateway_url", "ledger_namespace", "telemetry_destination", "operator", "incident_response_owner")) {
        $failure = Test-NotPlaceholder -Name "staging operational drill $field" -Value (Read-ObjectString -Object $operational -Name $field)
        if ($failure) { $operationalFailures += $failure }
    }

    foreach ($check in @(
        @("completed", "staging operational drill completed"),
        @("production_candidate_upgrade_validated", "production-candidate upgrade validation"),
        @("endpoint_failover_validated", "endpoint failover validation"),
        @("signing_verification_validated", "signing verification"),
        @("ledger_export_replay_validated", "ledger export replay validation"),
        @("recovery_revocation_validated", "recovery and revocation validation"),
        @("storage_proof_validation_completed", "storage proof validation"),
        @("storage_redemption_dry_run_completed", "storage redemption dry-run"),
        @("conversion_disclosure_dry_run_completed", "conversion disclosure dry-run"),
        @("telemetry_privacy_validated", "telemetry/privacy validation"),
        @("incident_response_validated", "incident response validation"),
        @("support_access_controls_validated", "support access control validation"),
        @("ai_gateway_auth_privacy_validated", "AI gateway authentication/privacy validation"),
        @("prohibited_claims_blocked", "prohibited monetary claim blocking")
    )) {
        $failure = Test-RequiredTrue -Object $operational -Name $check[0] -Description $check[1]
        if ($failure) { $operationalFailures += $failure }
    }

    $refs = @($operational.evidence_references)
    if ($refs.Count -lt 3) {
        $operationalFailures += "staging operational drill must include at least three evidence references"
    }

    for ($index = 0; $index -lt $refs.Count; $index++) {
        $failure = Test-NotPlaceholder -Name "staging operational evidence reference $($index + 1)" -Value ([string]$refs[$index])
        if ($failure) { $operationalFailures += $failure }
    }
}

$rollback = Read-JsonFile -Path $paths.rollback
$rollbackFailures = @()
if ($null -eq $rollback) {
    $rollbackFailures += "missing or unreadable staging rollback drill report: $($paths.rollback)"
}
else {
    if ((Read-ObjectString -Object $rollback -Name "schema") -ne "archrealms.passport.staging_rollback_drill.v1") {
        $rollbackFailures += "staging rollback drill report has unexpected schema"
    }

    if ((Read-ObjectString -Object $rollback -Name "lane") -ne "staging") {
        $rollbackFailures += "staging rollback drill report must use staging lane"
    }

    foreach ($field in @("created_utc", "rollback_drill_id", "package_version", "policy_version", "reason_code", "user_facing_status")) {
        $failure = Test-NotPlaceholder -Name "staging rollback drill $field" -Value (Read-ObjectString -Object $rollback -Name $field)
        if ($failure) { $rollbackFailures += $failure }
    }

    foreach ($check in @(
        @("completed", "staging rollback drill completed"),
        @("new_operations_disabled_or_routed", "rollback operation-routing control"),
        @("ledger_events_preserved", "ledger event preservation"),
        @("no_deletion_mutation_or_backdating", "rollback no-mutation control"),
        @("pending_escrow_resolved_by_policy", "pending escrow rollback policy"),
        @("export_access_preserved", "export access preservation"),
        @("production_records_untouched", "production record isolation")
    )) {
        $failure = Test-RequiredTrue -Object $rollback -Name $check[0] -Description $check[1]
        if ($failure) { $rollbackFailures += $failure }
    }

    foreach ($collection in @(
        @("approvers", $rollback.approvers, 2),
        @("affected_service_classes", $rollback.affected_service_classes, 1),
        @("affected_assets", $rollback.affected_assets, 1)
    )) {
        $items = @($collection[1])
        if ($items.Count -lt [int]$collection[2]) {
            $rollbackFailures += "staging rollback drill must include $($collection[0])"
        }

        for ($index = 0; $index -lt $items.Count; $index++) {
            $failure = Test-NotPlaceholder -Name "staging rollback $($collection[0]) $($index + 1)" -Value ([string]$items[$index])
            if ($failure) { $rollbackFailures += $failure }
        }
    }
}

$promotion = Read-JsonFile -Path $paths.promotion
$promotionFailures = @()
if ($null -eq $promotion) {
    $promotionFailures += "missing or unreadable staging promotion approval record: $($paths.promotion)"
}
else {
    if ((Read-ObjectString -Object $promotion -Name "schema") -ne "archrealms.passport.staging_promotion_approval.v1") {
        $promotionFailures += "staging promotion approval record has unexpected schema"
    }

    if ((Read-ObjectString -Object $promotion -Name "lane") -ne "staging") {
        $promotionFailures += "staging promotion approval record must use staging lane"
    }

    foreach ($field in @("created_utc", "promotion_approval_id", "engineering_signoff_id", "security_privacy_signoff_id", "crown_monetary_authority_signoff_id", "rollback_drill_id")) {
        $failure = Test-NotPlaceholder -Name "staging promotion approval $field" -Value (Read-ObjectString -Object $promotion -Name $field)
        if ($failure) { $promotionFailures += $failure }
    }

    foreach ($field in @("pre_mvp_report_sha256", "staging_artifact_validation_report_sha256", "operational_drill_report_sha256", "rollback_drill_report_sha256")) {
        $failure = Test-Sha256 -Name "staging promotion approval $field" -Value (Read-ObjectString -Object $promotion -Name $field)
        if ($failure) { $promotionFailures += $failure }
    }

    foreach ($check in @(
        @("approve_canary_or_production_release", "canary or production release approval"),
        @("product_approval_signed", "product approval signature"),
        @("engineering_signoff_signed", "engineering signoff signature"),
        @("security_privacy_signoff_signed", "security/privacy signoff signature"),
        @("crown_monetary_authority_signoff_signed", "Crown monetary authority signoff signature")
    )) {
        $failure = Test-RequiredTrue -Object $promotion -Name $check[0] -Description $check[1]
        if ($failure) { $promotionFailures += $failure }
    }
}

$checks = @(
    New-Check -Id "staging_operational_drill_report" -Failures $operationalFailures -Evidence @{ path = $paths.operational }
    New-Check -Id "staging_rollback_drill_report" -Failures $rollbackFailures -Evidence @{ path = $paths.rollback }
    New-Check -Id "staging_promotion_approval_record" -Failures $promotionFailures -Evidence @{ path = $paths.promotion }
)

$crossFailures = @()
if ($rollback -and $promotion) {
    $rollbackId = Read-ObjectString -Object $rollback -Name "rollback_drill_id"
    if ($rollbackId -and (Read-ObjectString -Object $promotion -Name "rollback_drill_id") -ne $rollbackId) {
        $crossFailures += "promotion approval rollback_drill_id must match rollback drill report"
    }
}

if ($operational -and $promotion -and (Test-Path -LiteralPath $paths.operational -PathType Leaf)) {
    $actualOperationalHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $paths.operational).Hash.ToLowerInvariant()
    $recordedOperationalHash = Read-ObjectString -Object $promotion -Name "operational_drill_report_sha256"
    if ($recordedOperationalHash -match '^[0-9a-fA-F]{64}$' -and $recordedOperationalHash -ne $actualOperationalHash) {
        $crossFailures += "promotion approval operational_drill_report_sha256 must match operational drill file"
    }
}

if ($rollback -and $promotion -and (Test-Path -LiteralPath $paths.rollback -PathType Leaf)) {
    $actualRollbackHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $paths.rollback).Hash.ToLowerInvariant()
    $recordedRollbackHash = Read-ObjectString -Object $promotion -Name "rollback_drill_report_sha256"
    if ($recordedRollbackHash -match '^[0-9a-fA-F]{64}$' -and $recordedRollbackHash -ne $actualRollbackHash) {
        $crossFailures += "promotion approval rollback_drill_report_sha256 must match rollback drill file"
    }
}

if ($operational -and $rollback) {
    foreach ($field in @("package_version", "policy_version")) {
        if ((Read-ObjectString -Object $operational -Name $field) -and (Read-ObjectString -Object $rollback -Name $field) -and (Read-ObjectString -Object $operational -Name $field) -ne (Read-ObjectString -Object $rollback -Name $field)) {
            $crossFailures += "$field must match between operational and rollback drill reports"
        }
    }
}

if ($RequireNoPlaceholders) {
    foreach ($key in $paths.Keys) {
        $path = $paths[$key]
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            $text = Get-Content -LiteralPath $path -Raw
            if ($text -match '<[^>\r\n]+>' -or $text -match '\\u003c[^"]+\\u003e') {
                $crossFailures += "$key evidence file contains placeholder text"
            }
        }
    }
}

$checks += New-Check -Id "staging_evidence_cross_references" -Failures $crossFailures

$evidenceFiles = @()
foreach ($path in $paths.Values) {
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        $evidenceFiles += [pscustomobject][ordered]@{
            id = [System.IO.Path]::GetFileNameWithoutExtension($path)
            path = $path
            sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $path).Hash.ToLowerInvariant()
        }
    }
}

$failed = @($checks | Where-Object { -not $_.passed })
$report = [pscustomobject][ordered]@{
    schema = "archrealms.passport.staging_readiness_evidence_validation.v1"
    created_utc = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
    packet_root = $resolvedPacketRoot
    require_no_placeholders = [bool]$RequireNoPlaceholders
    passed = ($failed.Count -eq 0)
    failed_check_count = $failed.Count
    evidence_files = $evidenceFiles
    checks = $checks
}

$json = $report | ConvertTo-Json -Depth 10
if (-not [string]::IsNullOrWhiteSpace($resolvedOutput)) {
    $parent = Split-Path -Parent $resolvedOutput
    if ($parent) {
        New-Item -ItemType Directory -Force -Path $parent | Out-Null
    }

    Set-Content -LiteralPath $resolvedOutput -Value $json -Encoding UTF8
}

$json

if ($failed.Count -gt 0 -and -not $NoFail) {
    exit 1
}
