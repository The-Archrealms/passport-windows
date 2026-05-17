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

function Get-PlaceholderTokensFromCommand {
    param([string]$Command)

    $tokens = New-Object System.Collections.Generic.List[string]
    if ([string]::IsNullOrWhiteSpace($Command)) {
        return @()
    }

    foreach ($match in [regex]::Matches($Command, "<[A-Za-z0-9][A-Za-z0-9_.:-]*>")) {
        $token = [string]$match.Value
        if (-not $tokens.Contains($token)) {
            $tokens.Add($token)
        }
    }

    return @($tokens)
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
$phaseCommandDirectory = Join-Path $resolvedPacketRoot "operator-command-phases"
$phaseManifestPath = Join-Path $resolvedPacketRoot "operator-command-phases.manifest.json"
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
$checks += Add-Check -Id "operator_command_phase_manifest_exists" -Condition (Test-Path -LiteralPath $phaseManifestPath -PathType Leaf) -Failure "operator command phase manifest is missing" -Evidence ([pscustomobject][ordered]@{ path = $phaseManifestPath })

$manifest = Read-JsonFile -Path $manifestPath
$plan = Read-JsonFile -Path $planPath
$matrix = Read-JsonFile -Path $matrixPath
$phaseManifest = Read-JsonFile -Path $phaseManifestPath
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

if ($null -ne $phaseManifest) {
    $checks += Add-Check -Id "operator_command_phase_manifest_schema" -Condition ([string]$phaseManifest.schema -eq "archrealms.passport.production_mvp_operator_command_phase_manifest.v1") -Failure "unexpected operator command phase manifest schema"
}
else {
    $checks += New-Check -Id "operator_command_phase_manifest_schema" -Passed $false -Failures @("operator command phase manifest could not be parsed")
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
    [pscustomobject]@{ name = "operator input matrix"; document = $matrix },
    [pscustomobject]@{ name = "operator command phase manifest"; document = $phaseManifest }
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
    $packetCommands = @($packetActions | ForEach-Object { Get-ObjectArray -Object $_ -Name "commands" } | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
    $uniquePacketCommands = @($packetCommands | Select-Object -Unique)
    $sourceOperatorPlaceholderCount = (@($sourceActions | ForEach-Object { @(Get-ObjectArray -Object $_ -Name "operator_placeholders").Count }) | Measure-Object -Sum).Sum
    if ($null -eq $sourceOperatorPlaceholderCount) { $sourceOperatorPlaceholderCount = 0 }

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
    if (-not $plan.source_report.PSObject.Properties["unique_operator_command_count"]) {
        $sourceFailures += "plan source_report is missing unique_operator_command_count."
    }
    elseif ([int]$plan.source_report.unique_operator_command_count -ne $uniquePacketCommands.Count) {
        $sourceFailures += "plan unique_operator_command_count does not match packet unique command count."
    }
    if ([int]$plan.source_report.operator_placeholder_count -ne [int]$sourceOperatorPlaceholderCount) {
        $sourceFailures += "plan operator_placeholder_count does not match source report next_action_plan operator placeholders."
    }
    if ([int]$plan.source_report.blocker_count -ne $sourceBlockers.Count) {
        $sourceFailures += "plan blocker_count does not match source report blocker count."
    }
    if ([int]$manifest.source_report.next_action_count -ne $sourceActions.Count) {
        $sourceFailures += "manifest next_action_count does not match source report next_action_plan count."
    }
    if (-not $manifest.source_report.PSObject.Properties["unique_operator_command_count"]) {
        $sourceFailures += "manifest source_report is missing unique_operator_command_count."
    }
    elseif ([int]$manifest.source_report.unique_operator_command_count -ne $uniquePacketCommands.Count) {
        $sourceFailures += "manifest unique_operator_command_count does not match packet unique command count."
    }
    if ([int]$manifest.source_report.operator_placeholder_count -ne [int]$sourceOperatorPlaceholderCount) {
        $sourceFailures += "manifest operator_placeholder_count does not match source report next_action_plan operator placeholders."
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
        foreach ($field in @("phase", "title", "summary", "action")) {
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
        foreach ($arrayName in @("commands", "blocker_ids", "blocker_summaries", "external_blocker_ids", "categories", "source_ids")) {
            $packetArray = @(Get-ObjectArray -Object $packetAction -Name $arrayName)
            $sourceArray = @(Get-ObjectArray -Object $sourceAction -Name $arrayName)
            if ((Join-ArrayForCompare -Values $packetArray) -ne (Join-ArrayForCompare -Values $sourceArray)) {
                $actionFailures += "packet action $id array mismatch: $arrayName"
            }
        }

        if ((Convert-ForCompare -Value @(Get-ObjectArray -Object $packetAction -Name "operator_placeholders")) -ne (Convert-ForCompare -Value @(Get-ObjectArray -Object $sourceAction -Name "operator_placeholders"))) {
            $actionFailures += "packet action $id operator_placeholders mismatch."
        }
    }
    $checks += New-Check -Id "action_plan_matches_source" -Passed ($actionFailures.Count -eq 0) -Failures $actionFailures -Evidence ([pscustomobject][ordered]@{ action_count = $packetActions.Count })

    $commandSequenceFailures = @()
    if (-not $plan.PSObject.Properties["summary"]) {
        $commandSequenceFailures += "next-action plan is missing summary."
    }
    else {
        if ([int]$plan.summary.action_count -ne $packetActions.Count) {
            $commandSequenceFailures += "plan summary action_count does not match packet actions."
        }
        if ([int]$plan.summary.unique_operator_command_count -ne $uniquePacketCommands.Count) {
            $commandSequenceFailures += "plan summary unique_operator_command_count does not match packet unique commands."
        }
        $expectedDuplicateCount = [Math]::Max(0, $packetCommands.Count - $uniquePacketCommands.Count)
        if ([int]$plan.summary.duplicate_operator_command_count -ne $expectedDuplicateCount) {
            $commandSequenceFailures += "plan summary duplicate_operator_command_count does not match duplicate command count."
        }
        if (-not $plan.summary.PSObject.Properties["operator_command_phase_count"]) {
            $commandSequenceFailures += "plan summary is missing operator_command_phase_count."
        }
    }

    $deduplicatedCommands = @(Get-ObjectArray -Object $plan -Name "deduplicated_operator_commands")
    if ($deduplicatedCommands.Count -ne $uniquePacketCommands.Count) {
        $commandSequenceFailures += "deduplicated_operator_commands count does not match unique packet commands."
    }

    $dedupeCommandsSeen = @{}
    $expectedSequence = 1
    $previousLatestPhaseOrder = -1
    foreach ($group in $deduplicatedCommands) {
        $groupCommand = [string]$group.command
        if ([string]::IsNullOrWhiteSpace($groupCommand)) {
            $commandSequenceFailures += "deduplicated command group is missing command."
        }
        elseif ($dedupeCommandsSeen.ContainsKey($groupCommand)) {
            $commandSequenceFailures += "duplicate command appears in deduplicated sequence: $groupCommand"
        }
        else {
            $dedupeCommandsSeen[$groupCommand] = $true
        }

        if ([int]$group.sequence -ne $expectedSequence) {
            $commandSequenceFailures += "deduplicated command group has unexpected sequence $($group.sequence), expected $expectedSequence."
        }
        $expectedSequence += 1

        if (-not $group.PSObject.Properties["earliest_phase_order"]) {
            $commandSequenceFailures += "deduplicated command group is missing earliest_phase_order."
        }
        if (-not $group.PSObject.Properties["latest_phase_order"]) {
            $commandSequenceFailures += "deduplicated command group is missing latest_phase_order."
        }
        if ($group.PSObject.Properties["earliest_phase_order"] -and $group.PSObject.Properties["latest_phase_order"]) {
            if ([int]$group.earliest_phase_order -gt [int]$group.latest_phase_order) {
                $commandSequenceFailures += "deduplicated command group has earliest_phase_order greater than latest_phase_order."
            }
            if ([int]$group.latest_phase_order -lt $previousLatestPhaseOrder) {
                $commandSequenceFailures += "deduplicated command sequence is not sorted by latest_phase_order at command: $groupCommand"
            }
            $previousLatestPhaseOrder = [int]$group.latest_phase_order
        }

        if (@(Get-ObjectArray -Object $group -Name "action_ids").Count -eq 0) {
            $commandSequenceFailures += "deduplicated command group is missing action_ids."
        }
        if (@(Get-ObjectArray -Object $group -Name "blocker_ids").Count -eq 0 -and $packetActions.Count -gt 0) {
            $commandSequenceFailures += "deduplicated command group is missing blocker_ids."
        }

        $expectedPlaceholderTokens = @(Get-PlaceholderTokensFromCommand -Command $groupCommand)
        $actualPlaceholderTokens = @(Get-ObjectArray -Object $group -Name "placeholder_tokens" | ForEach-Object { [string]$_ })
        foreach ($token in $expectedPlaceholderTokens) {
            if ($actualPlaceholderTokens -notcontains $token) {
                $commandSequenceFailures += "deduplicated command group placeholder_tokens missing $token for command: $groupCommand"
            }
        }
        foreach ($token in $actualPlaceholderTokens) {
            if ($expectedPlaceholderTokens -notcontains $token) {
                $commandSequenceFailures += "deduplicated command group placeholder_tokens includes $token not present in command: $groupCommand"
            }
        }
    }

    foreach ($command in $uniquePacketCommands) {
        if (-not $dedupeCommandsSeen.ContainsKey($command)) {
            $commandSequenceFailures += "packet unique command is missing from deduplicated sequence: $command"
        }
    }

    $pilotWorkspaceCommand = @($deduplicatedCommands | Where-Object { [string]$_.command -match "Start-PassportPreMvpStaffStewardPilot\.ps1" } | Select-Object -First 1)
    $pilotFillCommand = @($deduplicatedCommands | Where-Object { [string]$_.command -match "Set-PassportPreMvpStaffStewardPilotEvidencePacket\.ps1" } | Select-Object -First 1)
    $pilotCloseoutCommand = @($deduplicatedCommands | Where-Object { [string]$_.command -match "Complete-PassportPreMvpStaffStewardPilotHandoff\.ps1" } | Select-Object -First 1)
    if ($pilotWorkspaceCommand.Count -gt 0 -and $pilotFillCommand.Count -gt 0) {
        if ([int]$pilotWorkspaceCommand[0].sequence -ge [int]$pilotFillCommand[0].sequence) {
            $commandSequenceFailures += "staff/steward pilot workspace launcher must appear before the pilot evidence fill helper."
        }
    }
    if ($pilotFillCommand.Count -gt 0 -and $pilotCloseoutCommand.Count -gt 0) {
        if ([int]$pilotFillCommand[0].sequence -ge [int]$pilotCloseoutCommand[0].sequence) {
            $commandSequenceFailures += "staff/steward pilot evidence fill helper must appear before the pilot closeout command."
        }
    }
    if ($pilotWorkspaceCommand.Count -gt 0 -and $pilotCloseoutCommand.Count -gt 0) {
        if ([int]$pilotWorkspaceCommand[0].sequence -ge [int]$pilotCloseoutCommand[0].sequence) {
            $commandSequenceFailures += "staff/steward pilot workspace launcher must appear before the pilot closeout command."
        }
    }

    $checks += New-Check -Id "deduplicated_operator_command_sequence" -Passed ($commandSequenceFailures.Count -eq 0) -Failures $commandSequenceFailures -Evidence ([pscustomobject][ordered]@{
        action_command_count = $packetCommands.Count
        unique_operator_command_count = $uniquePacketCommands.Count
        duplicate_operator_command_count = [Math]::Max(0, $packetCommands.Count - $uniquePacketCommands.Count)
    })

    $phaseScriptFailures = @()
    $phaseScriptRecords = @(Get-ObjectArray -Object $plan -Name "operator_command_phase_scripts")
    $phaseManifestScriptRecords = @(Get-ObjectArray -Object $phaseManifest -Name "phase_scripts")
    $expectedPhaseGroups = @($deduplicatedCommands | Group-Object -Property latest_phase_order | Sort-Object @{ Expression = { [int]$_.Name }; Ascending = $true })
    if ($plan.PSObject.Properties["summary"] -and $plan.summary.PSObject.Properties["operator_command_phase_count"]) {
        if ([int]$plan.summary.operator_command_phase_count -ne $expectedPhaseGroups.Count) {
            $phaseScriptFailures += "plan summary operator_command_phase_count does not match expected phase script count."
        }
    }
    if ($phaseScriptRecords.Count -ne $expectedPhaseGroups.Count) {
        $phaseScriptFailures += "operator_command_phase_scripts count does not match expected phase groups."
    }
    if ($null -eq $phaseManifest) {
        $phaseScriptFailures += "operator command phase manifest is missing or unreadable."
    }
    else {
        if ([string]$phaseManifest.app_commit -ne $currentCommit) {
            $phaseScriptFailures += "operator command phase manifest app_commit does not match current commit."
        }
        if ([string]$phaseManifest.source_report.sha256 -ne $sourceHash) {
            $phaseScriptFailures += "operator command phase manifest source report SHA-256 does not match actual source report."
        }
        if ([int]$phaseManifest.phase_script_count -ne $expectedPhaseGroups.Count) {
            $phaseScriptFailures += "operator command phase manifest phase_script_count does not match expected phase groups."
        }
        if ([System.IO.Path]::GetFullPath([string]$phaseManifest.phase_command_directory) -ne [System.IO.Path]::GetFullPath($phaseCommandDirectory)) {
            $phaseScriptFailures += "operator command phase manifest directory does not match packet phase directory."
        }
        if ((Convert-ForCompare -Value $phaseManifestScriptRecords) -ne (Convert-ForCompare -Value $phaseScriptRecords)) {
            $phaseScriptFailures += "operator command phase manifest phase_scripts do not match plan phase scripts."
        }
    }
    if ($null -ne $manifest) {
        $manifestPhaseRecords = @(Get-ObjectArray -Object $manifest -Name "operator_command_phase_scripts")
        if ($manifestPhaseRecords.Count -ne $phaseScriptRecords.Count) {
            $phaseScriptFailures += "manifest operator_command_phase_scripts count does not match plan."
        }
        elseif ((Convert-ForCompare -Value $manifestPhaseRecords) -ne (Convert-ForCompare -Value $phaseScriptRecords)) {
            $phaseScriptFailures += "manifest operator_command_phase_scripts does not match plan."
        }
    }

    $phaseRecordsByOrder = @{}
    foreach ($record in $phaseScriptRecords) {
        $phaseOrder = [int]$record.phase_order
        if ($phaseRecordsByOrder.ContainsKey($phaseOrder)) {
            $phaseScriptFailures += "duplicate phase script record for phase order $phaseOrder."
        }
        else {
            $phaseRecordsByOrder[$phaseOrder] = $record
        }
    }

    foreach ($expectedGroup in $expectedPhaseGroups) {
        $phaseOrder = [int]$expectedGroup.Name
        if (-not $phaseRecordsByOrder.ContainsKey($phaseOrder)) {
            $phaseScriptFailures += "missing phase script record for phase order $phaseOrder."
            continue
        }

        $record = $phaseRecordsByOrder[$phaseOrder]
        $expectedCommands = @($expectedGroup.Group | Sort-Object @{ Expression = { [int]$_.sequence }; Ascending = $true })
        $expectedSequences = @($expectedCommands | ForEach-Object { [int]$_.sequence })
        $actualSequences = @(Get-ObjectArray -Object $record -Name "command_sequences" | ForEach-Object { [int]$_ })
        if ((Join-ArrayForCompare -Values $actualSequences) -ne (Join-ArrayForCompare -Values $expectedSequences)) {
            $phaseScriptFailures += "phase script $phaseOrder command_sequences do not match expected command sequence."
        }
        if ([int]$record.command_count -ne $expectedCommands.Count) {
            $phaseScriptFailures += "phase script $phaseOrder command_count does not match expected command count."
        }

        $expectedPhases = @($expectedCommands | ForEach-Object { Get-ObjectArray -Object $_ -Name "phases" } | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Sort-Object -Unique)
        $actualPhases = @(Get-ObjectArray -Object $record -Name "phases" | ForEach-Object { [string]$_ } | Sort-Object -Unique)
        if ((Join-ArrayForCompare -Values $actualPhases) -ne (Join-ArrayForCompare -Values $expectedPhases)) {
            $phaseScriptFailures += "phase script $phaseOrder phases do not match expected phases."
        }

        $recordPath = [string]$record.path
        if ([string]::IsNullOrWhiteSpace($recordPath)) {
            $phaseScriptFailures += "phase script $phaseOrder is missing path."
            continue
        }
        $resolvedRecordPath = [System.IO.Path]::GetFullPath($recordPath)
        $resolvedPhaseDirectory = [System.IO.Path]::GetFullPath($phaseCommandDirectory)
        if (-not $resolvedRecordPath.StartsWith($resolvedPhaseDirectory, [System.StringComparison]::OrdinalIgnoreCase)) {
            $phaseScriptFailures += "phase script $phaseOrder path is outside operator-command-phases directory: $recordPath"
        }
        if (-not (Test-Path -LiteralPath $recordPath -PathType Leaf)) {
            $phaseScriptFailures += "phase script $phaseOrder file is missing: $recordPath"
            continue
        }
        if ([string]$record.sha256 -ne (Get-Sha256Hex -Path $recordPath)) {
            $phaseScriptFailures += "phase script $phaseOrder SHA-256 does not match file."
        }

        $phaseText = Get-Content -LiteralPath $recordPath -Raw
        foreach ($line in Get-Content -LiteralPath $recordPath) {
            $trimmed = $line.Trim()
            if ([string]::IsNullOrWhiteSpace($trimmed)) {
                continue
            }
            if (-not $trimmed.StartsWith("#")) {
                $phaseScriptFailures += "phase script $phaseOrder has executable non-comment line: $trimmed"
            }
        }
        foreach ($commandGroup in $expectedCommands) {
            $commandText = [string]$commandGroup.command
            if ($phaseText -notmatch [regex]::Escape("# $commandText")) {
                $phaseScriptFailures += "phase script $phaseOrder is missing commented command sequence $($commandGroup.sequence): $commandText"
            }
        }
    }
    $checks += New-Check -Id "operator_command_phase_scripts" -Passed ($phaseScriptFailures.Count -eq 0) -Failures $phaseScriptFailures -Evidence ([pscustomobject][ordered]@{
        expected_phase_script_count = $expectedPhaseGroups.Count
        actual_phase_script_count = $phaseScriptRecords.Count
        phase_command_directory = $phaseCommandDirectory
    })

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

    $staffStewardLauncherFailures = @()
    $staffStewardLauncherCommands = @()
    foreach ($packetAction in $packetActions) {
        foreach ($command in @(Get-ObjectArray -Object $packetAction -Name "commands")) {
            $commandText = [string]$command
            if ($commandText -match 'Start-PassportPreMvpStaffStewardPilot\.ps1') {
                $staffStewardLauncherCommands += $commandText
            }
        }
    }

    if ($staffStewardLauncherCommands.Count -lt 1) {
        $staffStewardLauncherFailures += "next-action packet must include the staff/steward pilot workspace launcher command"
    }
    foreach ($command in $staffStewardLauncherCommands) {
        if ($command -notmatch [regex]::Escape("-HandoffRoot artifacts\release\pre-mvp-staff-steward-pilot-handoff")) {
            $staffStewardLauncherFailures += "staff/steward pilot launcher command must target the generated handoff root: $command"
        }
        if ($command -match "-SkipLaunchPassport") {
            $staffStewardLauncherFailures += "operator-facing staff/steward pilot launcher command must not skip launching Passport: $command"
        }
    }

    $checks += New-Check -Id "staff_steward_workspace_launcher_command" -Passed ($staffStewardLauncherFailures.Count -eq 0) -Failures $staffStewardLauncherFailures -Evidence ([pscustomobject][ordered]@{
        launcher_command_count = $staffStewardLauncherCommands.Count
    })

    $staffStewardEvidenceFillFailures = @()
    $staffStewardActionIds = @("pre_mvp_internal_verification", "pre_mvp_passed")
    $staffStewardActions = @($packetActions | Where-Object { $staffStewardActionIds -contains [string]$_.id })
    $staffStewardHelperCommandCount = 0

    foreach ($action in $staffStewardActions) {
        $commands = @(Get-ObjectArray -Object $action -Name "commands" | ForEach-Object { [string]$_ })
        $hasFillHelper = @($commands | Where-Object { $_ -match 'Set-PassportPreMvpStaffStewardPilotEvidencePacket\.ps1' }).Count -gt 0
        $hasCloseout = @($commands | Where-Object { $_ -match 'Complete-PassportPreMvpStaffStewardPilotHandoff\.ps1' }).Count -gt 0
        if ($hasFillHelper) { $staffStewardHelperCommandCount += 1 }
        if (-not $hasFillHelper) {
            $staffStewardEvidenceFillFailures += "staff/steward action $($action.id) must include Set-PassportPreMvpStaffStewardPilotEvidencePacket.ps1 before closeout."
        }
        if (-not $hasCloseout) {
            $staffStewardEvidenceFillFailures += "staff/steward action $($action.id) must include Complete-PassportPreMvpStaffStewardPilotHandoff.ps1."
        }
    }

    $checks += New-Check -Id "staff_steward_fill_helper_commands" -Passed ($staffStewardEvidenceFillFailures.Count -eq 0) -Failures $staffStewardEvidenceFillFailures -Evidence ([pscustomobject][ordered]@{
        staff_steward_action_count = $staffStewardActions.Count
        staff_steward_helper_command_count = $staffStewardHelperCommandCount
    })

    $evidenceFillHelperFailures = @()
    $stagingActionIds = @("staging_readiness", "staging_readiness_report_ready", "staging_readiness_report_promotion_approved")
    $canaryActionIds = @("canary_mvp_readiness", "canary_mvp_readiness_report_ready", "canary_mvp_readiness_report_production_approved", "canary_readiness_evidence_packet")
    $stagingActions = @($packetActions | Where-Object { $stagingActionIds -contains [string]$_.id })
    $canaryActions = @($packetActions | Where-Object { $canaryActionIds -contains [string]$_.id })
    $stagingHelperCommandCount = 0
    $canaryHelperCommandCount = 0

    foreach ($action in $stagingActions) {
        $commands = @(Get-ObjectArray -Object $action -Name "commands" | ForEach-Object { [string]$_ })
        $hasFillHelper = @($commands | Where-Object { $_ -match 'Set-PassportStagingReadinessEvidencePacket\.ps1' }).Count -gt 0
        $hasCloseout = @($commands | Where-Object { $_ -match 'Complete-PassportStagingReadinessEvidencePacket\.ps1' }).Count -gt 0
        if ($hasFillHelper) { $stagingHelperCommandCount += 1 }
        if (-not $hasFillHelper) {
            $evidenceFillHelperFailures += "staging action $($action.id) must include Set-PassportStagingReadinessEvidencePacket.ps1 before closeout."
        }
        if (-not $hasCloseout) {
            $evidenceFillHelperFailures += "staging action $($action.id) must include Complete-PassportStagingReadinessEvidencePacket.ps1."
        }
    }

    foreach ($action in $canaryActions) {
        $commands = @(Get-ObjectArray -Object $action -Name "commands" | ForEach-Object { [string]$_ })
        $hasFillHelper = @($commands | Where-Object { $_ -match 'Set-PassportCanaryMvpReadinessEvidencePacket\.ps1' }).Count -gt 0
        $hasCloseoutOrValidation = @($commands | Where-Object { $_ -match '(Complete|Test)-PassportCanaryMvpReadinessEvidencePacket\.ps1' }).Count -gt 0
        if ($hasFillHelper) { $canaryHelperCommandCount += 1 }
        if (-not $hasFillHelper) {
            $evidenceFillHelperFailures += "canary action $($action.id) must include Set-PassportCanaryMvpReadinessEvidencePacket.ps1 before closeout or validation."
        }
        if (-not $hasCloseoutOrValidation) {
            $evidenceFillHelperFailures += "canary action $($action.id) must include Complete- or Test-PassportCanaryMvpReadinessEvidencePacket.ps1."
        }
    }

    $checks += New-Check -Id "staging_canary_fill_helper_commands" -Passed ($evidenceFillHelperFailures.Count -eq 0) -Failures $evidenceFillHelperFailures -Evidence ([pscustomobject][ordered]@{
        staging_action_count = $stagingActions.Count
        staging_helper_command_count = $stagingHelperCommandCount
        canary_action_count = $canaryActions.Count
        canary_helper_command_count = $canaryHelperCommandCount
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
    $expectedFileIds += "operator_command_phase_manifest"
    foreach ($phaseScript in @(Get-ObjectArray -Object $plan -Name "operator_command_phase_scripts")) {
        $expectedFileIds += ("operator_command_phase_{0:d3}" -f [int]$phaseScript.phase_order)
    }
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
        if ($uniquePacketCommands.Count -gt 0 -and $markdown -notmatch "## Deduplicated Operator Command Sequence") {
            $markdownFailures += "Markdown is missing deduplicated operator command sequence."
        }
        if ($packetCommands.Count -gt 0 -and $markdown -notmatch [regex]::Escape('```powershell')) {
            $markdownFailures += "Markdown is missing fenced PowerShell command blocks."
        }
        foreach ($group in @(Get-ObjectArray -Object $plan -Name "deduplicated_operator_commands")) {
            foreach ($value in @([string]$group.command, [string]"Step $($group.sequence)", [string]"$($group.earliest_phase_order)-$($group.latest_phase_order)")) {
                if (-not [string]::IsNullOrWhiteSpace($value) -and $markdown -notmatch [regex]::Escape($value)) {
                    $markdownFailures += "Markdown is missing deduplicated command metadata: $value"
                }
            }
            foreach ($actionId in @(Get-ObjectArray -Object $group -Name "action_ids")) {
                if (-not [string]::IsNullOrWhiteSpace([string]$actionId) -and $markdown -notmatch [regex]::Escape([string]$actionId)) {
                    $markdownFailures += "Markdown is missing deduplicated command action id: $actionId"
                }
            }
        }
        foreach ($phaseScript in @(Get-ObjectArray -Object $plan -Name "operator_command_phase_scripts")) {
            foreach ($value in @("## Phase Command Scripts", [string]$phaseScript.phase_order, [string]$phaseScript.command_count, [string]$phaseScript.path)) {
                if (-not [string]::IsNullOrWhiteSpace($value) -and $markdown -notmatch [regex]::Escape($value)) {
                    $markdownFailures += "Markdown is missing phase script metadata: $value"
                }
            }
        }
        foreach ($packetAction in $packetActions) {
            foreach ($value in @([string]$packetAction.id, [string]$packetAction.title, [string]$packetAction.summary, [string]$packetAction.action)) {
                if (-not [string]::IsNullOrWhiteSpace($value) -and $markdown -notmatch [regex]::Escape($value)) {
                    $markdownFailures += "Markdown is missing action value for $($packetAction.id): $value"
                }
            }
            foreach ($blockerId in @(Get-ObjectArray -Object $packetAction -Name "blocker_ids")) {
                if ($markdown -notmatch [regex]::Escape([string]$blockerId)) {
                    $markdownFailures += "Markdown is missing blocker id for $($packetAction.id): $blockerId"
                }
            }
            foreach ($summary in @(Get-ObjectArray -Object $packetAction -Name "blocker_summaries")) {
                if (-not [string]::IsNullOrWhiteSpace([string]$summary) -and $markdown -notmatch [regex]::Escape([string]$summary)) {
                    $markdownFailures += "Markdown is missing blocker summary for $($packetAction.id): $summary"
                }
            }
            foreach ($command in @(Get-ObjectArray -Object $packetAction -Name "commands")) {
                if ($markdown -notmatch [regex]::Escape([string]$command)) {
                    $markdownFailures += "Markdown is missing command for $($packetAction.id): $command"
                }
            }
            foreach ($placeholder in @(Get-ObjectArray -Object $packetAction -Name "operator_placeholders")) {
                foreach ($value in @([string]$placeholder.token, [string]$placeholder.input_kind, [string]$placeholder.validation_hint)) {
                    if (-not [string]::IsNullOrWhiteSpace($value) -and $markdown -notmatch [regex]::Escape($value)) {
                        $markdownFailures += "Markdown is missing placeholder metadata for $($packetAction.id): $value"
                    }
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
        if ($uniquePacketCommands.Count -gt 0 -and $commandText -notmatch "Deduplicated operator command sequence") {
            $commandFailures += "operator command checklist is missing deduplicated command sequence."
        }
        foreach ($packetAction in $packetActions) {
            foreach ($value in @([string]$packetAction.id, [string]$packetAction.title, [string]$packetAction.phase, [string]$packetAction.summary)) {
                if (-not [string]::IsNullOrWhiteSpace($value) -and $commandText -notmatch [regex]::Escape($value)) {
                    $commandFailures += "operator command checklist is missing action metadata for $($packetAction.id): $value"
                }
            }
            foreach ($summary in @(Get-ObjectArray -Object $packetAction -Name "blocker_summaries")) {
                if (-not [string]::IsNullOrWhiteSpace([string]$summary) -and $commandText -notmatch [regex]::Escape([string]$summary)) {
                    $commandFailures += "operator command checklist is missing blocker summary for $($packetAction.id): $summary"
                }
            }
            foreach ($placeholder in @(Get-ObjectArray -Object $packetAction -Name "operator_placeholders")) {
                foreach ($value in @([string]$placeholder.token, [string]$placeholder.input_kind, [string]$placeholder.validation_hint)) {
                    if (-not [string]::IsNullOrWhiteSpace($value) -and $commandText -notmatch [regex]::Escape($value)) {
                        $commandFailures += "operator command checklist is missing placeholder metadata for $($packetAction.id): $value"
                    }
                }
            }
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
    operator_command_phase_directory = $phaseCommandDirectory
    operator_command_phase_manifest_path = $phaseManifestPath
    operator_command_phase_manifest_sha256 = Get-Sha256Hex -Path $phaseManifestPath
    operator_command_phase_count = @(Get-ObjectArray -Object $plan -Name "operator_command_phase_scripts").Count
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
