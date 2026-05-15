param(
    [string]$PackageSigningPath = "deploy\package-signing",

    [string]$OutputPath = "artifacts\release\package-signing-provisioning-validation-report.json",

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

$resolvedPackageSigningPath = Resolve-InputPath -Path $PackageSigningPath
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

$readmePath = Join-Path $resolvedPackageSigningPath "README.md"
$signingRequestPath = Join-Path $resolvedPackageSigningPath "production-msix-signing-request.template.md"
$sideloadPolicyPath = Join-Path $resolvedPackageSigningPath "sideload-trust-policy.template.md"
$storePolicyPath = Join-Path $resolvedPackageSigningPath "store-signing-policy.template.md"

$checks = @()
$checks += Test-Document -Id "readme_contract" -Path $readmePath -RequiredText @(
    "PASSPORT_WINDOWS_MSIX_PFX_BASE64",
    "PASSPORT_WINDOWS_MSIX_PFX_PATH",
    "PASSPORT_WINDOWS_MSIX_PFX_PASSWORD",
    "PASSPORT_WINDOWS_MSIX_PUBLISHER",
    "PASSPORT_WINDOWS_MSIX_TIMESTAMP_URL",
    "Test-PassportWindowsSigningCertificate.ps1"
)
$checks += Test-Document -Id "production_msix_signing_request_contract" -Path $signingRequestPath -RequiredText @(
    "PASSPORT_WINDOWS_MSIX_PUBLISHER",
    "PASSPORT_WINDOWS_MSIX_TIMESTAMP_URL",
    "Code Signing",
    "1.3.6.1.5.5.7.3.3",
    "publisher-subject match",
    "Test-PassportWindowsSigningCertificate.ps1"
)
$checks += Test-Document -Id "sideload_trust_policy_contract" -Path $sideloadPolicyPath -RequiredText @(
    "controlled sideload",
    "self-signed",
    ".cer",
    "certificate thumbprint",
    "msix-package-manifest.json",
    "production-signing-certificate-report.json"
)
$checks += Test-Document -Id "store_signing_policy_contract" -Path $storePolicyPath -RequiredText @(
    "Microsoft Store",
    "Partner Center",
    "ProductionMvp",
    "Channel Store",
    "Store metadata approval",
    "production readiness report"
)

$failed = @($checks | Where-Object { -not $_.passed })
$report = [pscustomobject][ordered]@{
    schema = "archrealms.passport.package_signing_provisioning_validation.v1"
    created_utc = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
    package_signing_path = $resolvedPackageSigningPath
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
