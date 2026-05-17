param(
    [string]$VllmComposePath = "deploy\open-weight-ai-runtime\docker-compose.vllm.yml",

    [string]$TgiComposePath = "deploy\open-weight-ai-runtime\docker-compose.tgi.yml",

    [string]$EnvTemplatePath = "deploy\open-weight-ai-runtime\open-weight-ai-runtime.env.template",

    [string]$ReadmePath = "deploy\open-weight-ai-runtime\README.md",

    [string]$ModelApprovalPath = "deploy\open-weight-ai-runtime\model-approval-request.template.md",

    [string]$VectorStoreProvisioningPath = "deploy\open-weight-ai-runtime\vector-store-provisioning.template.md",

    [string]$RuntimeReadinessEvidencePath = "deploy\open-weight-ai-runtime\ai-runtime-readiness-evidence.template.md",

    [string]$OutputPath = "artifacts\release\open-weight-ai-runtime-deployment-validation-report.json",

    [switch]$RequireNoPlaceholders,

    [switch]$ProbeRuntime,

    [string]$RuntimeBaseUrl = $env:ARCHREALMS_PASSPORT_AI_INFERENCE_BASE_URL,

    [string]$ModelId = $env:ARCHREALMS_PASSPORT_AI_MODEL_ID,

    [string]$RuntimeApiKey = $env:ARCHREALMS_PASSPORT_AI_INFERENCE_API_KEY,

    [int]$EndpointTimeoutSeconds = 20
)

$ErrorActionPreference = "Stop"

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $scriptRoot "..\.."))

function Resolve-RepoPath {
    param([string]$Path)

    if ([System.IO.Path]::IsPathRooted($Path)) {
        return [System.IO.Path]::GetFullPath($Path)
    }

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
        [string[]]$Forbidden = @(),
        [string]$Path = ""
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

    if ($RequireNoPlaceholders -and $Text -match '<[^>\r\n]+>') {
        if ([string]::IsNullOrWhiteSpace($Path)) {
            $failures.Add("placeholder values remain")
        }
        else {
            $failures.Add("placeholder values remain in $Path")
        }
    }

    return $failures.ToArray()
}

function Get-EnvTemplateValue {
    param(
        [string]$Text,
        [string]$Name
    )

    foreach ($line in ($Text -split "`r?`n")) {
        $trimmed = $line.Trim()
        if ([string]::IsNullOrWhiteSpace($trimmed) -or $trimmed.StartsWith("#")) {
            continue
        }

        $pattern = "^\s*" + [regex]::Escape($Name) + "\s*=(.*)$"
        $match = [regex]::Match($line, $pattern)
        if ($match.Success) {
            return $match.Groups[1].Value.Trim()
        }
    }

    return ""
}

function Test-RuntimeImagePin {
    param([string]$RuntimeImage)

    $failures = New-Object System.Collections.Generic.List[string]
    if ([string]::IsNullOrWhiteSpace($RuntimeImage)) {
        $failures.Add("ARCHREALMS_PASSPORT_AI_RUNTIME_IMAGE is required.")
        return $failures.ToArray()
    }

    if ($RuntimeImage -match '<[^>\r\n]+>') {
        if ($RequireNoPlaceholders) {
            $failures.Add("ARCHREALMS_PASSPORT_AI_RUNTIME_IMAGE still contains a placeholder value.")
        }

        return $failures.ToArray()
    }

    if ($RuntimeImage -match '(^|[:/])latest($|[@\s])') {
        $failures.Add("ARCHREALMS_PASSPORT_AI_RUNTIME_IMAGE must not use a floating latest tag.")
    }

    if ($RuntimeImage -notmatch '@sha256:[0-9a-fA-F]{64}$' -and $RuntimeImage -notmatch ':[^/:@]+$') {
        $failures.Add("ARCHREALMS_PASSPORT_AI_RUNTIME_IMAGE must include an approved digest or explicit non-latest tag.")
    }

    return $failures.ToArray()
}

