param(
    [string]$ReportPath = "artifacts\release\production-mvp-outstanding-work-report.json",
    [string]$MarkdownPath = "artifacts\release\production-mvp-outstanding-work-report.md",
    [string]$OutputPath = "artifacts\release\production-mvp-outstanding-work-validation-report.json",
    [switch]$Generate,
    [switch]$UseGeneratedFixture,
    [switch]$RequireReady,
    [switch]$NoFail
)

$ErrorActionPreference = "Stop"
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path

function Resolve-RepoPath {
    param([string]$Path)

    if ([System.IO.Path]::IsPathRooted($Path)) {
        return $Path
    }

    return (Join-Path $repoRoot $Path)
}

function Get-Sha256Hex {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return ""
    }

    return (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant()
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

function Invoke-OutstandingWorkGenerator {
    param(
        [string]$JsonPath,
        [string]$MarkdownOutputPath,
        [bool]$Fixture
    )

    $powershell = Get-Command powershell -ErrorAction Stop
    $generator = Resolve-RepoPath -Path "tools\release\New-PassportProductionMvpOutstandingWorkReport.ps1"
    $args = @(
        "-NoProfile",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        $generator,
        "-OutputPath",
        $JsonPath,
        "-MarkdownOutputPath",
        $MarkdownOutputPath,
        "-NoFail"
    )

    if ($Fixture) {
        $args += "-UseGeneratedFixture"
    }

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $powershell.Source
    $psi.Arguments = ($args | ForEach-Object { Format-CommandArgument -Argument $_ }) -join " "
    $psi.WorkingDirectory = $repoRoot
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false

    $process = [System.Diagnostics.Process]::Start($psi)
    $stdout = $process.StandardOutput.ReadToEnd()
    $stderr = $process.StandardError.ReadToEnd()
    $process.WaitForExit()

    $output = (($stdout + $stderr) -replace "`r", "").Trim()
    if ($output.Length -gt 4000) {
        $output = $output.Substring($output.Length - 4000)
    }

    return [pscustomobject][ordered]@{
        command = (($args | ForEach-Object { Format-CommandArgument -Argument $_ }) -join " ")
        exit_code = [int]$process.ExitCode
        output_excerpt = $output
    }
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
        failures = @($Failures)
        evidence = $Evidence
    }
}

function Add-Check {
    param(
        [string]$Id,
        [bool]$Condition,
        [string]$Failure,
        [object]$Evidence = $null
    )

    $failures = @()
    if (-not $Condition) {
        $failures += $Failure
    }

    return New-Check -Id $Id -Passed $Condition -Failures $failures -Evidence $Evidence
}

function Get-ObjectArray {
    param(
        [object]$Object,
        [string]$Name
    )

    if ($null -eq $Object -or -not $Object.PSObject.Properties[$Name]) {
        return @()
    }

    return @($Object.$Name)
}

function Read-ObjectInt {
    param(
        [object]$Object,
        [string]$Name
    )

    if ($null -eq $Object -or -not $Object.PSObject.Properties[$Name]) {
        return 0
    }

    return [int]$Object.$Name
}

function Get-OperatorCommandScriptPath {
    param([string]$Command)

    if ([string]::IsNullOrWhiteSpace($Command)) {
        return ""
    }

    $match = [regex]::Match($Command, '(?i)(?:^|\s)-File\s+(?:"([^"]+)"|''([^'']+)''|([^\s]+))')
    if (-not $match.Success) {
        return ""
    }

    for ($i = 1; $i -le 3; $i++) {
        if ($match.Groups[$i].Success -and -not [string]::IsNullOrWhiteSpace($match.Groups[$i].Value)) {
            return [string]$match.Groups[$i].Value
        }
    }

    return ""
}

function Add-CommandRecord {
    param(
        [System.Collections.Generic.List[object]]$Records,
        [string]$Source,
        [string]$Command
    )

    if ([string]::IsNullOrWhiteSpace($Command)) {
        $Records.Add([pscustomobject][ordered]@{
            source = $Source
            command = ""
            script_path = ""
        })
        return
    }

    $Records.Add([pscustomobject][ordered]@{
        source = $Source
        command = [string]$Command
        script_path = Get-OperatorCommandScriptPath -Command ([string]$Command)
    })
}

