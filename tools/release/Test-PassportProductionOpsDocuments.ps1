param(
    [string]$ProductionOpsPath = "deploy\production-ops",

    [string]$OutputPath = "artifacts\release\production-ops-documents-validation-report.json",

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

$resolvedOpsPath = Resolve-InputPath -Path $ProductionOpsPath
$resolvedOutput = Resolve-InputPath -Path $OutputPath

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

    $failures = @()
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return New-Check -Id $Id -Passed $false -Failures @("missing file: $Path") -Evidence @{ path = $Path }
    }

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

$documents = [ordered]@{
    backup_policy = Join-Path $resolvedOpsPath "backup-policy.template.md"
    restore_runbook = Join-Path $resolvedOpsPath "restore-runbook.template.md"
    telemetry_retention_policy = Join-Path $resolvedOpsPath "telemetry-retention-policy.template.md"
    incident_response_runbook = Join-Path $resolvedOpsPath "incident-response-runbook.template.md"
    release_approval_record = Join-Path $resolvedOpsPath "release-approval-record.template.md"
}

$checks = @()
$checks += Test-Document -Id "backup_policy_contract" -Path $documents.backup_policy -RequiredText @(
    "ARCHREALMS_PASSPORT_HOSTED_STORAGE_BACKUP_POLICY_URI",
    "ARCHREALMS_PASSPORT_HOSTED_DATA_ROOT",
    "POST /ops/backup/manifests",
    "Recovery point objective",
    "Recovery time objective",
    "restore validation"
)
$checks += Test-Document -Id "restore_runbook_contract" -Path $documents.restore_runbook -RequiredText @(
    "ARCHREALMS_PASSPORT_HOSTED_STORAGE_RESTORE_RUNBOOK_URI",
    "/ops/storage/status",
    "/ops/runtime/status",
    "records/",
    "append-log/",
    "Rollback"
)
$checks += Test-Document -Id "telemetry_retention_contract" -Path $documents.telemetry_retention_policy -RequiredText @(
    "ARCHREALMS_PASSPORT_TELEMETRY_RETENTION_POLICY_URI",
    "raw AI prompts",
    "not retained by default",
    "no-training",
    "metadata-only",
    "telemetry_access"
)
$checks += Test-Document -Id "incident_response_contract" -Path $documents.incident_response_runbook -RequiredText @(
    "ARCHREALMS_PASSPORT_INCIDENT_RESPONSE_RUNBOOK_URI",
    "ARCHREALMS_PASSPORT_INCIDENT_RESPONSE_OWNER",
    "Key Compromise",
    "Hosted Storage Failure",
    "Ledger Or Issuance Error",
    "AI Privacy"
)
$checks += Test-Document -Id "release_approvals_contract" -Path $documents.release_approval_record -RequiredText @(
    "ARCHREALMS_PASSPORT_PRODUCTION_RELEASE_APPROVAL_ID",
    "ARCHREALMS_PASSPORT_ENGINEERING_SIGNOFF_ID",
    "ARCHREALMS_PASSPORT_SECURITY_PRIVACY_SIGNOFF_ID",
    "ARCHREALMS_PASSPORT_CROWN_MONETARY_AUTHORITY_SIGNOFF_ID",
    "Production readiness gate returned"
)

$failed = @($checks | Where-Object { -not $_.passed })
$report = [pscustomobject][ordered]@{
    schema = "archrealms.passport.production_ops_documents_validation.v1"
    created_utc = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
    production_ops_path = $resolvedOpsPath
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
