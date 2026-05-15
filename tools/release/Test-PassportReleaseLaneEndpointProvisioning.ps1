param(
    [string]$EndpointProvisioningPath = "deploy\release-lane-endpoints",

    [string]$OutputPath = "artifacts\release\release-lane-endpoint-provisioning-validation-report.json",

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

$resolvedEndpointProvisioningPath = Resolve-InputPath -Path $EndpointProvisioningPath
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

$readmePath = Join-Path $resolvedEndpointProvisioningPath "README.md"
$endpointRequestPath = Join-Path $resolvedEndpointProvisioningPath "production-endpoint-request.template.md"
$routingPolicyPath = Join-Path $resolvedEndpointProvisioningPath "tls-dns-routing-policy.template.md"
$readinessEvidencePath = Join-Path $resolvedEndpointProvisioningPath "endpoint-readiness-evidence.template.md"

$checks = @()
$checks += Test-Document -Id "readme_contract" -Path $readmePath -RequiredText @(
    "PASSPORT_WINDOWS_PRODUCTION_MVP_API_BASE_URL",
    "PASSPORT_WINDOWS_PRODUCTION_MVP_AI_GATEWAY_URL",
    "ARCHREALMS_PASSPORT_HOSTED_OPERATOR_API_KEY_SHA256",
    "Test-PassportProductionMvpReadiness.ps1",
    "/ops/runtime/status",
    "/ai/runtime/probe"
)
$checks += Test-Document -Id "production_endpoint_request_contract" -Path $endpointRequestPath -RequiredText @(
    "PASSPORT_WINDOWS_PRODUCTION_MVP_API_BASE_URL",
    "PASSPORT_WINDOWS_PRODUCTION_MVP_AI_GATEWAY_URL",
    "X-Archrealms-Operator-Key",
    "/ops/storage/status",
    "/arch/genesis/manifests",
    "/capacity/reports/cc",
    "/ai/session",
    "/ai/chat"
)
$checks += Test-Document -Id "tls_dns_routing_policy_contract" -Path $routingPolicyPath -RequiredText @(
    "Production endpoint URLs must use HTTPS",
    "Loopback HTTP",
    "PASSPORT_WINDOWS_PRODUCTION_MVP_API_BASE_URL",
    "PASSPORT_WINDOWS_PRODUCTION_MVP_AI_GATEWAY_URL",
    "Operator routes must not be cached",
    "telemetry-retention policy"
)
$checks += Test-Document -Id "endpoint_readiness_evidence_contract" -Path $readinessEvidencePath -RequiredText @(
    "release_lane_endpoints",
    "hosted_runtime_status",
    "hosted_operator_status",
    "managed_storage_status",
    "hosted_ai_runtime_probe",
    "runtime_answer_received=true",
    "ready=true"
)

$failed = @($checks | Where-Object { -not $_.passed })
$report = [pscustomobject][ordered]@{
    schema = "archrealms.passport.release_lane_endpoint_provisioning_validation.v1"
    created_utc = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
    endpoint_provisioning_path = $resolvedEndpointProvisioningPath
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
