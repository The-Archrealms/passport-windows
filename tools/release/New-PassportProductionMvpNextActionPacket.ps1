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
        action = [string]$Item.action
        commands = @(Get-ObjectArray -Object $Item -Name "commands" | ForEach-Object { [string]$_ })
        blocker_ids = @(Get-ObjectArray -Object $Item -Name "blocker_ids" | ForEach-Object { [string]$_ })
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

$resolvedReportPath = Resolve-RepoPath -Path $OutstandingWorkReportPath
$resolvedOutputDirectory = Resolve-RepoPath -Path $OutputDirectory
$manifestPath = Join-Path $resolvedOutputDirectory "production-mvp-next-action-packet.manifest.json"
$planPath = Join-Path $resolvedOutputDirectory "next-action-plan.json"
$markdownPath = Join-Path $resolvedOutputDirectory "next-action-plan.md"
$commandsPath = Join-Path $resolvedOutputDirectory "operator-commands.ps1"

if ((Test-Path -LiteralPath $manifestPath -PathType Leaf) -and -not $Force) {
    throw "Next-action packet already exists. Pass -Force to overwrite: $manifestPath"
}

New-Item -ItemType Directory -Force -Path $resolvedOutputDirectory | Out-Null

$report = Read-JsonFile -Path $resolvedReportPath
if ([string]$report.schema -ne "archrealms.passport.production_mvp_outstanding_work_report.v1") {
    throw "Unexpected outstanding-work report schema: $($report.schema)"
}

$actions = @(Get-ObjectArray -Object $report -Name "next_action_plan" | ForEach-Object { New-ActionRecord -Item $_ })
$blockers = @(Get-ObjectArray -Object $report -Name "blockers")
$sourceCommit = Get-SourceCommit
$sourceReportHash = Get-Sha256Hex -Path $resolvedReportPath

$plan = [pscustomobject][ordered]@{
    schema = "archrealms.passport.production_mvp_next_action_plan.v1"
    created_utc = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
    app_commit = $sourceCommit
    source_report = [pscustomobject][ordered]@{
        path = $resolvedReportPath
        sha256 = $sourceReportHash
        ready_for_production_testing = [bool]$report.ready_for_production_testing
        blocker_count = $blockers.Count
        next_action_count = $actions.Count
    }
    actions = @($actions)
}

Write-JsonFile -Path $planPath -Value $plan

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
$markdown.Add("")

if ($actions.Count -eq 0) {
    $markdown.Add("No next actions are required by the source outstanding-work report.")
}
else {
    $currentPhase = ""
    foreach ($action in $actions) {
        if ($action.phase -ne $currentPhase) {
            $currentPhase = $action.phase
            $markdown.Add("## Phase: $currentPhase")
            $markdown.Add("")
        }

        $markdown.Add("### $($action.id): $($action.title)")
        $markdown.Add("")
        $markdown.Add("- Action: $($action.action)")
        $markdown.Add("- Blockers covered: $((@($action.blocker_ids) -join ', '))")
        if (@($action.categories).Count -gt 0) {
            $markdown.Add("- Categories: $((@($action.categories) -join ', '))")
        }
        $markdown.Add("")
        $markdown.Add("````powershell")
        foreach ($command in @($action.commands)) {
            $markdown.Add($command)
        }
        $markdown.Add("````")
        $markdown.Add("")
    }
}

Set-Content -LiteralPath $markdownPath -Value $markdown -Encoding UTF8

$commandLines = New-Object System.Collections.Generic.List[string]
$commandLines.Add("# Production MVP next-action command checklist.")
$commandLines.Add("# Commands are commented intentionally because they require filled external evidence and secrets.")
$commandLines.Add("# Replace placeholders, review the target evidence packet, then run one command at a time in a secure operator shell.")
$commandLines.Add("")
foreach ($action in $actions) {
    $commandLines.Add("# Action: $($action.id) - $($action.title)")
    $commandLines.Add("# Phase: $($action.phase)")
    $commandLines.Add("# Blockers: $((@($action.blocker_ids) -join ', '))")
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
        ready_for_production_testing = [bool]$report.ready_for_production_testing
        blocker_count = $blockers.Count
        next_action_count = $actions.Count
    }
    generated_files = @(
        New-FileRecord -Id "next_action_plan_json" -Path $planPath
        New-FileRecord -Id "next_action_plan_markdown" -Path $markdownPath
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
    operator_commands_path = $commandsPath
    operator_commands_sha256 = Get-Sha256Hex -Path $commandsPath
    action_count = $actions.Count
    blocker_count = $blockers.Count
}

$result | ConvertTo-Json -Depth 12
