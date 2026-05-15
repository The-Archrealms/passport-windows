param(
    [ValidateSet("Json", "PowerShell", "Env")]
    [string]$Format = "Json",

    [string]$OutputPath,

    [switch]$IncludeCurrentPreMvpReport,

    [string]$PreMvpReportPath = "artifacts\release\pre-mvp-internal-verification-report.json",

    [switch]$GenerateOperatorKey,

    [switch]$BlankUnconfiguredValues
)

$ErrorActionPreference = "Stop"
$script:materializedVariableNames = @{}

function New-Variable {
    param(
        [string]$Gate,
        [string]$Name,
        [string]$Description,
        [string]$Example = "",
        [bool]$Required = $true,
        [bool]$Secret = $false
    )

    return [pscustomobject][ordered]@{
        gate = $Gate
        name = $Name
        required = $Required
        secret = $Secret
        description = $Description
        example = $Example
    }
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

function New-OperatorKey {
    $bytes = New-Object byte[] 32
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $rng.GetBytes($bytes)
    }
    finally {
        $rng.Dispose()
    }

    return [Convert]::ToBase64String($bytes)
}

function Set-VariableExample {
    param(
        [object[]]$Variables,
        [string]$Name,
        [string]$Example
    )

    $variable = $Variables | Where-Object { $_.name -eq $Name } | Select-Object -First 1
    if ($null -eq $variable) {
        throw "Template variable not found: $Name"
    }

    $variable.example = $Example
    $script:materializedVariableNames[$Name] = $true
}

function Get-TemplateValue {
    param([object]$Variable)

    if ($BlankUnconfiguredValues -and -not $script:materializedVariableNames.ContainsKey($Variable.name)) {
        return ""
    }

    if ($Variable.example) {
        return $Variable.example
    }

    if ($BlankUnconfiguredValues) {
        return ""
    }

    return "<set value>"
}

