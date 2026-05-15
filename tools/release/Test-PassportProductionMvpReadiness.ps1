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

    $endpoint = [System.Environment]::GetEnvironmentVariable("ARCHREALMS_PASSPORT_HOSTED_SIGNING_ENDPOINT")
    if (-not [string]::IsNullOrWhiteSpace($endpoint)) {
        $uri = $null
        if (-not [System.Uri]::TryCreate($endpoint.Trim(), [System.UriKind]::Absolute, [ref]$uri)) {
            return "ARCHREALMS_PASSPORT_HOSTED_SIGNING_ENDPOINT must be an absolute URL"
        }

        $isHttps = [string]::Equals($uri.Scheme, [System.Uri]::UriSchemeHttps, [System.StringComparison]::OrdinalIgnoreCase)
        if (-not $isHttps -and -not $uri.IsLoopback) {
            return "ARCHREALMS_PASSPORT_HOSTED_SIGNING_ENDPOINT must use HTTPS unless it is a loopback validation URL"
        }
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

function Test-ManagedSigningEndpointProbe {
    $endpoint = [System.Environment]::GetEnvironmentVariable("ARCHREALMS_PASSPORT_HOSTED_SIGNING_ENDPOINT")
    if ([string]::IsNullOrWhiteSpace($endpoint)) {
        return ""
    }

    $keyId = [System.Environment]::GetEnvironmentVariable("ARCHREALMS_PASSPORT_HOSTED_SIGNING_KEY_ID")
    $provider = [System.Environment]::GetEnvironmentVariable("ARCHREALMS_PASSPORT_HOSTED_SIGNING_KEY_PROVIDER")
    $custody = [System.Environment]::GetEnvironmentVariable("ARCHREALMS_PASSPORT_HOSTED_SIGNING_KEY_CUSTODY")
    $payloadText = "archrealms-passport-production-mvp-readiness-signing-probe"
    $payloadBytes = [System.Text.Encoding]::UTF8.GetBytes($payloadText)
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        $payloadSha256 = [System.BitConverter]::ToString($sha256.ComputeHash($payloadBytes)).Replace("-", "").ToLowerInvariant()
    }
    finally {
        $sha256.Dispose()
    }
    $body = [pscustomobject][ordered]@{
        key_id = $keyId
        provider = $provider
        custody = $custody
        purpose = "production_mvp_readiness_probe"
        payload_sha256 = $payloadSha256
        payload_base64 = [System.Convert]::ToBase64String($payloadBytes)
    } | ConvertTo-Json -Depth 4

    $headers = @{}
    $apiKey = [System.Environment]::GetEnvironmentVariable("ARCHREALMS_PASSPORT_HOSTED_SIGNING_ENDPOINT_API_KEY")
    if (-not [string]::IsNullOrWhiteSpace($apiKey)) {
        $headers["X-Archrealms-Managed-Signing-Key"] = $apiKey
    }

    try {
        $response = Invoke-RestMethod -Method Post -Uri $endpoint.Trim() -Headers $headers -Body $body -ContentType "application/json" -TimeoutSec $EndpointTimeoutSeconds
    }
    catch {
        return "managed signing endpoint probe failed for $endpoint`: $($_.Exception.Message)"
    }

    if ($null -eq $response) {
        return "managed signing endpoint probe returned no JSON for $endpoint"
    }

    if ($response.signature_algorithm -ne "RSA_PKCS1_SHA256") {
        return "managed signing endpoint probe must return RSA_PKCS1_SHA256"
    }

    if ($response.signed_payload_sha256 -ne $payloadSha256) {
        return "managed signing endpoint probe signed the wrong payload hash"
    }

    try {
        $signatureBytes = [System.Convert]::FromBase64String($response.signature_base64)
        $publicKeyBytes = [System.Convert]::FromBase64String($response.public_key_spki_der_base64)
    }
    catch {
        return "managed signing endpoint probe returned invalid base64 signature or public key"
    }

    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        $publicKeySha256 = [System.BitConverter]::ToString($sha256.ComputeHash($publicKeyBytes)).Replace("-", "").ToLowerInvariant()
    }
    finally {
        $sha256.Dispose()
    }
    if ($response.public_key_sha256 -ne $publicKeySha256) {
        return "managed signing endpoint probe returned public key hash mismatch"
    }

    $verificationFailure = Test-RsaPkcs1Sha256Signature -PayloadBytes $payloadBytes -SignatureBytes $signatureBytes -PublicKeySpkiDer $publicKeyBytes
    if ($verificationFailure) {
        return "managed signing endpoint probe could not verify returned signature: $verificationFailure"
    }

    return ""
}

