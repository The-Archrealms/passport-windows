param(
    [string]$OutputPath = "artifacts\release\canary-mvp-readiness-report.json",
    [string]$EnvironmentFile,
    [switch]$UseSyntheticFixtures,
    [switch]$NoFail
)

$ErrorActionPreference = "Stop"
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path

function Import-EnvironmentFile {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return @()
    }

    $resolvedPath = (Resolve-Path -LiteralPath $Path).Path
    $loaded = @()
    foreach ($line in Get-Content -LiteralPath $resolvedPath) {
        $trimmed = $line.Trim()
        if ([string]::IsNullOrWhiteSpace($trimmed) -or $trimmed.StartsWith("#")) {
            continue
        }

        $separator = $trimmed.IndexOf("=")
        if ($separator -le 0) {
            continue
        }

        $name = $trimmed.Substring(0, $separator).Trim()
        $value = $trimmed.Substring($separator + 1).Trim()
        if ([string]::IsNullOrWhiteSpace($name)) {
            continue
        }

        if (($value.StartsWith('"') -and $value.EndsWith('"')) -or ($value.StartsWith("'") -and $value.EndsWith("'"))) {
            $value = $value.Substring(1, $value.Length - 2)
        }

        [System.Environment]::SetEnvironmentVariable($name, $value, "Process")
        $loaded += $name
    }

    return $loaded
}

function Get-EnvironmentValue {
    param([string]$Name)

    $value = [System.Environment]::GetEnvironmentVariable($Name)
    if ($null -eq $value) {
        return ""
    }

    return $value.Trim()
}

function Get-Sha256Hex {
    param([byte[]]$Bytes)

    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        return [System.BitConverter]::ToString($sha256.ComputeHash($Bytes)).Replace("-", "").ToLowerInvariant()
    }
    finally {
        $sha256.Dispose()
    }
}

function Test-NotPlaceholder {
    param(
        [string]$Name,
        [string]$Value
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return ""
    }

    $trimmed = $Value.Trim()
    if ($trimmed -match '<[^>]+>' -or $trimmed -match '^\s*set value\s*$') {
        return "$Name contains a placeholder value"
    }

    return ""
}

function Test-NonEmptyEnvironment {
    param([string]$Name)

    return -not [string]::IsNullOrWhiteSpace([System.Environment]::GetEnvironmentVariable($Name))
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

    return [int64]$Object.$Name
}

function Test-RequiredTrueField {
    param(
        [object]$Object,
        [string]$Name,
        [string]$Description
    )

    if (-not (Read-ObjectBool -Object $Object -Name $Name)) {
        return "$Description must be true"
    }

    return ""
}

function Read-JsonEvidenceReport {
    param(
        [string]$Label,
        [string]$PathEnvironmentName,
        [string]$HashEnvironmentName,
        [string]$ExpectedSchema
    )

    $path = Get-EnvironmentValue -Name $PathEnvironmentName
    $expectedHash = Get-EnvironmentValue -Name $HashEnvironmentName
    $failures = @()

    if ([string]::IsNullOrWhiteSpace($path)) {
        return [pscustomobject][ordered]@{ report = $null; failures = $failures }
    }

    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        $failures += "$PathEnvironmentName does not exist"
        return [pscustomobject][ordered]@{ report = $null; failures = $failures }
    }

    if ([string]::IsNullOrWhiteSpace($expectedHash)) {
        $failures += "$HashEnvironmentName is required"
    }
    elseif ($expectedHash -notmatch '^[0-9a-fA-F]{64}$') {
        $failures += "$HashEnvironmentName must be a SHA-256 hex string"
    }
    else {
        $actualHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $path).Hash.ToLowerInvariant()
        if (-not [string]::Equals($actualHash, $expectedHash, [System.StringComparison]::OrdinalIgnoreCase)) {
            $failures += "$HashEnvironmentName does not match the report file"
        }
    }

    $report = $null
    try {
        $report = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
    }
    catch {
        $failures += "$Label is not valid JSON: $($_.Exception.Message)"
        return [pscustomobject][ordered]@{ report = $null; failures = $failures }
    }

    if (-not [string]::IsNullOrWhiteSpace($ExpectedSchema) -and $report.schema -ne $ExpectedSchema) {
        $failures += "$Label has unexpected schema"
    }

    return [pscustomobject][ordered]@{ report = $report; failures = $failures }
}