$variables = @(
    New-Variable -Gate "pre_mvp_internal_verification" -Name "ARCHREALMS_PASSPORT_PRE_MVP_VERIFICATION_REPORT_PATH" -Description "Path to the passing pre-MVP internal verification report produced by tools/release/Test-PassportPreMvpInternalVerification.ps1."
    New-Variable -Gate "pre_mvp_internal_verification" -Name "ARCHREALMS_PASSPORT_PRE_MVP_VERIFICATION_REPORT_SHA256" -Description "SHA-256 hex digest of the pre-MVP internal verification report."

    New-Variable -Gate "package_signing" -Name "PASSPORT_WINDOWS_MSIX_PFX_BASE64" -Required $false -Secret $true -Description "Base64-encoded stable production MVP MSIX signing PFX. Required unless PASSPORT_WINDOWS_MSIX_PFX_PATH is set."
    New-Variable -Gate "package_signing" -Name "PASSPORT_WINDOWS_MSIX_PFX_PATH" -Required $false -Secret $true -Description "Local path to the stable production MVP MSIX signing PFX. Required unless PASSPORT_WINDOWS_MSIX_PFX_BASE64 is set."
    New-Variable -Gate "package_signing" -Name "PASSPORT_WINDOWS_MSIX_PFX_PASSWORD" -Secret $true -Description "Password for the stable production MVP MSIX signing PFX."
    New-Variable -Gate "package_signing" -Name "PASSPORT_WINDOWS_MSIX_PUBLISHER" -Required $false -Description "Expected MSIX publisher string. The signing certificate subject must match this value." -Example "CN=The Archrealms"
    New-Variable -Gate "package_signing" -Name "PASSPORT_WINDOWS_MSIX_TIMESTAMP_URL" -Description "Authenticode timestamp server used for production MVP package signing." -Example "http://timestamp.sectigo.com"

    New-Variable -Gate "release_lane_endpoints" -Name "PASSPORT_WINDOWS_PRODUCTION_MVP_API_BASE_URL" -Description "Production MVP Passport hosted API base URL." -Example "https://passport.archrealms.example"
    New-Variable -Gate "release_lane_endpoints" -Name "PASSPORT_WINDOWS_PRODUCTION_MVP_AI_GATEWAY_URL" -Description "Production MVP hosted AI gateway URL." -Example "https://ai.archrealms.example"

    New-Variable -Gate "hosted_operator_gate" -Name "ARCHREALMS_PASSPORT_HOSTED_OPERATOR_API_KEY_SHA256" -Description "SHA-256 hex digest of the operator API key accepted by authority-bearing hosted endpoints."
    New-Variable -Gate "hosted_operator_gate" -Name "ARCHREALMS_PASSPORT_HOSTED_OPERATOR_API_KEY" -Secret $true -Description "Actual operator API key used by the production readiness gate to verify authority-bearing hosted endpoint authentication."

    New-Variable -Gate "managed_storage_backups" -Name "ARCHREALMS_PASSPORT_HOSTED_DATA_ROOT" -Description "Managed hosted data root for ledger, capacity, genesis, recovery, telemetry, AI, and storage-delivery records." -Example "/mnt/archrealms-passport-hosted"
    New-Variable -Gate "managed_storage_backups" -Name "ARCHREALMS_PASSPORT_HOSTED_STORAGE_PROVIDER" -Description "Managed durable storage provider identifier." -Example "managed-object-storage"
    New-Variable -Gate "managed_storage_backups" -Name "ARCHREALMS_PASSPORT_HOSTED_STORAGE_BACKUP_POLICY_URI" -Description "URI or controlled document ID for the hosted storage backup policy."
    New-Variable -Gate "managed_storage_backups" -Name "ARCHREALMS_PASSPORT_HOSTED_STORAGE_RESTORE_RUNBOOK_URI" -Description "URI or controlled document ID for the hosted storage restore runbook."

    New-Variable -Gate "managed_signing_key_custody" -Name "ARCHREALMS_PASSPORT_HOSTED_SIGNING_KEY_PROVIDER" -Description "Managed signing-key provider for hosted service signatures and Crown issuance keys." -Example "cloud-kms"
    New-Variable -Gate "managed_signing_key_custody" -Name "ARCHREALMS_PASSPORT_HOSTED_SIGNING_KEY_ID" -Description "Managed signing-key identifier."
    New-Variable -Gate "managed_signing_key_custody" -Name "ARCHREALMS_PASSPORT_HOSTED_SIGNING_KEY_CUSTODY" -Description "Managed custody mode. Allowed values: managed, kms, hsm, managed-hsm, cloud-kms." -Example "kms"
    New-Variable -Gate "managed_signing_key_custody" -Name "ARCHREALMS_PASSPORT_HOSTED_SIGNING_ENDPOINT" -Description "HTTPS endpoint for managed service-record signing. The hosted service sends unsigned record payloads here and receives signature/public-key evidence." -Example "https://signing.archrealms.example/sign"
    New-Variable -Gate "managed_signing_key_custody" -Name "ARCHREALMS_PASSPORT_HOSTED_SIGNING_ENDPOINT_API_KEY" -Required $false -Secret $true -Description "Optional bearer-like secret sent to the managed signing endpoint as X-Archrealms-Managed-Signing-Key."
    New-Variable -Gate "managed_signing_key_custody" -Name "ARCHREALMS_PASSPORT_HOSTED_SIGNING_TIMEOUT_SECONDS" -Required $false -Description "Optional timeout for managed signing endpoint calls." -Example "10"

    New-Variable -Gate "issuer_capacity_genesis_secrets" -Name "ARCHREALMS_PASSPORT_CC_ISSUER_AUTHORITY_ID" -Description "Production MVP Crown Credit issuer authority identifier."
    New-Variable -Gate "issuer_capacity_genesis_secrets" -Name "ARCHREALMS_PASSPORT_CAPACITY_REPORT_ISSUER_ID" -Description "Production MVP conservative capacity-report issuer identifier."
    New-Variable -Gate "issuer_capacity_genesis_secrets" -Name "ARCHREALMS_PASSPORT_ARCH_GENESIS_MANIFEST_ID" -Description "Production MVP fixed-genesis ARCH manifest identifier."
    New-Variable -Gate "issuer_capacity_genesis_secrets" -Name "ARCHREALMS_PASSPORT_PRODUCTION_LEDGER_NAMESPACE" -Description "Production MVP ledger namespace." -Example "archrealms-passport-production-mvp"

    New-Variable -Gate "open_weight_ai_runtime" -Name "ARCHREALMS_PASSPORT_AI_INFERENCE_BASE_URL" -Description "Private OpenAI-compatible vLLM/TGI runtime base URL." -Example "https://model-runtime.internal/v1"
    New-Variable -Gate "open_weight_ai_runtime" -Name "ARCHREALMS_PASSPORT_AI_MODEL_ID" -Description "Approved open-weight model ID for the production MVP lane." -Example "Qwen/Qwen3-8B"
    New-Variable -Gate "open_weight_ai_runtime" -Name "ARCHREALMS_PASSPORT_AI_MODEL_ARTIFACT_SHA256" -Description "SHA-256 hex digest of the approved model artifact."
    New-Variable -Gate "open_weight_ai_runtime" -Name "ARCHREALMS_PASSPORT_AI_MODEL_LICENSE_APPROVAL_ID" -Description "Approval reference for the model license review."
    New-Variable -Gate "open_weight_ai_runtime" -Name "ARCHREALMS_PASSPORT_AI_VECTOR_STORE_PROVIDER" -Description "Managed vector-store provider identifier." -Example "managed-vector-store"
    New-Variable -Gate "open_weight_ai_runtime" -Name "ARCHREALMS_PASSPORT_AI_VECTOR_STORE_ID" -Description "Managed vector-store ID for approved Archrealms knowledge packs."
    New-Variable -Gate "open_weight_ai_runtime" -Name "ARCHREALMS_PASSPORT_AI_KNOWLEDGE_APPROVAL_ROOT" -Description "Approval root/hash or controlled document ID for the production knowledge pack."
    New-Variable -Gate "open_weight_ai_runtime" -Name "ARCHREALMS_PASSPORT_AI_INFERENCE_API_KEY" -Required $false -Secret $true -Description "Bearer credential for the private model runtime, if required."
    New-Variable -Gate "open_weight_ai_runtime" -Name "ARCHREALMS_PASSPORT_AI_SYSTEM_PROMPT" -Required $false -Description "Optional hosted AI system prompt override."
    New-Variable -Gate "open_weight_ai_runtime" -Name "ARCHREALMS_PASSPORT_AI_MAX_OUTPUT_TOKENS" -Required $false -Description "Optional hosted AI max output token limit." -Example "1024"
    New-Variable -Gate "open_weight_ai_runtime" -Name "ARCHREALMS_PASSPORT_AI_TEMPERATURE" -Required $false -Description "Optional hosted AI sampling temperature." -Example "0.2"

    New-Variable -Gate "telemetry_incident_response" -Name "ARCHREALMS_PASSPORT_TELEMETRY_DESTINATION" -Description "Production MVP telemetry destination identifier." -Example "managed-telemetry"
    New-Variable -Gate "telemetry_incident_response" -Name "ARCHREALMS_PASSPORT_TELEMETRY_RETENTION_POLICY_URI" -Description "URI or controlled document ID for telemetry retention policy."
    New-Variable -Gate "telemetry_incident_response" -Name "ARCHREALMS_PASSPORT_INCIDENT_RESPONSE_RUNBOOK_URI" -Description "URI or controlled document ID for production incident response."
    New-Variable -Gate "telemetry_incident_response" -Name "ARCHREALMS_PASSPORT_INCIDENT_RESPONSE_OWNER" -Description "Production incident response owner or rotation ID."

    New-Variable -Gate "production_release_approvals" -Name "ARCHREALMS_PASSPORT_PRODUCTION_RELEASE_APPROVAL_ID" -Description "Product approval reference for production MVP release."
    New-Variable -Gate "production_release_approvals" -Name "ARCHREALMS_PASSPORT_ENGINEERING_SIGNOFF_ID" -Description "Engineering signoff reference for production MVP release."
    New-Variable -Gate "production_release_approvals" -Name "ARCHREALMS_PASSPORT_SECURITY_PRIVACY_SIGNOFF_ID" -Description "Security/privacy signoff reference for production MVP release."
    New-Variable -Gate "production_release_approvals" -Name "ARCHREALMS_PASSPORT_CROWN_MONETARY_AUTHORITY_SIGNOFF_ID" -Description "Crown monetary authority signoff reference for production MVP release."
)

