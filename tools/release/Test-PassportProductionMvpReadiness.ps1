param(
    [string]$OutputPath,
    [string]$EnvironmentFile,
    [string]$PackageSigningConfigured = "false",
    [string]$TimestampConfigured = "false",
    [string]$CertificatePfxPath,
    [string]$CertificatePfxBase64,
    [string]$CertificatePassword,
    [string]$PackagePublisher,
    [string]$TimestampUrl,
    [int]$EndpointTimeoutSeconds = 10,
    [switch]$NoFail
)

$ErrorActionPreference = "Stop"
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
Import-Module (Join-Path $PSScriptRoot "PassportWindowsRelease.psm1") -Force -DisableNameChecking
$script:packageSigningCertificateReport = $null

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

function Get-Sha256Hex {
    param(
        [byte[]]$Bytes
    )

    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        return [System.BitConverter]::ToString($sha256.ComputeHash($Bytes)).Replace("-", "").ToLowerInvariant()
    }
    finally {
        $sha256.Dispose()
    }
}

function Test-HostedOperatorSecret {
    $expectedHash = [System.Environment]::GetEnvironmentVariable("ARCHREALMS_PASSPORT_HOSTED_OPERATOR_API_KEY_SHA256")
    $operatorKey = [System.Environment]::GetEnvironmentVariable("ARCHREALMS_PASSPORT_HOSTED_OPERATOR_API_KEY")
    if ([string]::IsNullOrWhiteSpace($expectedHash) -or [string]::IsNullOrWhiteSpace($operatorKey)) {
        return ""
    }

    $actualHash = Get-Sha256Hex -Bytes ([System.Text.Encoding]::UTF8.GetBytes($operatorKey.Trim()))
    if (-not [string]::Equals($actualHash, $expectedHash.Trim(), [System.StringComparison]::OrdinalIgnoreCase)) {
        return "ARCHREALMS_PASSPORT_HOSTED_OPERATOR_API_KEY does not match ARCHREALMS_PASSPORT_HOSTED_OPERATOR_API_KEY_SHA256"
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
    $pfxPath = $CertificatePfxPath
    if (-not $pfxPath) {
        $pfxPath = Get-FirstEnvironmentValue -Names @(
            "PASSPORT_WINDOWS_MSIX_PFX_PATH",
            "PASSPORT_WINDOWS_SIDELOAD_PFX_PATH",
            "PASSPORT_WINDOWS_STORE_PFX_PATH"
        )
    }

    $pfxBase64 = $CertificatePfxBase64
    if (-not $pfxBase64) {
        $pfxBase64 = Get-FirstEnvironmentValue -Names @(
            "PASSPORT_WINDOWS_MSIX_PFX_BASE64",
            "PASSPORT_WINDOWS_SIDELOAD_PFX_BASE64",
            "PASSPORT_WINDOWS_STORE_PFX_BASE64"
        )
    }

    $password = $CertificatePassword
    if (-not $password) {
        $password = Get-FirstEnvironmentValue -Names @(
            "PASSPORT_WINDOWS_MSIX_PFX_PASSWORD",
            "PASSPORT_WINDOWS_SIDELOAD_PFX_PASSWORD",
            "PASSPORT_WINDOWS_STORE_PFX_PASSWORD"
        )
    }

    $timestamp = $TimestampUrl
    if (-not $timestamp) {
        $timestamp = Get-FirstEnvironmentValue -Names @(
            "PASSPORT_WINDOWS_MSIX_TIMESTAMP_URL",
            "PASSPORT_WINDOWS_SIDELOAD_TIMESTAMP_URL",
            "PASSPORT_WINDOWS_STORE_TIMESTAMP_URL"
        )
    }

    $expectedPublisher = $PackagePublisher
    if (-not $expectedPublisher) {
        $expectedPublisher = Get-FirstEnvironmentValue -Names @(
            "PASSPORT_WINDOWS_MSIX_PUBLISHER",
            "PASSPORT_WINDOWS_SIDELOAD_PUBLISHER",
            "PASSPORT_WINDOWS_STORE_PUBLISHER"
        )
    }
    if (-not $expectedPublisher) {
        $expectedPublisher = "CN=The Archrealms"
    }

    $pfxConfigured = -not [string]::IsNullOrWhiteSpace($pfxPath) -or -not [string]::IsNullOrWhiteSpace($pfxBase64)
    if (-not $pfxConfigured) {
        return "production package signing certificate is not configured"
    }

    if ($pfxConfigured -and [string]::IsNullOrWhiteSpace($password)) {
        return "PASSPORT_WINDOWS_MSIX_PFX_PASSWORD"
    }

    if ([string]::IsNullOrWhiteSpace($timestamp)) {
        return "PASSPORT_WINDOWS_MSIX_TIMESTAMP_URL"
    }

    if ($pfxConfigured) {
        $script:packageSigningCertificateReport = Test-PassportWindowsSigningCertificateInput `
            -PfxPath $pfxPath `
            -PfxBase64 $pfxBase64 `
            -Password $password `
            -ExpectedPublisher $expectedPublisher `
            -TimestampUrl $timestamp `
            -MinimumDaysValid 30

        if ($script:packageSigningCertificateReport.passed -ne $true) {
            return @($script:packageSigningCertificateReport.failures)
        }
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

function Test-HostedOperatorStatusEndpoint {
    $apiBaseUrl = Get-FirstEnvironmentValue -Names @(
        "PASSPORT_WINDOWS_PRODUCTION_MVP_API_BASE_URL",
        "PASSPORT_WINDOWS_RELEASE_LANE_API_BASE_URL"
    )
    $operatorKey = [System.Environment]::GetEnvironmentVariable("ARCHREALMS_PASSPORT_HOSTED_OPERATOR_API_KEY")
    if ([string]::IsNullOrWhiteSpace($apiBaseUrl) -or [string]::IsNullOrWhiteSpace($operatorKey)) {
        return ""
    }

    $url = Join-EndpointPath -BaseUrl $apiBaseUrl -Path "/ops/operator/status"
    try {
        $response = Invoke-RestMethod `
            -Method Get `
            -Uri $url `
            -Headers @{ "X-Archrealms-Operator-Key" = $operatorKey } `
            -TimeoutSec $EndpointTimeoutSeconds
    }
    catch {
        return "hosted operator status endpoint check failed for $url`: $($_.Exception.Message)"
    }

    if ($null -eq $response) {
        return "hosted operator status endpoint returned no JSON for $url"
    }

    if ($response.schema -ne "archrealms.passport.hosted_operator_auth_status.v1" -or $response.authorized -ne $true) {
        return "hosted operator status endpoint did not confirm authorization for $url"
    }

    return ""
}

function Test-HostedAiRuntimeProbeEndpoint {
    $aiGatewayUrl = Get-FirstEnvironmentValue -Names @(
        "PASSPORT_WINDOWS_PRODUCTION_MVP_AI_GATEWAY_URL",
        "PASSPORT_WINDOWS_RELEASE_LANE_AI_GATEWAY_URL"
    )
    $operatorKey = [System.Environment]::GetEnvironmentVariable("ARCHREALMS_PASSPORT_HOSTED_OPERATOR_API_KEY")
    if ([string]::IsNullOrWhiteSpace($aiGatewayUrl) -or [string]::IsNullOrWhiteSpace($operatorKey)) {
        return ""
    }

    $url = Join-EndpointPath -BaseUrl $aiGatewayUrl -Path "/ai/runtime/probe"
    try {
        $response = Invoke-RestMethod `
            -Method Get `
            -Uri $url `
            -Headers @{ "X-Archrealms-Operator-Key" = $operatorKey } `
            -TimeoutSec $EndpointTimeoutSeconds
    }
    catch {
        return "hosted AI runtime probe endpoint check failed for $url`: $($_.Exception.Message)"
    }

    if ($null -eq $response) {
        return "hosted AI runtime probe endpoint returned no JSON for $url"
    }

    if ($response.schema -ne "archrealms.passport.hosted_ai_runtime_probe.v1" -or $response.ready -ne $true -or $response.runtime_answer_received -ne $true) {
        $missing = @()
        if ($response.missing) {
            $missing = @($response.missing)
        }

        if ($missing.Count -gt 0) {
            return "hosted AI runtime probe endpoint is not ready for $url`: " + ($missing -join ", ")
        }

        return "hosted AI runtime probe endpoint is not ready for $url"
    }

    return ""
}

function Test-HostedStorageStatusEndpoint {
    $apiBaseUrl = Get-FirstEnvironmentValue -Names @(
        "PASSPORT_WINDOWS_PRODUCTION_MVP_API_BASE_URL",
        "PASSPORT_WINDOWS_RELEASE_LANE_API_BASE_URL"
    )
    $operatorKey = [System.Environment]::GetEnvironmentVariable("ARCHREALMS_PASSPORT_HOSTED_OPERATOR_API_KEY")
    if ([string]::IsNullOrWhiteSpace($apiBaseUrl) -or [string]::IsNullOrWhiteSpace($operatorKey)) {
        return ""
    }

    $url = Join-EndpointPath -BaseUrl $apiBaseUrl -Path "/ops/storage/status"
    try {
        $response = Invoke-RestMethod `
            -Method Get `
            -Uri $url `
            -Headers @{ "X-Archrealms-Operator-Key" = $operatorKey } `
            -TimeoutSec $EndpointTimeoutSeconds
    }
    catch {
        return "hosted storage status endpoint check failed for $url`: $($_.Exception.Message)"
    }

    if ($null -eq $response) {
        return "hosted storage status endpoint returned no JSON for $url"
    }

    if ($response.schema -ne "archrealms.passport.hosted_storage_readiness.v1" -or $response.ready -ne $true) {
        $missing = @()
        if ($response.missing) {
            $missing = @($response.missing)
        }

        if ($missing.Count -gt 0) {
            return "hosted storage status endpoint is not ready for $url`: " + ($missing -join ", ")
        }

        return "hosted storage status endpoint is not ready for $url"
    }

    return ""
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

    if ($response.PSObject.Properties.Name -notcontains "signing_key_provider" -or [string]::IsNullOrWhiteSpace([string]$response.signing_key_provider)) {
        return "managed signing endpoint probe must return signing_key_provider"
    }

    if ($response.PSObject.Properties.Name -notcontains "signing_key_id" -or [string]::IsNullOrWhiteSpace([string]$response.signing_key_id)) {
        return "managed signing endpoint probe must return signing_key_id"
    }

    if ($response.PSObject.Properties.Name -notcontains "signing_key_custody" -or [string]::IsNullOrWhiteSpace([string]$response.signing_key_custody)) {
        return "managed signing endpoint probe must return signing_key_custody"
    }

    if (-not [string]::Equals([string]$response.signing_key_provider, $provider, [System.StringComparison]::Ordinal)) {
        return "managed signing endpoint probe returned signing_key_provider that does not match ARCHREALMS_PASSPORT_HOSTED_SIGNING_KEY_PROVIDER"
    }

    if (-not [string]::Equals([string]$response.signing_key_id, $keyId, [System.StringComparison]::Ordinal)) {
        return "managed signing endpoint probe returned signing_key_id that does not match ARCHREALMS_PASSPORT_HOSTED_SIGNING_KEY_ID"
    }

    if (-not [string]::Equals([string]$response.signing_key_custody, $custody, [System.StringComparison]::Ordinal)) {
        return "managed signing endpoint probe returned signing_key_custody that does not match ARCHREALMS_PASSPORT_HOSTED_SIGNING_KEY_CUSTODY"
    }

    if ($response.PSObject.Properties.Name -notcontains "local_validation_only") {
        return "managed signing endpoint probe must return local_validation_only"
    }

    if ([bool]$response.local_validation_only -eq $true) {
        return "managed signing endpoint probe reports local_validation_only=true; ProductionMvp requires managed custody"
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

function Test-PreMvpInternalVerificationReport {
    $reportPath = [System.Environment]::GetEnvironmentVariable("ARCHREALMS_PASSPORT_PRE_MVP_VERIFICATION_REPORT_PATH")
    $expectedHash = [System.Environment]::GetEnvironmentVariable("ARCHREALMS_PASSPORT_PRE_MVP_VERIFICATION_REPORT_SHA256")
    if ([string]::IsNullOrWhiteSpace($reportPath)) {
        return ""
    }

    $failures = @()
    if (-not (Test-Path -LiteralPath $reportPath -PathType Leaf)) {
        return "ARCHREALMS_PASSPORT_PRE_MVP_VERIFICATION_REPORT_PATH does not exist"
    }

    if ([string]::IsNullOrWhiteSpace($expectedHash)) {
        return $failures
    }
    elseif ($expectedHash.Trim() -notmatch '^[0-9a-fA-F]{64}$') {
        $failures += "ARCHREALMS_PASSPORT_PRE_MVP_VERIFICATION_REPORT_SHA256 must be a SHA-256 hex string"
    }
    else {
        $actualHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $reportPath).Hash.ToLowerInvariant()
        if (-not [string]::Equals($actualHash, $expectedHash.Trim(), [System.StringComparison]::OrdinalIgnoreCase)) {
            $failures += "ARCHREALMS_PASSPORT_PRE_MVP_VERIFICATION_REPORT_SHA256 does not match the report file"
        }
    }

    try {
        $report = Get-Content -LiteralPath $reportPath -Raw | ConvertFrom-Json
    }
    catch {
        $failures += "pre-MVP internal verification report is not valid JSON: $($_.Exception.Message)"
        return $failures
    }

    if ($report.schema -ne "archrealms.passport.pre_mvp_internal_verification.v1") {
        $failures += "pre-MVP internal verification report has unexpected schema"
    }

    if ($report.passed -ne $true) {
        $failures += "pre-MVP internal verification report did not pass"
    }

    if ($report.pre_mvp_testing_is_mvp -ne $false) {
        $failures += "pre-MVP internal verification report must state pre-MVP testing is not the MVP"
    }

    if ($report.citizen_facing_token_release -ne $false) {
        $failures += "pre-MVP internal verification report must not mark citizen-facing token release complete"
    }

    if ($report.fake_balance_migration_blocked -ne $true) {
        $failures += "pre-MVP internal verification report must prove fake-balance migration is blocked"
    }

    $requiredIds = @(
        "synthetic_users",
        "crown_owned_test_devices",
        "crown_owned_test_storage_nodes",
        "synthetic_storage_payloads",
        "fake_balances",
        "fake_arch",
        "fake_cc",
        "ledger_replay_tests",
        "key_recovery_attacks",
        "storage_proof_attacks",
        "storage_revocation_and_wipe_tests",
        "bandwidth_limit_tests",
        "escrow_burn_refund_recredit_tests",
        "market_manipulation_simulations",
        "service_failure_simulations",
        "wallet_compromise_simulations",
        "identity_compromise_simulations",
        "ai_privacy_and_retention_tests",
        "no_fake_record_migration"
    )

    $requirementsById = @{}
    foreach ($requirement in @($report.requirements)) {
        if ($requirement.id) {
            $requirementsById[[string]$requirement.id] = $requirement
        }
    }

    foreach ($requiredId in $requiredIds) {
        if (-not $requirementsById.ContainsKey($requiredId)) {
            $failures += "pre-MVP internal verification report is missing requirement $requiredId"
            continue
        }

        if ($requirementsById[$requiredId].passed -ne $true) {
            $failures += "pre-MVP internal verification requirement did not pass: $requiredId"
        }
    }

    return $failures
}

function Test-StagingReadinessReport {
    $reportPath = [System.Environment]::GetEnvironmentVariable("ARCHREALMS_PASSPORT_STAGING_READINESS_REPORT_PATH")
    $expectedHash = [System.Environment]::GetEnvironmentVariable("ARCHREALMS_PASSPORT_STAGING_READINESS_REPORT_SHA256")
    if ([string]::IsNullOrWhiteSpace($reportPath)) {
        return ""
    }

    $failures = @()
    if (-not (Test-Path -LiteralPath $reportPath -PathType Leaf)) {
        return "ARCHREALMS_PASSPORT_STAGING_READINESS_REPORT_PATH does not exist"
    }

    if ([string]::IsNullOrWhiteSpace($expectedHash)) {
        return $failures
    }
    elseif ($expectedHash.Trim() -notmatch '^[0-9a-fA-F]{64}$') {
        $failures += "ARCHREALMS_PASSPORT_STAGING_READINESS_REPORT_SHA256 must be a SHA-256 hex string"
    }
    else {
        $actualHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $reportPath).Hash.ToLowerInvariant()
        if (-not [string]::Equals($actualHash, $expectedHash.Trim(), [System.StringComparison]::OrdinalIgnoreCase)) {
            $failures += "ARCHREALMS_PASSPORT_STAGING_READINESS_REPORT_SHA256 does not match the report file"
        }
    }

    try {
        $report = Get-Content -LiteralPath $reportPath -Raw | ConvertFrom-Json
    }
    catch {
        $failures += "staging readiness report is not valid JSON: $($_.Exception.Message)"
        return $failures
    }

    if ($report.schema -ne "archrealms.passport.staging_readiness.v1") {
        $failures += "staging readiness report has unexpected schema"
    }

    if ($report.ready -ne $true) {
        $failures += "staging readiness report did not pass"
    }

    if ($report.staging_is_mvp -ne $false) {
        $failures += "staging readiness report must state staging is not the MVP"
    }

    if ($report.synthetic_fixtures_used -eq $true) {
        $failures += "production readiness cannot accept a staging readiness report created with synthetic fixtures"
    }

    if ($report.canary_or_production_release_approved -ne $true) {
        $failures += "staging readiness report must approve canary or production release promotion"
    }

    $requiredGateIds = @(
        "pre_mvp_internal_verification",
        "staging_package_artifact",
        "staging_lane_endpoints",
        "staging_ledger_telemetry",
        "staging_operational_drill",
        "staging_rollback_drill",
        "staging_promotion_approvals",
        "no_staging_to_production_migration"
    )

    $gatesById = @{}
    foreach ($gate in @($report.gates)) {
        if ($gate.id) {
            $gatesById[[string]$gate.id] = $gate
        }
    }

    foreach ($gateId in $requiredGateIds) {
        if (-not $gatesById.ContainsKey($gateId)) {
            $failures += "staging readiness report is missing gate $gateId"
            continue
        }

        if ($gatesById[$gateId].passed -ne $true) {
            $failures += "staging readiness gate did not pass: $gateId"
        }
    }

    return $failures
}

function Test-CanaryMvpReadinessReport {
    $reportPath = [System.Environment]::GetEnvironmentVariable("ARCHREALMS_PASSPORT_CANARY_MVP_READINESS_REPORT_PATH")
    $expectedHash = [System.Environment]::GetEnvironmentVariable("ARCHREALMS_PASSPORT_CANARY_MVP_READINESS_REPORT_SHA256")
    if ([string]::IsNullOrWhiteSpace($reportPath)) {
        return ""
    }

    $failures = @()
    if (-not (Test-Path -LiteralPath $reportPath -PathType Leaf)) {
        return "ARCHREALMS_PASSPORT_CANARY_MVP_READINESS_REPORT_PATH does not exist"
    }

    if ([string]::IsNullOrWhiteSpace($expectedHash)) {
        return $failures
    }
    elseif ($expectedHash.Trim() -notmatch '^[0-9a-fA-F]{64}$') {
        $failures += "ARCHREALMS_PASSPORT_CANARY_MVP_READINESS_REPORT_SHA256 must be a SHA-256 hex string"
    }
    else {
        $actualHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $reportPath).Hash.ToLowerInvariant()
        if (-not [string]::Equals($actualHash, $expectedHash.Trim(), [System.StringComparison]::OrdinalIgnoreCase)) {
            $failures += "ARCHREALMS_PASSPORT_CANARY_MVP_READINESS_REPORT_SHA256 does not match the report file"
        }
    }

    try {
        $report = Get-Content -LiteralPath $reportPath -Raw | ConvertFrom-Json
    }
    catch {
        $failures += "canary MVP readiness report is not valid JSON: $($_.Exception.Message)"
        return $failures
    }

    if ($report.schema -ne "archrealms.passport.canary_mvp_readiness.v1") {
        $failures += "canary MVP readiness report has unexpected schema"
    }

    if ($report.ready -ne $true) {
        $failures += "canary MVP readiness report did not pass"
    }

    if ($report.lane -ne "canary-mvp") {
        $failures += "canary MVP readiness report must be for lane canary-mvp"
    }

    if ($report.canary_is_mvp -ne $true) {
        $failures += "canary MVP readiness report must state canary is the MVP citizen-facing real-token lane"
    }

    if ($report.synthetic_fixtures_used -eq $true) {
        $failures += "production readiness cannot accept a canary MVP readiness report created with synthetic fixtures"
    }

    if ($report.production_release_approved -ne $true) {
        $failures += "canary MVP readiness report must approve ProductionMvp release promotion"
    }

    $requiredGateIds = @(
        "staging_readiness",
        "canary_package_artifact",
        "canary_policy_limits",
        "canary_incident_review",
        "canary_balance_reconciliation",
        "canary_service_delivery_reconciliation",
        "canary_support_readiness",
        "canary_production_approvals"
    )

    $gatesById = @{}
    foreach ($gate in @($report.gates)) {
        if ($gate.id) {
            $gatesById[[string]$gate.id] = $gate
        }
    }

    foreach ($gateId in $requiredGateIds) {
        if (-not $gatesById.ContainsKey($gateId)) {
            $failures += "canary MVP readiness report is missing gate $gateId"
            continue
        }

        if ($gatesById[$gateId].passed -ne $true) {
            $failures += "canary MVP readiness gate did not pass: $gateId"
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
        -Id "pre_mvp_internal_verification" `
        -Description "Pre-MVP internal verification has passed and cannot migrate fake ARCH, fake CC, or synthetic records into production balances." `
        -RequiredEnvironment @(
            "ARCHREALMS_PASSPORT_PRE_MVP_VERIFICATION_REPORT_PATH",
            "ARCHREALMS_PASSPORT_PRE_MVP_VERIFICATION_REPORT_SHA256"
        ) `
        -ExtraCheck ${function:Test-PreMvpInternalVerificationReport}

    New-Gate `
        -Id "staging_readiness" `
        -Description "Staging has passed with isolated staging records, production-candidate artifacts, rollback evidence, and signed promotion approvals." `
        -RequiredEnvironment @(
            "ARCHREALMS_PASSPORT_STAGING_READINESS_REPORT_PATH",
            "ARCHREALMS_PASSPORT_STAGING_READINESS_REPORT_SHA256"
        ) `
        -ExtraCheck ${function:Test-StagingReadinessReport}

    New-Gate `
        -Id "canary_mvp_readiness" `
        -Description "Canary MVP has passed real-token policy, incident, balance, service-delivery, support, and production-promotion checks." `
        -RequiredEnvironment @(
            "ARCHREALMS_PASSPORT_CANARY_MVP_READINESS_REPORT_PATH",
            "ARCHREALMS_PASSPORT_CANARY_MVP_READINESS_REPORT_SHA256"
        ) `
        -ExtraCheck ${function:Test-CanaryMvpReadinessReport}

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
        -RequiredAnyEnvironment @(
            @("PASSPORT_WINDOWS_PRODUCTION_MVP_API_BASE_URL", "PASSPORT_WINDOWS_RELEASE_LANE_API_BASE_URL"),
            @("PASSPORT_WINDOWS_PRODUCTION_MVP_AI_GATEWAY_URL", "PASSPORT_WINDOWS_RELEASE_LANE_AI_GATEWAY_URL")
        ) `
        -ExtraCheck ${function:Test-HostedRuntimeStatusEndpoints}

    New-Gate `
        -Id "hosted_ai_runtime_probe" `
        -Description "Configured hosted AI gateway can obtain a non-mutating answer from the approved model runtime." `
        -RequiredEnvironment @(
            "ARCHREALMS_PASSPORT_HOSTED_OPERATOR_API_KEY"
        ) `
        -RequiredAnyEnvironment @(
            ,@("PASSPORT_WINDOWS_PRODUCTION_MVP_AI_GATEWAY_URL", "PASSPORT_WINDOWS_RELEASE_LANE_AI_GATEWAY_URL")
        ) `
        -ExtraCheck ${function:Test-HostedAiRuntimeProbeEndpoint}

    New-Gate `
        -Id "hosted_operator_gate" `
        -Description "Authority-bearing hosted endpoints require a configured operator key hash." `
        -RequiredEnvironment @(
            "ARCHREALMS_PASSPORT_HOSTED_OPERATOR_API_KEY_SHA256",
            "ARCHREALMS_PASSPORT_HOSTED_OPERATOR_API_KEY"
        ) `
        -ExtraCheck {
            $failures = @()
            $hashFailure = Test-HexSha256Environment -Name "ARCHREALMS_PASSPORT_HOSTED_OPERATOR_API_KEY_SHA256"
            if ($hashFailure) {
                $failures += $hashFailure
            }

            $secretFailure = Test-HostedOperatorSecret
            if ($secretFailure) {
                $failures += $secretFailure
            }

            return $failures
        }

    New-Gate `
        -Id "hosted_operator_status" `
        -Description "Configured operator key authenticates against the hosted production API without mutating state." `
        -RequiredEnvironment @(
            "ARCHREALMS_PASSPORT_HOSTED_OPERATOR_API_KEY"
        ) `
        -RequiredAnyEnvironment @(
            ,@("PASSPORT_WINDOWS_PRODUCTION_MVP_API_BASE_URL", "PASSPORT_WINDOWS_RELEASE_LANE_API_BASE_URL")
        ) `
        -ExtraCheck ${function:Test-HostedOperatorStatusEndpoint}

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
        -Id "managed_storage_status" `
        -Description "Hosted managed storage is writable and backup-manifest enumeration is available." `
        -RequiredEnvironment @(
            "ARCHREALMS_PASSPORT_HOSTED_OPERATOR_API_KEY"
        ) `
        -RequiredAnyEnvironment @(
            ,@("PASSPORT_WINDOWS_PRODUCTION_MVP_API_BASE_URL", "PASSPORT_WINDOWS_RELEASE_LANE_API_BASE_URL")
        ) `
        -ExtraCheck ${function:Test-HostedStorageStatusEndpoint}

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
        -RequiredEnvironment @(
            "ARCHREALMS_PASSPORT_HOSTED_SIGNING_KEY_PROVIDER",
            "ARCHREALMS_PASSPORT_HOSTED_SIGNING_KEY_ID",
            "ARCHREALMS_PASSPORT_HOSTED_SIGNING_KEY_CUSTODY",
            "ARCHREALMS_PASSPORT_HOSTED_SIGNING_ENDPOINT"
        ) `
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
    package_signing_certificate = $script:packageSigningCertificateReport
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