function New-Gate {
    param(
        [string]$Id,
        [string]$Description,
        [string[]]$RequiredEnvironment,
        [scriptblock]$ExtraCheck = $null
    )

    $missing = @()
    foreach ($name in $RequiredEnvironment) {
        if (-not (Test-NonEmptyEnvironment -Name $name)) {
            $missing += $name
            continue
        }

        $placeholderFailure = Test-NotPlaceholder -Name $name -Value (Get-EnvironmentValue -Name $name)
        if ($placeholderFailure) {
            $missing += $placeholderFailure
        }
    }

    if ($ExtraCheck) {
        $extraFailures = @(& $ExtraCheck)
        foreach ($failure in $extraFailures) {
            if ($failure) {
                $missing += $failure
            }
        }
    }

    return [pscustomobject][ordered]@{
        id = $Id
        description = $Description
        passed = ($missing.Count -eq 0)
        missing = $missing
    }
}

function Test-StagingReadiness {
    $evidence = Read-JsonEvidenceReport `
        -Label "staging readiness report" `
        -PathEnvironmentName "ARCHREALMS_PASSPORT_STAGING_READINESS_REPORT_PATH" `
        -HashEnvironmentName "ARCHREALMS_PASSPORT_STAGING_READINESS_REPORT_SHA256" `
        -ExpectedSchema "archrealms.passport.staging_readiness.v1"
    $failures = @($evidence.failures)
    $report = $evidence.report
    if ($null -eq $report) {
        return $failures
    }

    if ($report.ready -ne $true) {
        $failures += "staging readiness report did not pass"
    }
    if ($report.staging_is_mvp -ne $false) {
        $failures += "staging readiness report must state staging is not the MVP"
    }
    if ($report.synthetic_fixtures_used -eq $true) {
        $failures += "canary readiness cannot accept a staging readiness report created with synthetic fixtures"
    }
    if ($report.canary_or_production_release_approved -ne $true) {
        $failures += "staging readiness report must approve canary release promotion"
    }

    return $failures
}

function Test-CanaryArtifact {
    $evidence = Read-JsonEvidenceReport `
        -Label "canary artifact validation report" `
        -PathEnvironmentName "ARCHREALMS_PASSPORT_CANARY_ARTIFACT_VALIDATION_REPORT_PATH" `
        -HashEnvironmentName "ARCHREALMS_PASSPORT_CANARY_ARTIFACT_VALIDATION_REPORT_SHA256" `
        -ExpectedSchema ""
    $failures = @($evidence.failures)
    $report = $evidence.report
    if ($null -eq $report) {
        return $failures
    }

    if ($report.passed -ne $true) {
        $failures += "canary artifact validation report did not pass"
    }

    $artifacts = @($report.artifacts)
    if ($artifacts.Count -lt 1) {
        $failures += "canary artifact validation report must include at least one artifact"
    }

    foreach ($artifact in $artifacts) {
        if ($artifact.passed -ne $true) {
            $failures += "canary artifact validation contains a failed artifact"
        }
        if ([string]$artifact.lane -ne "canary-mvp") {
            $failures += "canary artifact validation must be for lane canary-mvp"
        }
        if ([string]::IsNullOrWhiteSpace([string]$artifact.ledger_namespace)) {
            $failures += "canary artifact validation must include a ledger namespace"
        }
    }

    return $failures
}

function Test-CanaryPolicy {
    $evidence = Read-JsonEvidenceReport `
        -Label "canary policy report" `
        -PathEnvironmentName "ARCHREALMS_PASSPORT_CANARY_POLICY_REPORT_PATH" `
        -HashEnvironmentName "ARCHREALMS_PASSPORT_CANARY_POLICY_REPORT_SHA256" `
        -ExpectedSchema "archrealms.passport.canary_policy.v1"
    $failures = @($evidence.failures)
    $report = $evidence.report
    if ($null -eq $report) {
        return $failures
    }

    $policyId = Get-EnvironmentValue -Name "ARCHREALMS_PASSPORT_CANARY_POLICY_ID"
    if ((Read-ObjectString -Object $report -Name "policy_id") -ne $policyId) {
        $failures += "canary policy report policy_id must match ARCHREALMS_PASSPORT_CANARY_POLICY_ID"
    }
    if ((Read-ObjectString -Object $report -Name "lane") -ne "canary-mvp") {
        $failures += "canary policy report lane must be canary-mvp"
    }

    foreach ($field in @(
        @("production_intended", "canary policy production_intended"),
        @("production_ledger", "canary policy production_ledger"),
        @("allowlisted_citizens_only", "canary policy allowlisted_citizens_only")
    )) {
        $failure = Test-RequiredTrueField -Object $report -Name $field[0] -Description $field[1]
        if ($failure) { $failures += $failure }
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
        if (Read-ObjectBool -Object $report -Name $field[0]) {
            $failures += "canary policy must keep $($field[1]) disabled"
        }
    }

    foreach ($field in @("max_citizens", "max_arch_per_citizen_base_units", "max_cc_outstanding_base_units", "max_conversion_quote_base_units")) {
        if ((Read-ObjectInt -Object $report -Name $field) -le 0) {
            $failures += "canary policy $field must be greater than zero"
        }
    }

    if (@($report.allowed_service_classes).Count -lt 1) {
        $failures += "canary policy must list allowed_service_classes"
    }
    if ([string]::IsNullOrWhiteSpace((Read-ObjectString -Object $report -Name "support_owner"))) {
        $failures += "canary policy support_owner is required"
    }
    if ([string]::IsNullOrWhiteSpace((Read-ObjectString -Object $report -Name "incident_response_owner"))) {
        $failures += "canary policy incident_response_owner is required"
    }

    return $failures
}

