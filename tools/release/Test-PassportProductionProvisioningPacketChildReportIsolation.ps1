param(
    [string]$FixtureRoot = "artifacts\release\production-provisioning-child-report-isolation-fixture",
    [string]$OutputRoot = "artifacts\release\production-provisioning-child-report-isolation-validation",
    [string]$OutputPath = "artifacts\release\production-provisioning-child-report-isolation-validation-report.json",
    [switch]$NoFail
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

function Format-CommandArgument {
    param([string]$Argument)

    if ($null -eq $Argument) {
        return '""'
    }

    if ($Argument.Length -eq 0 -or $Argument -match '\s|["]') {
        return '"' + ($Argument -replace '"', '\"') + '"'
    }

    return $Argument
}

function Start-ToolProcess {
    param(
        [string]$FilePath,
        [string[]]$Arguments
    )

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $FilePath
    $psi.Arguments = ($Arguments | ForEach-Object { Format-CommandArgument -Argument $_ }) -join " "
    $psi.WorkingDirectory = $repoRoot
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false

    return [System.Diagnostics.Process]::Start($psi)
}

function Complete-ToolProcess {
    param([System.Diagnostics.Process]$Process)

    $stdout = $Process.StandardOutput.ReadToEnd()
    $stderr = $Process.StandardError.ReadToEnd()
    $Process.WaitForExit()

    $output = (($stdout + $stderr) -replace "`r", "").Trim()
    if ($output.Length -gt 4000) {
        $output = $output.Substring($output.Length - 4000)
    }

    return [pscustomobject][ordered]@{
        exit_code = [int]$Process.ExitCode
        output_excerpt = $output
    }
}

function Read-JsonFile {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $null
    }

    return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
}

