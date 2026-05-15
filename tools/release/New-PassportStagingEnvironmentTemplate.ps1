param(
    [ValidateSet("Json", "PowerShell", "Env")]
    [string]$Format = "Json",

    [string]$OutputPath,

    [switch]$IncludeCurrentPreMvpReport,

    [string]$PreMvpReportPath = "artifacts\release\pre-mvp-internal-verification-report.json",

    [switch]$IncludeCurrentArtifactValidationReport,

    [string]$ArtifactValidationReportPath = "artifacts\release\staging-artifact-validation-report.json",

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
    New-Variable -Gate "pre_mvp_internal_verification" -Name "ARCHREALMS_PASSPORT_PRE_MVP_VERIFICATION_REPORT_PATH" -Description "Path to the passing pre-MVP internal verification report produced by tools/release/Test-PassportPreMvpInternalVerification.ps1."
    New-Variable -Gate "pre_mvp_internal_verification" -Name "ARCHREALMS_PASSPORT_PRE_MVP_VERIFICATION_REPORT_SHA256" -Description "SHA-256 hex digest of the pre-MVP internal verification report."

    New-Variable -Gate "staging_package_artifact" -Name "ARCHREALMS_PASSPORT_STAGING_ARTIFACT_VALIDATION_REPORT_PATH" -Description "Path to the passing staging artifact validation report produced by tools/release/Test-PassportWindowsReleaseArtifact.ps1."
    New-Variable -Gate "staging_package_artifact" -Name "ARCHREALMS_PASSPORT_STAGING_ARTIFACT_VALIDATION_REPORT_SHA256" -Description "SHA-256 hex digest of the staging artifact validation report."

    New-Variable -Gate "staging_lane_endpoints" -Name "PASSPORT_WINDOWS_STAGING_API_BASE_URL" -Description "Staging Passport hosted API base URL. HTTPS is required unless this is a loopback validation URL." -Example "https://passport-staging.archrealms.example"
    New-Variable -Gate "staging_lane_endpoints" -Name "PASSPORT_WINDOWS_STAGING_AI_GATEWAY_URL" -Description "Staging hosted AI gateway URL. HTTPS is required unless this is a loopback validation URL." -Example "https://ai-staging.archrealms.example"

    New-Variable -Gate "staging_ledger_telemetry" -Name "ARCHREALMS_PASSPORT_STAGING_LEDGER_NAMESPACE" -Description "Staging ledger namespace; must be distinct from production." -Example "archrealms-passport-staging"
    New-Variable -Gate "staging_ledger_telemetry" -Name "ARCHREALMS_PASSPORT_STAGING_TELEMETRY_DESTINATION" -Description "Staging telemetry destination; must be distinct from production." -Example "staging-managed-telemetry"

    New-Variable -Gate "staging_rollback_drill" -Name "ARCHREALMS_PASSPORT_STAGING_ROLLBACK_DRILL_ID" -Description "Controlled evidence ID for the completed staging rollback drill."
    New-Variable -Gate "staging_rollback_drill" -Name "ARCHREALMS_PASSPORT_STAGING_ROLLBACK_DRILL_REPORT_PATH" -Description "Path to the staging rollback drill report using schema archrealms.passport.staging_rollback_drill.v1."
    New-Variable -Gate "staging_rollback_drill" -Name "ARCHREALMS_PASSPORT_STAGING_ROLLBACK_DRILL_REPORT_SHA256" -Description "SHA-256 hex digest of the staging rollback drill report."

    New-Variable -Gate "staging_promotion_approvals" -Name "ARCHREALMS_PASSPORT_STAGING_PROMOTION_APPROVAL_ID" -Description "Product approval reference for staging exit."
    New-Variable -Gate "staging_promotion_approvals" -Name "ARCHREALMS_PASSPORT_STAGING_ENGINEERING_SIGNOFF_ID" -Description "Engineering signoff reference for staging exit."
    New-Variable -Gate "staging_promotion_approvals" -Name "ARCHREALMS_PASSPORT_STAGING_SECURITY_PRIVACY_SIGNOFF_ID" -Description "Security/privacy signoff reference for staging exit."
    New-Variable -Gate "staging_promotion_approvals" -Name "ARCHREALMS_PASSPORT_STAGING_CROWN_MONETARY_AUTHORITY_SIGNOFF_ID" -Description "Crown monetary authority signoff reference for staging exit."
    New-Variable -Gate "staging_promotion_approvals" -Name "ARCHREALMS_PASSPORT_STAGING_PROMOTION_APPROVAL_RECORD_PATH" -Description "Path to the signed staging promotion approval record using schema archrealms.passport.staging_promotion_approval.v1."
    New-Variable -Gate "staging_promotion_approvals" -Name "ARCHREALMS_PASSPORT_STAGING_PROMOTION_APPROVAL_RECORD_SHA256" -Description "SHA-256 hex digest of the signed staging promotion approval record."
)

if ($IncludeCurrentPreMvpReport) {
    $resolvedReportPath = [System.IO.Path]::GetFullPath($PreMvpReportPath)
    if (-not (Test-Path -LiteralPath $resolvedReportPath -PathType Leaf)) {
        throw "Pre-MVP verification report was not found: $resolvedReportPath"
    }

    Set-VariableExample -Variables $variables -Name "ARCHREALMS_PASSPORT_PRE_MVP_VERIFICATION_REPORT_PATH" -Example $resolvedReportPath
    Set-VariableExample -Variables $variables -Name "ARCHREALMS_PASSPORT_PRE_MVP_VERIFICATION_REPORT_SHA256" -Example ((Get-FileHash -Algorithm SHA256 -LiteralPath $resolvedReportPath).Hash.ToLowerInvariant())
}

if ($IncludeCurrentArtifactValidationReport) {
    $resolvedArtifactReportPath = [System.IO.Path]::GetFullPath($ArtifactValidationReportPath)
    if (-not (Test-Path -LiteralPath $resolvedArtifactReportPath -PathType Leaf)) {
        throw "Staging artifact validation report was not found: $resolvedArtifactReportPath"
    }

    Set-VariableExample -Variables $variables -Name "ARCHREALMS_PASSPORT_STAGING_ARTIFACT_VALIDATION_REPORT_PATH" -Example $resolvedArtifactReportPath
    Set-VariableExample -Variables $variables -Name "ARCHREALMS_PASSPORT_STAGING_ARTIFACT_VALIDATION_REPORT_SHA256" -Example ((Get-FileHash -Algorithm SHA256 -LiteralPath $resolvedArtifactReportPath).Hash.ToLowerInvariant())
}

$template = [pscustomobject][ordered]@{
    schema = "archrealms.passport.staging_environment_template.v1"
    created_utc = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
    readiness_gate = "tools/release/Test-PassportStagingReadiness.ps1"
    note = "Fill the values in a secure staging shell or staging secret store. Do not commit populated env files."
    current_pre_mvp_report_included = [bool]$IncludeCurrentPreMvpReport
    current_artifact_validation_report_included = [bool]$IncludeCurrentArtifactValidationReport
    variables = $variables
}

function Convert-ToPowerShellTemplate {
    param([object[]]$Variables)

    $lines = @(
        "# Archrealms Passport Staging environment template",
        "# Fill values in a secure staging shell or staging secret store. Do not commit populated files.",
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
        "# Archrealms Passport Staging environment template",
        "# Fill values in a secure staging environment. Do not commit populated files.",
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
