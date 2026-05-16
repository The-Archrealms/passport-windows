param(
    [string]$ProductionMonetaryPath = "deploy\production-monetary",

    [string]$OutputPath = "artifacts\release\production-monetary-provisioning-validation-report.json",

    [switch]$RequireNoPlaceholders,

    [switch]$CreateHostedRecords,

    [string]$HostedApiBaseUrl = $env:PASSPORT_WINDOWS_PRODUCTION_MVP_API_BASE_URL,

    [string]$OperatorKey = $env:ARCHREALMS_PASSPORT_HOSTED_OPERATOR_API_KEY,

    [int]$EndpointTimeoutSeconds = 20
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

$resolvedMonetaryPath = Resolve-InputPath -Path $ProductionMonetaryPath
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

function Test-TextDocument {
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

function Read-JsonObject {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "missing file: $Path"
    }

    return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
}

function Test-NoPlaceholders {
    param(
        [string]$Path,
        [string[]]$Failures
    )

    if (-not $RequireNoPlaceholders) {
        return $Failures
    }

    $text = Get-Content -LiteralPath $Path -Raw
    if ($text -match '<[^>\r\n]+>') {
        $Failures += "placeholder values remain in $Path"
    }

    return ,$Failures
}

function Test-HexSha256 {
    param([string]$Value)

    return -not [string]::IsNullOrWhiteSpace($Value) -and $Value.Trim() -match '^[0-9a-fA-F]{64}$'
}

function Test-ArchGenesisRequest {
    param([string]$Path)

    $failures = @()
    $request = $null
    try {
        $request = Read-JsonObject -Path $Path
    }
    catch {
        return New-Check -Id "arch_genesis_request_contract" -Passed $false -Failures @($_.Exception.Message) -Evidence @{ path = $Path }
    }

    $failures = Test-NoPlaceholders -Path $Path -Failures $failures
    if ($request.release_lane -ne "production-mvp") {
        $failures += "release_lane must be production-mvp"
    }
    if ([string]::IsNullOrWhiteSpace([string]$request.ledger_namespace)) {
        $failures += "ledger_namespace is required"
    }
    if ([string]::IsNullOrWhiteSpace([string]$request.policy_version)) {
        $failures += "policy_version is required"
    }
    if ([int64]$request.total_supply_base_units -le 0) {
        $failures += "total_supply_base_units must be greater than zero"
    }
    if ([int]$request.base_unit_precision -lt 0 -or [int]$request.base_unit_precision -gt 18) {
        $failures += "base_unit_precision must be between 0 and 18"
    }
    if ($RequireNoPlaceholders -and -not (Test-HexSha256 -Value ([string]$request.genesis_authority_record_sha256))) {
        $failures += "genesis_authority_record_sha256 must be a SHA-256 hex string"
    }
    foreach ($field in @("allocation_policy_sha256", "vesting_lock_policy_sha256", "treasury_policy_sha256", "genesis_ledger_hash_sha256")) {
        if ($RequireNoPlaceholders -and -not (Test-HexSha256 -Value ([string]$request.$field))) {
            $failures += "$field must be a SHA-256 hex string"
        }
        elseif ([string]::IsNullOrWhiteSpace([string]$request.$field)) {
            $failures += "$field is required"
        }
    }

    $allocations = @($request.allocations)
    if ($allocations.Count -eq 0) {
        $failures += "allocations must not be empty"
    }

    $allocationIds = @{}
    [int64]$allocationTotal = 0
    foreach ($allocation in $allocations) {
        $allocationId = [string]$allocation.allocation_id
        if ([string]::IsNullOrWhiteSpace($allocationId)) {
            $failures += "allocation_id is required"
        }
        elseif ($allocationIds.ContainsKey($allocationId)) {
            $failures += "allocation IDs must be unique: $allocationId"
        }
        else {
            $allocationIds[$allocationId] = $true
        }

        foreach ($field in @("account_id", "archrealms_identity_id", "wallet_key_id")) {
            if ([string]::IsNullOrWhiteSpace([string]$allocation.$field)) {
                $failures += "$field is required for allocation $allocationId"
            }
        }
        foreach ($field in @("allocation_bucket", "vesting_lock_rule_id")) {
            if ([string]::IsNullOrWhiteSpace([string]$allocation.$field)) {
                $failures += "$field is required for allocation $allocationId"
            }
        }

        $amount = [int64]$allocation.amount_base_units
        if ($amount -le 0) {
            $failures += "amount_base_units must be greater than zero for allocation $allocationId"
        }
        $allocationTotal += $amount
    }

    if ($allocationTotal -ne [int64]$request.total_supply_base_units) {
        $failures += "allocation total must equal total_supply_base_units"
    }

    return New-Check -Id "arch_genesis_request_contract" -Passed ($failures.Count -eq 0) -Failures $failures -Evidence @{
        path = $Path
        allocation_count = $allocations.Count
        total_supply_base_units = [int64]$request.total_supply_base_units
    }
}

function Test-CcCapacityRequest {
    param([string]$Path)

    $failures = @()
    $request = $null
    try {
        $request = Read-JsonObject -Path $Path
    }
    catch {
        return New-Check -Id "cc_capacity_request_contract" -Passed $false -Failures @($_.Exception.Message) -Evidence @{ path = $Path }
    }

    $failures = Test-NoPlaceholders -Path $Path -Failures $failures
    if ($request.release_lane -ne "production-mvp") {
        $failures += "release_lane must be production-mvp"
    }
    if ([string]::IsNullOrWhiteSpace([string]$request.ledger_namespace)) {
        $failures += "ledger_namespace is required"
    }
    if ([string]::IsNullOrWhiteSpace([string]$request.policy_version)) {
        $failures += "policy_version is required"
    }
    if ([int64]$request.conservative_service_liability_capacity_base_units -le 0) {
        $failures += "conservative_service_liability_capacity_base_units must be greater than zero"
    }
    if ([int64]$request.outstanding_cc_before_base_units -lt 0 -or [int64]$request.max_issuance_base_units -lt 0) {
        $failures += "outstanding_cc_before_base_units and max_issuance_base_units cannot be negative"
    }
    if ([int]$request.capacity_haircut_basis_points -lt 0 -or [int]$request.capacity_haircut_basis_points -gt 10000) {
        $failures += "capacity_haircut_basis_points must be between 0 and 10000"
    }
    if ($request.independent_volume_qualified -ne $true) {
        $failures += "independent_volume_qualified must be true for production issuance capacity"
    }
    if ($request.thin_market_issuance_zero -eq $true) {
        $failures += "thin_market_issuance_zero cannot authorize production issuance"
    }
    if ($request.continuity_reserve_excluded -ne $true -or $request.operational_reserve_excluded -ne $true) {
        $failures += "continuity and operational reserves must be excluded"
    }
    if ($RequireNoPlaceholders -and -not (Test-HexSha256 -Value ([string]$request.capacity_report_authority_record_sha256))) {
        $failures += "capacity_report_authority_record_sha256 must be a SHA-256 hex string"
    }
    foreach ($field in @("conservative_methodology_sha256", "issuance_authority_record_sha256", "issuance_record_schema_sha256", "no_arch_creation_validation_sha256")) {
        if ($RequireNoPlaceholders -and -not (Test-HexSha256 -Value ([string]$request.$field))) {
            $failures += "$field must be a SHA-256 hex string"
        }
        elseif ([string]::IsNullOrWhiteSpace([string]$request.$field)) {
            $failures += "$field is required"
        }
    }

    return New-Check -Id "cc_capacity_request_contract" -Passed ($failures.Count -eq 0) -Failures $failures -Evidence @{
        path = $Path
        service_class = [string]$request.service_class
        max_issuance_base_units = [int64]$request.max_issuance_base_units
    }
}

function Invoke-HostedRecordCreation {
    param(
        [string]$Id,
        [string]$Path,
        [string]$EndpointPath
    )

    if ([string]::IsNullOrWhiteSpace($HostedApiBaseUrl)) {
        return New-Check -Id $Id -Passed $false -Failures @("HostedApiBaseUrl is required when -CreateHostedRecords is set.") -Evidence $null
    }
    if ([string]::IsNullOrWhiteSpace($OperatorKey)) {
        return New-Check -Id $Id -Passed $false -Failures @("OperatorKey is required when -CreateHostedRecords is set.") -Evidence $null
    }

    $url = $HostedApiBaseUrl.TrimEnd("/") + "/" + $EndpointPath.TrimStart("/")
    $body = Get-Content -LiteralPath $Path -Raw
    try {
        $response = Invoke-RestMethod `
            -Method Post `
            -Uri $url `
            -Headers @{ "X-Archrealms-Operator-Key" = $OperatorKey } `
            -Body $body `
            -ContentType "application/json" `
            -TimeoutSec $EndpointTimeoutSeconds
    }
    catch {
        return New-Check -Id $Id -Passed $false -Failures @("hosted record creation failed for $url`: $($_.Exception.Message)") -Evidence @{ endpoint = $url }
    }

    $failures = @()
    if ($response.succeeded -ne $true) {
        $failures += "hosted endpoint did not return succeeded=true"
    }
    if ([string]::IsNullOrWhiteSpace([string]$response.record_id)) {
        $failures += "hosted endpoint did not return record_id"
    }
    if (-not (Test-HexSha256 -Value ([string]$response.record_sha256))) {
        $failures += "hosted endpoint did not return a SHA-256 record hash"
    }

    return New-Check -Id $Id -Passed ($failures.Count -eq 0) -Failures $failures -Evidence @{
        endpoint = $url
        record_id = [string]$response.record_id
        record_sha256 = [string]$response.record_sha256
    }
}

$readmePath = Join-Path $resolvedMonetaryPath "README.md"
$provisioningPath = Join-Path $resolvedMonetaryPath "issuer-capacity-genesis-provisioning.template.md"
$archGenesisPath = Join-Path $resolvedMonetaryPath "arch-genesis-manifest-request.template.json"
$ccCapacityPath = Join-Path $resolvedMonetaryPath "cc-capacity-report-request.template.json"

$checks = @()
$checks += Test-TextDocument -Id "readme_contract" -Path $readmePath -RequiredText @(
    "ARCHREALMS_PASSPORT_CC_ISSUER_AUTHORITY_ID",
    "ARCHREALMS_PASSPORT_CAPACITY_REPORT_ISSUER_ID",
    "ARCHREALMS_PASSPORT_ARCH_GENESIS_MANIFEST_ID",
    "POST /arch/genesis/manifests",
    "POST /capacity/reports/cc",
    "allocation policy",
    "vesting",
    "treasury policy",
    "no-ARCH-creation validation"
)
$checks += Test-TextDocument -Id "provisioning_record_contract" -Path $provisioningPath -RequiredText @(
    "ARCHREALMS_PASSPORT_CC_ISSUER_AUTHORITY_ID",
    "ARCHREALMS_PASSPORT_CAPACITY_REPORT_ISSUER_ID",
    "ARCHREALMS_PASSPORT_ARCH_GENESIS_MANIFEST_ID",
    "ARCHREALMS_PASSPORT_PRODUCTION_LEDGER_NAMESPACE",
    "CC issuance cannot create ARCH",
    "Thin-market or unqualified capacity authorizes zero CC issuance",
    "Allocation policy",
    "Vesting or lock policy",
    "Treasury policy",
    "No-ARCH-creation validation"
)
$checks += Test-ArchGenesisRequest -Path $archGenesisPath
$checks += Test-CcCapacityRequest -Path $ccCapacityPath

if ($CreateHostedRecords) {
    $checks += Invoke-HostedRecordCreation -Id "hosted_arch_genesis_record_creation" -Path $archGenesisPath -EndpointPath "/arch/genesis/manifests"
    $checks += Invoke-HostedRecordCreation -Id "hosted_cc_capacity_record_creation" -Path $ccCapacityPath -EndpointPath "/capacity/reports/cc"
}
else {
    $checks += New-Check -Id "hosted_record_creation" -Passed $true -Failures @() -Evidence @{
        skipped = $true
        reason = "Use -CreateHostedRecords with approved production values to post records to the hosted API."
    }
}

$failed = @($checks | Where-Object { -not $_.passed })
$report = [pscustomobject][ordered]@{
    schema = "archrealms.passport.production_monetary_provisioning_validation.v1"
    created_utc = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
    production_monetary_path = $resolvedMonetaryPath
    require_no_placeholders = [bool]$RequireNoPlaceholders
    create_hosted_records = [bool]$CreateHostedRecords
    hosted_api_base_url_configured = -not [string]::IsNullOrWhiteSpace($HostedApiBaseUrl)
    operator_key_configured = -not [string]::IsNullOrWhiteSpace($OperatorKey)
    endpoint_timeout_seconds = [int]$EndpointTimeoutSeconds
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
