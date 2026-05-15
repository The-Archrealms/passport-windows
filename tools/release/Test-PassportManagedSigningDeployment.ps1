param(
    [string]$DockerfilePath = "deploy\managed-signing\Dockerfile",

    [string]$ComposePath = "deploy\managed-signing\docker-compose.local-validation.yml",

    [string]$EnvTemplatePath = "deploy\managed-signing\managed-signing-env.template",

    [string]$ReadmePath = "deploy\managed-signing\README.md",

    [string]$OutputPath = "artifacts\release\managed-signing-deployment-validation-report.json",

    [switch]$SkipPublish,

    [switch]$ProbeEndpoint,

    [string]$SigningEndpoint = $env:ARCHREALMS_PASSPORT_HOSTED_SIGNING_ENDPOINT,

    [string]$SigningEndpointApiKey = $env:ARCHREALMS_PASSPORT_HOSTED_SIGNING_ENDPOINT_API_KEY,

    [string]$KeyProvider = $env:ARCHREALMS_PASSPORT_HOSTED_SIGNING_KEY_PROVIDER,

    [string]$KeyId = $env:ARCHREALMS_PASSPORT_HOSTED_SIGNING_KEY_ID,

    [string]$KeyCustody = $env:ARCHREALMS_PASSPORT_HOSTED_SIGNING_KEY_CUSTODY,

    [switch]$AllowLocalValidationResponse,

    [int]$EndpointTimeoutSeconds = 10
)

$ErrorActionPreference = "Stop"

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $scriptRoot "..\.."))

function Resolve-RepoPath {
    param([string]$Path)
    return [System.IO.Path]::GetFullPath((Join-Path $repoRoot $Path))
}

function New-Check {
    param(
        [string]$Id,
        [bool]$Passed,
        [string[]]$Failures = @(),
        [object]$Evidence = $null
    )

    $normalizedFailures = @($Failures | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })

    return [pscustomobject][ordered]@{
        id = $Id
        passed = $Passed
        failures = $normalizedFailures
        evidence = $Evidence
    }
}

function Test-TextContains {
    param(
        [string]$Text,
        [string[]]$Required,
        [string[]]$Forbidden = @()
    )

    $failures = New-Object System.Collections.Generic.List[string]
    foreach ($requiredText in $Required) {
        if ($Text.IndexOf($requiredText, [StringComparison]::OrdinalIgnoreCase) -lt 0) {
            $failures.Add("missing text: $requiredText")
        }
    }

    foreach ($forbiddenText in $Forbidden) {
        if ($Text.IndexOf($forbiddenText, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
            $failures.Add("forbidden text: $forbiddenText")
        }
    }

    return $failures.ToArray()
}

function Invoke-CommandCapture {
    param(
        [string]$FilePath,
        [string[]]$Arguments,
        [string]$WorkingDirectory
    )

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $FilePath
    $psi.Arguments = ($Arguments | ForEach-Object { '"' + ($_ -replace '"', '\"') + '"' }) -join " "
    $psi.WorkingDirectory = $WorkingDirectory
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false

    $process = [System.Diagnostics.Process]::Start($psi)
    $stdout = $process.StandardOutput.ReadToEnd()
    $stderr = $process.StandardError.ReadToEnd()
    $process.WaitForExit()

    return [pscustomobject][ordered]@{
        exit_code = $process.ExitCode
        stdout = $stdout
        stderr = $stderr
    }
}

function Get-Sha256Hex {
    param([byte[]]$Bytes)

    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        return [System.BitConverter]::ToString($sha256.ComputeHash($Bytes)).Replace("-", "").ToLowerInvariant()
    }
    finally {
        $sha256.Dispose()
    }
}

function Test-RsaPkcs1Sha256Signature {
    param(
        [byte[]]$PayloadBytes,
        [byte[]]$SignatureBytes,
        [byte[]]$PublicKeySpkiDer
    )

    try {
        $rsa = [System.Security.Cryptography.RSA]::Create()
        try {
            $bytesRead = 0
            $rsa.ImportSubjectPublicKeyInfo($PublicKeySpkiDer, [ref]$bytesRead)
            return $rsa.VerifyData(
                $PayloadBytes,
                $SignatureBytes,
                [System.Security.Cryptography.HashAlgorithmName]::SHA256,
                [System.Security.Cryptography.RSASignaturePadding]::Pkcs1)
        }
        finally {
            $rsa.Dispose()
        }
    }
    catch {
        return $false
    }
}