function Test-CanaryIncidentReview {
    $evidence = Read-JsonEvidenceReport `
        -Label "canary incident review report" `
        -PathEnvironmentName "ARCHREALMS_PASSPORT_CANARY_INCIDENT_REVIEW_REPORT_PATH" `
        -HashEnvironmentName "ARCHREALMS_PASSPORT_CANARY_INCIDENT_REVIEW_REPORT_SHA256" `
        -ExpectedSchema "archrealms.passport.canary_incident_review.v1"
    $failures = @($evidence.failures)
    $report = $evidence.report
    if ($null -eq $report) { return $failures }

    if ((Read-ObjectString -Object $report -Name "incident_review_id") -ne (Get-EnvironmentValue -Name "ARCHREALMS_PASSPORT_CANARY_INCIDENT_REVIEW_ID")) {
        $failures += "canary incident review ID must match ARCHREALMS_PASSPORT_CANARY_INCIDENT_REVIEW_ID"
    }
    foreach ($field in @("completed", "incident_review_completed", "no_unresolved_critical_incidents", "no_unresolved_high_incidents")) {
        $failure = Test-RequiredTrueField -Object $report -Name $field -Description "canary incident review $field"
        if ($failure) { $failures += $failure }
    }
    if ((Read-ObjectInt -Object $report -Name "unresolved_critical_incident_count") -ne 0 -or (Read-ObjectInt -Object $report -Name "unresolved_high_incident_count") -ne 0) {
        $failures += "canary incident review must have zero unresolved critical/high incidents"
    }
    if ([string]::IsNullOrWhiteSpace((Read-ObjectString -Object $report -Name "incident_response_owner"))) {
        $failures += "canary incident review incident_response_owner is required"
    }

    return $failures
}

function Test-CanaryBalanceReconciliation {
    $evidence = Read-JsonEvidenceReport `
        -Label "canary balance reconciliation report" `
        -PathEnvironmentName "ARCHREALMS_PASSPORT_CANARY_BALANCE_RECONCILIATION_REPORT_PATH" `
        -HashEnvironmentName "ARCHREALMS_PASSPORT_CANARY_BALANCE_RECONCILIATION_REPORT_SHA256" `
        -ExpectedSchema "archrealms.passport.canary_balance_reconciliation.v1"
    $failures = @($evidence.failures)
    $report = $evidence.report
    if ($null -eq $report) { return $failures }

    if ((Read-ObjectString -Object $report -Name "balance_reconciliation_id") -ne (Get-EnvironmentValue -Name "ARCHREALMS_PASSPORT_CANARY_BALANCE_RECONCILIATION_ID")) {
        $failures += "canary balance reconciliation ID must match ARCHREALMS_PASSPORT_CANARY_BALANCE_RECONCILIATION_ID"
    }
    foreach ($field in @("completed", "arch_balances_reconciled", "cc_balances_reconciled", "escrow_reconciled", "burn_refund_recredit_reconciled", "crown_reserve_reconciled", "no_negative_balances", "no_unapproved_issuance", "no_staging_records_detected")) {
        $failure = Test-RequiredTrueField -Object $report -Name $field -Description "canary balance reconciliation $field"
        if ($failure) { $failures += $failure }
    }
    if ([string]::IsNullOrWhiteSpace((Read-ObjectString -Object $report -Name "production_ledger_namespace"))) {
        $failures += "canary balance reconciliation production_ledger_namespace is required"
    }

    return $failures
}

