param(
    [string]$OutputPath = "artifacts\release\production-mvp-readiness-fail-closed-report.json",
    [int]$EndpointTimeoutSeconds = 2,
    [switch]$NoFail
)

$ErrorActionPreference = "Stop"
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path

$readinessEnvironmentVariables = @(
    "ARCHREALMS_PASSPORT_PRE_MVP_VERIFICATION_REPORT_PATH",
    "ARCHREALMS_PASSPORT_PRE_MVP_VERIFICATION_REPORT_SHA256",
    "ARCHREALMS_PASSPORT_STAGING_READINESS_REPORT_PATH",
    "ARCHREALMS_PASSPORT_STAGING_READINESS_REPORT_SHA256",
    "ARCHREALMS_PASSPORT_CANARY_MVP_READINESS_REPORT_PATH",
    "ARCHREALMS_PASSPORT_CANARY_MVP_READINESS_REPORT_SHA256",
    "PASSPORT_WINDOWS_MSIX_PFX_BASE64",
    "PASSPORT_WINDOWS_MSIX_PFX_PATH",
    "PASSPORT_WINDOWS_MSIX_PFX_PASSWORD",
    "PASSPORT_WINDOWS_MSIX_PUBLISHER",
    "PASSPORT_WINDOWS_MSIX_TIMESTAMP_URL",
    "PASSPORT_WINDOWS_SIDELOAD_PFX_BASE64",
    "PASSPORT_WINDOWS_SIDELOAD_PFX_PATH",
    "PASSPORT_WINDOWS_SIDELOAD_PFX_PASSWORD",
    "PASSPORT_WINDOWS_SIDELOAD_PUBLISHER",
    "PASSPORT_WINDOWS_SIDELOAD_TIMESTAMP_URL",
    "PASSPORT_WINDOWS_STORE_PFX_BASE64",
    "PASSPORT_WINDOWS_STORE_PFX_PATH",
    "PASSPORT_WINDOWS_STORE_PFX_PASSWORD",
    "PASSPORT_WINDOWS_STORE_PUBLISHER",
    "PASSPORT_WINDOWS_STORE_TIMESTAMP_URL",
    "PASSPORT_WINDOWS_PRODUCTION_MVP_API_BASE_URL",
    "PASSPORT_WINDOWS_PRODUCTION_MVP_AI_GATEWAY_URL",
    "PASSPORT_WINDOWS_RELEASE_LANE_API_BASE_URL",
    "PASSPORT_WINDOWS_RELEASE_LANE_AI_GATEWAY_URL",
    "ARCHREALMS_PASSPORT_HOSTED_OPERATOR_API_KEY_SHA256",
    "ARCHREALMS_PASSPORT_HOSTED_OPERATOR_API_KEY",
    "ARCHREALMS_PASSPORT_HOSTED_DATA_ROOT",
    "ARCHREALMS_PASSPORT_HOSTED_STORAGE_PROVIDER",
    "ARCHREALMS_PASSPORT_HOSTED_STORAGE_BACKUP_POLICY_URI",
    "ARCHREALMS_PASSPORT_HOSTED_STORAGE_RESTORE_RUNBOOK_URI",
    "ARCHREALMS_PASSPORT_HOSTED_SIGNING_KEY_PROVIDER",
    "ARCHREALMS_PASSPORT_HOSTED_SIGNING_KEY_ID",
    "ARCHREALMS_PASSPORT_HOSTED_SIGNING_KEY_CUSTODY",
    "ARCHREALMS_PASSPORT_HOSTED_SIGNING_ENDPOINT",
    "ARCHREALMS_PASSPORT_HOSTED_SIGNING_ENDPOINT_API_KEY",
    "ARCHREALMS_PASSPORT_HOSTED_SIGNING_TIMEOUT_SECONDS",
    "ARCHREALMS_PASSPORT_HOSTED_SIGNING_KEY_PATH",
    "ARCHREALMS_PASSPORT_CC_ISSUER_AUTHORITY_ID",
    "ARCHREALMS_PASSPORT_CAPACITY_REPORT_ISSUER_ID",
    "ARCHREALMS_PASSPORT_ARCH_GENESIS_MANIFEST_ID",
    "ARCHREALMS_PASSPORT_PRODUCTION_LEDGER_NAMESPACE",
    "ARCHREALMS_PASSPORT_AI_INFERENCE_BASE_URL",
    "ARCHREALMS_PASSPORT_AI_MODEL_ID",
    "ARCHREALMS_PASSPORT_AI_MODEL_ARTIFACT_SHA256",
    "ARCHREALMS_PASSPORT_AI_MODEL_LICENSE_APPROVAL_ID",
    "ARCHREALMS_PASSPORT_AI_VECTOR_STORE_PROVIDER",
    "ARCHREALMS_PASSPORT_AI_VECTOR_STORE_ID",
    "ARCHREALMS_PASSPORT_AI_KNOWLEDGE_APPROVAL_ROOT",
    "ARCHREALMS_PASSPORT_AI_INFERENCE_API_KEY",
    "ARCHREALMS_PASSPORT_AI_SYSTEM_PROMPT",
    "ARCHREALMS_PASSPORT_AI_MAX_OUTPUT_TOKENS",
    "ARCHREALMS_PASSPORT_AI_TEMPERATURE",
    "ARCHREALMS_PASSPORT_TELEMETRY_DESTINATION",
    "ARCHREALMS_PASSPORT_TELEMETRY_RETENTION_POLICY_URI",
    "ARCHREALMS_PASSPORT_INCIDENT_RESPONSE_RUNBOOK_URI",
    "ARCHREALMS_PASSPORT_INCIDENT_RESPONSE_OWNER",
    "ARCHREALMS_PASSPORT_PRODUCTION_RELEASE_APPROVAL_ID",
    "ARCHREALMS_PASSPORT_ENGINEERING_SIGNOFF_ID",
    "ARCHREALMS_PASSPORT_SECURITY_PRIVACY_SIGNOFF_ID",
    "ARCHREALMS_PASSPORT_CROWN_MONETARY_AUTHORITY_SIGNOFF_ID"
)