function Invoke-SigningProbe {
    if ([string]::IsNullOrWhiteSpace($SigningEndpoint)) {
        return New-Check -Id "managed_signing_endpoint_probe" -Passed $false -Failures @("SigningEndpoint is required when -ProbeEndpoint is set.") -Evidence $null
    }

    foreach ($required in @(
        @{ name = "KeyProvider"; value = $KeyProvider },
        @{ name = "KeyId"; value = $KeyId },
        @{ name = "KeyCustody"; value = $KeyCustody }
    )) {
        if ([string]::IsNullOrWhiteSpace([string]$required.value)) {
            return New-Check -Id "managed_signing_endpoint_probe" -Passed $false -Failures @("$($required.name) is required when -ProbeEndpoint is set.") -Evidence $null
        }
    }

    $payloadBytes = [System.Text.Encoding]::UTF8.GetBytes("archrealms-managed-signing-deployment-probe")
    $payloadSha256 = Get-Sha256Hex -Bytes $payloadBytes
    $body = [pscustomobject][ordered]@{
        key_id = $KeyId
        provider = $KeyProvider
        custody = $KeyCustody
        purpose = "production_mvp_readiness_probe"
        payload_sha256 = $payloadSha256
        payload_base64 = [Convert]::ToBase64String($payloadBytes)
    } | ConvertTo-Json -Depth 4

    $headers = @{}
    if (-not [string]::IsNullOrWhiteSpace($SigningEndpointApiKey)) {
        $headers["X-Archrealms-Managed-Signing-Key"] = $SigningEndpointApiKey
    }

    try {
        $response = Invoke-RestMethod -Method Post -Uri $SigningEndpoint -Headers $headers -Body $body -ContentType "application/json" -TimeoutSec $EndpointTimeoutSeconds
    }
    catch {
        return New-Check -Id "managed_signing_endpoint_probe" -Passed $false -Failures @("managed signing endpoint probe failed for $SigningEndpoint`: $($_.Exception.Message)") -Evidence @{ endpoint = $SigningEndpoint }
    }

    $failures = @()
    if ($response.signature_algorithm -ne "RSA_PKCS1_SHA256") {
        $failures += "signature_algorithm must be RSA_PKCS1_SHA256"
    }
    if ($response.signed_payload_sha256 -ne $payloadSha256) {
        $failures += "signed_payload_sha256 must match probe payload"
    }
    if ($response.signing_key_provider -ne $KeyProvider) {
        $failures += "signing_key_provider must match probe key provider"
    }
    if ($response.signing_key_id -ne $KeyId) {
        $failures += "signing_key_id must match probe key id"
    }
    if ($response.signing_key_custody -ne $KeyCustody) {
        $failures += "signing_key_custody must match probe key custody"
    }
    if ($response.local_validation_only -eq $true -and -not $AllowLocalValidationResponse) {
        $failures += "local_validation_only=true is allowed only with -AllowLocalValidationResponse"
    }

    try {
        $signatureBytes = [Convert]::FromBase64String([string]$response.signature_base64)
        $publicKeyBytes = [Convert]::FromBase64String([string]$response.public_key_spki_der_base64)
        if ($response.public_key_sha256 -ne (Get-Sha256Hex -Bytes $publicKeyBytes)) {
            $failures += "public_key_sha256 must match returned public key"
        }
        if (-not (Test-RsaPkcs1Sha256Signature -PayloadBytes $payloadBytes -SignatureBytes $signatureBytes -PublicKeySpkiDer $publicKeyBytes)) {
            $failures += "signature did not verify with returned public key"
        }
    }
    catch {
        $failures += "signature_base64 or public_key_spki_der_base64 is invalid"
    }

    return New-Check -Id "managed_signing_endpoint_probe" -Passed ($failures.Count -eq 0) -Failures $failures -Evidence @{
        endpoint = $SigningEndpoint
        key_provider = $KeyProvider
        key_id = $KeyId
        key_custody = $KeyCustody
        local_validation_only = [bool]$response.local_validation_only
    }
}