function Test-CanaryServiceDeliveryReconciliation {
    $evidence = Read-JsonEvidenceReport `
        -Label "canary service-delivery reconciliation report" `
        -PathEnvironmentName "ARCHREALMS_PASSPORT_CANARY_SERVICE_DELIVERY_RECONCILIATION_REPORT_PATH" `
        -HashEnvironmentName "ARCHREALMS_PASSPORT_CANARY_SERVICE_DELIVERY_RECONCILIATION_REPORT_SHA256" `
        -ExpectedSchema "archrealms.passport.canary_service_delivery_reconciliation.v1"
    $failures = @($evidence.failures)
    $report = $evidence.report
    if ($null -eq $report) { return $failures }

    if ((Read-ObjectString -Object $report -Name "service_delivery_reconciliation_id") -ne (Get-EnvironmentValue -Name "ARCHREALMS_PASSPORT_CANARY_SERVICE_DELIVERY_RECONCILIATION_ID")) {
        $failures += "canary service-delivery reconciliation ID must match ARCHREALMS_PASSPORT_CANARY_SERVICE_DELIVERY_RECONCILIATION_ID"
    }
    foreach ($field in @("completed", "service_delivery_reconciled", "storage_redemptions_reconciled", "storage_proofs_reconciled", "burns_match_verified_epochs", "refunds_recredits_extensions_reconciled")) {
        $failure = Test-RequiredTrueField -Object $report -Name $field -Description "canary service-delivery reconciliation $field"
        if ($failure) { $failures += $failure }
    }
    if ((Read-ObjectInt -Object $report -Name "unresolved_failed_epoch_count") -ne 0) {
        $failures += "canary service-delivery reconciliation must have zero unresolved failed epochs"
    }

    return $failures
}

function Test-CanarySupportReadiness {
    $evidence = Read-JsonEvidenceReport `
        -Label "canary support readiness report" `
        -PathEnvironmentName "ARCHREALMS_PASSPORT_CANARY_SUPPORT_READINESS_REPORT_PATH" `
        -HashEnvironmentName "ARCHREALMS_PASSPORT_CANARY_SUPPORT_READINESS_REPORT_SHA256" `
        -ExpectedSchema "archrealms.passport.canary_support_readiness.v1"
    $failures = @($evidence.failures)
    $report = $evidence.report
    if ($null -eq $report) { return $failures }

    if ((Read-ObjectString -Object $report -Name "support_readiness_id") -ne (Get-EnvironmentValue -Name "ARCHREALMS_PASSPORT_CANARY_SUPPORT_READINESS_ID")) {
        $failures += "canary support readiness ID must match ARCHREALMS_PASSPORT_CANARY_SUPPORT_READINESS_ID"
    }
    foreach ($field in @("completed", "support_ready", "support_queue_reviewed", "recovery_support_ready", "escalation_path_ready", "support_access_controls_validated")) {
        $failure = Test-RequiredTrueField -Object $report -Name $field -Description "canary support readiness $field"
        if ($failure) { $failures += $failure }
    }
    if ([string]::IsNullOrWhiteSpace((Read-ObjectString -Object $report -Name "support_owner"))) {
        $failures += "canary support readiness support_owner is required"
    }
    if ([string]::IsNullOrWhiteSpace((Read-ObjectString -Object $report -Name "incident_response_owner"))) {
        $failures += "canary support readiness incident_response_owner is required"
    }

    return $failures
}

function Test-CanaryProductionApprovals {
    $evidence = Read-JsonEvidenceReport `
        -Label "canary production approval record" `
        -PathEnvironmentName "ARCHREALMS_PASSPORT_CANARY_PRODUCTION_APPROVAL_RECORD_PATH" `
        -HashEnvironmentName "ARCHREALMS_PASSPORT_CANARY_PRODUCTION_APPROVAL_RECORD_SHA256" `
        -ExpectedSchema "archrealms.passport.canary_production_approval.v1"
    $failures = @($evidence.failures)
    $report = $evidence.report
    if ($null -eq $report) { return $failures }

    if ((Read-ObjectString -Object $report -Name "production_approval_id") -ne (Get-EnvironmentValue -Name "ARCHREALMS_PASSPORT_CANARY_PRODUCTION_APPROVAL_ID")) {
        $failures += "canary production approval ID must match ARCHREALMS_PASSPORT_CANARY_PRODUCTION_APPROVAL_ID"
    }
    if (-not (Read-ObjectBool -Object $report -Name "approve_production_mvp_release")) {
        $failures += "canary production approval must approve ProductionMvp release"
    }

    $fieldPairs = @(
        @("product_approval_id", "ARCHREALMS_PASSPORT_CANARY_PRODUCTION_APPROVAL_ID"),
        @("engineering_signoff_id", "ARCHREALMS_PASSPORT_CANARY_ENGINEERING_SIGNOFF_ID"),
        @("security_privacy_signoff_id", "ARCHREALMS_PASSPORT_CANARY_SECURITY_PRIVACY_SIGNOFF_ID"),
        @("crown_monetary_authority_signoff_id", "ARCHREALMS_PASSPORT_CANARY_CROWN_MONETARY_AUTHORITY_SIGNOFF_ID")
    )
    foreach ($pair in $fieldPairs) {
        if ((Read-ObjectString -Object $report -Name $pair[0]) -ne (Get-EnvironmentValue -Name $pair[1])) {
            $failures += "canary production approval $($pair[0]) must match $($pair[1])"
        }
    }

    $hashPairs = @(
        @("staging_readiness_report_sha256", "ARCHREALMS_PASSPORT_STAGING_READINESS_REPORT_SHA256"),
        @("canary_artifact_validation_report_sha256", "ARCHREALMS_PASSPORT_CANARY_ARTIFACT_VALIDATION_REPORT_SHA256"),
        @("canary_policy_report_sha256", "ARCHREALMS_PASSPORT_CANARY_POLICY_REPORT_SHA256"),
        @("canary_incident_review_report_sha256", "ARCHREALMS_PASSPORT_CANARY_INCIDENT_REVIEW_REPORT_SHA256"),
        @("canary_balance_reconciliation_report_sha256", "ARCHREALMS_PASSPORT_CANARY_BALANCE_RECONCILIATION_REPORT_SHA256"),
        @("canary_service_delivery_reconciliation_report_sha256", "ARCHREALMS_PASSPORT_CANARY_SERVICE_DELIVERY_RECONCILIATION_REPORT_SHA256"),
        @("canary_support_readiness_report_sha256", "ARCHREALMS_PASSPORT_CANARY_SUPPORT_READINESS_REPORT_SHA256")
    )
    foreach ($pair in $hashPairs) {
        $expected = Get-EnvironmentValue -Name $pair[1]
        if (-not [string]::IsNullOrWhiteSpace($expected) -and (Read-ObjectString -Object $report -Name $pair[0]) -ne $expected) {
            $failures += "canary production approval $($pair[0]) must match $($pair[1])"
        }
    }

    return $failures
}

