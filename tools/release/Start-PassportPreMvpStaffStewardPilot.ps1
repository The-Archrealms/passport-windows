param(
    [string]$HandoffRoot = "artifacts\release\pre-mvp-staff-steward-pilot-handoff",
    [string]$ArtifactManifestPath,
    [string]$PilotId = "pre-mvp-staff-steward-pilot-001",
    [string]$PilotOwner = "<pilot-owner>",
    [string]$OutputPath,
    [switch]$SkipOpenRunbook,
    [switch]$SkipOpenEvidenceFolder,
    [switch]$SkipLaunchPassport,
    [switch]$GenerateDryRunEvidence,
    [switch]$RunUiSmoke,
    [switch]$RunInstalledArtifactValidation,
    [switch]$SkipDaemon,
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

function Read-JsonFile {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $null
    }

    return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
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

    return "passport-windows-commit-unavailable"
}

function Get-Sha256Hex {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return ""
    }

    return (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant()
}

function New-FileRecord {
    param(
        [string]$Id,
        [string]$Path
    )

    $resolved = Resolve-RepoPath -Path $Path
    $exists = (-not [string]::IsNullOrWhiteSpace($resolved)) -and (Test-Path -LiteralPath $resolved -PathType Leaf)
    return [pscustomobject][ordered]@{
        id = $Id
        path = $resolved
        exists = $exists
        sha256 = $(if ($exists) { Get-Sha256Hex -Path $resolved } else { "" })
    }
}

function Find-InternalVerificationManifestPath {
    $candidates = @(
        "artifacts\release\internal-verification-lane\passport-windows-win-x64\release-manifest.json",
        "artifacts\release\passport-windows-win-x64\release-manifest.json",
        "artifacts\release\passport-windows-msix-sideload\x64\msix-package-manifest.json",
        "artifacts\release\passport-windows-msix-store\x64\msix-package-manifest.json",
        "artifacts\release\passport-windows-msix\x64\msix-package-manifest.json"
    )

    foreach ($candidate in $candidates) {
        $path = Resolve-RepoPath -Path $candidate
        $json = Read-JsonFile -Path $path
        if ($null -ne $json -and $json.PSObject.Properties["lane"] -and $json.lane -eq "internal-verification") {
            return $path
        }
    }

    return ""
}

function Resolve-ExecutablePath {
    param([object]$Manifest)

    if ($null -eq $Manifest -or -not $Manifest.PSObject.Properties["publish_dir"]) {
        return ""
    }

    $candidate = Join-Path ([string]$Manifest.publish_dir) "ArchrealmsPassport.Windows.exe"
    if (Test-Path -LiteralPath $candidate -PathType Leaf) {
        return [System.IO.Path]::GetFullPath($candidate)
    }

    return ""
}

