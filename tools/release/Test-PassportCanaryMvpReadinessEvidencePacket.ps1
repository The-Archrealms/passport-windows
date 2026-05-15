param(
    [string]$PacketRoot = "deploy\canary-readiness",
    [string]$OutputPath = "artifacts\release\canary-mvp-readiness-evidence-validation-report.json",
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
    param(
        [object]$Object,
        [string]$Name
    )

    if ($null -eq $Object -or -not $Object.PSObject.Properties[$Name]) {
        return ""
    }

    return ([string]$Object.$Name).Trim()
}

function Read-ObjectBool {
    param(
        [object]$Object,
        [string]$Name
    )

    if ($null -eq $Object -or -not $Object.PSObject.Properties[$Name]) {
        return $false
    }

    return [bool]$Object.$Name
}

function Read-ObjectInt {
    param(
        [object]$Object,
        [string]$Name
    )

    if ($null -eq $Object -or -not $Object.PSObject.Properties[$Name]) {
        return 0
    }

    try {
        return [int64]$Object.$Name
    }
    catch {
        return 0
    }
}

function Test-PlaceholderText {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $false
    }

    return ($Value -match '<[^>]+>' -or $Value -match '\\u003c[^"]+\\u003e' -or $Value -match '^\s*set value\s*$')
}

function Test-NotPlaceholder {
    param(
        [string]$Name,
        [string]$Value,
        [bool]$Required = $true
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        if ($Required) {
            return "$Name is required"
        }

        return ""
    }

    if ($RequireNoPlaceholders -and (Test-PlaceholderText -Value $Value)) {
        return "$Name contains a placeholder value"
    }

    return ""
}

function Test-Sha256 {
    param(
        [string]$Name,
        [string]$Value,
        [bool]$Required = $true
    )

    $failure = Test-NotPlaceholder -Name $Name -Value $Value -Required:$Required
    if ($failure) {
        return $failure
    }

    if (-not [string]::IsNullOrWhiteSpace($Value) -and $Value -notmatch '^[0-9a-fA-F]{64}$') {
        if ($RequireNoPlaceholders -or -not (Test-PlaceholderText -Value $Value)) {
            return "$Name must be a SHA-256 hex string"
        }
    }

    return ""
}

function Test-RequiredTrue {
    param(
        [object]$Object,
        [string]$Name,
        [string]$Description
    )

    if ($null -eq $Object -or -not $Object.PSObject.Properties[$Name]) {
        return "$Description field is required"
    }

    if ($RequireNoPlaceholders -and -not (Read-ObjectBool -Object $Object -Name $Name)) {
        return "$Description must be true"
    }

    return ""
}

function Test-RequiredFalse {
    param(
        [object]$Object,
        [string]$Name,
        [string]$Description
    )

    if ($null -eq $Object -or -not $Object.PSObject.Properties[$Name]) {
        return "$Description field is required"
    }

    if (Read-ObjectBool -Object $Object -Name $Name) {
        return "$Description must remain disabled"
    }

    return ""
}

function Test-EvidenceRefs {
    param(
        [object]$Object,
        [string]$Name,
        [int]$MinimumCount = 1
    )

    $failures = @()
    if ($null -eq $Object -or -not $Object.PSObject.Properties["evidence_refs"]) {
        $failures += "$Name evidence_refs field is required"
        return $failures
    }

    $refs = @($Object.evidence_refs)
    if ($refs.Count -lt $MinimumCount) {
        $failures += "$Name must include at least $MinimumCount evidence_refs entry"
    }

    for ($index = 0; $index -lt $refs.Count; $index++) {
        $failure = Test-NotPlaceholder -Name "$Name evidence_refs $($index + 1)" -Value ([string]$refs[$index])
        if ($failure) {
            $failures += $failure
        }
    }

    return $failures
}