$generatedOperatorKey = ""
$generatedOperatorKeySha256 = ""
if ($IncludeCurrentPreMvpReport) {
    $resolvedReportPath = [System.IO.Path]::GetFullPath($PreMvpReportPath)
    if (-not (Test-Path -LiteralPath $resolvedReportPath -PathType Leaf)) {
        throw "Pre-MVP verification report was not found: $resolvedReportPath"
    }

    $reportSha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $resolvedReportPath).Hash.ToLowerInvariant()
    Set-VariableExample -Variables $variables -Name "ARCHREALMS_PASSPORT_PRE_MVP_VERIFICATION_REPORT_PATH" -Example $resolvedReportPath
    Set-VariableExample -Variables $variables -Name "ARCHREALMS_PASSPORT_PRE_MVP_VERIFICATION_REPORT_SHA256" -Example $reportSha256
}

if ($GenerateOperatorKey) {
    $generatedOperatorKey = New-OperatorKey
    $generatedOperatorKeySha256 = Get-Sha256Hex -Bytes ([System.Text.Encoding]::UTF8.GetBytes($generatedOperatorKey.Trim()))
    Set-VariableExample -Variables $variables -Name "ARCHREALMS_PASSPORT_HOSTED_OPERATOR_API_KEY" -Example $generatedOperatorKey
    Set-VariableExample -Variables $variables -Name "ARCHREALMS_PASSPORT_HOSTED_OPERATOR_API_KEY_SHA256" -Example $generatedOperatorKeySha256
}