function Write-JsonFile {
    param(
        [string]$Path,
        [object]$Value
    )

    $parent = Split-Path -Parent $Path
    if ($parent) {
        New-Item -ItemType Directory -Force -Path $parent | Out-Null
    }

    Set-Content -LiteralPath $Path -Value ($Value | ConvertTo-Json -Depth 10) -Encoding UTF8
}

$loadedEnvironmentVariables = Import-EnvironmentFile -Path $EnvironmentFile
$syntheticFixtures = $null

if ($UseSyntheticFixtures) {
    $syntheticRoot = Join-Path $repoRoot "artifacts\release\canary-readiness-fixture"
    New-Item -ItemType Directory -Force -Path $syntheticRoot | Out-Null

    $stagingPath = Join-Path $syntheticRoot "staging-readiness-report.json"
    $artifactPath = Join-Path $syntheticRoot "canary-artifact-validation-report.json"
    $policyPath = Join-Path $syntheticRoot "canary-policy.json"
    $incidentPath = Join-Path $syntheticRoot "canary-incident-review.json"
    $balancePath = Join-Path $syntheticRoot "canary-balance-reconciliation.json"
    $servicePath = Join-Path $syntheticRoot "canary-service-delivery-reconciliation.json"
    $supportPath = Join-Path $syntheticRoot "canary-support-readiness.json"
    $approvalPath = Join-Path $syntheticRoot "canary-production-approval.json"

    Write-JsonFile -Path $stagingPath -Value ([pscustomobject][ordered]@{
        schema = "archrealms.passport.staging_readiness.v1"
        ready = $true
        staging_is_mvp = $false
        synthetic_fixtures_used = $false
        canary_or_production_release_approved = $true
        failed_gate_count = 0
        gates = @()
    })
    Write-JsonFile -Path $artifactPath -Value ([pscustomobject][ordered]@{
        passed = $true
        failed_artifact_count = 0
        artifacts = @([pscustomobject][ordered]@{
            lane = "canary-mvp"
            ledger_namespace = "archrealms-passport-canary-mvp"
            passed = $true
            failures = @()
        })
    })
    Write-JsonFile -Path $policyPath -Value ([pscustomobject][ordered]@{
        schema = "archrealms.passport.canary_policy.v1"
        lane = "canary-mvp"
        policy_id = "canary-policy-synthetic"
        production_intended = $true
        production_ledger = $true
        allowlisted_citizens_only = $true
        production_ledger_namespace = "archrealms-passport-canary-mvp"
        max_citizens = 5
        max_arch_per_citizen_base_units = 1000000
        max_cc_outstanding_base_units = 1000000
        max_conversion_quote_base_units = 100000
        allowed_service_classes = @("storage_standard")
        external_wallet_transfers_enabled = $false
        fiat_rails_enabled = $false
        unrestricted_cc_payments_enabled = $false
        guaranteed_conversion_claims_enabled = $false
        stable_value_claims_enabled = $false
        yield_or_staking_enabled = $false
        token_governance_enabled = $false
        support_owner = "support-synthetic"
        incident_response_owner = "incident-synthetic"
        rollback_policy_id = "rollback-synthetic"
        evidence_refs = @("policy-ref")
    })
    Write-JsonFile -Path $incidentPath -Value ([pscustomobject][ordered]@{
        schema = "archrealms.passport.canary_incident_review.v1"
        lane = "canary-mvp"
        incident_review_id = "incident-review-synthetic"
        completed = $true
        incident_review_completed = $true
        no_unresolved_critical_incidents = $true
        no_unresolved_high_incidents = $true
        incident_response_owner = "incident-synthetic"
        incident_count = 0
        unresolved_critical_incident_count = 0
        unresolved_high_incident_count = 0
        evidence_refs = @("incident-ref")
    })
    Write-JsonFile -Path $balancePath -Value ([pscustomobject][ordered]@{
        schema = "archrealms.passport.canary_balance_reconciliation.v1"
        lane = "canary-mvp"
        balance_reconciliation_id = "balance-reconciliation-synthetic"
        completed = $true
        production_ledger_namespace = "archrealms-passport-canary-mvp"
        arch_balances_reconciled = $true
        cc_balances_reconciled = $true
        escrow_reconciled = $true
        burn_refund_recredit_reconciled = $true
        crown_reserve_reconciled = $true
        no_negative_balances = $true
        no_unapproved_issuance = $true
        no_staging_records_detected = $true
        evidence_refs = @("balance-ref")
    })
    Write-JsonFile -Path $servicePath -Value ([pscustomobject][ordered]@{
        schema = "archrealms.passport.canary_service_delivery_reconciliation.v1"
        lane = "canary-mvp"
        service_delivery_reconciliation_id = "service-delivery-synthetic"
        completed = $true
        service_delivery_reconciled = $true
        storage_redemptions_reconciled = $true
        storage_proofs_reconciled = $true
        burns_match_verified_epochs = $true
        refunds_recredits_extensions_reconciled = $true
        unresolved_failed_epoch_count = 0
        evidence_refs = @("service-ref")
    })
    Write-JsonFile -Path $supportPath -Value ([pscustomobject][ordered]@{
        schema = "archrealms.passport.canary_support_readiness.v1"
        lane = "canary-mvp"
        support_readiness_id = "support-readiness-synthetic"
        completed = $true
        support_ready = $true
        support_queue_reviewed = $true
        recovery_support_ready = $true
        escalation_path_ready = $true
        support_access_controls_validated = $true
        support_owner = "support-synthetic"
        incident_response_owner = "incident-synthetic"
        evidence_refs = @("support-ref")
    })

    $stagingHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $stagingPath).Hash.ToLowerInvariant()
    $artifactHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $artifactPath).Hash.ToLowerInvariant()
    $policyHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $policyPath).Hash.ToLowerInvariant()
    $incidentHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $incidentPath).Hash.ToLowerInvariant()
    $balanceHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $balancePath).Hash.ToLowerInvariant()
    $serviceHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $servicePath).Hash.ToLowerInvariant()
    $supportHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $supportPath).Hash.ToLowerInvariant()

    Write-JsonFile -Path $approvalPath -Value ([pscustomobject][ordered]@{
        schema = "archrealms.passport.canary_production_approval.v1"
        lane = "canary-mvp"
        production_approval_id = "canary-production-approval-synthetic"
        approve_production_mvp_release = $true
        product_approval_id = "canary-production-approval-synthetic"
        engineering_signoff_id = "canary-engineering-synthetic"
        security_privacy_signoff_id = "canary-security-synthetic"
        crown_monetary_authority_signoff_id = "canary-crown-synthetic"
        staging_readiness_report_sha256 = $stagingHash
        canary_artifact_validation_report_sha256 = $artifactHash
        canary_policy_report_sha256 = $policyHash
        canary_incident_review_report_sha256 = $incidentHash
        canary_balance_reconciliation_report_sha256 = $balanceHash
        canary_service_delivery_reconciliation_report_sha256 = $serviceHash
        canary_support_readiness_report_sha256 = $supportHash
        approval_notes = "synthetic"
    })
    $approvalHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $approvalPath).Hash.ToLowerInvariant()

    $fixtureEnvironment = @{
        ARCHREALMS_PASSPORT_STAGING_READINESS_REPORT_PATH = $stagingPath
        ARCHREALMS_PASSPORT_STAGING_READINESS_REPORT_SHA256 = $stagingHash
        ARCHREALMS_PASSPORT_CANARY_ARTIFACT_VALIDATION_REPORT_PATH = $artifactPath
        ARCHREALMS_PASSPORT_CANARY_ARTIFACT_VALIDATION_REPORT_SHA256 = $artifactHash
        ARCHREALMS_PASSPORT_CANARY_POLICY_ID = "canary-policy-synthetic"
        ARCHREALMS_PASSPORT_CANARY_POLICY_REPORT_PATH = $policyPath
        ARCHREALMS_PASSPORT_CANARY_POLICY_REPORT_SHA256 = $policyHash
        ARCHREALMS_PASSPORT_CANARY_INCIDENT_REVIEW_ID = "incident-review-synthetic"
        ARCHREALMS_PASSPORT_CANARY_INCIDENT_REVIEW_REPORT_PATH = $incidentPath
        ARCHREALMS_PASSPORT_CANARY_INCIDENT_REVIEW_REPORT_SHA256 = $incidentHash
        ARCHREALMS_PASSPORT_CANARY_BALANCE_RECONCILIATION_ID = "balance-reconciliation-synthetic"
        ARCHREALMS_PASSPORT_CANARY_BALANCE_RECONCILIATION_REPORT_PATH = $balancePath
        ARCHREALMS_PASSPORT_CANARY_BALANCE_RECONCILIATION_REPORT_SHA256 = $balanceHash
        ARCHREALMS_PASSPORT_CANARY_SERVICE_DELIVERY_RECONCILIATION_ID = "service-delivery-synthetic"
        ARCHREALMS_PASSPORT_CANARY_SERVICE_DELIVERY_RECONCILIATION_REPORT_PATH = $servicePath
        ARCHREALMS_PASSPORT_CANARY_SERVICE_DELIVERY_RECONCILIATION_REPORT_SHA256 = $serviceHash
        ARCHREALMS_PASSPORT_CANARY_SUPPORT_READINESS_ID = "support-readiness-synthetic"
        ARCHREALMS_PASSPORT_CANARY_SUPPORT_READINESS_REPORT_PATH = $supportPath
        ARCHREALMS_PASSPORT_CANARY_SUPPORT_READINESS_REPORT_SHA256 = $supportHash
        ARCHREALMS_PASSPORT_CANARY_PRODUCTION_APPROVAL_ID = "canary-production-approval-synthetic"
        ARCHREALMS_PASSPORT_CANARY_ENGINEERING_SIGNOFF_ID = "canary-engineering-synthetic"
        ARCHREALMS_PASSPORT_CANARY_SECURITY_PRIVACY_SIGNOFF_ID = "canary-security-synthetic"
        ARCHREALMS_PASSPORT_CANARY_CROWN_MONETARY_AUTHORITY_SIGNOFF_ID = "canary-crown-synthetic"
        ARCHREALMS_PASSPORT_CANARY_PRODUCTION_APPROVAL_RECORD_PATH = $approvalPath
        ARCHREALMS_PASSPORT_CANARY_PRODUCTION_APPROVAL_RECORD_SHA256 = $approvalHash
    }
    foreach ($entry in $fixtureEnvironment.GetEnumerator()) {
        [System.Environment]::SetEnvironmentVariable($entry.Key, $entry.Value, "Process")
    }

    $syntheticFixtures = [pscustomobject][ordered]@{
        root = $syntheticRoot
        files = $fixtureEnvironment
    }
}

