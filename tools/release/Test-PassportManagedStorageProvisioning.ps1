param(
    [string]$ManagedStoragePath = "deploy\managed-storage",

    [string]$OutputPath = "artifacts\release\managed-storage-provisioning-validation-report.json",

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

$resolvedManagedStoragePath = Resolve-InputPath -Path $ManagedStoragePath
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

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return New-Check -Id $Id -Passed $false -Failures @("missing file: $Path") -Evidence @{ path = $Path }
    }

    $text = Get-Content -LiteralPath $Path -Raw
    $failures = @()
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

$readmePath = Join-Path $resolvedManagedStoragePath "README.md"
$provisioningRecordPath = Join-Path $resolvedManagedStoragePath "managed-storage-provisioning-record.template.md"
$backupSchedulePath = Join-Path $resolvedManagedStoragePath "backup-manifest-schedule.template.md"
$readinessEvidencePath = Join-Path $resolvedManagedStoragePath "storage-readiness-evidence.template.md"

$checks = @()
$checks += Test-Document -Id "readme_contract" -Path $readmePath -RequiredText @(
    "ARCHREALMS_PASSPORT_HOSTED_DATA_ROOT",
    "ARCHREALMS_PASSPORT_HOSTED_STORAGE_PROVIDER",
    "ARCHREALMS_PASSPORT_HOSTED_STORAGE_BACKUP_POLICY_URI",
    "ARCHREALMS_PASSPORT_HOSTED_STORAGE_RESTORE_RUNBOOK_URI",
    "/ops/storage/status",
    "POST /ops/backup/manifests"
)
$checks += Test-Document -Id "managed_storage_provisioning_record_contract" -Path $provisioningRecordPath -RequiredText @(
    "ARCHREALMS_PASSPORT_HOSTED_DATA_ROOT",
    "ARCHREALMS_PASSPORT_HOSTED_STORAGE_PROVIDER",
    "records/",
    "append-log/",
    "private key material",
    "raw AI prompts",
    "managed_storage_backups",
    "managed_storage_status"
)
$checks += Test-Document -Id "backup_manifest_schedule_contract" -Path $backupSchedulePath -RequiredText @(
    "ARCHREALMS_PASSPORT_HOSTED_STORAGE_BACKUP_POLICY_URI",
    "ARCHREALMS_PASSPORT_HOSTED_STORAGE_RESTORE_RUNBOOK_URI",
    "POST /ops/backup/manifests",
    "records/",
    "append-log/",
    "private key material",
    "raw AI prompts",
    "ARCHREALMS_PASSPORT_INCIDENT_RESPONSE_RUNBOOK_URI"
)
$checks += Test-Document -Id "storage_readiness_evidence_contract" -Path $readinessEvidencePath -RequiredText @(
    "Test-PassportProductionMvpReadiness.ps1",
    "managed_storage_backups",
    "managed_storage_status",
    "backup_manifest_enumerable",
    "POST /ops/backup/manifests",
    "manifest root SHA-256",
    "storage payload contents"
)

$failed = @($checks | Where-Object { -not $_.passed })
$report = [pscustomobject][ordered]@{
    schema = "archrealms.passport.managed_storage_provisioning_validation.v1"
    created_utc = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
    managed_storage_path = $resolvedManagedStoragePath
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