function Find-EvidenceFile {
    param(
        [string]$Root,
        [string]$BaseName
    )

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
    param(
        [string]$Id,
        [string[]]$Failures,
        [object]$Evidence = $null
    )

    $cleanFailures = @($Failures | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    return [pscustomobject][ordered]@{
        id = $Id
        passed = ($cleanFailures.Count -eq 0)
        failures = $cleanFailures
        evidence = $Evidence
    }
}

function Test-CommonReport {
    param(
        [object]$Report,
        [string]$Name,
        [string]$ExpectedSchema
    )

    $failures = @()
    if ($null -eq $Report) {
        $failures += "$Name is missing or unreadable"
        return $failures
    }

    if ((Read-ObjectString -Object $Report -Name "schema") -ne $ExpectedSchema) {
        $failures += "$Name has unexpected schema"
    }

    if ((Read-ObjectString -Object $Report -Name "lane") -ne "canary-mvp") {
        $failures += "$Name must use canary-mvp lane"
    }

    $failure = Test-NotPlaceholder -Name "$Name created_utc" -Value (Read-ObjectString -Object $Report -Name "created_utc")
    if ($failure) {
        $failures += $failure
    }

    return $failures
}

$resolvedPacketRoot = Resolve-RepoPath -Path $PacketRoot
$resolvedOutput = Resolve-RepoPath -Path $OutputPath

$paths = [ordered]@{
    policy = Find-EvidenceFile -Root $resolvedPacketRoot -BaseName "canary-policy"
    incident = Find-EvidenceFile -Root $resolvedPacketRoot -BaseName "canary-incident-review"
    balance = Find-EvidenceFile -Root $resolvedPacketRoot -BaseName "canary-balance-reconciliation"
    service_delivery = Find-EvidenceFile -Root $resolvedPacketRoot -BaseName "canary-service-delivery-reconciliation"
    support = Find-EvidenceFile -Root $resolvedPacketRoot -BaseName "canary-support-readiness"
    approval = Find-EvidenceFile -Root $resolvedPacketRoot -BaseName "canary-production-approval-record"
}

$policy = Read-JsonFile -Path $paths.policy
$policyFailures = @(Test-CommonReport -Report $policy -Name "canary policy" -ExpectedSchema "archrealms.passport.canary_policy.v1")
if ($policy) {
    foreach ($field in @("policy_id", "production_ledger_namespace", "support_owner", "incident_response_owner", "rollback_policy_id")) {
        $failure = Test-NotPlaceholder -Name "canary policy $field" -Value (Read-ObjectString -Object $policy -Name $field)
        if ($failure) { $policyFailures += $failure }
    }

    foreach ($field in @(
        @("production_intended", "canary policy production_intended"),
        @("production_ledger", "canary policy production_ledger"),
        @("allowlisted_citizens_only", "canary policy allowlisted_citizens_only")
    )) {
        $failure = Test-RequiredTrue -Object $policy -Name $field[0] -Description $field[1]
        if ($failure) { $policyFailures += $failure }
    }

    foreach ($field in @(
        @("external_wallet_transfers_enabled", "external wallet transfers"),
        @("fiat_rails_enabled", "fiat rails"),
        @("unrestricted_cc_payments_enabled", "unrestricted CC payments"),
        @("guaranteed_conversion_claims_enabled", "guaranteed conversion claims"),
        @("stable_value_claims_enabled", "stable-value claims"),
        @("yield_or_staking_enabled", "yield or staking"),
        @("token_governance_enabled", "token governance")
    )) {
        $failure = Test-RequiredFalse -Object $policy -Name $field[0] -Description "canary policy $($field[1])"
        if ($failure) { $policyFailures += $failure }
    }

    foreach ($field in @("max_citizens", "max_arch_per_citizen_base_units", "max_cc_outstanding_base_units", "max_conversion_quote_base_units")) {
        if ((Read-ObjectInt -Object $policy -Name $field) -le 0) {
            $policyFailures += "canary policy $field must be greater than zero"
        }
    }

    $classes = @($policy.allowed_service_classes)
    if ($classes.Count -lt 1) {
        $policyFailures += "canary policy must list allowed_service_classes"
    }
    for ($index = 0; $index -lt $classes.Count; $index++) {
        $failure = Test-NotPlaceholder -Name "canary policy allowed service class $($index + 1)" -Value ([string]$classes[$index])
        if ($failure) { $policyFailures += $failure }
    }

    $policyFailures += Test-EvidenceRefs -Object $policy -Name "canary policy"
}

$incident = Read-JsonFile -Path $paths.incident
$incidentFailures = @(Test-CommonReport -Report $incident -Name "canary incident review" -ExpectedSchema "archrealms.passport.canary_incident_review.v1")
if ($incident) {
    foreach ($field in @("incident_review_id", "incident_response_owner")) {
        $failure = Test-NotPlaceholder -Name "canary incident review $field" -Value (Read-ObjectString -Object $incident -Name $field)
        if ($failure) { $incidentFailures += $failure }
    }

    foreach ($field in @("completed", "incident_review_completed", "no_unresolved_critical_incidents", "no_unresolved_high_incidents")) {
        $failure = Test-RequiredTrue -Object $incident -Name $field -Description "canary incident review $field"
        if ($failure) { $incidentFailures += $failure }
    }

    if ((Read-ObjectInt -Object $incident -Name "unresolved_critical_incident_count") -ne 0 -or
        (Read-ObjectInt -Object $incident -Name "unresolved_high_incident_count") -ne 0) {
        $incidentFailures += "canary incident review must have zero unresolved critical/high incidents"
    }

    $incidentFailures += Test-EvidenceRefs -Object $incident -Name "canary incident review"
}

$balance = Read-JsonFile -Path $paths.balance
$balanceFailures = @(Test-CommonReport -Report $balance -Name "canary balance reconciliation" -ExpectedSchema "archrealms.passport.canary_balance_reconciliation.v1")
if ($balance) {
    foreach ($field in @("balance_reconciliation_id", "production_ledger_namespace")) {
        $failure = Test-NotPlaceholder -Name "canary balance reconciliation $field" -Value (Read-ObjectString -Object $balance -Name $field)
        if ($failure) { $balanceFailures += $failure }
    }

    foreach ($field in @("completed", "arch_balances_reconciled", "cc_balances_reconciled", "escrow_reconciled", "burn_refund_recredit_reconciled", "crown_reserve_reconciled", "no_negative_balances", "no_unapproved_issuance", "no_staging_records_detected")) {
        $failure = Test-RequiredTrue -Object $balance -Name $field -Description "canary balance reconciliation $field"
        if ($failure) { $balanceFailures += $failure }
    }

    $balanceFailures += Test-EvidenceRefs -Object $balance -Name "canary balance reconciliation"
}

$service = Read-JsonFile -Path $paths.service_delivery
$serviceFailures = @(Test-CommonReport -Report $service -Name "canary service-delivery reconciliation" -ExpectedSchema "archrealms.passport.canary_service_delivery_reconciliation.v1")
if ($service) {
    $failure = Test-NotPlaceholder -Name "canary service-delivery reconciliation service_delivery_reconciliation_id" -Value (Read-ObjectString -Object $service -Name "service_delivery_reconciliation_id")
    if ($failure) { $serviceFailures += $failure }

    foreach ($field in @("completed", "service_delivery_reconciled", "storage_redemptions_reconciled", "storage_proofs_reconciled", "burns_match_verified_epochs", "refunds_recredits_extensions_reconciled")) {
        $failure = Test-RequiredTrue -Object $service -Name $field -Description "canary service-delivery reconciliation $field"
        if ($failure) { $serviceFailures += $failure }
    }

    if ((Read-ObjectInt -Object $service -Name "unresolved_failed_epoch_count") -ne 0) {
        $serviceFailures += "canary service-delivery reconciliation must have zero unresolved failed epochs"
    }

    $serviceFailures += Test-EvidenceRefs -Object $service -Name "canary service-delivery reconciliation"
}

$support = Read-JsonFile -Path $paths.support
$supportFailures = @(Test-CommonReport -Report $support -Name "canary support readiness" -ExpectedSchema "archrealms.passport.canary_support_readiness.v1")
if ($support) {
    foreach ($field in @("support_readiness_id", "support_owner", "incident_response_owner")) {
        $failure = Test-NotPlaceholder -Name "canary support readiness $field" -Value (Read-ObjectString -Object $support -Name $field)
        if ($failure) { $supportFailures += $failure }
    }

    foreach ($field in @("completed", "support_ready", "support_queue_reviewed", "recovery_support_ready", "escalation_path_ready", "support_access_controls_validated")) {
        $failure = Test-RequiredTrue -Object $support -Name $field -Description "canary support readiness $field"
        if ($failure) { $supportFailures += $failure }
    }

    $supportFailures += Test-EvidenceRefs -Object $support -Name "canary support readiness"
}

$approval = Read-JsonFile -Path $paths.approval
$approvalFailures = @(Test-CommonReport -Report $approval -Name "canary production approval" -ExpectedSchema "archrealms.passport.canary_production_approval.v1")
if ($approval) {
    foreach ($field in @("production_approval_id", "product_approval_id", "engineering_signoff_id", "security_privacy_signoff_id", "crown_monetary_authority_signoff_id", "approval_notes")) {
        $failure = Test-NotPlaceholder -Name "canary production approval $field" -Value (Read-ObjectString -Object $approval -Name $field)
        if ($failure) { $approvalFailures += $failure }
    }

    $failure = Test-RequiredTrue -Object $approval -Name "approve_production_mvp_release" -Description "canary production approval approve_production_mvp_release"
    if ($failure) { $approvalFailures += $failure }

    foreach ($field in @(
        "staging_readiness_report_sha256",
        "canary_artifact_validation_report_sha256",
        "canary_policy_report_sha256",
        "canary_incident_review_report_sha256",
        "canary_balance_reconciliation_report_sha256",
        "canary_service_delivery_reconciliation_report_sha256",
        "canary_support_readiness_report_sha256"
    )) {
        $failure = Test-Sha256 -Name "canary production approval $field" -Value (Read-ObjectString -Object $approval -Name $field)
        if ($failure) { $approvalFailures += $failure }
    }

    $productionApprovalId = Read-ObjectString -Object $approval -Name "production_approval_id"
    $productApprovalId = Read-ObjectString -Object $approval -Name "product_approval_id"
    if ($RequireNoPlaceholders -and
        -not (Test-PlaceholderText -Value $productionApprovalId) -and
        -not (Test-PlaceholderText -Value $productApprovalId) -and
        $productionApprovalId -ne $productApprovalId) {
        $approvalFailures += "canary production approval product_approval_id must match production_approval_id"
    }
}

$checks = @(
    New-Check -Id "canary_policy_report" -Failures $policyFailures -Evidence @{ path = $paths.policy }
    New-Check -Id "canary_incident_review_report" -Failures $incidentFailures -Evidence @{ path = $paths.incident }
    New-Check -Id "canary_balance_reconciliation_report" -Failures $balanceFailures -Evidence @{ path = $paths.balance }
    New-Check -Id "canary_service_delivery_reconciliation_report" -Failures $serviceFailures -Evidence @{ path = $paths.service_delivery }
    New-Check -Id "canary_support_readiness_report" -Failures $supportFailures -Evidence @{ path = $paths.support }
    New-Check -Id "canary_production_approval_record" -Failures $approvalFailures -Evidence @{ path = $paths.approval }
)

$crossFailures = @()

if ($policy -and $balance) {
    $policyNamespace = Read-ObjectString -Object $policy -Name "production_ledger_namespace"
    $balanceNamespace = Read-ObjectString -Object $balance -Name "production_ledger_namespace"
    if ($policyNamespace -and $balanceNamespace -and
        -not (Test-PlaceholderText -Value $policyNamespace) -and
        -not (Test-PlaceholderText -Value $balanceNamespace) -and
        $policyNamespace -ne $balanceNamespace) {
        $crossFailures += "production_ledger_namespace must match between canary policy and balance reconciliation"
    }
}

if ($policy -and $support) {
    $policySupportOwner = Read-ObjectString -Object $policy -Name "support_owner"
    $supportOwner = Read-ObjectString -Object $support -Name "support_owner"
    if ($policySupportOwner -and $supportOwner -and
        -not (Test-PlaceholderText -Value $policySupportOwner) -and
        -not (Test-PlaceholderText -Value $supportOwner) -and
        $policySupportOwner -ne $supportOwner) {
        $crossFailures += "support_owner must match between canary policy and support readiness"
    }
}

$incidentOwners = @()
foreach ($record in @($policy, $incident, $support)) {
    $owner = Read-ObjectString -Object $record -Name "incident_response_owner"
    if (-not [string]::IsNullOrWhiteSpace($owner) -and -not (Test-PlaceholderText -Value $owner)) {
        $incidentOwners += $owner
    }
}
if (($incidentOwners | Select-Object -Unique).Count -gt 1) {
    $crossFailures += "incident_response_owner must match across canary policy, incident review, and support readiness"
}

if ($approval) {
    $localHashFields = @(
        @("canary_policy_report_sha256", $paths.policy, "canary policy"),
        @("canary_incident_review_report_sha256", $paths.incident, "canary incident review"),
        @("canary_balance_reconciliation_report_sha256", $paths.balance, "canary balance reconciliation"),
        @("canary_service_delivery_reconciliation_report_sha256", $paths.service_delivery, "canary service-delivery reconciliation"),
        @("canary_support_readiness_report_sha256", $paths.support, "canary support readiness")
    )

    foreach ($field in $localHashFields) {
        $recordedHash = Read-ObjectString -Object $approval -Name $field[0]
        $path = $field[1]
        if ($recordedHash -match '^[0-9a-fA-F]{64}$' -and (Test-Path -LiteralPath $path -PathType Leaf)) {
            $actualHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $path).Hash.ToLowerInvariant()
            if (-not [string]::Equals($actualHash, $recordedHash, [System.StringComparison]::OrdinalIgnoreCase)) {
                $crossFailures += "canary production approval $($field[0]) must match $($field[2]) file"
            }
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

            if ($text -match '(?im)^\s*\"?[a-z0-9_ -]+\"?\s*:\s*\"?set value\"?\s*[,}]?') {
                $crossFailures += "$key evidence file contains set value placeholder text"
            }
        }
    }
}

$checks += New-Check -Id "canary_evidence_cross_references" -Failures $crossFailures

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
    schema = "archrealms.passport.canary_mvp_readiness_evidence_validation.v1"
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