$resolvedDockerfile = Resolve-RepoPath $DockerfilePath
$resolvedCompose = Resolve-RepoPath $ComposePath
$resolvedEnvTemplate = Resolve-RepoPath $EnvTemplatePath
$resolvedReadme = Resolve-RepoPath $ReadmePath
$resolvedOutput = Resolve-RepoPath $OutputPath
$publishOutput = Resolve-RepoPath "artifacts\release\managed-signing-publish-validation"
$releaseArtifactsRoot = Resolve-RepoPath "artifacts\release"

$checks = New-Object System.Collections.Generic.List[object]

$missingFiles = @()
foreach ($path in @($resolvedDockerfile, $resolvedCompose, $resolvedEnvTemplate, $resolvedReadme)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        $missingFiles += $path
    }
}
$checks.Add((New-Check -Id "deployment_files_exist" -Passed ($missingFiles.Count -eq 0) -Failures $missingFiles -Evidence @{
    dockerfile = $resolvedDockerfile
    compose = $resolvedCompose
    env_template = $resolvedEnvTemplate
    readme = $resolvedReadme
}))

if ($missingFiles.Count -eq 0) {
    $dockerfileText = Get-Content -LiteralPath $resolvedDockerfile -Raw
    $dockerfileFailures = Test-TextContains `
        -Text $dockerfileText `
        -Required @(
            "mcr.microsoft.com/dotnet/sdk:8.0",
            "mcr.microsoft.com/dotnet/aspnet:8.0",
            "src/ArchrealmsPassport.ManagedSigning/ArchrealmsPassport.ManagedSigning.csproj",
            "dotnet publish src/ArchrealmsPassport.ManagedSigning/ArchrealmsPassport.ManagedSigning.csproj",
            "ASPNETCORE_URLS=http://+:8080",
            "USER archrealms",
            "ENTRYPOINT [""dotnet"", ""ArchrealmsPassport.ManagedSigning.dll""]"
        ) `
        -Forbidden @(
            "ARCHREALMS_MANAGED_SIGNING_API_KEY_SHA256="
        )
    $checks.Add((New-Check -Id "dockerfile_production_posture" -Passed ($dockerfileFailures.Count -eq 0) -Failures $dockerfileFailures -Evidence @{ path = $resolvedDockerfile }))

    $composeText = Get-Content -LiteralPath $resolvedCompose -Raw
    $composeFailures = Test-TextContains `
        -Text $composeText `
        -Required @(
            "deploy/managed-signing/Dockerfile",
            "managed-signing.local-validation.env",
            "127.0.0.1:8081:8080",
            "ARCHREALMS_MANAGED_SIGNING_LOCAL_PKCS8_PATH",
            "managed-signing-local-validation-data"
        )
    $checks.Add((New-Check -Id "compose_local_validation_posture" -Passed ($composeFailures.Count -eq 0) -Failures $composeFailures -Evidence @{ path = $resolvedCompose }))

    $envText = Get-Content -LiteralPath $resolvedEnvTemplate -Raw
    $envFailures = Test-TextContains `
        -Text $envText `
        -Required @(
            "ARCHREALMS_MANAGED_SIGNING_KEY_PROVIDER",
            "ARCHREALMS_MANAGED_SIGNING_KEY_ID",
            "ARCHREALMS_MANAGED_SIGNING_KEY_CUSTODY",
            "ARCHREALMS_MANAGED_SIGNING_API_KEY_SHA256",
            "ARCHREALMS_MANAGED_SIGNING_LOCAL_PKCS8_PATH",
            "ARCHREALMS_MANAGED_SIGNING_COMMAND_PATH",
            "ARCHREALMS_MANAGED_SIGNING_ALLOWED_PURPOSES"
        ) `
        -Forbidden @(
            "sk-",
            "hf-"
        )
    $checks.Add((New-Check -Id "env_template_required_variables" -Passed ($envFailures.Count -eq 0) -Failures $envFailures -Evidence @{ path = $resolvedEnvTemplate }))

    $readmeText = Get-Content -LiteralPath $resolvedReadme -Raw
    $readmeFailures = Test-TextContains `
        -Text $readmeText `
        -Required @(
            "POST /sign",
            "X-Archrealms-Managed-Signing-Key",
            "signing_key_provider",
            "signing_key_id",
            "signing_key_custody",
            "local_validation_only",
            "readiness rejects this mode",
            "Test-PassportManagedSigningDeployment.ps1"
        )
    $checks.Add((New-Check -Id "readme_operator_contract" -Passed ($readmeFailures.Count -eq 0) -Failures $readmeFailures -Evidence @{ path = $resolvedReadme }))
}

