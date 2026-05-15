param(
    [ValidateSet("Json", "PowerShell", "Env")]
    [string]$Format = "Json",

    [string]$OutputPath,

    [switch]$IncludeCurrentStagingReadinessReport,

    [string]$StagingReadinessReportPath = "artifacts\release\staging-readiness-report.json",

    [switch]$IncludeCurrentArtifactValidationReport,

    [string]$ArtifactValidationReportPath = "artifacts\release\canary-artifact-validation-report.json",

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
    New-Variable -Gate "staging_readiness" -Name "ARCHREALMS_PASSPORT_STAGING_READINESS_REPORT_PATH" -Description "Path to the passing non-synthetic staging readiness report produced by tools/release/Test-PassportStagingReadiness.ps1."
    New-Variable -Gate "staging_readiness" -Name "ARCHREALMS_PASSPORT_STAGING_READINESS_REPORT_SHA256" -Description "SHA-256 hex digest of the staging readiness report."

    New-Variable -Gate "canary_package_artifact" -Name "ARCHREALMS_PASSPORT_CANARY_ARTIFACT_VALIDATION_REPORT_PATH" -Description "Path to the passing CanaryMvp artifact validation report produced by tools/release/Test-PassportWindowsReleaseArtifact.ps1."
    New-Variable -Gate "canary_package_artifact" -Name "ARCHREALMS_PASSPORT_CANARY_ARTIFACT_VALIDATION_REPORT_SHA256" -Description "SHA-256 hex digest of the CanaryMvp artifact validation report."

    New-Variable -Gate "canary_policy_limits" -Name "ARCHREALMS_PASSPORT_CANARY_POLICY_ID" -Description "Controlled evidence ID for the approved Canary MVP policy limits."
    New-Variable -Gate "canary_policy_limits" -Name "ARCHREALMS_PASSPORT_CANARY_POLICY_REPORT_PATH" -Description "Path to the canary policy report using schema archrealms.passport.canary_policy.v1."
    New-Variable -Gate "canary_policy_limits" -Name "ARCHREALMS_PASSPORT_CANARY_POLICY_REPORT_SHA256" -Description "SHA-256 hex digest of the canary policy report."

    New-Variable -Gate "canary_incident_review" -Name "ARCHREALMS_PASSPORT_CANARY_INCIDENT_REVIEW_ID" -Description "Controlled evidence ID for the completed Canary MVP incident review."
    New-Variable -Gate "canary_incident_review" -Name "ARCHREALMS_PASSPORT_CANARY_INCIDENT_REVIEW_REPORT_PATH" -Description "Path to the canary incident review report using schema archrealms.passport.canary_incident_review.v1."
    New-Variable -Gate "canary_incident_review" -Name "ARCHREALMS_PASSPORT_CANARY_INCIDENT_REVIEW_REPORT_SHA256" -Description "SHA-256 hex digest of the canary incident review report."

    New-Variable -Gate "canary_balance_reconciliation" -Name "ARCHREALMS_PASSPORT_CANARY_BALANCE_RECONCILIATION_ID" -Description "Controlled evidence ID for Canary MVP ARCH/CC/escrow/burn/refund/re-credit balance reconciliation."
    New-Variable -Gate "canary_balance_reconciliation" -Name "ARCHREALMS_PASSPORT_CANARY_BALANCE_RECONCILIATION_REPORT_PATH" -Description "Path to the canary balance reconciliation report using schema archrealms.passport.canary_balance_reconciliation.v1."
    New-Variable -Gate "canary_balance_reconciliation" -Name "ARCHREALMS_PASSPORT_CANARY_BALANCE_RECONCILIATION_REPORT_SHA256" -Description "SHA-256 hex digest of the canary balance reconciliation report."

    New-Variable -Gate "canary_service_delivery_reconciliation" -Name "ARCHREALMS_PASSPORT_CANARY_SERVICE_DELIVERY_RECONCILIATION_ID" -Description "Controlled evidence ID for Canary MVP service-delivery reconciliation."
    New-Variable -Gate "canary_service_delivery_reconciliation" -Name "ARCHREALMS_PASSPORT_CANARY_SERVICE_DELIVERY_RECONCILIATION_REPORT_PATH" -Description "Path to the canary service-delivery reconciliation report using schema archrealms.passport.canary_service_delivery_reconciliation.v1."
    New-Variable -Gate "canary_service_delivery_reconciliation" -Name "ARCHREALMS_PASSPORT_CANARY_SERVICE_DELIVERY_RECONCILIATION_REPORT_SHA256" -Description "SHA-256 hex digest of the canary service-delivery reconciliation report."

    New-Variable -Gate "canary_support_readiness" -Name "ARCHREALMS_PASSPORT_CANARY_SUPPORT_READINESS_ID" -Description "Controlled evidence ID for Canary MVP support and recovery readiness."
    New-Variable -Gate "canary_support_readiness" -Name "ARCHREALMS_PASSPORT_CANARY_SUPPORT_READINESS_REPORT_PATH" -Description "Path to the canary support readiness report using schema archrealms.passport.canary_support_readiness.v1."
    New-Variable -Gate "canary_support_readiness" -Name "ARCHREALMS_PASSPORT_CANARY_SUPPORT_READINESS_REPORT_SHA256" -Description "SHA-256 hex digest of the canary support readiness report."

    New-Variable -Gate "canary_production_approvals" -Name "ARCHREALMS_PASSPORT_CANARY_PRODUCTION_APPROVAL_ID" -Description "Product approval reference for Canary MVP to Production MVP promotion."
    New-Variable -Gate "canary_production_approvals" -Name "ARCHREALMS_PASSPORT_CANARY_ENGINEERING_SIGNOFF_ID" -Description "Engineering signoff reference for Canary MVP to Production MVP promotion."
    New-Variable -Gate "canary_production_approvals" -Name "ARCHREALMS_PASSPORT_CANARY_SECURITY_PRIVACY_SIGNOFF_ID" -Description "Security/privacy signoff reference for Canary MVP to Production MVP promotion."
    New-Variable -Gate "canary_production_approvals" -Name "ARCHREALMS_PASSPORT_CANARY_CROWN_MONETARY_AUTHORITY_SIGNOFF_ID" -Description "Crown monetary authority signoff reference for Canary MVP to Production MVP promotion."
    New-Variable -Gate "canary_production_approvals" -Name "ARCHREALMS_PASSPORT_CANARY_PRODUCTION_APPROVAL_RECORD_PATH" -Description "Path to the signed canary production approval record using schema archrealms.passport.canary_production_approval.v1."
    New-Variable -Gate "canary_production_approvals" -Name "ARCHREALMS_PASSPORT_CANARY_PRODUCTION_APPROVAL_RECORD_SHA256" -Description "SHA-256 hex digest of the signed canary production approval record."
)