$expectedFailedGateIds = @(
    "pre_mvp_internal_verification",
    "staging_readiness",
    "canary_mvp_readiness",
    "package_signing",
    "release_lane_endpoints",
    "hosted_runtime_status",
    "hosted_ai_runtime_probe",
    "hosted_operator_gate",
    "hosted_operator_status",
    "managed_storage_backups",
    "managed_storage_status",
    "managed_signing_key_custody",
    "managed_signing_endpoint_probe",
    "issuer_capacity_genesis_secrets",
    "open_weight_ai_runtime",
    "telemetry_incident_response",
    "production_release_approvals"
)

$probeGateIds = @(
    "hosted_runtime_status",
    "hosted_ai_runtime_probe",
    "hosted_operator_status",
    "managed_storage_status",
    "managed_signing_endpoint_probe"
)

function Format-Command {
    param(
        [string]$FilePath,
        [string[]]$Arguments
    )

    $parts = @($FilePath)
    foreach ($argument in $Arguments) {
        if ($argument -match '\s') {
            $parts += '"' + $argument.Replace('"', '\"') + '"'
        }
        else {
            $parts += $argument
        }
    }

    return ($parts -join " ")
}

function Get-OutputExcerpt {
    param([object[]]$Output)

    $text = (($Output | ForEach-Object { $_.ToString() }) -join [Environment]::NewLine).Trim()
    if ($text.Length -le 4000) {
        return $text
    }

    return $text.Substring($text.Length - 4000)
}

$resolvedOutputPath = [System.IO.Path]::GetFullPath($OutputPath)
$outputDirectory = Split-Path -Parent $resolvedOutputPath
if ($outputDirectory) {
    New-Item -ItemType Directory -Force -Path $outputDirectory | Out-Null
}

$subjectReportPath = Join-Path $outputDirectory "production-mvp-readiness-fail-closed-subject-report.json"
$readinessScript = Join-Path $repoRoot "tools\release\Test-PassportProductionMvpReadiness.ps1"
$readinessScriptText = Get-Content -LiteralPath $readinessScript -Raw
$requiredReadinessParityText = @(
    "ExpectedFields",
    "model_artifact_sha256",
    "model_license_approval_id",
    "vector_store_provider",
    "vector_store_id",
    "knowledge_approval_root",
    "does not match production configuration",
    "hosted AI runtime probe endpoint model_id does not match production configuration"
)
$arguments = @(
    "-NoProfile",
    "-ExecutionPolicy",
    "Bypass",
    "-File",
    $readinessScript,
    "-NoFail",
    "-EndpointTimeoutSeconds",
    ([string]$EndpointTimeoutSeconds),
    "-OutputPath",
    $subjectReportPath
)

$savedEnvironment = @{}
foreach ($name in $readinessEnvironmentVariables) {
    $savedEnvironment[$name] = [System.Environment]::GetEnvironmentVariable($name, "Process")
    [System.Environment]::SetEnvironmentVariable($name, $null, "Process")
}

$failures = @()
$sourceContractFailures = @()
foreach ($requiredText in $requiredReadinessParityText) {
    if ($readinessScriptText.IndexOf($requiredText, [StringComparison]::OrdinalIgnoreCase) -lt 0) {
        $sourceContractFailures += "Readiness script is missing AI runtime parity contract text: $requiredText"
    }
}

