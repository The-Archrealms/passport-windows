param(
    [string]$ProductionMonetaryPath = "deploy\production-monetary",
    [string]$OutputPath = "artifacts\release\production-monetary-provisioning-failure-shape-validation-report.json",
    [string]$ChildOutputPath = "artifacts\release\production-monetary-provisioning-failure-shape-child-report.json"
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

function Get-CheckById {
    param(
        [object]$Report,
        [string]$Id
    )

    if ($null -eq $Report -or -not $Report.PSObject.Properties["checks"]) {
        return $null
    }

    return @($Report.checks | Where-Object { [string]$_.id -eq $Id } | Select-Object -First 1)
}

function Test-SeparateFailureShape {
    param(
        [object]$ChildCheck,
        [string]$Id,
        [string]$RequiredValidationFailure,
        [string]$ForbiddenJoinedText
    )

    $failures = @()
    $messages = @()
    if ($null -eq $ChildCheck) {
        $failures += "$Id check was not present in the child report."
    }
    else {
        $messages = @($ChildCheck.failures | ForEach-Object { [string]$_ })
        if ($messages.Count -lt 2) {
            $failures += "$Id should report placeholder and field-validation failures as separate entries."
        }
        if (-not @($messages | Where-Object { $_ -like "placeholder values remain in *" })) {
            $failures += "$Id did not include a separate placeholder failure."
        }
        if (-not @($messages | Where-Object { $_ -eq $RequiredValidationFailure })) {
            $failures += "$Id did not include the expected separate validation failure."
        }
        if (@($messages | Where-Object { $_ -match [regex]::Escape($ForbiddenJoinedText) }).Count -gt 0) {
            $failures += "$Id still contains a joined path and validation failure message."
        }
    }

    return New-Check -Id $Id -Passed ($failures.Count -eq 0) -Failures $failures -Evidence @{
        failures = $messages
    }
}

$resolvedOutput = Resolve-InputPath -Path $OutputPath
$resolvedChildOutput = Resolve-InputPath -Path $ChildOutputPath

$outputDirectory = Split-Path -Parent $resolvedOutput
if ($outputDirectory) {
    New-Item -ItemType Directory -Force -Path $outputDirectory | Out-Null
}

$childDirectory = Split-Path -Parent $resolvedChildOutput
if ($childDirectory) {
    New-Item -ItemType Directory -Force -Path $childDirectory | Out-Null
}

Push-Location $repoRoot
try {
    $validatorOutput = & powershell -NoProfile -ExecutionPolicy Bypass -File "tools\release\Test-PassportProductionMonetaryProvisioning.ps1" -ProductionMonetaryPath $ProductionMonetaryPath -RequireNoPlaceholders -OutputPath $resolvedChildOutput 2>&1
    $validatorExitCode = $LASTEXITCODE
    if ($null -eq $validatorExitCode) {
        $validatorExitCode = 0
    }
}
finally {
    Pop-Location
}

$childReport = $null
$childParseFailure = ""
if (Test-Path -LiteralPath $resolvedChildOutput -PathType Leaf) {
    try {
        $childReport = Get-Content -LiteralPath $resolvedChildOutput -Raw | ConvertFrom-Json
    }
    catch {
        $childParseFailure = $_.Exception.Message
    }
}

$checks = @()
$checks += New-Check -Id "validator_failed_closed" -Passed ($validatorExitCode -ne 0) -Failures $(if ($validatorExitCode -eq 0) { @("Production monetary provisioning should fail closed with -RequireNoPlaceholders on placeholder templates.") } else { @() }) -Evidence @{
    exit_code = [int]$validatorExitCode
}
$checks += New-Check -Id "child_report_written" -Passed ((Test-Path -LiteralPath $resolvedChildOutput -PathType Leaf) -and [string]::IsNullOrWhiteSpace($childParseFailure)) -Failures $(if (-not (Test-Path -LiteralPath $resolvedChildOutput -PathType Leaf)) { @("Child report was not written.") } elseif (-not [string]::IsNullOrWhiteSpace($childParseFailure)) { @("Child report could not be parsed: $childParseFailure") } else { @() }) -Evidence @{
    path = $resolvedChildOutput
}

$checks += Test-SeparateFailureShape `
    -ChildCheck (Get-CheckById -Report $childReport -Id "arch_genesis_request_contract") `
    -Id "arch_genesis_request_failure_shape" `
    -RequiredValidationFailure "genesis_authority_record_sha256 must be a SHA-256 hex string" `
    -ForbiddenJoinedText ".jsongenesis_authority_record_sha256"

$checks += Test-SeparateFailureShape `
    -ChildCheck (Get-CheckById -Report $childReport -Id "cc_capacity_request_contract") `
    -Id "cc_capacity_request_failure_shape" `
    -RequiredValidationFailure "capacity_report_authority_record_sha256 must be a SHA-256 hex string" `
    -ForbiddenJoinedText ".jsoncapacity_report_authority_record_sha256"

$failed = @($checks | Where-Object { -not $_.passed })
$outputExcerpt = (($validatorOutput | ForEach-Object { $_.ToString() }) -join [Environment]::NewLine).Trim()
if ($outputExcerpt.Length -gt 4000) {
    $outputExcerpt = $outputExcerpt.Substring($outputExcerpt.Length - 4000)
}

$report = [pscustomobject][ordered]@{
    schema = "archrealms.passport.production_monetary_provisioning_failure_shape_validation.v1"
    created_utc = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
    production_monetary_path = Resolve-InputPath -Path $ProductionMonetaryPath
    child_report_path = $resolvedChildOutput
    passed = $failed.Count -eq 0
    failed_check_count = $failed.Count
    validator_exit_code = [int]$validatorExitCode
    validator_output_excerpt = $outputExcerpt
    checks = $checks
}

$report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $resolvedOutput -Encoding UTF8
$report | ConvertTo-Json -Depth 8

if ($failed.Count -gt 0) {
    exit 1
}
