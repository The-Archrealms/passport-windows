param(
    [string]$OutstandingWorkReportPath = "artifacts\release\production-mvp-outstanding-work-report.json",
    [string]$OutputDirectory = "artifacts\release\production-mvp-next-action-packet",
    [switch]$Force
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
        throw "Required JSON file was not found: $Path"
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

    Set-Content -LiteralPath $Path -Value ($Value | ConvertTo-Json -Depth 16) -Encoding UTF8
}

function Get-SourceCommit {
    $git = Get-Command git -ErrorAction SilentlyContinue
    if ($null -eq $git) {
        return ""
    }

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $git.Source
    $psi.Arguments = "rev-parse --short HEAD"
    $psi.WorkingDirectory = $repoRoot
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false

    $process = [System.Diagnostics.Process]::Start($psi)
    $stdout = $process.StandardOutput.ReadToEnd()
    $process.WaitForExit()
    if ($process.ExitCode -ne 0) {
        return ""
    }

    return $stdout.Trim()
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

function New-ActionRecord {
    param([object]$Item)

    return [pscustomobject][ordered]@{
        id = [string]$Item.id
        phase = [string]$Item.phase
        phase_order = [int]$Item.phase_order
        title = [string]$Item.title
        summary = $(if ($Item.PSObject.Properties["summary"]) { [string]$Item.summary } else { "" })
        action = [string]$Item.action
        commands = @(Get-ObjectArray -Object $Item -Name "commands" | ForEach-Object { [string]$_ })
        operator_placeholders = @(Get-ObjectArray -Object $Item -Name "operator_placeholders")
        blocker_ids = @(Get-ObjectArray -Object $Item -Name "blocker_ids" | ForEach-Object { [string]$_ })
        blocker_summaries = @(Get-ObjectArray -Object $Item -Name "blocker_summaries" | ForEach-Object { [string]$_ })
        operator_input_required = $(if ($Item.PSObject.Properties["operator_input_required"]) { [bool]$Item.operator_input_required } else { $false })
        required_operator_input_count = $(if ($Item.PSObject.Properties["required_operator_input_count"]) { [int]$Item.required_operator_input_count } else { 0 })
        blocked_by_external_actor = $(if ($Item.PSObject.Properties["blocked_by_external_actor"]) { [bool]$Item.blocked_by_external_actor } else { $false })
        external_blocker_ids = @(Get-ObjectArray -Object $Item -Name "external_blocker_ids" | ForEach-Object { [string]$_ })
        categories = @(Get-ObjectArray -Object $Item -Name "categories" | ForEach-Object { [string]$_ })
        source_ids = @(Get-ObjectArray -Object $Item -Name "source_ids" | ForEach-Object { [string]$_ })
    }
}

function New-FileRecord {
    param(
        [string]$Id,
        [string]$Path
    )

    return [pscustomobject][ordered]@{
        id = $Id
        path = $Path
        sha256 = Get-Sha256Hex -Path $Path
    }
}

function Join-StringArray {
    param([object[]]$Values)

    return (@($Values | ForEach-Object { [string]$_ }) -join ", ")
}

function Escape-MarkdownCell {
    param([string]$Value)

    if ($null -eq $Value) {
        return ""
    }

    return (($Value -replace "\|", "\|") -replace "`r?`n", " ")
}

function Add-MarkdownRow {
    param(
        [System.Collections.Generic.List[string]]$Lines,
        [string[]]$Cells
    )

    $escaped = @($Cells | ForEach-Object { Escape-MarkdownCell -Value $_ })
    $Lines.Add("| " + ($escaped -join " | ") + " |")
}

function Add-UniqueString {
    param(
        [System.Collections.Generic.List[string]]$List,
        [string]$Value
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return
    }

    if (-not $List.Contains($Value)) {
        $List.Add($Value)
    }
}

function New-CommandGroupRecords {
    param([object[]]$Actions)

    $groupsByCommand = [ordered]@{}
    foreach ($action in @($Actions)) {
        foreach ($command in @(Get-ObjectArray -Object $action -Name "commands" | ForEach-Object { [string]$_ })) {
            if ([string]::IsNullOrWhiteSpace($command)) {
                continue
            }

            if (-not $groupsByCommand.Contains($command)) {
                $groupsByCommand[$command] = [ordered]@{
                    command = $command
                    phase_order = [int]$action.phase_order
                    earliest_phase_order = [int]$action.phase_order
                    latest_phase_order = [int]$action.phase_order
                    phases = New-Object System.Collections.Generic.List[string]
                    action_ids = New-Object System.Collections.Generic.List[string]
                    action_titles = New-Object System.Collections.Generic.List[string]
                    blocker_ids = New-Object System.Collections.Generic.List[string]
                    placeholder_tokens = New-Object System.Collections.Generic.List[string]
                }
            }

            $entry = $groupsByCommand[$command]
            if ([int]$action.phase_order -lt [int]$entry.earliest_phase_order) {
                $entry.earliest_phase_order = [int]$action.phase_order
            }
            if ([int]$action.phase_order -gt [int]$entry.latest_phase_order) {
                $entry.latest_phase_order = [int]$action.phase_order
                $entry.phase_order = [int]$action.phase_order
            }
            Add-UniqueString -List $entry.phases -Value ([string]$action.phase)
            Add-UniqueString -List $entry.action_ids -Value ([string]$action.id)
            Add-UniqueString -List $entry.action_titles -Value ([string]$action.title)
            foreach ($blockerId in @(Get-ObjectArray -Object $action -Name "blocker_ids")) {
                Add-UniqueString -List $entry.blocker_ids -Value ([string]$blockerId)
            }
            foreach ($placeholder in @(Get-ObjectArray -Object $action -Name "operator_placeholders")) {
                Add-UniqueString -List $entry.placeholder_tokens -Value ([string]$placeholder.token)
            }
        }
    }

    $index = 0
    return @($groupsByCommand.Values |
        Sort-Object @{ Expression = { [int]$_["latest_phase_order"] }; Ascending = $true }, @{ Expression = { [int]$_["earliest_phase_order"] }; Ascending = $true }, @{ Expression = { [string]$_["command"] }; Ascending = $true } |
        ForEach-Object {
            $index += 1
            [pscustomobject][ordered]@{
                sequence = $index
                command = [string]$_["command"]
                phase_order = [int]$_["phase_order"]
                earliest_phase_order = [int]$_["earliest_phase_order"]
                latest_phase_order = [int]$_["latest_phase_order"]
                phases = @($_["phases"])
                action_ids = @($_["action_ids"])
                action_titles = @($_["action_titles"])
                blocker_ids = @($_["blocker_ids"])
                placeholder_tokens = @($_["placeholder_tokens"])
            }
        })
}

$resolvedReportPath = Resolve-RepoPath -Path $OutstandingWorkReportPath
$resolvedOutputDirectory = Resolve-RepoPath -Path $OutputDirectory
$manifestPath = Join-Path $resolvedOutputDirectory "production-mvp-next-action-packet.manifest.json"
$planPath = Join-Path $resolvedOutputDirectory "next-action-plan.json"
$markdownPath = Join-Path $resolvedOutputDirectory "next-action-plan.md"
$commandsPath = Join-Path $resolvedOutputDirectory "operator-commands.ps1"
$matrixPath = Join-Path $resolvedOutputDirectory "operator-input-matrix.json"
$matrixMarkdownPath = Join-Path $resolvedOutputDirectory "operator-input-matrix.md"

if ((Test-Path -LiteralPath $manifestPath -PathType Leaf) -and -not $Force) {
    throw "Next-action packet already exists. Pass -Force to overwrite: $manifestPath"
}

New-Item -ItemType Directory -Force -Path $resolvedOutputDirectory | Out-Null

$report = Read-JsonFile -Path $resolvedReportPath
if ([string]$report.schema -ne "archrealms.passport.production_mvp_outstanding_work_report.v1") {
    throw "Unexpected outstanding-work report schema: $($report.schema)"
}

$actions = @(Get-ObjectArray -Object $report -Name "next_action_plan" | ForEach-Object { New-ActionRecord -Item $_ })
$commandGroups = @(New-CommandGroupRecords -Actions $actions)
$blockers = @(Get-ObjectArray -Object $report -Name "blockers")
$matrix = $report.operator_input_matrix
$environmentVariables = @(Get-ObjectArray -Object $matrix -Name "environment_variables")
$reportReferenceRefreshes = @(Get-ObjectArray -Object $matrix -Name "report_reference_refreshes")
$readinessEvidenceItems = @(Get-ObjectArray -Object $matrix -Name "readiness_evidence_items")
$provisioningEvidenceFiles = @(Get-ObjectArray -Object $matrix -Name "provisioning_evidence_files")
$releaseEvidenceItems = @(Get-ObjectArray -Object $matrix -Name "release_evidence_items")
$sourceCommit = Get-SourceCommit
$sourceReportHash = Get-Sha256Hex -Path $resolvedReportPath
$sourceReportAppCommit = if ($report.PSObject.Properties["app_commit"]) { [string]$report.app_commit } else { "" }
$operatorPlaceholderCount = (@($actions | ForEach-Object { @($_.operator_placeholders).Count }) | Measure-Object -Sum).Sum
if ($null -eq $operatorPlaceholderCount) {
    $operatorPlaceholderCount = 0
}

$sourceReportRecord = [pscustomobject][ordered]@{
    path = $resolvedReportPath
    sha256 = $sourceReportHash
    app_commit = $sourceReportAppCommit
    ready_for_production_testing = [bool]$report.ready_for_production_testing
    blocker_count = $blockers.Count
    next_action_count = $actions.Count
    unique_operator_command_count = $commandGroups.Count
    operator_placeholder_count = [int]$operatorPlaceholderCount
}

$plan = [pscustomobject][ordered]@{
    schema = "archrealms.passport.production_mvp_next_action_plan.v1"
    created_utc = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
    app_commit = $sourceCommit
    source_report = $sourceReportRecord
    summary = [pscustomobject][ordered]@{
        action_count = $actions.Count
        unique_operator_command_count = $commandGroups.Count
        duplicate_operator_command_count = [Math]::Max(0, (($actions | ForEach-Object { @(Get-ObjectArray -Object $_ -Name "commands").Count } | Measure-Object -Sum).Sum) - $commandGroups.Count)
    }
    deduplicated_operator_commands = @($commandGroups)
    actions = @($actions)
}

Write-JsonFile -Path $planPath -Value $plan

$matrixDocument = [pscustomobject][ordered]@{
    schema = "archrealms.passport.production_mvp_operator_input_matrix.v1"
    created_utc = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
    app_commit = $sourceCommit
    source_report = $sourceReportRecord
    summary = [pscustomobject][ordered]@{
        environment_variable_count = $environmentVariables.Count
        report_reference_refresh_count = $reportReferenceRefreshes.Count
        readiness_evidence_item_count = $readinessEvidenceItems.Count
        provisioning_evidence_file_count = $provisioningEvidenceFiles.Count
        release_evidence_item_count = $releaseEvidenceItems.Count
    }
    environment_variables = @($environmentVariables)
    report_reference_refreshes = @($reportReferenceRefreshes)
    readiness_evidence_items = @($readinessEvidenceItems)
    provisioning_evidence_files = @($provisioningEvidenceFiles)
    release_evidence_items = @($releaseEvidenceItems)
}
Write-JsonFile -Path $matrixPath -Value $matrixDocument

$markdown = New-Object System.Collections.Generic.List[string]
$markdown.Add("# Production MVP Next Action Plan")
$markdown.Add("")
$markdown.Add("- Generated UTC: $($plan.created_utc)")
$markdown.Add("- App commit: $sourceCommit")
$markdown.Add("- Source report: ``$resolvedReportPath``")
$markdown.Add("- Source report SHA-256: ``$sourceReportHash``")
$markdown.Add("- Ready for production testing: $(([bool]$report.ready_for_production_testing).ToString().ToLowerInvariant())")
$markdown.Add("- Blockers: $($blockers.Count)")
$markdown.Add("- Action items: $($actions.Count)")
$markdown.Add("- Unique operator commands: $($commandGroups.Count)")
$markdown.Add("- Operator placeholders: $([int]$operatorPlaceholderCount)")
$markdown.Add("")

if ($actions.Count -eq 0) {
    $markdown.Add("No next actions are required by the source outstanding-work report.")
}
else {
    $markdown.Add("## Deduplicated Operator Command Sequence")
    $markdown.Add("")
    $markdown.Add("Run each command at most once after replacing placeholders and validating the referenced evidence packet. The detailed action sections below preserve every covered blocker.")
    $markdown.Add("")
    foreach ($group in $commandGroups) {
        $markdown.Add("### Step $($group.sequence)")
        $markdown.Add("")
        $markdown.Add("- Phases: $((@($group.phases) -join ', '))")
        $markdown.Add("- Phase order window: $($group.earliest_phase_order)-$($group.latest_phase_order)")
        $markdown.Add("- Actions covered: $((@($group.action_ids) -join ', '))")
        $markdown.Add("- Blockers covered: $((@($group.blocker_ids) -join ', '))")
        if (@($group.placeholder_tokens).Count -gt 0) {
            $markdown.Add("- Placeholder tokens: $((@($group.placeholder_tokens) -join ', '))")
        }
        $markdown.Add("")
        $markdown.Add('```powershell')
        $markdown.Add([string]$group.command)
        $markdown.Add('```')
        $markdown.Add("")
    }

    $markdown.Add("## Detailed Action Plan")
    $markdown.Add("")

    $currentPhase = ""
    foreach ($action in $actions) {
        if ($action.phase -ne $currentPhase) {
            $currentPhase = $action.phase
            $markdown.Add("## Phase: $currentPhase")
            $markdown.Add("")
        }

        $markdown.Add("### $($action.id): $($action.title)")
        $markdown.Add("")
        if (-not [string]::IsNullOrWhiteSpace([string]$action.summary)) {
            $markdown.Add("- Summary: $($action.summary)")
        }
        if (@($action.blocker_summaries).Count -gt 0) {
            $markdown.Add("- Covered blocker summaries:")
            foreach ($summary in @($action.blocker_summaries)) {
                $markdown.Add("  - $summary")
            }
        }
        $markdown.Add("- Action: $($action.action)")
        $markdown.Add("- Blockers covered: $((@($action.blocker_ids) -join ', '))")
        $markdown.Add("- Operator input required: $(([bool]$action.operator_input_required).ToString().ToLowerInvariant())")
        $markdown.Add("- External blocker count: $($action.required_operator_input_count)")
        $markdown.Add("- Blocked by external actor: $(([bool]$action.blocked_by_external_actor).ToString().ToLowerInvariant())")
        if (@($action.operator_placeholders).Count -gt 0) {
            $markdown.Add("- Placeholders:")
            foreach ($placeholder in @($action.operator_placeholders)) {
                $markdown.Add("  - ``$($placeholder.token)`` ($($placeholder.input_kind)): $($placeholder.validation_hint)")
            }
        }
        if (@($action.categories).Count -gt 0) {
            $markdown.Add("- Categories: $((@($action.categories) -join ', '))")
        }
        $markdown.Add("")
        $markdown.Add('```powershell')
        foreach ($command in @($action.commands)) {
            $markdown.Add($command)
        }
        $markdown.Add('```')
        $markdown.Add("")
    }
}

Set-Content -LiteralPath $markdownPath -Value $markdown -Encoding UTF8

$matrixMarkdown = New-Object System.Collections.Generic.List[string]
$matrixMarkdown.Add("# Production MVP Operator Input Matrix")
$matrixMarkdown.Add("")
$matrixMarkdown.Add("- Generated UTC: $($matrixDocument.created_utc)")
$matrixMarkdown.Add("- App commit: $sourceCommit")
$matrixMarkdown.Add("- Source report: ``$resolvedReportPath``")
$matrixMarkdown.Add("- Source report SHA-256: ``$sourceReportHash``")
$matrixMarkdown.Add("- Environment variables: $($environmentVariables.Count)")
$matrixMarkdown.Add("- Report reference refreshes: $($reportReferenceRefreshes.Count)")
$matrixMarkdown.Add("- Readiness evidence items: $($readinessEvidenceItems.Count)")
$matrixMarkdown.Add("- Provisioning evidence files: $($provisioningEvidenceFiles.Count)")
$matrixMarkdown.Add("- Release evidence items: $($releaseEvidenceItems.Count)")
$matrixMarkdown.Add("")

$matrixMarkdown.Add("## Environment Variables")
$matrixMarkdown.Add("")
Add-MarkdownRow -Lines $matrixMarkdown -Cells @("Variable", "Sources", "Template gate", "Required", "Kind", "Sensitivity", "Secret store", "Validation", "Readiness gates", "Missing text")
Add-MarkdownRow -Lines $matrixMarkdown -Cells @("---", "---", "---", "---", "---", "---", "---", "---", "---", "---")
foreach ($item in $environmentVariables) {
    Add-MarkdownRow -Lines $matrixMarkdown -Cells @(
        [string]$item.name,
        (Join-StringArray -Values (Get-ObjectArray -Object $item -Name "sources")),
        [string]$item.template_gate,
        $(if ($null -ne $item.PSObject.Properties["template_required"] -and $null -ne $item.template_required) { ([bool]$item.template_required).ToString().ToLowerInvariant() } else { "" }),
        [string]$item.input_kind,
        [string]$item.sensitivity,
        ([bool]$item.requires_secret_store).ToString().ToLowerInvariant(),
        [string]$item.validation_hint,
        (Join-StringArray -Values (Get-ObjectArray -Object $item -Name "readiness_gate_ids")),
        (Join-StringArray -Values (Get-ObjectArray -Object $item -Name "missing_texts"))
    )
}
$matrixMarkdown.Add("")

$matrixMarkdown.Add("## Readiness Evidence")
$matrixMarkdown.Add("")
Add-MarkdownRow -Lines $matrixMarkdown -Cells @("Gate", "Missing text", "Next action")
Add-MarkdownRow -Lines $matrixMarkdown -Cells @("---", "---", "---")
foreach ($item in $readinessEvidenceItems) {
    Add-MarkdownRow -Lines $matrixMarkdown -Cells @([string]$item.readiness_gate_id, [string]$item.missing_text, [string]$item.operator_action)
}
$matrixMarkdown.Add("")

$matrixMarkdown.Add("## Provisioning Evidence Files")
$matrixMarkdown.Add("")
Add-MarkdownRow -Lines $matrixMarkdown -Cells @("Provisioning check", "Child check", "Evidence path", "Failures")
Add-MarkdownRow -Lines $matrixMarkdown -Cells @("---", "---", "---", "---")
foreach ($item in $provisioningEvidenceFiles) {
    Add-MarkdownRow -Lines $matrixMarkdown -Cells @(
        [string]$item.provisioning_check_id,
        [string]$item.child_check_id,
        [string]$item.evidence_path,
        (Join-StringArray -Values (Get-ObjectArray -Object $item -Name "failures"))
    )
}
$matrixMarkdown.Add("")

$matrixMarkdown.Add("## Release Evidence")
$matrixMarkdown.Add("")
Add-MarkdownRow -Lines $matrixMarkdown -Cells @("Release item", "Failures", "Next action")
Add-MarkdownRow -Lines $matrixMarkdown -Cells @("---", "---", "---")
foreach ($item in $releaseEvidenceItems) {
    Add-MarkdownRow -Lines $matrixMarkdown -Cells @(
        [string]$item.id,
        (Join-StringArray -Values (Get-ObjectArray -Object $item -Name "failures")),
        [string]$item.operator_action
    )
}
$matrixMarkdown.Add("")

Set-Content -LiteralPath $matrixMarkdownPath -Value $matrixMarkdown -Encoding UTF8

$commandLines = New-Object System.Collections.Generic.List[string]
$commandLines.Add("# Production MVP next-action command checklist.")
$commandLines.Add("# Commands are commented intentionally because they require filled external evidence and secrets.")
$commandLines.Add("# Replace placeholders, review the target evidence packet, then run the deduplicated sequence in a secure operator shell.")
$commandLines.Add("")
if ($commandGroups.Count -gt 0) {
    $commandLines.Add("# Deduplicated operator command sequence.")
    foreach ($group in $commandGroups) {
        $commandLines.Add("# Step $($group.sequence)")
        $commandLines.Add("# Phases: $((@($group.phases) -join ', '))")
        $commandLines.Add("# Phase order window: $($group.earliest_phase_order)-$($group.latest_phase_order)")
        $commandLines.Add("# Actions: $((@($group.action_ids) -join ', '))")
        $commandLines.Add("# Blockers: $((@($group.blocker_ids) -join ', '))")
        if (@($group.placeholder_tokens).Count -gt 0) {
            $commandLines.Add("# Placeholders: $((@($group.placeholder_tokens) -join ', '))")
        }
        $commandLines.Add("# $($group.command)")
        $commandLines.Add("")
    }

    $commandLines.Add("# Detailed action traceability.")
    $commandLines.Add("")
}
foreach ($action in $actions) {
    $commandLines.Add("# Action: $($action.id) - $($action.title)")
    $commandLines.Add("# Phase: $($action.phase)")
    if (-not [string]::IsNullOrWhiteSpace([string]$action.summary)) {
        $commandLines.Add("# Summary: $($action.summary)")
    }
    if (@($action.blocker_summaries).Count -gt 0) {
        $commandLines.Add("# Covered blocker summaries:")
        foreach ($summary in @($action.blocker_summaries)) {
            $commandLines.Add("# - $summary")
        }
    }
    $commandLines.Add("# Blockers: $((@($action.blocker_ids) -join ', '))")
    $commandLines.Add("# Operator input required: $(([bool]$action.operator_input_required).ToString().ToLowerInvariant())")
    $commandLines.Add("# External blocker count: $($action.required_operator_input_count)")
    $commandLines.Add("# Blocked by external actor: $(([bool]$action.blocked_by_external_actor).ToString().ToLowerInvariant())")
    foreach ($placeholder in @($action.operator_placeholders)) {
        $commandLines.Add("# Placeholder: $($placeholder.token) [$($placeholder.input_kind)] $($placeholder.validation_hint)")
    }
    foreach ($command in @($action.commands)) {
        $commandLines.Add("# $command")
    }
    $commandLines.Add("")
}
Set-Content -LiteralPath $commandsPath -Value $commandLines -Encoding UTF8

$manifest = [pscustomobject][ordered]@{
    schema = "archrealms.passport.production_mvp_next_action_packet_manifest.v1"
    created_utc = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
    app_commit = $sourceCommit
    output_directory = $resolvedOutputDirectory
    source_report = [pscustomobject][ordered]@{
        path = $resolvedReportPath
        sha256 = $sourceReportHash
        app_commit = $sourceReportAppCommit
        ready_for_production_testing = [bool]$report.ready_for_production_testing
        blocker_count = $blockers.Count
        next_action_count = $actions.Count
        unique_operator_command_count = $commandGroups.Count
        operator_placeholder_count = [int]$operatorPlaceholderCount
        environment_variable_count = $environmentVariables.Count
        readiness_evidence_item_count = $readinessEvidenceItems.Count
        provisioning_evidence_file_count = $provisioningEvidenceFiles.Count
        release_evidence_item_count = $releaseEvidenceItems.Count
    }
    generated_files = @(
        New-FileRecord -Id "next_action_plan_json" -Path $planPath
        New-FileRecord -Id "next_action_plan_markdown" -Path $markdownPath
        New-FileRecord -Id "operator_input_matrix_json" -Path $matrixPath
        New-FileRecord -Id "operator_input_matrix_markdown" -Path $matrixMarkdownPath
        New-FileRecord -Id "operator_commands" -Path $commandsPath
    )
}
Write-JsonFile -Path $manifestPath -Value $manifest

$result = [pscustomobject][ordered]@{
    schema = "archrealms.passport.production_mvp_next_action_packet_result.v1"
    output_directory = $resolvedOutputDirectory
    manifest_path = $manifestPath
    manifest_sha256 = Get-Sha256Hex -Path $manifestPath
    next_action_plan_path = $planPath
    next_action_plan_sha256 = Get-Sha256Hex -Path $planPath
    markdown_path = $markdownPath
    markdown_sha256 = Get-Sha256Hex -Path $markdownPath
    operator_input_matrix_path = $matrixPath
    operator_input_matrix_sha256 = Get-Sha256Hex -Path $matrixPath
    operator_input_matrix_markdown_path = $matrixMarkdownPath
    operator_input_matrix_markdown_sha256 = Get-Sha256Hex -Path $matrixMarkdownPath
    operator_commands_path = $commandsPath
    operator_commands_sha256 = Get-Sha256Hex -Path $commandsPath
    action_count = $actions.Count
    unique_operator_command_count = $commandGroups.Count
    blocker_count = $blockers.Count
    operator_placeholder_count = [int]$operatorPlaceholderCount
}

$result | ConvertTo-Json -Depth 12