function Add-ActionCommandRecords {
    param(
        [System.Collections.Generic.List[object]]$Records,
        [string]$Source,
        [object]$Action
    )

    foreach ($command in Get-ObjectArray -Object $Action -Name "commands") {
        Add-CommandRecord -Records $Records -Source $Source -Command ([string]$command)
    }
}

function Add-CommandArrayRecords {
    param(
        [System.Collections.Generic.List[object]]$Records,
        [string]$Source,
        [object[]]$Commands
    )

    foreach ($command in @($Commands)) {
        Add-CommandRecord -Records $Records -Source $Source -Command ([string]$command)
    }
}

function Test-CommandRecord {
    param([object]$Record)

    $failures = @()
    $command = [string]$Record.command
    $scriptPath = [string]$Record.script_path

    if ([string]::IsNullOrWhiteSpace($command)) {
        $failures += "$($Record.source) command is empty."
        return $failures
    }

    if ([string]::IsNullOrWhiteSpace($scriptPath)) {
        $failures += "$($Record.source) command must include a PowerShell -File script path: $command"
        return $failures
    }

    if ($scriptPath -match '[<>]') {
        $failures += "$($Record.source) command script path must not contain placeholder brackets: $command"
        return $failures
    }

    $resolvedScriptPath = Resolve-RepoPath -Path $scriptPath
    $releaseRoot = Resolve-RepoPath -Path "tools\release"
    $normalizedScriptPath = [System.IO.Path]::GetFullPath($resolvedScriptPath)
    $normalizedReleaseRoot = [System.IO.Path]::GetFullPath($releaseRoot).TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
    $releasePrefix = $normalizedReleaseRoot + [System.IO.Path]::DirectorySeparatorChar

    if (-not $normalizedScriptPath.StartsWith($releasePrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        $failures += "$($Record.source) command must target a tools\release PowerShell script: $command"
    }

    if ([System.IO.Path]::GetExtension($normalizedScriptPath) -ne ".ps1") {
        $failures += "$($Record.source) command must target a .ps1 script: $command"
    }

    if (-not (Test-Path -LiteralPath $normalizedScriptPath -PathType Leaf)) {
        $failures += "$($Record.source) command script does not exist: $scriptPath"
    }

    return $failures
}

if ($UseGeneratedFixture) {
    $ReportPath = "artifacts\release\production-mvp-outstanding-work-fixture\production-mvp-outstanding-work-report.json"
    $MarkdownPath = "artifacts\release\production-mvp-outstanding-work-fixture\production-mvp-outstanding-work-report.md"
}

$resolvedReportPath = Resolve-RepoPath -Path $ReportPath
$resolvedMarkdownPath = Resolve-RepoPath -Path $MarkdownPath
$resolvedOutputPath = Resolve-RepoPath -Path $OutputPath

$checks = @()
$generatorResult = $null
if ($Generate -or $UseGeneratedFixture) {
    $generatorResult = Invoke-OutstandingWorkGenerator -JsonPath $resolvedReportPath -MarkdownOutputPath $resolvedMarkdownPath -Fixture ([bool]$UseGeneratedFixture)
    $checks += Add-Check -Id "generator_exit_code" -Condition ($generatorResult.exit_code -eq 0) -Failure "outstanding-work generator exited with code $($generatorResult.exit_code)" -Evidence $generatorResult
}

$reportExists = Test-Path -LiteralPath $resolvedReportPath -PathType Leaf
$markdownExists = Test-Path -LiteralPath $resolvedMarkdownPath -PathType Leaf
$checks += Add-Check -Id "report_exists" -Condition $reportExists -Failure "outstanding-work JSON report is missing" -Evidence ([pscustomobject][ordered]@{ path = $resolvedReportPath })
$checks += Add-Check -Id "markdown_exists" -Condition $markdownExists -Failure "outstanding-work Markdown report is missing" -Evidence ([pscustomobject][ordered]@{ path = $resolvedMarkdownPath })

$report = $null
if ($reportExists) {
    try {
        $report = Get-Content -LiteralPath $resolvedReportPath -Raw | ConvertFrom-Json
    }
    catch {
        $checks += New-Check -Id "report_json_parse" -Passed $false -Failures @("outstanding-work JSON report could not be parsed: $($_.Exception.Message)")
    }
}

if ($null -ne $report) {
    $checks += Add-Check -Id "schema" -Condition ([string]$report.schema -eq "archrealms.passport.production_mvp_outstanding_work_report.v1") -Failure "unexpected outstanding-work report schema"
    $checks += Add-Check -Id "input_failures_absent" -Condition ((Get-ObjectArray -Object $report -Name "input_failures").Count -eq 0) -Failure "outstanding-work report has input failures"

    $failedReadinessGates = @(Get-ObjectArray -Object $report -Name "failed_readiness_gates")
    $failedProvisioningChecks = @(Get-ObjectArray -Object $report -Name "failed_provisioning_checks")
    $failedReleaseEvidenceChecks = @(Get-ObjectArray -Object $report -Name "failed_release_evidence_checks")
    $closeoutFailures = @(Get-ObjectArray -Object $report -Name "closeout_failures")
    $matrix = $report.operator_input_matrix
    $environmentVariables = @(Get-ObjectArray -Object $matrix -Name "environment_variables")
    $reportReferenceRefreshes = @(Get-ObjectArray -Object $matrix -Name "report_reference_refreshes")
    $readinessEvidenceItems = @(Get-ObjectArray -Object $matrix -Name "readiness_evidence_items")
    $provisioningEvidenceFiles = @(Get-ObjectArray -Object $matrix -Name "provisioning_evidence_files")
    $releaseEvidenceItems = @(Get-ObjectArray -Object $matrix -Name "release_evidence_items")
    $summary = $report.summary

    $countFailures = @()
    if ((Read-ObjectInt -Object $summary -Name "closeout_failure_count") -ne $closeoutFailures.Count) { $countFailures += "closeout_failure_count does not match closeout_failures." }
    if ((Read-ObjectInt -Object $summary -Name "failed_readiness_gate_count") -ne $failedReadinessGates.Count) { $countFailures += "failed_readiness_gate_count does not match failed_readiness_gates." }
    if ((Read-ObjectInt -Object $summary -Name "failed_provisioning_check_count") -ne $failedProvisioningChecks.Count) { $countFailures += "failed_provisioning_check_count does not match failed_provisioning_checks." }
    if ((Read-ObjectInt -Object $summary -Name "failed_release_evidence_check_count") -ne $failedReleaseEvidenceChecks.Count) { $countFailures += "failed_release_evidence_check_count does not match failed_release_evidence_checks." }
    if ((Read-ObjectInt -Object $summary -Name "required_environment_variable_count") -ne $environmentVariables.Count) { $countFailures += "required_environment_variable_count does not match environment_variables." }
    if ((Read-ObjectInt -Object $summary -Name "report_reference_refresh_count") -ne $reportReferenceRefreshes.Count) { $countFailures += "report_reference_refresh_count does not match report_reference_refreshes." }
    if ((Read-ObjectInt -Object $summary -Name "required_readiness_evidence_item_count") -ne $readinessEvidenceItems.Count) { $countFailures += "required_readiness_evidence_item_count does not match readiness_evidence_items." }
    if ((Read-ObjectInt -Object $summary -Name "required_provisioning_evidence_file_count") -ne $provisioningEvidenceFiles.Count) { $countFailures += "required_provisioning_evidence_file_count does not match provisioning_evidence_files." }
    if ((Read-ObjectInt -Object $summary -Name "required_release_evidence_item_count") -ne $releaseEvidenceItems.Count) { $countFailures += "required_release_evidence_item_count does not match release_evidence_items." }

    $childFailedCheckCount = 0
    foreach ($check in $failedProvisioningChecks) {
        $childFailedCheckCount += (Get-ObjectArray -Object $check -Name "child_failed_checks").Count
    }
    if ((Read-ObjectInt -Object $summary -Name "failed_provisioning_child_check_count") -ne $childFailedCheckCount) {
        $countFailures += "failed_provisioning_child_check_count does not match child_failed_checks."
    }

    $readinessEvidenceItemsWithCommands = @($readinessEvidenceItems | Where-Object { (Get-ObjectArray -Object $_ -Name "operator_action_commands").Count -gt 0 }).Count
    $releaseEvidenceItemsWithCommands = @($releaseEvidenceItems | Where-Object { (Get-ObjectArray -Object $_ -Name "operator_action_commands").Count -gt 0 }).Count
    if ((Read-ObjectInt -Object $summary -Name "required_readiness_evidence_item_command_count") -ne $readinessEvidenceItemsWithCommands) { $countFailures += "required_readiness_evidence_item_command_count does not match readiness evidence items with commands." }
    if ((Read-ObjectInt -Object $summary -Name "required_release_evidence_item_command_count") -ne $releaseEvidenceItemsWithCommands) { $countFailures += "required_release_evidence_item_command_count does not match release evidence items with commands." }

    $checks += New-Check -Id "summary_counts" -Passed ($countFailures.Count -eq 0) -Failures $countFailures

    $commandRecords = New-Object System.Collections.Generic.List[object]
    foreach ($gate in $failedReadinessGates) {
        Add-ActionCommandRecords -Records $commandRecords -Source "failed_readiness_gates.$($gate.id)" -Action $gate.operator_action
    }
    foreach ($check in $failedProvisioningChecks) {
        Add-ActionCommandRecords -Records $commandRecords -Source "failed_provisioning_checks.$($check.id)" -Action $check.operator_action
    }
    foreach ($check in $failedReleaseEvidenceChecks) {
        Add-ActionCommandRecords -Records $commandRecords -Source "failed_release_evidence_checks.$($check.id)" -Action $check.operator_action
    }
    foreach ($item in $reportReferenceRefreshes) {
        Add-CommandArrayRecords -Records $commandRecords -Source "report_reference_refreshes.$($item.readiness_gate_id)" -Commands (Get-ObjectArray -Object $item -Name "operator_action_commands")
    }
    foreach ($item in $readinessEvidenceItems) {
        Add-CommandArrayRecords -Records $commandRecords -Source "readiness_evidence_items.$($item.readiness_gate_id)" -Commands (Get-ObjectArray -Object $item -Name "operator_action_commands")
    }
    foreach ($item in $releaseEvidenceItems) {
        Add-CommandArrayRecords -Records $commandRecords -Source "release_evidence_items.$($item.id)" -Commands (Get-ObjectArray -Object $item -Name "operator_action_commands")
    }
    Add-CommandRecord -Records $commandRecords -Source "next_closeout_command" -Command ([string]$report.next_closeout_command)

    $commandFailures = @()
    foreach ($record in $commandRecords) {
        $commandFailures += Test-CommandRecord -Record $record
    }
    $checks += New-Check -Id "operator_command_paths" -Passed ($commandFailures.Count -eq 0) -Failures $commandFailures -Evidence ([pscustomobject][ordered]@{ command_count = $commandRecords.Count })

    $actionFailures = @()
    foreach ($gate in $failedReadinessGates) {
        if ((Get-ObjectArray -Object $gate.operator_action -Name "commands").Count -eq 0) {
            $actionFailures += "failed readiness gate lacks operator action command: $($gate.id)"
        }
    }
    foreach ($check in $failedProvisioningChecks) {
        if ((Get-ObjectArray -Object $check.operator_action -Name "commands").Count -eq 0) {
            $actionFailures += "failed provisioning check lacks operator action command: $($check.id)"
        }
    }
    foreach ($check in $failedReleaseEvidenceChecks) {
        if ((Get-ObjectArray -Object $check.operator_action -Name "commands").Count -eq 0) {
            $actionFailures += "failed release-evidence check lacks operator action command: $($check.id)"
        }
    }
    $checks += New-Check -Id "operator_action_command_coverage" -Passed ($actionFailures.Count -eq 0) -Failures $actionFailures

    $checks += Add-Check -Id "ready_consistency" -Condition (-not [bool]$report.ready_for_production_testing -or ($closeoutFailures.Count -eq 0 -and $failedReadinessGates.Count -eq 0 -and $failedProvisioningChecks.Count -eq 0 -and $failedReleaseEvidenceChecks.Count -eq 0)) -Failure "ready_for_production_testing=true while outstanding blockers remain"
    if ($RequireReady) {
        $checks += Add-Check -Id "require_ready" -Condition ([bool]$report.ready_for_production_testing) -Failure "outstanding-work report is not ready for production testing"
    }

    if ($markdownExists) {
        $markdown = Get-Content -LiteralPath $resolvedMarkdownPath -Raw
        $markdownFailures = @()
        if ($markdown -notmatch '# Production MVP Outstanding Work') { $markdownFailures += "Markdown title is missing." }
        foreach ($section in @("## Operator Input Matrix", "## Readiness Gates", "## Provisioning Packet", "## Release Evidence", "## Next Command")) {
            if ($markdown -notmatch [regex]::Escape($section)) {
                $markdownFailures += "Markdown section is missing: $section"
            }
        }
        foreach ($gate in $failedReadinessGates) {
            if ($markdown -notmatch [regex]::Escape([string]$gate.id)) {
                $markdownFailures += "Markdown does not include failed readiness gate id: $($gate.id)"
            }
        }
        foreach ($check in $failedProvisioningChecks) {
            if ($markdown -notmatch [regex]::Escape([string]$check.id)) {
                $markdownFailures += "Markdown does not include failed provisioning check id: $($check.id)"
            }
        }
        foreach ($check in $failedReleaseEvidenceChecks) {
            if ($markdown -notmatch [regex]::Escape([string]$check.id)) {
                $markdownFailures += "Markdown does not include failed release-evidence check id: $($check.id)"
            }
        }
        if ($commandRecords.Count -gt 0 -and $markdown -notmatch '(?m)^\s+- Next command: ') {
            $markdownFailures += "Markdown does not include any Next command lines."
        }
        if (-not [string]::IsNullOrWhiteSpace([string]$report.next_closeout_command) -and $markdown -notmatch [regex]::Escape([string]$report.next_closeout_command)) {
            $markdownFailures += "Markdown does not include next_closeout_command."
        }
        $checks += New-Check -Id "markdown_coverage" -Passed ($markdownFailures.Count -eq 0) -Failures $markdownFailures -Evidence ([pscustomobject][ordered]@{ path = $resolvedMarkdownPath })
    }
    else {
        $checks += New-Check -Id "markdown_coverage" -Passed $false -Failures @("Markdown report is missing.") -Evidence ([pscustomobject][ordered]@{ path = $resolvedMarkdownPath })
    }
}

$failedChecks = @($checks | Where-Object { -not $_.passed })
$outputDirectory = Split-Path -Parent $resolvedOutputPath
if ($outputDirectory) {
    New-Item -ItemType Directory -Force -Path $outputDirectory | Out-Null
}

$validation = [pscustomobject][ordered]@{
    schema = "archrealms.passport.production_mvp_outstanding_work_validation.v1"
    created_utc = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
    repo_root = $repoRoot
    report_path = $resolvedReportPath
    report_sha256 = Get-Sha256Hex -Path $resolvedReportPath
    markdown_path = $resolvedMarkdownPath
    markdown_sha256 = Get-Sha256Hex -Path $resolvedMarkdownPath
    generated = [bool]($Generate -or $UseGeneratedFixture)
    use_generated_fixture = [bool]$UseGeneratedFixture
    require_ready = [bool]$RequireReady
    passed = ($failedChecks.Count -eq 0)
    failed_check_count = $failedChecks.Count
    checks = $checks
}

$validation | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $resolvedOutputPath -Encoding UTF8
$validation | ConvertTo-Json -Depth 12

if (-not $validation.passed -and -not $NoFail) {
    throw "Production MVP outstanding-work report validation failed. See $resolvedOutputPath."
}