function Test-ReportPathsUnderRoot {
    param(
        [object]$Report,
        [string]$Root
    )

    if ($null -eq $Report -or $null -eq $Report.checks) {
        return $false
    }

    $rootWithSeparator = $Root.TrimEnd(
        [System.IO.Path]::DirectorySeparatorChar,
        [System.IO.Path]::AltDirectorySeparatorChar
    ) + [System.IO.Path]::DirectorySeparatorChar

    foreach ($check in @($Report.checks)) {
        if ($null -eq $check.evidence -or -not $check.evidence.PSObject.Properties["report_path"]) {
            return $false
        }

        $reportPath = [System.IO.Path]::GetFullPath([string]$check.evidence.report_path)
        if (-not $reportPath.StartsWith($rootWithSeparator, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $false
        }
    }

    return $true
}

function Get-CheckById {
    param(
        [object]$Report,
        [string]$Id
    )

    if ($null -eq $Report -or $null -eq $Report.checks) {
        return $null
    }

    foreach ($check in @($Report.checks)) {
        if ([string]$check.id -eq $Id) {
            return $check
        }
    }

    return $null
}

$resolvedFixtureRoot = Resolve-RepoPath -Path $FixtureRoot
$resolvedOutputRoot = Resolve-RepoPath -Path $OutputRoot
New-Item -ItemType Directory -Force -Path $resolvedOutputRoot | Out-Null

$powershell = Get-Command powershell -ErrorAction Stop

$scaffold = Start-ToolProcess `
    -FilePath $powershell.Source `
    -Arguments @(
        "-NoProfile",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        (Join-Path $scriptRoot "New-PassportProductionProvisioningPacket.ps1"),
        "-OutputDirectory",
        $resolvedFixtureRoot,
        "-Force"
    )
$scaffoldResult = Complete-ToolProcess -Process $scaffold

$templateOutput = Join-Path $resolvedOutputRoot "template-validation-report.json"
$filledOutput = Join-Path $resolvedOutputRoot "filled-gate-report.json"

$templateProcess = Start-ToolProcess `
    -FilePath $powershell.Source `
    -Arguments @(
        "-NoProfile",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        (Join-Path $scriptRoot "Test-PassportProductionProvisioningPacket.ps1"),
        "-PacketRoot",
        $resolvedFixtureRoot,
        "-OutputPath",
        $templateOutput
    )

$filledProcess = Start-ToolProcess `
    -FilePath $powershell.Source `
    -Arguments @(
        "-NoProfile",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        (Join-Path $scriptRoot "Test-PassportProductionProvisioningPacket.ps1"),
        "-PacketRoot",
        $resolvedFixtureRoot,
        "-OutputPath",
        $filledOutput,
        "-RequireNoPlaceholders",
        "-NoFail"
    )

$templateResult = Complete-ToolProcess -Process $templateProcess
$filledResult = Complete-ToolProcess -Process $filledProcess

$templateReport = Read-JsonFile -Path $templateOutput
$filledReport = Read-JsonFile -Path $filledOutput

$failures = @()
if ($scaffoldResult.exit_code -ne 0) {
    $failures += "scaffold generation exited with code $($scaffoldResult.exit_code)"
}
if ($templateResult.exit_code -ne 0) {
    $failures += "template validation exited with code $($templateResult.exit_code)"
}
if ($filledResult.exit_code -ne 0) {
    $failures += "filled gate validation exited with code $($filledResult.exit_code)"
}
if ($null -eq $templateReport -or $templateReport.passed -ne $true) {
    $failures += "template report must pass"
}
if ($null -eq $filledReport -or $filledReport.passed -ne $false) {
    $failures += "filled gate report must fail closed while placeholders remain"
}
if ($templateReport -and $filledReport -and ([string]$templateReport.child_report_root -eq [string]$filledReport.child_report_root)) {
    $failures += "parallel validation reports must use different child_report_root values"
}
if ($templateReport -and -not (Test-Path -LiteralPath ([string]$templateReport.child_report_root) -PathType Container)) {
    $failures += "template child_report_root was not created"
}
if ($filledReport -and -not (Test-Path -LiteralPath ([string]$filledReport.child_report_root) -PathType Container)) {
    $failures += "filled child_report_root was not created"
}
if ($templateReport -and -not (Test-ReportPathsUnderRoot -Report $templateReport -Root ([string]$templateReport.child_report_root))) {
    $failures += "template child report paths must stay under template child_report_root"
}
if ($filledReport -and -not (Test-ReportPathsUnderRoot -Report $filledReport -Root ([string]$filledReport.child_report_root))) {
    $failures += "filled child report paths must stay under filled child_report_root"
}

$filledReleaseEndpointCheck = Get-CheckById -Report $filledReport -Id "release_lane_endpoint_provisioning"
$filledReleaseEndpointReportPath = ""
if ($filledReleaseEndpointCheck -and $filledReleaseEndpointCheck.evidence -and $filledReleaseEndpointCheck.evidence.PSObject.Properties["report_path"]) {
    $filledReleaseEndpointReportPath = [string]$filledReleaseEndpointCheck.evidence.report_path
}

$filledReleaseEndpointReport = if ([string]::IsNullOrWhiteSpace($filledReleaseEndpointReportPath)) { $null } else { Read-JsonFile -Path $filledReleaseEndpointReportPath }
$hostedProgramRouteCheck = Get-CheckById -Report $filledReleaseEndpointReport -Id "hosted_program_route_contract"
if ($null -eq $hostedProgramRouteCheck) {
    $failures += "filled release-lane endpoint child report must include hosted_program_route_contract"
}
elseif ($hostedProgramRouteCheck.passed -ne $true) {
    $failures += "hosted_program_route_contract must pass in filled-gate validation; C# generics must not be treated as operator placeholders"
}

$report = [pscustomobject][ordered]@{
    schema = "archrealms.passport.production_provisioning_child_report_isolation_validation.v1"
    created_utc = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
    fixture_root = $resolvedFixtureRoot
    output_root = $resolvedOutputRoot
    passed = $failures.Count -eq 0
    failed_check_count = $failures.Count
    failures = $failures
    evidence = [pscustomobject][ordered]@{
        scaffold = $scaffoldResult
        template = $templateResult
        filled_gate = $filledResult
        template_report_path = $templateOutput
        filled_gate_report_path = $filledOutput
        filled_release_lane_endpoint_report_path = $filledReleaseEndpointReportPath
        template_child_report_root = if ($templateReport) { [string]$templateReport.child_report_root } else { "" }
        filled_child_report_root = if ($filledReport) { [string]$filledReport.child_report_root } else { "" }
    }
}

$json = $report | ConvertTo-Json -Depth 8
$resolvedOutputPath = Resolve-RepoPath -Path $OutputPath
$resolvedOutputParent = Split-Path -Parent $resolvedOutputPath
if ($resolvedOutputParent) {
    New-Item -ItemType Directory -Force -Path $resolvedOutputParent | Out-Null
}

Set-Content -LiteralPath $resolvedOutputPath -Value $json -Encoding UTF8
$json

if ($failures.Count -gt 0 -and -not $NoFail) {
    throw "Production provisioning child report isolation validation failed: $($failures -join '; ')"
}
