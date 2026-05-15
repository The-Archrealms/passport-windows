param(
    [string]$CanaryReadinessPath = "deploy\canary-readiness",

    [string]$OutputPath = "artifacts\release\canary-readiness-provisioning-validation-report.json",

    [switch]$RequireNoPlaceholders
)

$ErrorActionPreference = "Stop"

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $scriptRoot "..\.."))

function Resolve-InputPath {
    param([string]$Path)

    if ([System.IO.Path]::IsPathRooted($Path)) {
        return [System.IO.Path]::GetFullPath($Path)
    }

    return [System.IO.Path]::GetFullPath((Join-Path $repoRoot $Path))
}

function New-Check {
    param(
        [string]$Id,
        [bool]$Passed,
        [string[]]$Failures = @(),
        [object]$Evidence = $null
    )

    return [pscustomobject][ordered]@{
        id = $Id
        passed = $Passed
        failures = @($Failures | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        evidence = $Evidence
    }
}

function Test-Document {
    param(
        [string]$Id,
        [string]$Path,
        [string[]]$RequiredText
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return New-Check -Id $Id -Passed $false -Failures @("missing file: $Path") -Evidence @{ path = $Path }
    }

    $failures = @()
    $text = Get-Content -LiteralPath $Path -Raw
    foreach ($required in $RequiredText) {
        if ($text.IndexOf($required, [StringComparison]::OrdinalIgnoreCase) -lt 0) {
            $failures += "missing required text: $required"
        }
    }

    if ($RequireNoPlaceholders -and $text -match '<[^>\r\n]+>') {
        $failures += "placeholder values remain in $Path"
    }

    return New-Check -Id $Id -Passed ($failures.Count -eq 0) -Failures $failures -Evidence @{ path = $Path }
}

function Read-JsonFile {
    param(
        [string]$Id,
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return [pscustomobject][ordered]@{
            document = $null
            check = New-Check -Id $Id -Passed $false -Failures @("missing file: $Path") -Evidence @{ path = $Path }
        }
    }

    try {
        return [pscustomobject][ordered]@{
            document = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
            check = $null
        }
    }
    catch {
        return [pscustomobject][ordered]@{
            document = $null
            check = New-Check -Id $Id -Passed $false -Failures @("invalid JSON in ${Path}: $($_.Exception.Message)") -Evidence @{ path = $Path }
        }
    }
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

function Test-JsonTemplate {
    param(
        [string]$Id,
        [string]$Path,
        [string]$ExpectedSchema,
        [string[]]$RequiredFields,
        [string[]]$RequiredTrueFields = @(),
        [string[]]$RequiredFalseFields = @(),
        [string[]]$RequiredZeroFields = @(),
        [string[]]$RequiredPositiveFields = @(),
        [scriptblock]$ExtraCheck = $null
    )

    $read = Read-JsonFile -Id $Id -Path $Path
    if ($null -ne $read.check) {
        return $read.check
    }

    $doc = $read.document
    $failures = @()
    if ((Read-ObjectString -Object $doc -Name "schema") -ne $ExpectedSchema) {
        $failures += "schema must be $ExpectedSchema"
    }
    if ((Read-ObjectString -Object $doc -Name "lane") -ne "canary-mvp") {
        $failures += "lane must be canary-mvp"
    }

    foreach ($field in $RequiredFields) {
        if (-not $doc.PSObject.Properties[$field]) {
            $failures += "missing required field: $field"
            continue
        }

        $value = Read-ObjectString -Object $doc -Name $field
        if ([string]::IsNullOrWhiteSpace($value) -and -not ($doc.$field -is [bool]) -and -not ($doc.$field -is [int])) {
            $failures += "required field is empty: $field"
        }
    }

    foreach ($field in $RequiredTrueFields) {
        if (-not (Read-ObjectBool -Object $doc -Name $field)) {
            $failures += "$field must be true"
        }
    }

    foreach ($field in $RequiredFalseFields) {
        if (Read-ObjectBool -Object $doc -Name $field) {
            $failures += "$field must be false"
        }
    }

    foreach ($field in $RequiredZeroFields) {
        if ((Read-ObjectInt -Object $doc -Name $field) -ne 0) {
            $failures += "$field must be zero"
        }
    }

    foreach ($field in $RequiredPositiveFields) {
        if ((Read-ObjectInt -Object $doc -Name $field) -le 0) {
            $failures += "$field must be greater than zero"
        }
    }

    if ($ExtraCheck) {
        $extraFailures = @(& $ExtraCheck $doc)
        foreach ($failure in $extraFailures) {
            if ($failure) {
                $failures += $failure
            }
        }
    }

    if ($RequireNoPlaceholders) {
        $text = Get-Content -LiteralPath $Path -Raw
        if ($text -match '<[^>\r\n]+>') {
            $failures += "placeholder values remain in $Path"
        }
    }

    return New-Check -Id $Id -Passed ($failures.Count -eq 0) -Failures $failures -Evidence @{ path = $Path }
}

$resolvedCanaryReadinessPath = Resolve-InputPath -Path $CanaryReadinessPath
$resolvedOutput = Resolve-InputPath -Path $OutputPath

$templates = [ordered]@{
    readme = Join-Path $resolvedCanaryReadinessPath "README.md"
    policy = Join-Path $resolvedCanaryReadinessPath "canary-policy.template.json"
    incident_review = Join-Path $resolvedCanaryReadinessPath "canary-incident-review.template.json"
    balance_reconciliation = Join-Path $resolvedCanaryReadinessPath "canary-balance-reconciliation.template.json"
    service_delivery_reconciliation = Join-Path $resolvedCanaryReadinessPath "canary-service-delivery-reconciliation.template.json"
    support_readiness = Join-Path $resolvedCanaryReadinessPath "canary-support-readiness.template.json"
    production_approval = Join-Path $resolvedCanaryReadinessPath "canary-production-approval-record.template.json"
}

$checks = @()
$checks += Test-Document -Id "readme_contract" -Path $templates.readme -RequiredText @(
    "Test-PassportCanaryMvpReadiness.ps1",
    "Canary MVP is the first citizen-facing real-token lane",
    "ProductionMvp readiness rejects synthetic canary reports",
    "signed product, engineering, security/privacy, and Crown monetary authority approval"
)

$checks += Test-JsonTemplate -Id "policy_template_contract" -Path $templates.policy `
    -ExpectedSchema "archrealms.passport.canary_policy.v1" `
    -RequiredFields @("created_utc", "policy_id", "production_ledger_namespace", "allowed_service_classes", "support_owner", "incident_response_owner", "rollback_policy_id", "evidence_refs") `
    -RequiredTrueFields @("production_intended", "production_ledger", "allowlisted_citizens_only") `
    -RequiredFalseFields @("external_wallet_transfers_enabled", "fiat_rails_enabled", "unrestricted_cc_payments_enabled", "guaranteed_conversion_claims_enabled", "stable_value_claims_enabled", "yield_or_staking_enabled", "token_governance_enabled") `
    -RequiredPositiveFields @("max_citizens", "max_arch_per_citizen_base_units", "max_cc_outstanding_base_units", "max_conversion_quote_base_units") `
    -ExtraCheck {
        param($doc)
        $failures = @()
        if (@($doc.allowed_service_classes).Count -lt 1) {
            $failures += "allowed_service_classes must contain at least one service class"
        }
        return $failures
    }

$checks += Test-JsonTemplate -Id "incident_review_template_contract" -Path $templates.incident_review `
    -ExpectedSchema "archrealms.passport.canary_incident_review.v1" `
    -RequiredFields @("created_utc", "incident_review_id", "incident_response_owner", "incident_count", "evidence_refs") `
    -RequiredTrueFields @("completed", "incident_review_completed", "no_unresolved_critical_incidents", "no_unresolved_high_incidents") `
    -RequiredZeroFields @("unresolved_critical_incident_count", "unresolved_high_incident_count")

$checks += Test-JsonTemplate -Id "balance_reconciliation_template_contract" -Path $templates.balance_reconciliation `
    -ExpectedSchema "archrealms.passport.canary_balance_reconciliation.v1" `
    -RequiredFields @("created_utc", "balance_reconciliation_id", "production_ledger_namespace", "evidence_refs") `
    -RequiredTrueFields @("completed", "arch_balances_reconciled", "cc_balances_reconciled", "escrow_reconciled", "burn_refund_recredit_reconciled", "crown_reserve_reconciled", "no_negative_balances", "no_unapproved_issuance", "no_staging_records_detected")

$checks += Test-JsonTemplate -Id "service_delivery_reconciliation_template_contract" -Path $templates.service_delivery_reconciliation `
    -ExpectedSchema "archrealms.passport.canary_service_delivery_reconciliation.v1" `
    -RequiredFields @("created_utc", "service_delivery_reconciliation_id", "evidence_refs") `
    -RequiredTrueFields @("completed", "service_delivery_reconciled", "storage_redemptions_reconciled", "storage_proofs_reconciled", "burns_match_verified_epochs", "refunds_recredits_extensions_reconciled") `
    -RequiredZeroFields @("unresolved_failed_epoch_count")

$checks += Test-JsonTemplate -Id "support_readiness_template_contract" -Path $templates.support_readiness `
    -ExpectedSchema "archrealms.passport.canary_support_readiness.v1" `
    -RequiredFields @("created_utc", "support_readiness_id", "support_owner", "incident_response_owner", "evidence_refs") `
    -RequiredTrueFields @("completed", "support_ready", "support_queue_reviewed", "recovery_support_ready", "escalation_path_ready", "support_access_controls_validated")

$checks += Test-JsonTemplate -Id "production_approval_template_contract" -Path $templates.production_approval `
    -ExpectedSchema "archrealms.passport.canary_production_approval.v1" `
    -RequiredFields @(
        "created_utc",
        "production_approval_id",
        "product_approval_id",
        "engineering_signoff_id",
        "security_privacy_signoff_id",
        "crown_monetary_authority_signoff_id",
        "staging_readiness_report_sha256",
        "canary_artifact_validation_report_sha256",
        "canary_policy_report_sha256",
        "canary_incident_review_report_sha256",
        "canary_balance_reconciliation_report_sha256",
        "canary_service_delivery_reconciliation_report_sha256",
        "canary_support_readiness_report_sha256",
        "approval_notes"
    ) `
    -RequiredTrueFields @("approve_production_mvp_release")

$failed = @($checks | Where-Object { -not $_.passed })
$report = [pscustomobject][ordered]@{
    schema = "archrealms.passport.canary_readiness_provisioning_validation.v1"
    created_utc = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
    canary_readiness_path = $resolvedCanaryReadinessPath
    require_no_placeholders = [bool]$RequireNoPlaceholders
    passed = $failed.Count -eq 0
    failed_check_count = $failed.Count
    checks = $checks
}

$parent = Split-Path -Parent $resolvedOutput
if ($parent) {
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
}

$json = $report | ConvertTo-Json -Depth 8
Set-Content -LiteralPath $resolvedOutput -Value $json -Encoding UTF8
$json

if ($failed.Count -gt 0) {
    exit 1
}