function Invoke-Tool {
    param(
        [string]$FilePath,
        [string[]]$Arguments
    )

    $started = [DateTimeOffset]::UtcNow
    $output = & powershell -NoProfile -ExecutionPolicy Bypass -File $FilePath @Arguments 2>&1
    $exitCode = $LASTEXITCODE
    $ended = [DateTimeOffset]::UtcNow

    return [pscustomobject][ordered]@{
        command = "powershell -NoProfile -ExecutionPolicy Bypass -File `"$FilePath`" $($Arguments -join ' ')"
        started_utc = $started.ToString("yyyy-MM-ddTHH:mm:ssZ")
        ended_utc = $ended.ToString("yyyy-MM-ddTHH:mm:ssZ")
        exit_code = $exitCode
        passed = ($exitCode -eq 0)
        output = @($output | ForEach-Object { [string]$_ })
    }
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

    $Value | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $Path -Encoding UTF8
}

$resolvedHandoffRoot = Resolve-RepoPath -Path $HandoffRoot
if (-not (Test-Path -LiteralPath $resolvedHandoffRoot -PathType Container)) {
    throw "Staff/steward pilot handoff directory is missing: $resolvedHandoffRoot"
}

$handoffManifestPath = Join-Path $resolvedHandoffRoot "pilot-handoff.manifest.json"
$handoffManifest = Read-JsonFile -Path $handoffManifestPath
if ($null -eq $handoffManifest) {
    throw "Staff/steward pilot handoff manifest is missing or unreadable: $handoffManifestPath"
}

$runbookPath = Join-Path $resolvedHandoffRoot "operator-runbook.md"
if (-not (Test-Path -LiteralPath $runbookPath -PathType Leaf)) {
    throw "Staff/steward pilot runbook is missing: $runbookPath"
}

$evidencePacketDirectory = ""
if ($handoffManifest.PSObject.Properties["evidence_packet_directory"]) {
    $evidencePacketDirectory = [string]$handoffManifest.evidence_packet_directory
}

if ([string]::IsNullOrWhiteSpace($evidencePacketDirectory)) {
    $evidencePacketDirectory = Join-Path $resolvedHandoffRoot "pilot-evidence"
}

$evidencePacketDirectory = Resolve-RepoPath -Path $evidencePacketDirectory
if (-not (Test-Path -LiteralPath $evidencePacketDirectory -PathType Container)) {
    throw "Staff/steward pilot evidence packet directory is missing: $evidencePacketDirectory"
}

if ([string]::IsNullOrWhiteSpace($ArtifactManifestPath)) {
    $ArtifactManifestPath = Find-InternalVerificationManifestPath
}

$artifactManifestRecord = New-FileRecord -Id "internal_verification_artifact_manifest" -Path $ArtifactManifestPath
if (-not $artifactManifestRecord.exists) {
    throw "Internal-verification artifact manifest is missing: $($artifactManifestRecord.path)"
}

$artifactManifest = Read-JsonFile -Path $artifactManifestRecord.path
if ($null -eq $artifactManifest -or -not $artifactManifest.PSObject.Properties["lane"] -or $artifactManifest.lane -ne "internal-verification") {
    throw "Artifact manifest must be for the internal-verification lane: $($artifactManifestRecord.path)"
}

$executablePath = Resolve-ExecutablePath -Manifest $artifactManifest
if ([string]::IsNullOrWhiteSpace($executablePath)) {
    throw "Internal-verification artifact manifest does not point to ArchrealmsPassport.Windows.exe."
}

if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $OutputPath = Join-Path $resolvedHandoffRoot "pilot-workspace-launch.json"
}

$resolvedOutputPath = Resolve-RepoPath -Path $OutputPath
if ((Test-Path -LiteralPath $resolvedOutputPath -PathType Leaf) -and -not $Force) {
    throw "Refusing to overwrite existing pilot workspace launch report without -Force: $resolvedOutputPath"
}

$actions = [ordered]@{
    opened_runbook = $false
    opened_evidence_folder = $false
    launched_passport = $false
}

$startedPassportProcess = $null
if (-not $SkipOpenRunbook) {
    Start-Process -FilePath $runbookPath | Out-Null
    $actions.opened_runbook = $true
}

if (-not $SkipOpenEvidenceFolder) {
    Start-Process -FilePath "explorer.exe" -ArgumentList @($evidencePacketDirectory) | Out-Null
    $actions.opened_evidence_folder = $true
}

$dryRunResult = $null
if ($GenerateDryRunEvidence) {
    $dryRunArguments = @(
        "-OutputDirectory", (Join-Path $resolvedHandoffRoot "pilot-dry-run"),
        "-HandoffRoot", $resolvedHandoffRoot,
        "-PilotId", $PilotId,
        "-PilotOwner", $PilotOwner,
        "-InternalVerificationManifestPath", $artifactManifestRecord.path,
        "-ExecutablePath", $executablePath,
        "-Force"
    )

    if ($RunUiSmoke) {
        $dryRunArguments += "-RunUiSmoke"
    }

    if ($RunInstalledArtifactValidation) {
        $dryRunArguments += "-RunInstalledArtifactValidation"
    }

    if ($SkipDaemon) {
        $dryRunArguments += "-SkipDaemon"
    }

    $dryRunResult = Invoke-Tool -FilePath (Join-Path $scriptRoot "New-PassportPreMvpStaffStewardPilotDryRunEvidence.ps1") -Arguments $dryRunArguments
}

if (-not $SkipLaunchPassport) {
    $startedPassportProcess = Start-Process -FilePath $executablePath -PassThru
    $actions.launched_passport = $true
}

$report = [pscustomobject][ordered]@{
    schema = "archrealms.passport.pre_mvp_staff_steward_pilot_workspace_launch.v1"
    created_utc = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
    lane = "internal-verification"
    app_commit = Get-CurrentCommit
    pilot_id = $PilotId
    pilot_owner = $PilotOwner
    not_a_passing_staff_steward_pilot_report = $true
    controlled_staff_steward_signoff_required = $true
    no_citizen_production_tokens_used = $true
    production_records_must_not_be_created = $true
    handoff_root = $resolvedHandoffRoot
    handoff_manifest = New-FileRecord -Id "staff_steward_pilot_handoff_manifest" -Path $handoffManifestPath
    runbook = New-FileRecord -Id "operator_runbook" -Path $runbookPath
    evidence_packet_directory = $evidencePacketDirectory
    artifact_manifest = $artifactManifestRecord
    executable = New-FileRecord -Id "archrealms_passport_windows_executable" -Path $executablePath
    actions = $actions
    passport_process_id = $(if ($startedPassportProcess) { $startedPassportProcess.Id } else { 0 })
    dry_run_generation = $dryRunResult
    next_step = "Perform the controlled staff/steward pilot, fill the evidence packet, validate it with -RequireNoPlaceholders, generate the pilot report, then rerun pre-MVP internal verification with the pilot report SHA-256."
}

Write-JsonFile -Path $resolvedOutputPath -Value $report

[pscustomobject][ordered]@{
    workspace_launch_report_path = $resolvedOutputPath
    workspace_launch_report_sha256 = Get-Sha256Hex -Path $resolvedOutputPath
    launched_passport = [bool]$actions.launched_passport
    passport_process_id = $report.passport_process_id
    opened_runbook = [bool]$actions.opened_runbook
    opened_evidence_folder = [bool]$actions.opened_evidence_folder
    dry_run_generated = ($null -ne $dryRunResult)
    dry_run_passed = $(if ($null -ne $dryRunResult) { [bool]$dryRunResult.passed } else { $null })
    next_step = $report.next_step
} | ConvertTo-Json -Depth 8

if ($null -ne $dryRunResult -and -not [bool]$dryRunResult.passed) {
    exit 1
}