$template = [pscustomobject][ordered]@{
    schema = "archrealms.passport.production_mvp_environment_template.v1"
    created_utc = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
    readiness_gate = "tools/release/Test-PassportProductionMvpReadiness.ps1"
    note = "Fill the values in a secure deployment environment. Do not commit populated env files."
    current_pre_mvp_report_included = [bool]$IncludeCurrentPreMvpReport
    generated_operator_key_included = [bool]$GenerateOperatorKey
    generated_operator_key_sha256 = $generatedOperatorKeySha256
    variables = $variables
}

function Convert-ToPowerShellTemplate {
    param([object[]]$Variables)

    $lines = @(
        "# Archrealms Passport Production MVP environment template",
        "# Fill values in a secure shell or deployment secret store. Do not commit populated files.",
        ""
    )
    if ($GenerateOperatorKey) {
        $lines += "# A new operator key was generated for this template. Store it only in the secure production secret store."
        $lines += "# Operator key SHA-256: $generatedOperatorKeySha256"
        $lines += ""
    }

    foreach ($variable in $Variables) {
        $lines += "# gate: $($variable.gate)"
        $lines += "# $($variable.description)"
        if ($variable.secret) {
            $lines += "# secret: true"
        }

        $value = Get-TemplateValue -Variable $variable
        $lines += '$env:' + $variable.name + ' = "' + $value.Replace('"', '\"') + '"'
        $lines += ""
    }

    return ($lines -join [Environment]::NewLine)
}

function Convert-ToEnvTemplate {
    param([object[]]$Variables)

    $lines = @(
        "# Archrealms Passport Production MVP environment template",
        "# Fill values in a secure deployment environment. Do not commit populated files.",
        ""
    )
    if ($GenerateOperatorKey) {
        $lines += "# A new operator key was generated for this template. Store it only in the secure production secret store."
        $lines += "# Operator key SHA-256: $generatedOperatorKeySha256"
        $lines += ""
    }

    foreach ($variable in $Variables) {
        $lines += "# gate: $($variable.gate)"
        $lines += "# $($variable.description)"
        if ($variable.secret) {
            $lines += "# secret: true"
        }

        $value = Get-TemplateValue -Variable $variable
        $lines += "$($variable.name)=$value"
        $lines += ""
    }

    return ($lines -join [Environment]::NewLine)
}

$content = switch ($Format) {
    "PowerShell" { Convert-ToPowerShellTemplate -Variables $variables }
    "Env" { Convert-ToEnvTemplate -Variables $variables }
    default { $template | ConvertTo-Json -Depth 6 }
}

if ($OutputPath) {
    $resolvedOutput = [System.IO.Path]::GetFullPath($OutputPath)
    $parent = Split-Path -Parent $resolvedOutput
    if ($parent) {
        New-Item -ItemType Directory -Force -Path $parent | Out-Null
    }

    Set-Content -LiteralPath $resolvedOutput -Value $content -Encoding UTF8
}

$content