function Invoke-RuntimeProbe {
    param(
        [string]$BaseUrl,
        [string]$RuntimeModelId,
        [string]$ApiKey
    )

    if ([string]::IsNullOrWhiteSpace($BaseUrl)) {
        return New-Check -Id "runtime_chat_completion_probe" -Passed $false -Failures @("RuntimeBaseUrl is required when -ProbeRuntime is set.") -Evidence $null
    }

    if ([string]::IsNullOrWhiteSpace($RuntimeModelId)) {
        return New-Check -Id "runtime_chat_completion_probe" -Passed $false -Failures @("ModelId is required when -ProbeRuntime is set.") -Evidence $null
    }

    $endpoint = $BaseUrl.TrimEnd("/") + "/chat/completions"
    $headers = @{}
    if (-not [string]::IsNullOrWhiteSpace($ApiKey)) {
        $headers["Authorization"] = "Bearer " + $ApiKey.Trim()
    }

    $body = [pscustomobject][ordered]@{
        model = $RuntimeModelId
        temperature = 0
        max_tokens = 64
        messages = @(
            [pscustomobject][ordered]@{
                role = "system"
                content = "You are a non-authoritative readiness probe responder."
            },
            [pscustomobject][ordered]@{
                role = "user"
                content = "Readiness probe. Reply with a short confirmation."
            }
        )
    } | ConvertTo-Json -Depth 5

    try {
        $response = Invoke-RestMethod `
            -Method Post `
            -Uri $endpoint `
            -Headers $headers `
            -Body $body `
            -ContentType "application/json" `
            -TimeoutSec $EndpointTimeoutSeconds
    }
    catch {
        return New-Check -Id "runtime_chat_completion_probe" -Passed $false -Failures @("runtime probe failed for $endpoint`: $($_.Exception.Message)") -Evidence @{ endpoint = $endpoint }
    }

    $answer = ""
    if ($response -and $response.choices -and $response.choices.Count -gt 0) {
        $answer = [string]$response.choices[0].message.content
    }

    $failures = @()
    if ([string]::IsNullOrWhiteSpace($answer)) {
        $failures += "runtime response did not include choices[0].message.content"
    }

    return New-Check -Id "runtime_chat_completion_probe" -Passed ($failures.Count -eq 0) -Failures $failures -Evidence @{
        endpoint = $endpoint
        model_id = $RuntimeModelId
        answer_received = -not [string]::IsNullOrWhiteSpace($answer)
    }
}

$resolvedVllmCompose = Resolve-RepoPath $VllmComposePath
$resolvedTgiCompose = Resolve-RepoPath $TgiComposePath
$resolvedEnvTemplate = Resolve-RepoPath $EnvTemplatePath
$resolvedReadme = Resolve-RepoPath $ReadmePath
$resolvedModelApproval = Resolve-RepoPath $ModelApprovalPath
$resolvedVectorStoreProvisioning = Resolve-RepoPath $VectorStoreProvisioningPath
$resolvedRuntimeReadinessEvidence = Resolve-RepoPath $RuntimeReadinessEvidencePath
$resolvedOutput = Resolve-RepoPath $OutputPath

$checks = New-Object System.Collections.Generic.List[object]

$missingFiles = @()
foreach ($path in @($resolvedVllmCompose, $resolvedTgiCompose, $resolvedEnvTemplate, $resolvedReadme, $resolvedModelApproval, $resolvedVectorStoreProvisioning, $resolvedRuntimeReadinessEvidence)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        $missingFiles += $path
    }
}

$checks.Add((New-Check -Id "deployment_files_exist" -Passed ($missingFiles.Count -eq 0) -Failures $missingFiles -Evidence @{
    vllm_compose = $resolvedVllmCompose
    tgi_compose = $resolvedTgiCompose
    env_template = $resolvedEnvTemplate
    readme = $resolvedReadme
    model_approval = $resolvedModelApproval
    vector_store_provisioning = $resolvedVectorStoreProvisioning
    runtime_readiness_evidence = $resolvedRuntimeReadinessEvidence
}))

