param(
    [string]$PacketRoot = "artifacts\release\production-mvp-next-action-packet",
    [string]$OutstandingWorkReportPath = "artifacts\release\production-mvp-outstanding-work-report.json",
    [string]$OutputPath = "artifacts\release\production-mvp-next-action-packet-validation-report.json",
    [switch]$Generate,
    [switch]$UseGeneratedFixture,
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

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return ""
    }

    return (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant()
}

function Read-JsonFile {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $null
    }

    return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
}

function Write-JsonFile {
    param(
        [string]$Path,
        [object]$Value
    )

    $parent = Split-Path -Parent $Path
    if ($parent) {
        New-Item -ItemType Directory -Force -Path $parent | Out-Null
    }

    Set-Content -LiteralPath $Path -Value ($Value | ConvertTo-Json -Depth 14) -Encoding UTF8
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

    $output = (($stdout + $stderr) -replace "`r", "").Trim()
    if ($output.Length -gt 4000) {
        $output = $output.Substring($output.Length - 4000)
    }

    return [pscustomobject][ordered]@{
        command = (($Arguments | ForEach-Object { Format-CommandArgument -Argument $_ }) -join " ")
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

function Join-ArrayForCompare {
    param([object[]]$Values)

    return (@($Values | ForEach-Object { [string]$_ }) -join [char]30)
}

if ($UseGeneratedFixture) {
    $fixtureRoot = Resolve-RepoPath -Path "artifacts\release\production-mvp-next-action-packet-fixture"
    New-Item -ItemType Directory -Force -Path $fixtureRoot | Out-Null

    $OutstandingWorkReportPath = "artifacts\release\production-mvp-outstanding-work-fixture\production-mvp-outstanding-work-report.json"
    if (-not $PSBoundParameters.ContainsKey("PacketRoot")) {
        $PacketRoot = "artifacts\release\production-mvp-next-action-packet-fixture\packet"
    }
    $Generate = $true

    $outstandingGenerator = Resolve-RepoPath -Path "tools\release\New-PassportProductionMvpOutstandingWorkReport.ps1"
    $outstandingResult = Invoke-Tool -FilePath "powershell" -Arguments @(
        "-NoProfile",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        $outstandingGenerator,
        "-UseGeneratedFixture",
        "-NoFail"
    )
}

$resolvedPacketRoot = Resolve-RepoPath -Path $PacketRoot
$resolvedOutstandingWorkReportPath = Resolve-RepoPath -Path $OutstandingWorkReportPath
$resolvedOutputPath = Resolve-RepoPath -Path $OutputPath
$manifestPath = Join-Path $resolvedPacketRoot "production-mvp-next-action-packet.manifest.json"
$planPath = Join-Path $resolvedPacketRoot "next-action-plan.json"
$markdownPath = Join-Path $resolvedPacketRoot "next-action-plan.md"
$commandsPath = Join-Path $resolvedPacketRoot "operator-commands.ps1"

$checks = @()
if ($UseGeneratedFixture) {
    $checks += Add-Check -Id "outstanding_work_fixture_generation" -Condition ($outstandingResult.exit_code -eq 0) -Failure "outstanding-work fixture generation failed" -Evidence $outstandingResult
}

if ($Generate) {
    $generator = Resolve-RepoPath -Path "tools\release\New-PassportProductionMvpNextActionPacket.ps1"
    $generatorResult = Invoke-Tool -FilePath "powershell" -Arguments @(
        "-NoProfile",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        $generator,
        "-OutstandingWorkReportPath",
        $resolvedOutstandingWorkReportPath,
        "-OutputDirectory",
        $resolvedPacketRoot,
        "-Force"
    )
    $checks += Add-Check -Id "generator_exit_code" -Condition ($generatorResult.exit_code -eq 0) -Failure "next-action packet generator failed" -Evidence $generatorResult
}

$checks += Add-Check -Id "manifest_exists" -Condition (Test-Path -LiteralPath $manifestPath -PathType Leaf) -Failure "next-action packet manifest is missing" -Evidence ([pscustomobject][ordered]@{ path = $manifestPath })
$checks += Add-Check -Id "plan_json_exists" -Condition (Test-Path -LiteralPath $planPath -PathType Leaf) -Failure "next-action plan JSON is missing" -Evidence ([pscustomobject][ordered]@{ path = $planPath })
$checks += Add-Check -Id "plan_markdown_exists" -Condition (Test-Path -LiteralPath $markdownPath -PathType Leaf) -Failure "next-action plan Markdown is missing" -Evidence ([pscustomobject][ordered]@{ path = $markdownPath })
$checks += Add-Check -Id "operator_commands_exists" -Condition (Test-Path -LiteralPath $commandsPath -PathType Leaf) -Failure "operator command checklist is missing" -Evidence ([pscustomobject][ordered]@{ path = $commandsPath })

$manifest = Read-JsonFile -Path $manifestPath
$plan = Read-JsonFile -Path $planPath
$sourceReport = Read-JsonFile -Path $resolvedOutstandingWorkReportPath

if ($null -ne $manifest) {
    $checks += Add-Check -Id "manifest_schema" -Condition ([string]$manifest.schema -eq "archrealms.passport.production_mvp_next_action_packet_manifest.v1") -Failure "unexpected next-action packet manifest schema"
}
else {
    $checks += New-Check -Id "manifest_schema" -Passed $false -Failures @("next-action packet manifest could not be parsed")
}

if ($null -ne $plan) {
    $checks += Add-Check -Id "plan_schema" -Condition ([string]$plan.schema -eq "archrealms.passport.production_mvp_next_action_plan.v1") -Failure "unexpected next-action plan schema"
}
else {
    $checks += New-Check -Id "plan_schema" -Passed $false -Failures @("next-action plan JSON could not be parsed")
}

if ($null -ne $sourceReport) {
    $checks += Add-Check -Id "source_report_schema" -Condition ([string]$sourceReport.schema -eq "archrealms.passport.production_mvp_outstanding_work_report.v1") -Failure "unexpected outstanding-work report schema"
}
else {
    $checks += New-Check -Id "source_report_schema" -Passed $false -Failures @("outstanding-work report could not be parsed")
}

if ($null -ne $manifest -and $null -ne $plan -and $null -ne $sourceReport) {
    $sourceHash = Get-Sha256Hex -Path $resolvedOutstandingWorkReportPath
    $sourceActions = @(Get-ObjectArray -Object $sourceReport -Name "next_action_plan")
    $packetActions = @(Get-ObjectArray -Object $plan -Name "actions")
    $sourceBlockers = @(Get-ObjectArray -Object $sourceReport -Name "blockers")

    $sourceFailures = @()
    if ([string]$manifest.source_report.sha256 -ne $sourceHash) {
        $sourceFailures += "manifest source report SHA-256 does not match actual source report."
    }
    if ([string]$plan.source_report.sha256 -ne $sourceHash) {
        $sourceFailures += "plan source report SHA-256 does not match actual source report."
    }
    if ([int]$plan.source_report.next_action_count -ne $sourceActions.Count) {
        $sourceFailures += "plan next_action_count does not match source report next_action_plan count."
    }
    if ([int]$plan.source_report.blocker_count -ne $sourceBlockers.Count) {
        $sourceFailures += "plan blocker_count does not match source report blocker count."
    }
    if ([int]$manifest.source_report.next_action_count -ne $sourceActions.Count) {
        $sourceFailures += "manifest next_action_count does not match source report next_action_plan count."
    }
    $checks += New-Check -Id "source_report_linkage" -Passed ($sourceFailures.Count -eq 0) -Failures $sourceFailures -Evidence ([pscustomobject][ordered]@{ source_report_sha256 = $sourceHash; action_count = $sourceActions.Count; blocker_count = $sourceBlockers.Count })

    $actionFailures = @()
    if ($packetActions.Count -ne $sourceActions.Count) {
        $actionFailures += "packet action count does not match source next_action_plan count."
    }

    $sourceById = @{}
    foreach ($sourceAction in $sourceActions) {
        $sourceById[[string]$sourceAction.id] = $sourceAction
    }

    foreach ($packetAction in $packetActions) {
        $id = [string]$packetAction.id
        if ([string]::IsNullOrWhiteSpace($id)) {
            $actionFailures += "packet action is missing id."
            continue
        }
        if (-not $sourceById.ContainsKey($id)) {
            $actionFailures += "packet action is not present in source report: $id"
            continue
        }

        $sourceAction = $sourceById[$id]
        foreach ($field in @("phase", "title", "action")) {
            if ([string]$packetAction.$field -ne [string]$sourceAction.$field) {
                $actionFailures += "packet action $id field mismatch: $field"
            }
        }
        if ([int]$packetAction.phase_order -ne [int]$sourceAction.phase_order) {
            $actionFailures += "packet action $id phase_order mismatch."
        }
        foreach ($arrayName in @("commands", "blocker_ids", "categories", "source_ids")) {
            $packetArray = @(Get-ObjectArray -Object $packetAction -Name $arrayName)
            $sourceArray = @(Get-ObjectArray -Object $sourceAction -Name $arrayName)
            if ((Join-ArrayForCompare -Values $packetArray) -ne (Join-ArrayForCompare -Values $sourceArray)) {
                $actionFailures += "packet action $id array mismatch: $arrayName"
            }
        }
    }
    $checks += New-Check -Id "action_plan_matches_source" -Passed ($actionFailures.Count -eq 0) -Failures $actionFailures -Evidence ([pscustomobject][ordered]@{ action_count = $packetActions.Count })

    $generatedFileFailures = @()
    $expectedFileIds = @("next_action_plan_json", "next_action_plan_markdown", "operator_commands")
    $generatedFiles = @(Get-ObjectArray -Object $manifest -Name "generated_files")
    foreach ($expectedFileId in $expectedFileIds) {
        $record = @($generatedFiles | Where-Object { [string]$_.id -eq $expectedFileId } | Select-Object -First 1)
        if ($record.Count -eq 0) {
            $generatedFileFailures += "manifest missing generated file record: $expectedFileId"
            continue
        }

        $recordPath = [string]$record[0].path
        if (-not (Test-Path -LiteralPath $recordPath -PathType Leaf)) {
            $generatedFileFailures += "manifest generated file is missing: $expectedFileId"
            continue
        }

        if ([string]$record[0].sha256 -ne (Get-Sha256Hex -Path $recordPath)) {
            $generatedFileFailures += "manifest generated file hash mismatch: $expectedFileId"
        }
    }
    $checks += New-Check -Id "generated_file_manifest" -Passed ($generatedFileFailures.Count -eq 0) -Failures $generatedFileFailures

    if (Test-Path -LiteralPath $markdownPath -PathType Leaf) {
        $markdown = Get-Content -LiteralPath $markdownPath -Raw
        $markdownFailures = @()
        if ($markdown -notmatch "# Production MVP Next Action Plan") {
            $markdownFailures += "Markdown title is missing."
        }
        foreach ($packetAction in $packetActions) {
            foreach ($value in @([string]$packetAction.id, [string]$packetAction.title, [string]$packetAction.action)) {
                if (-not [string]::IsNullOrWhiteSpace($value) -and $markdown -notmatch [regex]::Escape($value)) {
                    $markdownFailures += "Markdown is missing action value for $($packetAction.id): $value"
                }
            }
            foreach ($blockerId in @(Get-ObjectArray -Object $packetAction -Name "blocker_ids")) {
                if ($markdown -notmatch [regex]::Escape([string]$blockerId)) {
                    $markdownFailures += "Markdown is missing blocker id for $($packetAction.id): $blockerId"
                }
            }
            foreach ($command in @(Get-ObjectArray -Object $packetAction -Name "commands")) {
                if ($markdown -notmatch [regex]::Escape([string]$command)) {
                    $markdownFailures += "Markdown is missing command for $($packetAction.id): $command"
                }
            }
        }
        $checks += New-Check -Id "markdown_coverage" -Passed ($markdownFailures.Count -eq 0) -Failures $markdownFailures
    }

    if (Test-Path -LiteralPath $commandsPath -PathType Leaf) {
        $commandText = Get-Content -LiteralPath $commandsPath -Raw
        $commandFailures = @()
        foreach ($line in Get-Content -LiteralPath $commandsPath) {
            $trimmed = $line.Trim()
            if ([string]::IsNullOrWhiteSpace($trimmed)) {
                continue
            }
            if (-not $trimmed.StartsWith("#")) {
                $commandFailures += "operator command checklist has an executable non-comment line: $trimmed"
            }
        }
        foreach ($packetAction in $packetActions) {
            foreach ($command in @(Get-ObjectArray -Object $packetAction -Name "commands")) {
                if ($commandText -notmatch [regex]::Escape("# $command")) {
                    $commandFailures += "operator command checklist is missing commented command for $($packetAction.id): $command"
                }
            }
        }
        $checks += New-Check -Id "operator_commands_are_commented" -Passed ($commandFailures.Count -eq 0) -Failures $commandFailures
    }
}

$failedChecks = @($checks | Where-Object { -not $_.passed })
$validation = [pscustomobject][ordered]@{
    schema = "archrealms.passport.production_mvp_next_action_packet_validation.v1"
    created_utc = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
    repo_root = $repoRoot
    packet_root = $resolvedPacketRoot
    outstanding_work_report_path = $resolvedOutstandingWorkReportPath
    manifest_path = $manifestPath
    manifest_sha256 = Get-Sha256Hex -Path $manifestPath
    plan_path = $planPath
    plan_sha256 = Get-Sha256Hex -Path $planPath
    markdown_path = $markdownPath
    markdown_sha256 = Get-Sha256Hex -Path $markdownPath
    operator_commands_path = $commandsPath
    operator_commands_sha256 = Get-Sha256Hex -Path $commandsPath
    generated = [bool]$Generate
    used_generated_fixture = [bool]$UseGeneratedFixture
    passed = ($failedChecks.Count -eq 0)
    failed_check_count = $failedChecks.Count
    checks = $checks
}

Write-JsonFile -Path $resolvedOutputPath -Value $validation
$validation | ConvertTo-Json -Depth 14

if ($failedChecks.Count -gt 0 -and -not $NoFail) {
    throw "Production MVP next-action packet validation failed. See $resolvedOutputPath."
}