$gates = @(
    New-Gate `
        -Id "staging_readiness" `
        -Description "Staging has passed with a non-synthetic report before Canary MVP promotion review." `
        -RequiredEnvironment @("ARCHREALMS_PASSPORT_STAGING_READINESS_REPORT_PATH", "ARCHREALMS_PASSPORT_STAGING_READINESS_REPORT_SHA256") `
        -ExtraCheck ${function:Test-StagingReadiness}

    New-Gate `
        -Id "canary_package_artifact" `
        -Description "A CanaryMvp release artifact has passed artifact validation and is production-ledger capable." `
        -RequiredEnvironment @("ARCHREALMS_PASSPORT_CANARY_ARTIFACT_VALIDATION_REPORT_PATH", "ARCHREALMS_PASSPORT_CANARY_ARTIFACT_VALIDATION_REPORT_SHA256") `
        -ExtraCheck ${function:Test-CanaryArtifact}

    New-Gate `
        -Id "canary_policy_limits" `
        -Description "Canary MVP policy limits are approved, allowlisted, and prohibit non-MVP token behavior." `
        -RequiredEnvironment @("ARCHREALMS_PASSPORT_CANARY_POLICY_ID", "ARCHREALMS_PASSPORT_CANARY_POLICY_REPORT_PATH", "ARCHREALMS_PASSPORT_CANARY_POLICY_REPORT_SHA256") `
        -ExtraCheck ${function:Test-CanaryPolicy}

    New-Gate `
        -Id "canary_incident_review" `
        -Description "Canary incidents have been reviewed and critical/high incidents are resolved before production promotion." `
        -RequiredEnvironment @("ARCHREALMS_PASSPORT_CANARY_INCIDENT_REVIEW_ID", "ARCHREALMS_PASSPORT_CANARY_INCIDENT_REVIEW_REPORT_PATH", "ARCHREALMS_PASSPORT_CANARY_INCIDENT_REVIEW_REPORT_SHA256") `
        -ExtraCheck ${function:Test-CanaryIncidentReview}

    New-Gate `
        -Id "canary_balance_reconciliation" `
        -Description "Canary ARCH, CC, escrow, burn, refund, re-credit, and Crown reserve balances reconcile." `
        -RequiredEnvironment @("ARCHREALMS_PASSPORT_CANARY_BALANCE_RECONCILIATION_ID", "ARCHREALMS_PASSPORT_CANARY_BALANCE_RECONCILIATION_REPORT_PATH", "ARCHREALMS_PASSPORT_CANARY_BALANCE_RECONCILIATION_REPORT_SHA256") `
        -ExtraCheck ${function:Test-CanaryBalanceReconciliation}

    New-Gate `
        -Id "canary_service_delivery_reconciliation" `
        -Description "Canary storage redemption, proof, burn, refund, re-credit, and extension records reconcile to service delivery." `
        -RequiredEnvironment @("ARCHREALMS_PASSPORT_CANARY_SERVICE_DELIVERY_RECONCILIATION_ID", "ARCHREALMS_PASSPORT_CANARY_SERVICE_DELIVERY_RECONCILIATION_REPORT_PATH", "ARCHREALMS_PASSPORT_CANARY_SERVICE_DELIVERY_RECONCILIATION_REPORT_SHA256") `
        -ExtraCheck ${function:Test-CanaryServiceDeliveryReconciliation}

    New-Gate `
        -Id "canary_support_readiness" `
        -Description "Canary support, recovery support, escalation path, and support access controls are ready for Production MVP." `
        -RequiredEnvironment @("ARCHREALMS_PASSPORT_CANARY_SUPPORT_READINESS_ID", "ARCHREALMS_PASSPORT_CANARY_SUPPORT_READINESS_REPORT_PATH", "ARCHREALMS_PASSPORT_CANARY_SUPPORT_READINESS_REPORT_SHA256") `
        -ExtraCheck ${function:Test-CanarySupportReadiness}

    New-Gate `
        -Id "canary_production_approvals" `
        -Description "Product, engineering, security/privacy, and Crown monetary authority approved Canary MVP promotion to Production MVP." `
        -RequiredEnvironment @(
            "ARCHREALMS_PASSPORT_CANARY_PRODUCTION_APPROVAL_ID",
            "ARCHREALMS_PASSPORT_CANARY_ENGINEERING_SIGNOFF_ID",
            "ARCHREALMS_PASSPORT_CANARY_SECURITY_PRIVACY_SIGNOFF_ID",
            "ARCHREALMS_PASSPORT_CANARY_CROWN_MONETARY_AUTHORITY_SIGNOFF_ID",
            "ARCHREALMS_PASSPORT_CANARY_PRODUCTION_APPROVAL_RECORD_PATH",
            "ARCHREALMS_PASSPORT_CANARY_PRODUCTION_APPROVAL_RECORD_SHA256"
        ) `
        -ExtraCheck ${function:Test-CanaryProductionApprovals}
)