if ($missingFiles.Count -eq 0) {
    $vllmText = Get-Content -LiteralPath $resolvedVllmCompose -Raw
    $vllmFailures = Test-TextContains `
        -Text $vllmText `
        -Required @(
            "ARCHREALMS_PASSPORT_AI_RUNTIME_IMAGE",
            "ARCHREALMS_PASSPORT_AI_MODEL_ID",
            "--served-model-name",
            '127.0.0.1:${ARCHREALMS_PASSPORT_AI_RUNTIME_HOST_PORT:-8000}:8000',
            "/v1/models",
            "ai-model-cache"
        ) `
        -Forbidden @(
            ":latest",
            '0.0.0.0:${ARCHREALMS_PASSPORT_AI_RUNTIME_HOST_PORT'
        ) `
        -Path $resolvedVllmCompose
    $checks.Add((New-Check -Id "vllm_compose_gateway_contract" -Passed ($vllmFailures.Count -eq 0) -Failures $vllmFailures -Evidence @{ path = $resolvedVllmCompose }))

    $tgiText = Get-Content -LiteralPath $resolvedTgiCompose -Raw
    $tgiFailures = Test-TextContains `
        -Text $tgiText `
        -Required @(
            "ARCHREALMS_PASSPORT_AI_RUNTIME_IMAGE",
            "ARCHREALMS_PASSPORT_AI_MODEL_ID",
            "--model-id",
            '127.0.0.1:${ARCHREALMS_PASSPORT_AI_RUNTIME_HOST_PORT:-8000}:8000',
            "/health",
            "ai-model-cache"
        ) `
        -Forbidden @(
            ":latest",
            '0.0.0.0:${ARCHREALMS_PASSPORT_AI_RUNTIME_HOST_PORT'
        ) `
        -Path $resolvedTgiCompose
    $checks.Add((New-Check -Id "tgi_compose_gateway_contract" -Passed ($tgiFailures.Count -eq 0) -Failures $tgiFailures -Evidence @{ path = $resolvedTgiCompose }))

    $envText = Get-Content -LiteralPath $resolvedEnvTemplate -Raw
    $envFailures = Test-TextContains `
        -Text $envText `
        -Required @(
            "ARCHREALMS_PASSPORT_AI_RUNTIME_PROVIDER",
            "ARCHREALMS_PASSPORT_AI_RUNTIME_IMAGE",
            "ARCHREALMS_PASSPORT_AI_RUNTIME_HOST_PORT",
            "ARCHREALMS_PASSPORT_AI_INFERENCE_BASE_URL",
            "ARCHREALMS_PASSPORT_AI_INFERENCE_API_KEY",
            "ARCHREALMS_PASSPORT_AI_MODEL_ID",
            "ARCHREALMS_PASSPORT_AI_MODEL_ARTIFACT_SHA256",
            "ARCHREALMS_PASSPORT_AI_MODEL_LICENSE_APPROVAL_ID",
            "ARCHREALMS_PASSPORT_AI_VECTOR_STORE_PROVIDER",
            "ARCHREALMS_PASSPORT_AI_VECTOR_STORE_ID",
            "ARCHREALMS_PASSPORT_AI_KNOWLEDGE_APPROVAL_ROOT",
            "ARCHREALMS_PASSPORT_AI_MAX_OUTPUT_TOKENS",
            "ARCHREALMS_PASSPORT_AI_TEMPERATURE",
            "HF_TOKEN"
        ) `
        -Forbidden @(
            "hf-",
            "sk-"
        ) `
        -Path $resolvedEnvTemplate
    $checks.Add((New-Check -Id "env_template_runtime_readiness_variables" -Passed ($envFailures.Count -eq 0) -Failures $envFailures -Evidence @{ path = $resolvedEnvTemplate }))

    $runtimeImage = Get-EnvTemplateValue -Text $envText -Name "ARCHREALMS_PASSPORT_AI_RUNTIME_IMAGE"
    $runtimeImageFailures = Test-RuntimeImagePin -RuntimeImage $runtimeImage
    $checks.Add((New-Check -Id "runtime_image_pin_policy" -Passed ($runtimeImageFailures.Count -eq 0) -Failures $runtimeImageFailures -Evidence @{
        path = $resolvedEnvTemplate
        runtime_image = $runtimeImage
    }))

    $readmeText = Get-Content -LiteralPath $resolvedReadme -Raw
    $readmeFailures = Test-TextContains `
        -Text $readmeText `
        -Required @(
            "Passport clients never call this runtime directly",
            "ARCHREALMS_PASSPORT_AI_RUNTIME_IMAGE",
            "Floating `latest` image tags are forbidden",
            "/v1/chat/completions",
            "docker-compose.vllm.yml",
            "docker-compose.tgi.yml",
            "ARCHREALMS_PASSPORT_AI_INFERENCE_BASE_URL",
            "/ai/runtime/status",
            "/ai/runtime/probe",
            "Test-PassportOpenWeightAiRuntimeDeployment.ps1"
        ) `
        -Path $resolvedReadme
    $checks.Add((New-Check -Id "readme_operator_contract" -Passed ($readmeFailures.Count -eq 0) -Failures $readmeFailures -Evidence @{ path = $resolvedReadme }))

    $modelApprovalText = Get-Content -LiteralPath $resolvedModelApproval -Raw
    $modelApprovalFailures = Test-TextContains `
        -Text $modelApprovalText `
        -Required @(
            "ARCHREALMS_PASSPORT_AI_MODEL_LICENSE_APPROVAL_ID",
            "ARCHREALMS_PASSPORT_AI_MODEL_ID",
            "ARCHREALMS_PASSPORT_AI_MODEL_ARTIFACT_SHA256",
            "ARCHREALMS_PASSPORT_AI_INFERENCE_BASE_URL",
            "open weight",
            "/v1/chat/completions",
            "non-authoritative",
            "open-weight-ai-runtime-deployment-validation-report.json"
        ) `
        -Path $resolvedModelApproval
    $checks.Add((New-Check -Id "model_approval_contract" -Passed ($modelApprovalFailures.Count -eq 0) -Failures $modelApprovalFailures -Evidence @{ path = $resolvedModelApproval }))

    $vectorStoreText = Get-Content -LiteralPath $resolvedVectorStoreProvisioning -Raw
    $vectorStoreFailures = Test-TextContains `
        -Text $vectorStoreText `
        -Required @(
            "ARCHREALMS_PASSPORT_AI_VECTOR_STORE_PROVIDER",
            "ARCHREALMS_PASSPORT_AI_VECTOR_STORE_ID",
            "ARCHREALMS_PASSPORT_AI_KNOWLEDGE_APPROVAL_ROOT",
            "Raw AI prompts",
            "telemetry-retention policy",
            "/ai/runtime/status",
            "quota and non-authority policy"
        ) `
        -Path $resolvedVectorStoreProvisioning
    $checks.Add((New-Check -Id "vector_store_provisioning_contract" -Passed ($vectorStoreFailures.Count -eq 0) -Failures $vectorStoreFailures -Evidence @{ path = $resolvedVectorStoreProvisioning }))

    $runtimeEvidenceText = Get-Content -LiteralPath $resolvedRuntimeReadinessEvidence -Raw
    $runtimeEvidenceFailures = Test-TextContains `
        -Text $runtimeEvidenceText `
        -Required @(
            "ARCHREALMS_PASSPORT_AI_INFERENCE_BASE_URL",
            "ARCHREALMS_PASSPORT_AI_MODEL_ID",
            "ARCHREALMS_PASSPORT_AI_MODEL_ARTIFACT_SHA256",
            "ARCHREALMS_PASSPORT_AI_MODEL_LICENSE_APPROVAL_ID",
            "ARCHREALMS_PASSPORT_AI_VECTOR_STORE_PROVIDER",
            "ARCHREALMS_PASSPORT_AI_VECTOR_STORE_ID",
            "ARCHREALMS_PASSPORT_AI_KNOWLEDGE_APPROVAL_ROOT",
            "open_weight_ai_runtime",
            "hosted_ai_runtime_probe",
            "runtime_answer_received=true",
            "matched the approved production model ID",
            "returned the approved production model ID"
        ) `
        -Path $resolvedRuntimeReadinessEvidence
    $checks.Add((New-Check -Id "ai_runtime_readiness_evidence_contract" -Passed ($runtimeEvidenceFailures.Count -eq 0) -Failures $runtimeEvidenceFailures -Evidence @{ path = $resolvedRuntimeReadinessEvidence }))
}

if ($ProbeRuntime) {
    $checks.Add((Invoke-RuntimeProbe -BaseUrl $RuntimeBaseUrl -RuntimeModelId $ModelId -ApiKey $RuntimeApiKey))
}
else {
    $checks.Add((New-Check -Id "runtime_chat_completion_probe" -Passed $true -Failures @() -Evidence @{
        skipped = $true
        reason = "Use -ProbeRuntime with -RuntimeBaseUrl and -ModelId after a local or private runtime is running."
    }))
}

$failed = @($checks | Where-Object { -not $_.passed })
$report = [pscustomobject][ordered]@{
    schema = "archrealms.passport.open_weight_ai_runtime_deployment_validation.v1"
    created_utc = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
    repo_root = $repoRoot
    passed = $failed.Count -eq 0
    failed_check_count = $failed.Count
    require_no_placeholders = [bool]$RequireNoPlaceholders
    runtime_probe_requested = [bool]$ProbeRuntime
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