if (-not $SkipPublish) {
    if (Test-Path -LiteralPath $publishOutput) {
        $normalizedPublishOutput = [System.IO.Path]::GetFullPath($publishOutput).TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
        $normalizedArtifactsRoot = [System.IO.Path]::GetFullPath($releaseArtifactsRoot).TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
        if (-not $normalizedPublishOutput.StartsWith($normalizedArtifactsRoot, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Refusing to remove publish output outside artifacts release root: $publishOutput"
        }

        Remove-Item -LiteralPath $publishOutput -Recurse -Force
    }

    $dotnet = Get-Command dotnet -ErrorAction SilentlyContinue
    if ($null -eq $dotnet) {
        $checks.Add((New-Check -Id "managed_signing_publish" -Passed $false -Failures @("dotnet was not found on PATH") -Evidence $null))
    }
    else {
        $publish = Invoke-CommandCapture `
            -FilePath $dotnet.Source `
            -Arguments @(
                "publish",
                "src\ArchrealmsPassport.ManagedSigning\ArchrealmsPassport.ManagedSigning.csproj",
                "-c",
                "Release",
                "-o",
                $publishOutput,
                "/p:UseAppHost=false"
            ) `
            -WorkingDirectory $repoRoot
        $publishedDll = Join-Path $publishOutput "ArchrealmsPassport.ManagedSigning.dll"
        $publishFailures = @()
        if ($publish.exit_code -ne 0) {
            $publishFailures += "dotnet publish exited with code $($publish.exit_code)"
        }
        if (-not (Test-Path -LiteralPath $publishedDll -PathType Leaf)) {
            $publishFailures += "published managed signing DLL was not found"
        }

        $checks.Add((New-Check -Id "managed_signing_publish" -Passed ($publishFailures.Count -eq 0) -Failures $publishFailures -Evidence @{
            command = "dotnet publish src\ArchrealmsPassport.ManagedSigning\ArchrealmsPassport.ManagedSigning.csproj -c Release -o $publishOutput /p:UseAppHost=false"
            exit_code = $publish.exit_code
            output_excerpt = (($publish.stdout + $publish.stderr) -replace "\r", "").Trim()
            published_dll = $publishedDll
        }))
    }
}

if ($ProbeEndpoint) {
    $checks.Add((Invoke-SigningProbe))
}
else {
    $checks.Add((New-Check -Id "managed_signing_endpoint_probe" -Passed $true -Failures @() -Evidence @{
        skipped = $true
        reason = "Use -ProbeEndpoint after a local or private managed-signing endpoint is running."
    }))
}

$failed = @($checks | Where-Object { -not $_.passed })
$report = [pscustomobject][ordered]@{
    schema = "archrealms.passport.managed_signing_deployment_validation.v1"
    created_utc = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
    repo_root = $repoRoot
    passed = $failed.Count -eq 0
    failed_check_count = $failed.Count
    endpoint_probe_requested = [bool]$ProbeEndpoint
    checks = $checks
}

$parent = Split-Path -Parent $resolvedOutput
if ($parent) {
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
}
$report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $resolvedOutput -Encoding UTF8
$report | ConvertTo-Json -Depth 8

if ($failed.Count -gt 0) {
    exit 1
}
