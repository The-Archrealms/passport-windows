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

function Convert-ForCompare {
    param([object]$Value)

    return ($Value | ConvertTo-Json -Depth 20 -Compress)
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
$matrixPath = Join-Path $resolvedPacketRoot "operator-input-matrix.json"
$matrixMarkdownPath = Join-Path $resolvedPacketRoot "operator-input-matrix.md"
$currentCommit = Get-CurrentCommit

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
$checks += Add-Check -Id "operator_input_matrix_json_exists" -Condition (Test-Path -LiteralPath $matrixPath -PathType Leaf) -Failure "operator input matrix JSON is missing" -Evidence ([pscustomobject][ordered]@{ path = $matrixPath })
$checks += Add-Check -Id "operator_input_matrix_markdown_exists" -Condition (Test-Path -LiteralPath $matrixMarkdownPath -PathType Leaf) -Failure "operator input matrix Markdown is missing" -Evidence ([pscustomobject][ordered]@{ path = $matrixMarkdownPath })
$checks += Add-Check -Id "operator_commands_exists" -Condition (Test-Path -LiteralPath $commandsPath -PathType Leaf) -Failure "operator command checklist is missing" -Evidence ([pscustomobject][ordered]@{ path = $commandsPath })

$manifest = Read-JsonFile -Path $manifestPath
$plan = Read-JsonFile -Path $planPath
$matrix = Read-JsonFile -Path $matrixPath
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

if ($null -ne $matrix) {
    $checks += Add-Check -Id "operator_input_matrix_schema" -Condition ([string]$matrix.schema -eq "archrealms.passport.production_mvp_operator_input_matrix.v1") -Failure "unexpected operator input matrix schema"
}
else {
    $checks += New-Check -Id "operator_input_matrix_schema" -Passed $false -Failures @("operator input matrix JSON could not be parsed")
}

if ($null -ne $sourceReport) {
    $checks += Add-Check -Id "source_report_schema" -Condition ([string]$sourceReport.schema -eq "archrealms.passport.production_mvp_outstanding_work_report.v1") -Failure "unexpected outstanding-work report schema"
}
else {
    $checks += New-Check -Id "source_report_schema" -Passed $false -Failures @("outstanding-work report could not be parsed")
}

$commitFailures = @()
if ([string]::IsNullOrWhiteSpace($currentCommit)) {
    $commitFailures += "current git commit could not be resolved."
}

$commitDocuments = @(
    [pscustomobject]@{ name = "manifest"; document = $manifest },
    [pscustomobject]@{ name = "next-action plan"; document = $plan },
    [pscustomobject]@{ name = "operator input matrix"; document = $matrix }
)

foreach ($entry in $commitDocuments) {
    if ($null -eq $entry.document) {
        continue
    }

    $documentCommit = if ($entry.document.PSObject.Properties["app_commit"]) { [string]$entry.document.app_commit } else { "" }
    if ($documentCommit -notmatch '^[0-9a-f]{7,40}$') {
        $commitFailures += "$($entry.name) app_commit is missing or invalid."
    }
    elseif (-not [string]::IsNullOrWhiteSpace($currentCommit) -and $documentCommit -ne $currentCommit) {
        $commitFailures += "$($entry.name) app_commit $documentCommit does not match current app commit $currentCommit."
    }
}

if ($null -ne $sourceReport) {
    $sourceReportCommit = if ($sourceReport.PSObject.Properties["app_commit"]) { [string]$sourceReport.app_commit } else { "" }
    if ($sourceReportCommit -notmatch '^[0-9a-f]{7,40}$') {
        $commitFailures += "outstanding-work source report app_commit is missing or invalid."
    }
    elseif (-not [string]::IsNullOrWhiteSpace($currentCommit) -and $sourceReportCommit -ne $currentCommit) {
        $commitFailures += "outstanding-work source report app_commit $sourceReportCommit does not match current app commit $currentCommit."
    }
}

$checks += New-Check -Id "app_commit_freshness" -Passed ($commitFailures.Count -eq 0) -Failures $commitFailures -Evidence ([pscustomobject][ordered]@{ current_app_commit = $currentCommit })

if ($null -ne $manifest -and $null -ne $plan -and $null -ne $sourceReport) {
    $sourceHash = Get-Sha256Hex -Path $resolvedOutstandingWorkReportPath
    $sourceReportCommit = if ($sourceReport.PSObject.Properties["app_commit"]) { [string]$sourceReport.app_commit } else { "" }
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
    if ([string]$manifest.source_report.app_commit -ne $sourceReportCommit) {
        $sourceFailures += "manifest source report app_commit does not match actual source report app_commit."
    }
    if ([string]$plan.source_report.app_commit -ne $sourceReportCommit) {
        $sourceFailures += "plan source report app_commit does not match actual source report app_commit."
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
        foreach ($field in @("operator_input_required", "blocked_by_external_actor")) {
            if ([bool]$packetAction.$field -ne [bool]$sourceAction.$field) {
                $actionFailures += "packet action $id field mismatch: $field"
            }
        }
        if ([int]$packetAction.required_operator_input_count -ne [int]$sourceAction.required_operator_input_count) {
            $actionFailures += "packet action $id required_operator_input_count mismatch."
        }
        if ([int]$packetAction.phase_order -ne [int]$sourceAction.phase_order) {
            $actionFailures += "packet action $id phase_order mismatch."
        }
        foreach ($arrayName in @("commands", "blocker_ids", "external_blocker_ids", "categories", "source_ids")) {
            $packetArray = @(Get-ObjectArray -Object $packetAction -Name $arrayName)
            $sourceArray = @(Get-ObjectArray -Object $sourceAction -Name $arrayName)
            if ((Join-ArrayForCompare -Values $packetArray) -ne (Join-ArrayForCompare -Values $sourceArray)) {
                $actionFailures += "packet action $id array mismatch: $arrayName"
            }
        }
    }
    $checks += New-Check -Id "action_plan_matches_source" -Passed ($actionFailures.Count -eq 0) -Failures $actionFailures -Evidence ([pscustomobject][ordered]@{ action_count = $packetActions.Count })

    $simulationHashFailures = @()
    $simulationRunReportPath = Resolve-RepoPath -Path "artifacts\release\pre-mvp-simulation-run-report.json"
    $expectedSimulationRunSha256 = Get-Sha256Hex -Path $simulationRunReportPath
    $staffStewardPilotCommands = @()
    foreach ($packetAction in $packetActions) {
        foreach ($command in @(Get-ObjectArray -Object $packetAction -Name "commands")) {
            $commandText = [string]$command
            if ($commandText -match 'Complete-PassportPreMvpStaffStewardPilotHandoff\.ps1') {
                $staffStewardPilotCommands += $commandText
            }
        }
    }
    if ($staffStewardPilotCommands.Count -gt 0) {
        foreach ($command in $staffStewardPilotCommands) {
            if ($command -match '<simulation-run-sha256>') {
                $simulationHashFailures += "staff/steward pilot closeout command still contains <simulation-run-sha256>: $command"
            }

            if ($expectedSimulationRunSha256 -match '^[0-9a-f]{64}$' -and $command -notmatch [regex]::Escape("-SimulationRunReportSha256 $expectedSimulationRunSha256")) {
                $simulationHashFailures += "staff/steward pilot closeout command does not include current simulation-run SHA-256 $expectedSimulationRunSha256`: $command"
            }
        }
    }
    $checks += New-Check -Id "staff_steward_simulation_hash_prefill" -Passed ($simulationHashFailures.Count -eq 0) -Failures $simulationHashFailures -Evidence ([pscustomobject][ordered]@{
        simulation_run_report_path = $simulationRunReportPath
        simulation_run_report_sha256 = $expectedSimulationRunSha256
        staff_steward_command_count = $staffStewardPilotCommands.Count
    })

    if ($null -ne $matrix) {
        $sourceMatrix = $sourceReport.operator_input_matrix
        $sourceEnvironmentVariables = @(Get-ObjectArray -Object $sourceMatrix -Name "environment_variables")
        $sourceReportReferenceRefreshes = @(Get-ObjectArray -Object $sourceMatrix -Name "report_reference_refreshes")
        $sourceReadinessEvidenceItems = @(Get-ObjectArray -Object $sourceMatrix -Name "readiness_evidence_items")
        $sourceProvisioningEvidenceFiles = @(Get-ObjectArray -Object $sourceMatrix -Name "provisioning_evidence_files")
        $sourceReleaseEvidenceItems = @(Get-ObjectArray -Object $sourceMatrix -Name "release_evidence_items")

        $matrixFailures = @()
        if ([string]$matrix.source_report.sha256 -ne $sourceHash) {
            $matrixFailures += "operator input matrix source report SHA-256 does not match actual source report."
        }
        if ([string]$matrix.source_report.app_commit -ne $sourceReportCommit) {
            $matrixFailures += "operator input matrix source report app_commit does not match actual source report app_commit."
        }
        if ([int]$matrix.summary.environment_variable_count -ne $sourceEnvironmentVariables.Count) {
            $matrixFailures += "operator input matrix environment variable count does not match source report."
        }
        if ([int]$matrix.summary.report_reference_refresh_count -ne $sourceReportReferenceRefreshes.Count) {
            $matrixFailures += "operator input matrix report-reference refresh count does not match source report."
        }
        if ([int]$matrix.summary.readiness_evidence_item_count -ne $sourceReadinessEvidenceItems.Count) {
            $matrixFailures += "operator input matrix readiness evidence item count does not match source report."
        }
        if ([int]$matrix.summary.provisioning_evidence_file_count -ne $sourceProvisioningEvidenceFiles.Count) {
            $matrixFailures += "operator input matrix provisioning evidence file count does not match source report."
        }
        if ([int]$matrix.summary.release_evidence_item_count -ne $sourceReleaseEvidenceItems.Count) {
            $matrixFailures += "operator input matrix release evidence item count does not match source report."
        }

        $comparisons = @(
            [pscustomobject]@{ name = "environment_variables"; expected = $sourceEnvironmentVariables; actual = @(Get-ObjectArray -Object $matrix -Name "environment_variables") }
            [pscustomobject]@{ name = "report_reference_refreshes"; expected = $sourceReportReferenceRefreshes; actual = @(Get-ObjectArray -Object $matrix -Name "report_reference_refreshes") }
            [pscustomobject]@{ name = "readiness_evidence_items"; expected = $sourceReadinessEvidenceItems; actual = @(Get-ObjectArray -Object $matrix -Name "readiness_evidence_items") }
            [pscustomobject]@{ name = "provisioning_evidence_files"; expected = $sourceProvisioningEvidenceFiles; actual = @(Get-ObjectArray -Object $matrix -Name "provisioning_evidence_files") }
            [pscustomobject]@{ name = "release_evidence_items"; expected = $sourceReleaseEvidenceItems; actual = @(Get-ObjectArray -Object $matrix -Name "release_evidence_items") }
        )
        foreach ($comparison in $comparisons) {
            if ((Convert-ForCompare -Value $comparison.expected) -ne (Convert-ForCompare -Value $comparison.actual)) {
                $matrixFailures += "operator input matrix $($comparison.name) does not match source report."
            }
        }

        $checks += New-Check -Id "operator_input_matrix_matches_source" -Passed ($matrixFailures.Count -eq 0) -Failures $matrixFailures -Evidence ([pscustomobject][ordered]@{
            environment_variable_count = $sourceEnvironmentVariables.Count
            readiness_evidence_item_count = $sourceReadinessEvidenceItems.Count
            provisioning_evidence_file_count = $sourceProvisioningEvidenceFiles.Count
            release_evidence_item_count = $sourceReleaseEvidenceItems.Count
        })
    }

    $generatedFileFailures = @()
    $expectedFileIds = @("next_action_plan_json", "next_action_plan_markdown", "operator_input_matrix_json", "operator_input_matrix_markdown", "operator_commands")
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

    if ($null -ne $matrix -and (Test-Path -LiteralPath $matrixMarkdownPath -PathType Leaf)) {
        $matrixMarkdown = Get-Content -LiteralPath $matrixMarkdownPath -Raw
        $matrixMarkdownFailures = @()
        if ($matrixMarkdown -notmatch "# Production MVP Operator Input Matrix") {
            $matrixMarkdownFailures += "operator input matrix Markdown title is missing."
        }

        foreach ($item in @(Get-ObjectArray -Object $matrix -Name "environment_variables")) {
            $name = [string]$item.name
            if (-not [string]::IsNullOrWhiteSpace($name) -and $matrixMarkdown -notmatch [regex]::Escape($name)) {
                $matrixMarkdownFailures += "operator input matrix Markdown is missing environment variable: $name"
            }
            $metadataValues = @(
                [string]$item.input_kind,
                [string]$item.sensitivity,
                [string]$item.validation_hint,
                [string]$item.template_gate
            )
            foreach ($source in @(Get-ObjectArray -Object $item -Name "sources")) {
                $metadataValues += [string]$source
            }
            if ($item.PSObject.Properties["template_required"] -and $null -ne $item.template_required) {
                $metadataValues += ([bool]$item.template_required).ToString().ToLowerInvariant()
            }

            foreach ($value in $metadataValues) {
                if (-not [string]::IsNullOrWhiteSpace($value) -and $matrixMarkdown -notmatch [regex]::Escape($value)) {
                    $matrixMarkdownFailures += "operator input matrix Markdown is missing environment variable metadata for $name`: $value"
                }
            }
        }
        foreach ($item in @(Get-ObjectArray -Object $matrix -Name "readiness_evidence_items")) {
            $id = [string]$item.readiness_gate_id
            if (-not [string]::IsNullOrWhiteSpace($id) -and $matrixMarkdown -notmatch [regex]::Escape($id)) {
                $matrixMarkdownFailures += "operator input matrix Markdown is missing readiness evidence item: $id"
            }
        }
        foreach ($item in @(Get-ObjectArray -Object $matrix -Name "provisioning_evidence_files")) {
            foreach ($value in @([string]$item.provisioning_check_id, [string]$item.child_check_id, [string]$item.evidence_path)) {
                if (-not [string]::IsNullOrWhiteSpace($value) -and $matrixMarkdown -notmatch [regex]::Escape($value)) {
                    $matrixMarkdownFailures += "operator input matrix Markdown is missing provisioning evidence value: $value"
                }
            }
        }
        foreach ($item in @(Get-ObjectArray -Object $matrix -Name "release_evidence_items")) {
            $id = [string]$item.id
            if (-not [string]::IsNullOrWhiteSpace($id) -and $matrixMarkdown -notmatch [regex]::Escape($id)) {
                $matrixMarkdownFailures += "operator input matrix Markdown is missing release evidence item: $id"
            }
        }
        $checks += New-Check -Id "operator_input_matrix_markdown_coverage" -Passed ($matrixMarkdownFailures.Count -eq 0) -Failures $matrixMarkdownFailures
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
    app_commit = $currentCommit
    packet_root = $resolvedPacketRoot
    outstanding_work_report_path = $resolvedOutstandingWorkReportPath
    manifest_path = $manifestPath
    manifest_sha256 = Get-Sha256Hex -Path $manifestPath
    plan_path = $planPath
    plan_sha256 = Get-Sha256Hex -Path $planPath
    markdown_path = $markdownPath
    markdown_sha256 = Get-Sha256Hex -Path $markdownPath
    operator_input_matrix_path = $matrixPath
    operator_input_matrix_sha256 = Get-Sha256Hex -Path $matrixPath
    operator_input_matrix_markdown_path = $matrixMarkdownPath
    operator_input_matrix_markdown_sha256 = Get-Sha256Hex -Path $matrixMarkdownPath
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