if ($IncludeCurrentStagingReadinessReport) {
    $resolvedReportPath = [System.IO.Path]::GetFullPath($StagingReadinessReportPath)
    if (-not (Test-Path -LiteralPath $resolvedReportPath -PathType Leaf)) {
        throw "Staging readiness report was not found: $resolvedReportPath"
    }

    Set-VariableExample -Variables $variables -Name "ARCHREALMS_PASSPORT_STAGING_READINESS_REPORT_PATH" -Example $resolvedReportPath
    Set-VariableExample -Variables $variables -Name "ARCHREALMS_PASSPORT_STAGING_READINESS_REPORT_SHA256" -Example ((Get-FileHash -Algorithm SHA256 -LiteralPath $resolvedReportPath).Hash.ToLowerInvariant())
}

if ($IncludeCurrentArtifactValidationReport) {
    $resolvedArtifactReportPath = [System.IO.Path]::GetFullPath($ArtifactValidationReportPath)
    if (-not (Test-Path -LiteralPath $resolvedArtifactReportPath -PathType Leaf)) {
        throw "Canary artifact validation report was not found: $resolvedArtifactReportPath"
    }

    Set-VariableExample -Variables $variables -Name "ARCHREALMS_PASSPORT_CANARY_ARTIFACT_VALIDATION_REPORT_PATH" -Example $resolvedArtifactReportPath
    Set-VariableExample -Variables $variables -Name "ARCHREALMS_PASSPORT_CANARY_ARTIFACT_VALIDATION_REPORT_SHA256" -Example ((Get-FileHash -Algorithm SHA256 -LiteralPath $resolvedArtifactReportPath).Hash.ToLowerInvariant())
}

$template = [pscustomobject][ordered]@{
    schema = "archrealms.passport.canary_mvp_environment_template.v1"
    created_utc = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
    readiness_gate = "tools/release/Test-PassportCanaryMvpReadiness.ps1"
    note = "Fill the values in a secure canary operations shell or secret store. Do not commit populated env files."
    current_staging_readiness_report_included = [bool]$IncludeCurrentStagingReadinessReport
    current_artifact_validation_report_included = [bool]$IncludeCurrentArtifactValidationReport
    variables = $variables
}

function Convert-ToPowerShellTemplate {
    param([object[]]$Variables)

    $lines = @(
        "# Archrealms Passport Canary MVP environment template",
        "# Fill values in a secure canary operations shell or secret store. Do not commit populated files.",
        ""
    )

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
        "# Archrealms Passport Canary MVP environment template",
        "# Fill values in a secure canary operations environment. Do not commit populated files.",
        ""
    )

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

