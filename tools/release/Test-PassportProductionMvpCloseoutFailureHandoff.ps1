param(
    [string]$OutputPath = "artifacts\release\production-mvp-closeout-failure-handoff-validation-report.json",
    [switch]$NoFail
)

$ErrorActionPreference = "Stop"

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $scriptRoot "..\.."))

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

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return ""
    }

    return (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant()
}

function Get-CurrentCommit {
    Push-Location $repoRoot
    try {
        $commit = (& git rev-parse --short HEAD 2>$null)
        if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($commit)) {
            return ([string]$commit).Trim()
        }
    }
    finally {
        Pop-Location
    }

    return ""
}

function Read-JsonFile {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $null
    }

    return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
}

function Write-JsonFile {
    param(
        [string]$Path,
        [object]$Value
    )

    $resolved = Resolve-RepoPath -Path $Path
    $parent = Split-Path -Parent $resolved
    if ($parent) {
        New-Item -ItemType Directory -Force -Path $parent | Out-Null
    }

    $Value | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $resolved -Encoding UTF8
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

function Invoke-Tool {
    param(
        [string]$FilePath,
        [string[]]$Arguments
    )

    $command = Get-Command $FilePath -ErrorAction Stop
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $command.Source
    $psi.Arguments = ($Arguments | ForEach-Object { Format-CommandArgument -Argument $_ }) -join " "
    $psi.WorkingDirectory = $repoRoot
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false

    $process = [System.Diagnostics.Process]::Start($psi)
    $stdout = $process.StandardOutput.ReadToEnd()
    $stderr = $process.StandardError.ReadToEnd()
    $process.WaitForExit()

    $combined = (($stdout + $stderr) -replace "`r", "").Trim()
    $excerpt = $combined
    if ($excerpt.Length -gt 6000) {
        $excerpt = $excerpt.Substring($excerpt.Length - 6000)
    }

    return [pscustomobject][ordered]@{
        command = (($Arguments | ForEach-Object { Format-CommandArgument -Argument $_ }) -join " ")
        exit_code = [int]$process.ExitCode
        stdout = $stdout
        stderr = $stderr
        output_excerpt = $excerpt
    }
}

function New-Check {
    param(
        [string]$Id,
        [bool]$Passed,
        [string[]]$Failures,
        [object]$Evidence = $null
    )

    $cleanFailures = @($Failures | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
    return [pscustomobject][ordered]@{
        id = $Id
        passed = $Passed
        failures = $cleanFailures
        evidence = $Evidence
    }
}

function Get-ObjectArray {
    param(
        [object]$Object,
        [string]$Name
    )

    if ($null -eq $Object -or -not $Object.PSObject.Properties[$Name] -or $null -eq $Object.$Name) {
        return @()
    }

    return @($Object.$Name)
}

function Test-FileRecord {
    param(
        [object]$Record,
        [string]$Name
    )

    $failures = @()
    if ($null -eq $Record) {
        return @("$Name record is missing.")
    }

    if ([string]::IsNullOrWhiteSpace([string]$Record.path)) {
        $failures += "$Name path is missing."
    }
    elseif (-not (Test-Path -LiteralPath ([string]$Record.path) -PathType Leaf)) {
        $failures += "$Name file does not exist: $($Record.path)"
    }

    if (-not [bool]$Record.exists) {
        $failures += "$Name record does not report exists=true."
    }

    $actualSha = Get-Sha256Hex -Path ([string]$Record.path)
    if ([string]::IsNullOrWhiteSpace([string]$Record.sha256)) {
        $failures += "$Name sha256 is missing."
    }
    elseif ($actualSha -ne [string]$Record.sha256) {
        $failures += "$Name sha256 does not match file content."
    }

    return @($failures)
}

$closeoutResult = Invoke-Tool -FilePath "powershell" -Arguments @(
    "-NoProfile",
    "-ExecutionPolicy",
    "Bypass",
    "-File",
    "tools\release\Complete-PassportProductionMvpCloseout.ps1",
    "-UseGeneratedFailureFixture",
    "-NoFail"
)

$checks = @()
$checks += New-Check -Id "closeout_exit_code" -Passed ($closeoutResult.exit_code -eq 0) -Failures $(if ($closeoutResult.exit_code -eq 0) { @() } else { @("closeout failure fixture exited with code $($closeoutResult.exit_code).") }) -Evidence ([pscustomobject][ordered]@{
    command = $closeoutResult.command
    output_excerpt = $closeoutResult.output_excerpt
})

$closeout = $null
$parseFailures = @()
try {
    $closeout = $closeoutResult.stdout | ConvertFrom-Json
}
catch {
    $parseFailures += "closeout stdout could not be parsed as JSON: $($_.Exception.Message)"
}

$checks += New-Check -Id "closeout_result_json" -Passed ($parseFailures.Count -eq 0) -Failures $parseFailures

if ($null -ne $closeout) {
    $checks += New-Check -Id "closeout_result_contract" -Passed (
        [string]$closeout.schema -eq "archrealms.passport.production_mvp_closeout_result.v1" -and
        -not [bool]$closeout.passed -and
        $null -ne $closeout.failure_handoff
    ) -Failures @(
        $(if ([string]$closeout.schema -ne "archrealms.passport.production_mvp_closeout_result.v1") { "unexpected closeout result schema." }),
        $(if ([bool]$closeout.passed) { "generated failure fixture unexpectedly passed closeout." }),
        $(if ($null -eq $closeout.failure_handoff) { "closeout result is missing failure_handoff." })
    )

    $handoff = $closeout.failure_handoff
    if ($null -ne $handoff) {
        $checks += New-Check -Id "failure_handoff_status" -Passed ([bool]$handoff.generated -and [bool]$handoff.passed) -Failures @(
            $(if (-not [bool]$handoff.generated) { "failure handoff did not report generated=true." }),
            $(if (-not [bool]$handoff.passed) { "failure handoff did not report passed=true." })
        )

        $artifactFailures = @()
        $artifactFailures += Test-FileRecord -Record $handoff.outstanding_work.report -Name "outstanding work report"
        $artifactFailures += Test-FileRecord -Record $handoff.outstanding_work.markdown -Name "outstanding work markdown"
        $artifactFailures += Test-FileRecord -Record $handoff.outstanding_work.validation_report -Name "outstanding work validation report"
        $artifactFailures += Test-FileRecord -Record $handoff.next_action_packet.validation_report -Name "next-action validation report"
        $artifactFailures += Test-FileRecord -Record $handoff.next_action_packet.manifest -Name "next-action manifest"
        $artifactFailures += Test-FileRecord -Record $handoff.next_action_packet.plan_json -Name "next-action JSON plan"
        $artifactFailures += Test-FileRecord -Record $handoff.next_action_packet.plan_markdown -Name "next-action Markdown plan"
        $artifactFailures += Test-FileRecord -Record $handoff.next_action_packet.operator_input_matrix_json -Name "operator input matrix JSON"
        $artifactFailures += Test-FileRecord -Record $handoff.next_action_packet.operator_input_matrix_markdown -Name "operator input matrix Markdown"
        $artifactFailures += Test-FileRecord -Record $handoff.next_action_packet.operator_commands -Name "operator commands"
        $artifactFailures += Test-FileRecord -Record $handoff.next_action_packet.operator_command_phase_manifest -Name "operator command phase manifest"

        if ([string]::IsNullOrWhiteSpace([string]$handoff.next_action_packet.operator_command_phase_directory)) {
            $artifactFailures += "operator command phase directory is missing."
        }
        elseif (-not (Test-Path -LiteralPath ([string]$handoff.next_action_packet.operator_command_phase_directory) -PathType Container)) {
            $artifactFailures += "operator command phase directory does not exist: $($handoff.next_action_packet.operator_command_phase_directory)"
        }

        if (-not $handoff.next_action_packet.PSObject.Properties["operator_command_phase_count"] -or [int]$handoff.next_action_packet.operator_command_phase_count -le 0) {
            $artifactFailures += "operator command phase count is missing or zero."
        }

        $checks += New-Check -Id "failure_handoff_artifacts" -Passed ($artifactFailures.Count -eq 0) -Failures $artifactFailures

        $validationFailures = @()
        $nextActionValidation = Read-JsonFile -Path ([string]$handoff.next_action_packet.validation_report.path)
        if ($null -eq $nextActionValidation) {
            $validationFailures += "next-action validation report could not be read."
        }
        else {
            if (-not [bool]$nextActionValidation.passed) {
                $validationFailures += "next-action validation report did not pass."
            }

            if ([string]$nextActionValidation.operator_command_phase_manifest_path -ne [string]$handoff.next_action_packet.operator_command_phase_manifest.path) {
                $validationFailures += "phase manifest path in handoff does not match next-action validation report."
            }

            if ([string]$nextActionValidation.operator_command_phase_manifest_sha256 -ne [string]$handoff.next_action_packet.operator_command_phase_manifest.sha256) {
                $validationFailures += "phase manifest sha256 in handoff does not match next-action validation report."
            }

            if ([int]$nextActionValidation.operator_command_phase_count -ne [int]$handoff.next_action_packet.operator_command_phase_count) {
                $validationFailures += "phase count in handoff does not match next-action validation report."
            }

            $phaseScriptCheck = @(Get-ObjectArray -Object $nextActionValidation -Name "checks" | Where-Object { [string]$_.id -eq "operator_command_phase_scripts" } | Select-Object -First 1)
            if ($phaseScriptCheck.Count -eq 0) {
                $validationFailures += "next-action validation report is missing operator_command_phase_scripts check."
            }
            elseif (-not [bool]$phaseScriptCheck[0].passed) {
                $validationFailures += "next-action validation report operator_command_phase_scripts check did not pass."
            }
        }

        $phaseManifest = Read-JsonFile -Path ([string]$handoff.next_action_packet.operator_command_phase_manifest.path)
        if ($null -eq $phaseManifest) {
            $validationFailures += "operator command phase manifest could not be read."
        }
        else {
            if ([string]$phaseManifest.schema -ne "archrealms.passport.production_mvp_operator_command_phase_manifest.v1") {
                $validationFailures += "operator command phase manifest schema is unexpected."
            }
            if ([int]$phaseManifest.phase_script_count -ne [int]$handoff.next_action_packet.operator_command_phase_count) {
                $validationFailures += "operator command phase manifest count does not match handoff count."
            }
        }

        $checks += New-Check -Id "failure_handoff_phase_manifest_validation" -Passed ($validationFailures.Count -eq 0) -Failures $validationFailures
    }
}

$failedChecks = @($checks | Where-Object { -not [bool]$_.passed })
$report = [pscustomobject][ordered]@{
    schema = "archrealms.passport.production_mvp_closeout_failure_handoff_validation.v1"
    created_utc = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    repo_root = $repoRoot
    app_commit = Get-CurrentCommit
    passed = ($failedChecks.Count -eq 0)
    failed_check_count = $failedChecks.Count
    checks = @($checks)
}

Write-JsonFile -Path $OutputPath -Value $report
$report | ConvertTo-Json -Depth 12

if (-not [bool]$report.passed -and -not $NoFail) {
    exit 1
}
