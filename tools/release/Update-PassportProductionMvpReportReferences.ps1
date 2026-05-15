param(
    [string]$EnvironmentFile = "artifacts\release\production-mvp.env",

    [switch]$IncludeCurrentPreMvpReport,

    [string]$PreMvpReportPath = "artifacts\release\pre-mvp-internal-verification-report.json",

    [switch]$IncludeCurrentStagingReadinessReport,

    [string]$StagingReadinessReportPath = "artifacts\release\staging-readiness-report.json",

    [switch]$IncludeCurrentCanaryMvpReadinessReport,

    [string]$CanaryMvpReadinessReportPath = "artifacts\release\canary-mvp-readiness-report.json"
)

$ErrorActionPreference = "Stop"
$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\.."))

function Resolve-RepoPath {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return ""
    }

    if ([System.IO.Path]::IsPathRooted($Path)) {
        return [System.IO.Path]::GetFullPath($Path)
    }

    return [System.IO.Path]::GetFullPath((Join-Path $repoRoot $Path))
}

function Get-Sha256Hex {
    param([string]$Path)

    return (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant()
}

function Get-EnvAssignment {
    param(
        [string]$Name,
        [string]$Value
    )

    if ($Value.Contains("`"")) {
        throw "Environment value for $Name contains a double quote and cannot be written safely."
    }

    return "$Name=`"$Value`""
}

function Set-EnvValue {
    param(
        [string[]]$Lines,
        [string]$Name,
        [string]$Value
    )

    $assignment = Get-EnvAssignment -Name $Name -Value $Value
    $pattern = "^\s*(?:export\s+)?$([regex]::Escape($Name))\s*="
    $updated = $false
    $next = New-Object System.Collections.Generic.List[string]

    foreach ($line in $Lines) {
        if (-not $updated -and $line -match $pattern) {
            $next.Add($assignment)
            $updated = $true
        }
        else {
            $next.Add($line)
        }
    }

    if (-not $updated) {
        $next.Add($assignment)
    }

    return ,[string[]]$next.ToArray()
}

function Add-ReportReference {
    param(
        [string[]]$Lines,
        [string]$PathName,
        [string]$HashName,
        [string]$ReportPath
    )

    $resolvedReportPath = Resolve-RepoPath -Path $ReportPath
    if (-not (Test-Path -LiteralPath $resolvedReportPath -PathType Leaf)) {
        throw "Report file was not found: $resolvedReportPath"
    }

    $next = Set-EnvValue -Lines $Lines -Name $PathName -Value $resolvedReportPath
    $next = Set-EnvValue -Lines $next -Name $HashName -Value (Get-Sha256Hex -Path $resolvedReportPath)
    return ,[string[]]$next
}

if (-not $IncludeCurrentPreMvpReport -and -not $IncludeCurrentStagingReadinessReport -and -not $IncludeCurrentCanaryMvpReadinessReport) {
    throw "Select at least one report reference to update."
}

$resolvedEnvironmentFile = Resolve-RepoPath -Path $EnvironmentFile
if (-not (Test-Path -LiteralPath $resolvedEnvironmentFile -PathType Leaf)) {
    throw "Environment file was not found: $resolvedEnvironmentFile"
}

$lines = [string[]](Get-Content -LiteralPath $resolvedEnvironmentFile)

if ($IncludeCurrentPreMvpReport) {
    $lines = Add-ReportReference `
        -Lines $lines `
        -PathName "ARCHREALMS_PASSPORT_PRE_MVP_VERIFICATION_REPORT_PATH" `
        -HashName "ARCHREALMS_PASSPORT_PRE_MVP_VERIFICATION_REPORT_SHA256" `
        -ReportPath $PreMvpReportPath
}

if ($IncludeCurrentStagingReadinessReport) {
    $lines = Add-ReportReference `
        -Lines $lines `
        -PathName "ARCHREALMS_PASSPORT_STAGING_READINESS_REPORT_PATH" `
        -HashName "ARCHREALMS_PASSPORT_STAGING_READINESS_REPORT_SHA256" `
        -ReportPath $StagingReadinessReportPath
}

if ($IncludeCurrentCanaryMvpReadinessReport) {
    $lines = Add-ReportReference `
        -Lines $lines `
        -PathName "ARCHREALMS_PASSPORT_CANARY_MVP_READINESS_REPORT_PATH" `
        -HashName "ARCHREALMS_PASSPORT_CANARY_MVP_READINESS_REPORT_SHA256" `
        -ReportPath $CanaryMvpReadinessReportPath
}

Set-Content -LiteralPath $resolvedEnvironmentFile -Value $lines -Encoding UTF8

[pscustomobject][ordered]@{
    schema = "archrealms.passport.production_mvp_report_reference_update.v1"
    environment_file = $resolvedEnvironmentFile
    pre_mvp_report_reference_updated = [bool]$IncludeCurrentPreMvpReport
    staging_readiness_report_reference_updated = [bool]$IncludeCurrentStagingReadinessReport
    canary_mvp_readiness_report_reference_updated = [bool]$IncludeCurrentCanaryMvpReadinessReport
} | ConvertTo-Json -Depth 4