function Test-RsaPkcs1Sha256Signature {
    param(
        [byte[]]$PayloadBytes,
        [byte[]]$SignatureBytes,
        [byte[]]$PublicKeySpkiDer
    )

    try {
        $parameters = ConvertFrom-SubjectPublicKeyInfo -PublicKeySpkiDer $PublicKeySpkiDer
        $rsa = [System.Security.Cryptography.RSACryptoServiceProvider]::new()
        try {
            $rsa.ImportParameters($parameters)
            $sha256Oid = [System.Security.Cryptography.CryptoConfig]::MapNameToOID("SHA256")
            if (-not $rsa.VerifyData($PayloadBytes, $sha256Oid, $SignatureBytes)) {
                return "signature verification failed"
            }
        }
        finally {
            $rsa.Dispose()
        }
    }
    catch {
        return $_.Exception.Message
    }

    return ""
}

function ConvertFrom-SubjectPublicKeyInfo {
    param(
        [byte[]]$PublicKeySpkiDer
    )

    $offset = 0
    $root = Read-DerValue -Bytes $PublicKeySpkiDer -Offset ([ref]$offset) -ExpectedTag 0x30
    $rootOffset = 0
    [void](Read-DerValue -Bytes $root -Offset ([ref]$rootOffset) -ExpectedTag 0x30)
    $bitString = Read-DerValue -Bytes $root -Offset ([ref]$rootOffset) -ExpectedTag 0x03
    if ($bitString.Length -lt 2 -or $bitString[0] -ne 0) {
        throw "unsupported RSA public-key bit string"
    }

    $rsaPublicKey = New-Object byte[] ($bitString.Length - 1)
    [System.Array]::Copy($bitString, 1, $rsaPublicKey, 0, $rsaPublicKey.Length)

    $rsaOffset = 0
    $rsaSequence = Read-DerValue -Bytes $rsaPublicKey -Offset ([ref]$rsaOffset) -ExpectedTag 0x30
    $sequenceOffset = 0
    $modulus = Remove-DerIntegerPadding (Read-DerValue -Bytes $rsaSequence -Offset ([ref]$sequenceOffset) -ExpectedTag 0x02)
    $exponent = Remove-DerIntegerPadding (Read-DerValue -Bytes $rsaSequence -Offset ([ref]$sequenceOffset) -ExpectedTag 0x02)

    $parameters = [System.Security.Cryptography.RSAParameters]::new()
    $parameters.Modulus = $modulus
    $parameters.Exponent = $exponent
    return $parameters
}

function Read-DerValue {
    param(
        [byte[]]$Bytes,
        [ref]$Offset,
        [int]$ExpectedTag
    )

    if ($Offset.Value -ge $Bytes.Length -or $Bytes[$Offset.Value] -ne $ExpectedTag) {
        throw "unexpected DER tag"
    }

    $Offset.Value++
    $length = Read-DerLength -Bytes $Bytes -Offset $Offset
    if ($length -lt 0 -or $Offset.Value + $length -gt $Bytes.Length) {
        throw "invalid DER length"
    }

    $value = New-Object byte[] $length
    [System.Array]::Copy($Bytes, $Offset.Value, $value, 0, $length)
    $Offset.Value += $length
    return $value
}

function Read-DerLength {
    param(
        [byte[]]$Bytes,
        [ref]$Offset
    )

    if ($Offset.Value -ge $Bytes.Length) {
        throw "missing DER length"
    }

    $first = [int]$Bytes[$Offset.Value]
    $Offset.Value++
    if (($first -band 0x80) -eq 0) {
        return $first
    }

    $count = $first -band 0x7F
    if ($count -le 0 -or $count -gt 4 -or $Offset.Value + $count -gt $Bytes.Length) {
        throw "unsupported DER length"
    }

    $length = 0
    for ($index = 0; $index -lt $count; $index++) {
        $length = ($length -shl 8) -bor [int]$Bytes[$Offset.Value]
        $Offset.Value++
    }

    return $length
}

function Remove-DerIntegerPadding {
    param(
        [byte[]]$Value
    )

    $start = 0
    while ($start -lt ($Value.Length - 1) -and $Value[$start] -eq 0) {
        $start++
    }

    if ($start -eq 0) {
        return $Value
    }

    $trimmed = New-Object byte[] ($Value.Length - $start)
    [System.Array]::Copy($Value, $start, $trimmed, 0, $trimmed.Length)
    return $trimmed
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
            "ARCHREALMS_PASSPORT_HOSTED_SIGNING_KEY_CUSTODY",
            "ARCHREALMS_PASSPORT_HOSTED_SIGNING_ENDPOINT"
        ) `
        -ExtraCheck ${function:Test-ManagedSigningCustody}

    New-Gate `
        -Id "managed_signing_endpoint_probe" `
        -Description "Managed hosted signing endpoint signs a non-mutating readiness probe with verifiable public-key evidence." `
        -RequiredEnvironment @() `
        -ExtraCheck ${function:Test-ManagedSigningEndpointProbe}

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
