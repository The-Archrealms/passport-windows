param(
    [string]$OutputPath,
    [string]$EnvironmentFile,
    [string]$PackageSigningConfigured = "false",
    [string]$TimestampConfigured = "false",
    [int]$EndpointTimeoutSeconds = 10,
    [switch]$NoFail
)

$ErrorActionPreference = "Stop"
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path

function Import-EnvironmentFile {
    param(
        [string]$Path
    )

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

$loadedEnvironmentVariables = Import-EnvironmentFile -Path $EnvironmentFile

function Test-NonEmptyEnvironment {
    param(
        [string]$Name
    )

    return -not [string]::IsNullOrWhiteSpace([System.Environment]::GetEnvironmentVariable($Name))
}

function Test-AnyEnvironment {
    param(
        [string[]]$Names
    )

    foreach ($name in $Names) {
        if (Test-NonEmptyEnvironment -Name $name) {
            return $true
        }
    }

    return $false
}

function Get-FirstEnvironmentValue {
    param(
        [string[]]$Names
    )

    foreach ($name in $Names) {
        $value = [System.Environment]::GetEnvironmentVariable($name)
        if (-not [string]::IsNullOrWhiteSpace($value)) {
            return $value.Trim()
        }
    }

    return ""
}

function New-Gate {
    param(
        [string]$Id,
        [string]$Description,
        [string[]]$RequiredEnvironment,
        [string[][]]$RequiredAnyEnvironment = @(),
        [scriptblock]$ExtraCheck = $null
    )

    $missing = @()
    foreach ($name in $RequiredEnvironment) {
        if (-not (Test-NonEmptyEnvironment -Name $name)) {
            $missing += $name
        }
    }

    foreach ($group in $RequiredAnyEnvironment) {
        if (-not (Test-AnyEnvironment -Names $group)) {
            $missing += ($group -join " or ")
        }
    }

    $extraFailure = ""
    if ($ExtraCheck) {
        $extraFailure = & $ExtraCheck
        if ($extraFailure) {
            $missing += $extraFailure
        }
    }

    return [pscustomobject][ordered]@{
        id = $Id
        description = $Description
        passed = ($missing.Count -eq 0)
        missing = $missing
    }
}

function Test-HexSha256Environment {
    param(
        [string]$Name
    )

    $value = [System.Environment]::GetEnvironmentVariable($Name)
    if ([string]::IsNullOrWhiteSpace($value)) {
        return ""
    }

    if ($value.Trim() -notmatch '^[0-9a-fA-F]{64}$') {
        return "$Name must be a SHA-256 hex string"
    }

    return ""
}

function Test-ManagedSigningCustody {
    $custodyValue = [System.Environment]::GetEnvironmentVariable("ARCHREALMS_PASSPORT_HOSTED_SIGNING_KEY_CUSTODY")
    if ($null -eq $custodyValue) {
        $custodyValue = ""
    }

    $custody = $custodyValue.Trim().ToLowerInvariant()
    if (-not [string]::IsNullOrWhiteSpace($custody) -and $custody -notin @("managed", "kms", "hsm", "managed-hsm", "cloud-kms")) {
        return "ARCHREALMS_PASSPORT_HOSTED_SIGNING_KEY_CUSTODY must be managed/kms/hsm"
    }

    $localPath = [System.Environment]::GetEnvironmentVariable("ARCHREALMS_PASSPORT_HOSTED_SIGNING_KEY_PATH")
    if (-not [string]::IsNullOrWhiteSpace($localPath)) {
        return "ARCHREALMS_PASSPORT_HOSTED_SIGNING_KEY_PATH must not be used for ProductionMvp managed custody"
    }

    return ""
}

function Test-PackageSigning {
    if (-not (Test-Truthy -Value $PackageSigningConfigured)) {
        return "production package signing certificate is not configured"
    }

    if (-not (Test-Truthy -Value $TimestampConfigured) -and -not (Test-NonEmptyEnvironment -Name "PASSPORT_WINDOWS_MSIX_TIMESTAMP_URL")) {
        return "PASSPORT_WINDOWS_MSIX_TIMESTAMP_URL"
    }

    return ""
}

function Join-EndpointPath {
    param(
        [string]$BaseUrl,
        [string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($BaseUrl)) {
        return ""
    }

    return $BaseUrl.TrimEnd("/") + "/" + $Path.TrimStart("/")
}

function Test-JsonRuntimeStatusEndpoint {
    param(
        [string]$Name,
        [string]$Url,
        [string]$ExpectedSchema
    )

    if ([string]::IsNullOrWhiteSpace($Url)) {
        return ""
    }

    try {
        $response = Invoke-RestMethod -Method Get -Uri $Url -TimeoutSec $EndpointTimeoutSeconds
    }
    catch {
        return "$Name endpoint check failed for $Url`: $($_.Exception.Message)"
    }

    if ($null -eq $response) {
        return "$Name endpoint check returned no JSON for $Url"
    }

    if ($response.schema -ne $ExpectedSchema) {
        return "$Name endpoint returned unexpected schema for $Url"
    }

    if ($response.ready -ne $true) {
        $missing = @()
        if ($response.missing) {
            $missing = @($response.missing)
        }

        if ($missing.Count -gt 0) {
            return "$Name endpoint is not ready for $Url`: " + ($missing -join ", ")
        }

        return "$Name endpoint is not ready for $Url"
    }

    return ""
}

function Test-HostedRuntimeStatusEndpoints {
    $apiBaseUrl = Get-FirstEnvironmentValue -Names @(
        "PASSPORT_WINDOWS_PRODUCTION_MVP_API_BASE_URL",
        "PASSPORT_WINDOWS_RELEASE_LANE_API_BASE_URL"
    )
    $aiGatewayUrl = Get-FirstEnvironmentValue -Names @(
        "PASSPORT_WINDOWS_PRODUCTION_MVP_AI_GATEWAY_URL",
        "PASSPORT_WINDOWS_RELEASE_LANE_AI_GATEWAY_URL"
    )

    $failures = @()
    if (-not [string]::IsNullOrWhiteSpace($apiBaseUrl)) {
        $opsStatus = Test-JsonRuntimeStatusEndpoint `
            -Name "hosted operations runtime status" `
            -Url (Join-EndpointPath -BaseUrl $apiBaseUrl -Path "/ops/runtime/status") `
            -ExpectedSchema "archrealms.passport.hosted_operations_readiness.v1"
        if ($opsStatus) {
            $failures += $opsStatus
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($aiGatewayUrl)) {
        $aiStatus = Test-JsonRuntimeStatusEndpoint `
            -Name "hosted AI runtime status" `
            -Url (Join-EndpointPath -BaseUrl $aiGatewayUrl -Path "/ai/runtime/status") `
            -ExpectedSchema "archrealms.passport.hosted_ai_runtime_readiness.v1"
        if ($aiStatus) {
            $failures += $aiStatus
        }
    }

    return $failures
}

function Test-ReleaseLaneEndpointUrls {
    $endpoints = @(
        [pscustomobject]@{
            Name = "Production API"
            Value = Get-FirstEnvironmentValue -Names @(
                "PASSPORT_WINDOWS_PRODUCTION_MVP_API_BASE_URL",
                "PASSPORT_WINDOWS_RELEASE_LANE_API_BASE_URL"
            )
        },
        [pscustomobject]@{
            Name = "Production AI gateway"
            Value = Get-FirstEnvironmentValue -Names @(
                "PASSPORT_WINDOWS_PRODUCTION_MVP_AI_GATEWAY_URL",
                "PASSPORT_WINDOWS_RELEASE_LANE_AI_GATEWAY_URL"
            )
        }
    )

    $failures = @()
    foreach ($endpoint in $endpoints) {
        if ([string]::IsNullOrWhiteSpace($endpoint.Value)) {
            continue
        }

        $uri = $null
        if (-not [System.Uri]::TryCreate($endpoint.Value, [System.UriKind]::Absolute, [ref]$uri)) {
            $failures += "$($endpoint.Name) endpoint must be an absolute URL"
            continue
        }

        $isLoopback = $uri.IsLoopback
        $isHttps = [string]::Equals($uri.Scheme, [System.Uri]::UriSchemeHttps, [System.StringComparison]::OrdinalIgnoreCase)
        if (-not $isHttps -and -not $isLoopback) {
            $failures += "$($endpoint.Name) endpoint must use HTTPS unless it is a loopback validation URL"
        }
    }

    return $failures
}

function Test-Truthy {
    param(
        [string]$Value
    )

    return $Value -in @("1", "true", "True", "TRUE", "yes", "Yes", "YES")
}

$gates = @(
    New-Gate `
        -Id "package_signing" `
        -Description "Production MVP package signing uses a stable certificate and timestamping, not a generated test certificate." `
        -RequiredEnvironment @() `
        -ExtraCheck ${function:Test-PackageSigning}

    New-Gate `
        -Id "release_lane_endpoints" `
        -Description "Production MVP package lane has production API and AI gateway endpoints." `
        -RequiredEnvironment @() `
        -RequiredAnyEnvironment @(
            @("PASSPORT_WINDOWS_PRODUCTION_MVP_API_BASE_URL", "PASSPORT_WINDOWS_RELEASE_LANE_API_BASE_URL"),
            @("PASSPORT_WINDOWS_PRODUCTION_MVP_AI_GATEWAY_URL", "PASSPORT_WINDOWS_RELEASE_LANE_AI_GATEWAY_URL")
        ) `
        -ExtraCheck ${function:Test-ReleaseLaneEndpointUrls}

    New-Gate `
        -Id "hosted_runtime_status" `
        -Description "Configured production hosted API and AI gateway runtime status endpoints are reachable and ready." `
        -RequiredEnvironment @() `
        -ExtraCheck ${function:Test-HostedRuntimeStatusEndpoints}

    New-Gate `
        -Id "hosted_operator_gate" `
        -Description "Authority-bearing hosted endpoints require a configured operator key hash." `
        -RequiredEnvironment @("ARCHREALMS_PASSPORT_HOSTED_OPERATOR_API_KEY_SHA256") `
        -ExtraCheck { Test-HexSha256Environment -Name "ARCHREALMS_PASSPORT_HOSTED_OPERATOR_API_KEY_SHA256" }

    New-Gate `
        -Id "managed_storage_backups" `
        -Description "Hosted ledger, capacity, genesis, recovery, telemetry, and AI records use managed durable storage with backup and restore policy." `
        -RequiredEnvironment @(
            "ARCHREALMS_PASSPORT_HOSTED_DATA_ROOT",
            "ARCHREALMS_PASSPORT_HOSTED_STORAGE_PROVIDER",
            "ARCHREALMS_PASSPORT_HOSTED_STORAGE_BACKUP_POLICY_URI",
            "ARCHREALMS_PASSPORT_HOSTED_STORAGE_RESTORE_RUNBOOK_URI"
        )

    New-Gate `
        -Id "managed_signing_key_custody" `
        -Description "Hosted service signing keys and Crown issuance keys are in managed production custody." `
        -RequiredEnvironment @(
            "ARCHREALMS_PASSPORT_HOSTED_SIGNING_KEY_PROVIDER",
            "ARCHREALMS_PASSPORT_HOSTED_SIGNING_KEY_ID",
            "ARCHREALMS_PASSPORT_HOSTED_SIGNING_KEY_CUSTODY"
        ) `
        -ExtraCheck ${function:Test-ManagedSigningCustody}

    New-Gate `
        -Id "issuer_capacity_genesis_secrets" `
        -Description "Production issuer, capacity report, and ARCH genesis authority identifiers are wired." `
        -RequiredEnvironment @(
            "ARCHREALMS_PASSPORT_CC_ISSUER_AUTHORITY_ID",
            "ARCHREALMS_PASSPORT_CAPACITY_REPORT_ISSUER_ID",
            "ARCHREALMS_PASSPORT_ARCH_GENESIS_MANIFEST_ID",
            "ARCHREALMS_PASSPORT_PRODUCTION_LEDGER_NAMESPACE"
        )

    New-Gate `
        -Id "open_weight_ai_runtime" `
        -Description "Hosted AI has an approved open-weight model endpoint, artifact/license evidence, vector store, and knowledge-pack approval root." `
        -RequiredEnvironment @(
            "ARCHREALMS_PASSPORT_AI_INFERENCE_BASE_URL",
            "ARCHREALMS_PASSPORT_AI_MODEL_ID",
            "ARCHREALMS_PASSPORT_AI_MODEL_ARTIFACT_SHA256",
            "ARCHREALMS_PASSPORT_AI_MODEL_LICENSE_APPROVAL_ID",
            "ARCHREALMS_PASSPORT_AI_VECTOR_STORE_PROVIDER",
            "ARCHREALMS_PASSPORT_AI_VECTOR_STORE_ID",
            "ARCHREALMS_PASSPORT_AI_KNOWLEDGE_APPROVAL_ROOT"
        )

    New-Gate `
        -Id "telemetry_incident_response" `
        -Description "Production telemetry retention, incident logging, and incident response ownership are configured." `
        -RequiredEnvironment @(
            "ARCHREALMS_PASSPORT_TELEMETRY_DESTINATION",
            "ARCHREALMS_PASSPORT_TELEMETRY_RETENTION_POLICY_URI",
            "ARCHREALMS_PASSPORT_INCIDENT_RESPONSE_RUNBOOK_URI",
            "ARCHREALMS_PASSPORT_INCIDENT_RESPONSE_OWNER"
        )

    New-Gate `
        -Id "production_release_approvals" `
        -Description "Production MVP release has product, engineering, security/privacy, and Crown monetary authority signoff references." `
        -RequiredEnvironment @(
            "ARCHREALMS_PASSPORT_PRODUCTION_RELEASE_APPROVAL_ID",
            "ARCHREALMS_PASSPORT_ENGINEERING_SIGNOFF_ID",
            "ARCHREALMS_PASSPORT_SECURITY_PRIVACY_SIGNOFF_ID",
            "ARCHREALMS_PASSPORT_CROWN_MONETARY_AUTHORITY_SIGNOFF_ID"
        )
)

$failed = @($gates | Where-Object { -not $_.passed })
$report = [pscustomobject][ordered]@{
    schema = "archrealms.passport.production_mvp_readiness.v1"
    created_utc = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
    repo_root = $repoRoot
    lane = "production-mvp"
    environment_file_loaded = -not [string]::IsNullOrWhiteSpace($EnvironmentFile)
    environment_file_variable_count = $loadedEnvironmentVariables.Count
    environment_file_variables = $loadedEnvironmentVariables
    endpoint_timeout_seconds = $EndpointTimeoutSeconds
    ready = ($failed.Count -eq 0)
    failed_gate_count = $failed.Count
    gates = $gates
}

$json = $report | ConvertTo-Json -Depth 8
if ($OutputPath) {
    $resolvedOutput = [System.IO.Path]::GetFullPath($OutputPath)
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $resolvedOutput) | Out-Null
    Set-Content -LiteralPath $resolvedOutput -Value $json -Encoding UTF8
}

$json
if ($failed.Count -gt 0 -and -not $NoFail) {
    throw "ProductionMvp readiness failed. Missing gates: " + (($failed | ForEach-Object { $_.id }) -join ", ")
}
