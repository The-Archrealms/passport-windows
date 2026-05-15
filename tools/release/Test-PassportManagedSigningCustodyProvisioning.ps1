param(
    [string]$ManagedSigningCustodyPath = "deploy\managed-signing-custody",

    [string]$OutputPath = "artifacts\release\managed-signing-custody-provisioning-validation-report.json",

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

$resolvedManagedSigningCustodyPath = Resolve-InputPath -Path $ManagedSigningCustodyPath
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

$readmePath = Join-Path $resolvedManagedSigningCustodyPath "README.md"
$custodyRequestPath = Join-Path $resolvedManagedSigningCustodyPath "key-custody-request.template.md"
$endpointPolicyPath = Join-Path $resolvedManagedSigningCustodyPath "signing-endpoint-production-policy.template.md"
$readinessEvidencePath = Join-Path $resolvedManagedSigningCustodyPath "signing-readiness-evidence.template.md"

$checks = @()
$checks += Test-Document -Id "readme_contract" -Path $readmePath -RequiredText @(
    "ARCHREALMS_PASSPORT_HOSTED_SIGNING_KEY_PROVIDER",
    "ARCHREALMS_PASSPORT_HOSTED_SIGNING_KEY_ID",
    "ARCHREALMS_PASSPORT_HOSTED_SIGNING_KEY_CUSTODY",
    "ARCHREALMS_PASSPORT_HOSTED_SIGNING_ENDPOINT",
    "local_validation_only = false",
    "Test-PassportProductionMvpReadiness.ps1"
)
$checks += Test-Document -Id "key_custody_request_contract" -Path $custodyRequestPath -RequiredText @(
    "ARCHREALMS_PASSPORT_HOSTED_SIGNING_KEY_PROVIDER",
    "ARCHREALMS_PASSPORT_HOSTED_SIGNING_KEY_ID",
    "ARCHREALMS_PASSPORT_HOSTED_SIGNING_KEY_CUSTODY",
    "managed-hsm",
    "cloud-kms",
    "private key material",
    "production_mvp_readiness_probe",
    "managed-signing-deployment-validation-report.json"
)
$checks += Test-Document -Id "signing_endpoint_policy_contract" -Path $endpointPolicyPath -RequiredText @(
    "ARCHREALMS_PASSPORT_HOSTED_SIGNING_ENDPOINT",
    "HTTPS",
    "X-Archrealms-Managed-Signing-Key",
    "RSA_PKCS1_SHA256",
    "local_validation_only=false",
    "ARCHREALMS_PASSPORT_INCIDENT_RESPONSE_RUNBOOK_URI",
    "telemetry-retention policy"
)
$checks += Test-Document -Id "signing_readiness_evidence_contract" -Path $readinessEvidencePath -RequiredText @(
    "managed_signing_key_custody",
    "managed_signing_endpoint_probe",
    "RSA_PKCS1_SHA256",
    "public_key_sha256",
    "signing_key_provider",
    "signing_key_id",
    "signing_key_custody",
    "local_validation_only=false"
)

$failed = @($checks | Where-Object { -not $_.passed })
$report = [pscustomobject][ordered]@{
    schema = "archrealms.passport.managed_signing_custody_provisioning_validation.v1"
    created_utc = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
    managed_signing_custody_path = $resolvedManagedSigningCustodyPath
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