$failed = @($gates | Where-Object { -not $_.passed })
$report = [pscustomobject][ordered]@{
    schema = "archrealms.passport.canary_mvp_readiness.v1"
    created_utc = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
    repo_root = $repoRoot
    lane = "canary-mvp"
    canary_is_mvp = $true
    production_release_approved = ($failed.Count -eq 0 -and -not [bool]$UseSyntheticFixtures)
    environment_file_loaded = -not [string]::IsNullOrWhiteSpace($EnvironmentFile)
    environment_file_variable_count = $loadedEnvironmentVariables.Count
    environment_file_variables = @($loadedEnvironmentVariables)
    synthetic_fixtures_used = [bool]$UseSyntheticFixtures
    synthetic_fixtures = $syntheticFixtures
    ready = ($failed.Count -eq 0)
    failed_gate_count = $failed.Count
    gates = $gates
}

$json = $report | ConvertTo-Json -Depth 10
if ($OutputPath) {
    $resolvedOutputPath = [System.IO.Path]::GetFullPath($OutputPath)
    $outputDirectory = Split-Path -Parent $resolvedOutputPath
    if ($outputDirectory) {
        New-Item -ItemType Directory -Force -Path $outputDirectory | Out-Null
    }

    Set-Content -LiteralPath $resolvedOutputPath -Value $json -Encoding UTF8
}

$json
if ($failed.Count -gt 0 -and -not $NoFail) {
    throw "Canary MVP readiness failed. Missing gates: " + (($failed | ForEach-Object { $_.id }) -join ", ")
}

