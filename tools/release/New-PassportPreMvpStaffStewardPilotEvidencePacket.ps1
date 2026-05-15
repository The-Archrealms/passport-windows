param(
    [string]$OutputDirectory = "artifacts\release\pre-mvp-staff-steward-pilot-evidence",
    [string]$PilotId = "pre-mvp-staff-steward-pilot-001",
    [string]$PilotOwner = "<pilot-owner>",
    [string]$PolicyVersion = "token-ready-passport-mvp-pre-mvp-internal-verification-v1",
    [int]$ParticipantCount = 1,
    [string]$AppCommit,
    [string]$ArtifactManifestPath = "<internal-verification-artifact-manifest-path>",
    [string]$ArtifactManifestSha256 = "<sha256>",
    [string]$ProductionReadinessReportPath = "<production-mvp-readiness-report-path>",
    [string]$ProductionReadinessReportSha256 = "<sha256>",
    [string[]]$RemainingProductionBlocker = @("<known-production-readiness-blocker>"),
    [switch]$Force
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

    return "<passport-windows-commit>"
}

function Write-JsonFile {
    param(
        [string]$Path,
        [object]$Value
    )

    if ((Test-Path -LiteralPath $Path -PathType Leaf) -and -not $Force) {
        throw "Refusing to overwrite existing evidence file without -Force: $Path"
    }

    $Value | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $Path -Encoding UTF8
}

if ($ParticipantCount -lt 1) {
    throw "ParticipantCount must be at least 1."
}

if ([string]::IsNullOrWhiteSpace($AppCommit)) {
    $AppCommit = Get-CurrentCommit
}

$resolvedOutput = Resolve-RepoPath -Path $OutputDirectory
New-Item -ItemType Directory -Force -Path $resolvedOutput | Out-Null

$createdUtc = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")

$session = [pscustomobject][ordered]@{
    schema = "archrealms.passport.pre_mvp_staff_steward_pilot_session.v1"
    created_utc = $createdUtc
    lane = "internal-verification"
    pilot_id = $PilotId
    pilot_owner = $PilotOwner
    policy_version = $PolicyVersion
    app_commit = $AppCommit
    artifact_manifest_path = $ArtifactManifestPath
    artifact_manifest_sha256 = $ArtifactManifestSha256
    session_started_utc = "<yyyy-mm-ddThh:mm:ssZ>"
    session_ended_utc = "<yyyy-mm-ddThh:mm:ssZ>"
    pilot_participant_count = $ParticipantCount
    crown_owned_device_ids = @("<controlled-device-id>")
    synthetic_or_fake_balances_used = $true
    no_citizen_production_tokens_used = $true
    no_production_records_created = $true
    scenarios = @(
        [pscustomobject][ordered]@{ id = "identity_create_or_recover"; passed = $false; evidence_reference = "<evidence-id-or-uri>" }
        [pscustomobject][ordered]@{ id = "device_authorization"; passed = $false; evidence_reference = "<evidence-id-or-uri>" }
        [pscustomobject][ordered]@{ id = "wallet_key_binding"; passed = $false; evidence_reference = "<evidence-id-or-uri>" }
        [pscustomobject][ordered]@{ id = "recovery_revocation"; passed = $false; evidence_reference = "<evidence-id-or-uri>" }
        [pscustomobject][ordered]@{ id = "storage_contribution_opt_in_revocation"; passed = $false; evidence_reference = "<evidence-id-or-uri>" }
        [pscustomobject][ordered]@{ id = "ledger_export_verification"; passed = $false; evidence_reference = "<evidence-id-or-uri>" }
        [pscustomobject][ordered]@{ id = "hosted_ai_privacy"; passed = $false; evidence_reference = "<evidence-id-or-uri>" }
        [pscustomobject][ordered]@{ id = "production_blocker_review"; passed = $false; evidence_reference = "<evidence-id-or-uri>" }
    )
}

$signoff = [pscustomobject][ordered]@{
    schema = "archrealms.passport.pre_mvp_staff_steward_participant_signoff.v1"
    created_utc = $createdUtc
    lane = "internal-verification"
    pilot_id = $PilotId
    pilot_owner = $PilotOwner
    policy_version = $PolicyVersion
    signoffs = @(
        [pscustomobject][ordered]@{
            participant_id = "<staff-or-steward-id>"
            participant_role = "<staff-or-steward-role>"
            staff_or_steward_participant = $false
            crown_owned_device_used = $false
            no_citizen_production_tokens_used = $false
            no_production_records_created = $false
            signed_utc = "<yyyy-mm-ddThh:mm:ssZ>"
            signoff_reference = "<signature-or-controlled-approval-id>"
        }
    )
}

$issueReview = [pscustomobject][ordered]@{
    schema = "archrealms.passport.pre_mvp_staff_steward_pilot_issue_review.v1"
    created_utc = $createdUtc
    lane = "internal-verification"
    pilot_id = $PilotId
    pilot_owner = $PilotOwner
    policy_version = $PolicyVersion
    production_readiness_report_path = $ProductionReadinessReportPath
    production_readiness_report_sha256 = $ProductionReadinessReportSha256
    production_readiness_blockers_reviewed = $false
    pilot_signoff_signed = $false
    no_pilot_blocking_defects = $false
    no_production_records_created = $false
    pilot_blockers = @()
    remaining_production_blockers = @($RemainingProductionBlocker)
    review_signoff_reference = "<signature-or-controlled-approval-id>"
}

$files = [ordered]@{
    "pilot-session-record.json" = $session
    "participant-signoff.json" = $signoff
    "pilot-issue-review.json" = $issueReview
}

$fileRecords = @()
foreach ($entry in $files.GetEnumerator()) {
    $path = Join-Path $resolvedOutput $entry.Key
    Write-JsonFile -Path $path -Value $entry.Value
    $fileRecords += [pscustomobject][ordered]@{
        id = [System.IO.Path]::GetFileNameWithoutExtension($path)
        path = $path
        sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $path).Hash.ToLowerInvariant()
    }
}

$readmePath = Join-Path $resolvedOutput "README.md"
if ((-not (Test-Path -LiteralPath $readmePath -PathType Leaf)) -or $Force) {
    @(
        '# Staff/Steward Pilot Evidence Packet'
        ''
        'Fill the three JSON files in this folder after the controlled staff/steward pilot.'
        ''
        'Do not mark booleans true, scenario `passed` values true, or signoffs complete until the evidence exists.'
        'When filled, validate with:'
        ''
        '```powershell'
        ('.\tools\release\Test-PassportPreMvpStaffStewardPilotEvidencePacket.ps1 -PacketRoot "{0}" -RequireNoPlaceholders' -f $resolvedOutput)
        '```'
    ) | Set-Content -LiteralPath $readmePath -Encoding UTF8
}

[pscustomobject][ordered]@{
    packet_root = $resolvedOutput
    evidence_files = $fileRecords
    next_step = "Fill the packet, validate it with Test-PassportPreMvpStaffStewardPilotEvidencePacket.ps1 -RequireNoPlaceholders, then pass -EvidencePacketPath to New-PassportPreMvpStaffStewardPilotReport.ps1."
} | ConvertTo-Json -Depth 8
