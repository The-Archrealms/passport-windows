param(
    [string]$EnvironmentFile,
    [string]$PfxPath,
    [string]$PfxBase64,
    [string]$Password,
    [string]$ExpectedPublisher,
    [string]$TimestampUrl,
    [int]$MinimumDaysValid = 30,
    [switch]$DisallowSelfSigned,
    [string]$OutputPath,
    [switch]$NoFail
)

$ErrorActionPreference = "Stop"
Import-Module (Join-Path $PSScriptRoot "PassportWindowsRelease.psm1") -Force -DisableNameChecking

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

$loadedEnvironmentVariables = Import-EnvironmentFile -Path $EnvironmentFile

if (-not $PfxPath) {
    $PfxPath = Get-FirstEnvironmentValue -Names @(
        "PASSPORT_WINDOWS_MSIX_PFX_PATH",
        "PASSPORT_WINDOWS_SIDELOAD_PFX_PATH",
        "PASSPORT_WINDOWS_STORE_PFX_PATH"
    )
}

if (-not $PfxBase64) {
    $PfxBase64 = Get-FirstEnvironmentValue -Names @(
        "PASSPORT_WINDOWS_MSIX_PFX_BASE64",
        "PASSPORT_WINDOWS_SIDELOAD_PFX_BASE64",
        "PASSPORT_WINDOWS_STORE_PFX_BASE64"
    )
}

if (-not $Password) {
    $Password = Get-FirstEnvironmentValue -Names @(
        "PASSPORT_WINDOWS_MSIX_PFX_PASSWORD",
        "PASSPORT_WINDOWS_SIDELOAD_PFX_PASSWORD",
        "PASSPORT_WINDOWS_STORE_PFX_PASSWORD"
    )
}

if (-not $TimestampUrl) {
    $TimestampUrl = Get-FirstEnvironmentValue -Names @(
        "PASSPORT_WINDOWS_MSIX_TIMESTAMP_URL",
        "PASSPORT_WINDOWS_SIDELOAD_TIMESTAMP_URL",
        "PASSPORT_WINDOWS_STORE_TIMESTAMP_URL"
    )
}

if (-not $ExpectedPublisher) {
    $ExpectedPublisher = Get-FirstEnvironmentValue -Names @(
        "PASSPORT_WINDOWS_MSIX_PUBLISHER",
        "PASSPORT_WINDOWS_SIDELOAD_PUBLISHER",
        "PASSPORT_WINDOWS_STORE_PUBLISHER"
    )
}

if (-not $ExpectedPublisher) {
    $ExpectedPublisher = "CN=The Archrealms"
}

$report = Test-PassportWindowsSigningCertificateInput `
    -PfxPath $PfxPath `
    -PfxBase64 $PfxBase64 `
    -Password $Password `
    -ExpectedPublisher $ExpectedPublisher `
    -TimestampUrl $TimestampUrl `
    -MinimumDaysValid $MinimumDaysValid `
    -DisallowSelfSigned:$DisallowSelfSigned.IsPresent

$report | Add-Member -NotePropertyName environment_file_loaded -NotePropertyValue (-not [string]::IsNullOrWhiteSpace($EnvironmentFile))
$report | Add-Member -NotePropertyName environment_file_variable_count -NotePropertyValue $loadedEnvironmentVariables.Count
$report | Add-Member -NotePropertyName environment_file_variables -NotePropertyValue $loadedEnvironmentVariables

$json = $report | ConvertTo-Json -Depth 8
if ($OutputPath) {
    $resolvedOutput = [System.IO.Path]::GetFullPath($OutputPath)
    $outputDirectory = Split-Path -Parent $resolvedOutput
    if ($outputDirectory) {
        New-Item -ItemType Directory -Force -Path $outputDirectory | Out-Null
    }

    Set-Content -LiteralPath $resolvedOutput -Value $json -Encoding UTF8
}

$json
if ($report.passed -ne $true -and -not $NoFail) {
    throw "Passport Windows signing certificate check failed."
}