if ($sourceContractFailures.Count -gt 0) {
    $failures += $sourceContractFailures
}

$toolResult = $null
$subjectReport = $null

try {
    Push-Location $repoRoot
    try {
        $output = & powershell @arguments 2>&1
        $exitCode = $LASTEXITCODE
        if ($null -eq $exitCode) {
            $exitCode = 0
        }

        $toolResult = [pscustomobject][ordered]@{
            command = Format-Command -FilePath "powershell" -Arguments $arguments
            exit_code = [int]$exitCode
            output_excerpt = Get-OutputExcerpt -Output $output
        }
    }
    finally {
        Pop-Location
    }

    if ($toolResult.exit_code -ne 0) {
        $failures += "ProductionMvp readiness fail-closed subject command exited with code $($toolResult.exit_code)."
    }

    if (-not (Test-Path -LiteralPath $subjectReportPath -PathType Leaf)) {
        $failures += "ProductionMvp readiness subject report was not written: $subjectReportPath"
    }
    else {
        $subjectReport = Get-Content -LiteralPath $subjectReportPath -Raw | ConvertFrom-Json
        if ($subjectReport.schema -ne "archrealms.passport.production_mvp_readiness.v1") {
            $failures += "Subject readiness report schema is not archrealms.passport.production_mvp_readiness.v1."
        }

        if ($subjectReport.ready -ne $false) {
            $failures += "ProductionMvp readiness must be ready=false with all production readiness variables cleared."
        }

        if ([int]$subjectReport.failed_gate_count -ne $expectedFailedGateIds.Count) {
            $failures += "Expected $($expectedFailedGateIds.Count) failed gates with all production readiness variables cleared; found $($subjectReport.failed_gate_count)."
        }

        $failedGateIds = @($subjectReport.gates | Where-Object { $_.passed -ne $true } | ForEach-Object { [string]$_.id })
        $passedGateIds = @($subjectReport.gates | Where-Object { $_.passed -eq $true } | ForEach-Object { [string]$_.id })

        if ($passedGateIds.Count -gt 0) {
            $failures += "No ProductionMvp readiness gate may pass with all production readiness variables cleared; passed gates: " + ($passedGateIds -join ", ")
        }

        foreach ($gateId in $expectedFailedGateIds) {
            if ($failedGateIds -notcontains $gateId) {
                $failures += "Expected gate $gateId to fail with all production readiness variables cleared."
            }
        }

        foreach ($gateId in $failedGateIds) {
            if ($expectedFailedGateIds -notcontains $gateId) {
                $failures += "Unexpected failed gate in subject readiness report: $gateId"
            }
        }

        foreach ($gateId in $probeGateIds) {
            $gate = @($subjectReport.gates | Where-Object { $_.id -eq $gateId }) | Select-Object -First 1
            if ($null -eq $gate) {
                $failures += "Probe gate $gateId is missing from the subject readiness report."
                continue
            }

            if ($gate.passed -eq $true) {
                $failures += "Probe gate $gateId must fail closed when production probe inputs are absent."
            }

            if (-not $gate.missing -or @($gate.missing).Count -eq 0) {
                $failures += "Probe gate $gateId must explain which production probe inputs are missing."
            }
        }
    }
}
finally {
    foreach ($name in $readinessEnvironmentVariables) {
        [System.Environment]::SetEnvironmentVariable($name, $savedEnvironment[$name], "Process")
    }
}

$report = [pscustomobject][ordered]@{
    schema = "archrealms.passport.production_mvp_readiness_fail_closed_validation.v1"
    created_utc = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
    repo_root = $repoRoot
    passed = ($failures.Count -eq 0)
    failures = $failures
    expected_failed_gate_ids = $expectedFailedGateIds
    probe_gate_ids = $probeGateIds
    subject_report_path = $subjectReportPath
    source_contract_required_text = $requiredReadinessParityText
    source_contract_failures = $sourceContractFailures
    subject_failed_gate_count = $(if ($null -ne $subjectReport) { [int]$subjectReport.failed_gate_count } else { $null })
    subject_ready = $(if ($null -ne $subjectReport) { [bool]$subjectReport.ready } else { $null })
    tool = $toolResult
}

$json = $report | ConvertTo-Json -Depth 10
Set-Content -LiteralPath $resolvedOutputPath -Value $json -Encoding UTF8
$json

if (-not $report.passed -and -not $NoFail) {
    throw "ProductionMvp readiness fail-closed validation failed: " + ($failures -join "; ")
}
