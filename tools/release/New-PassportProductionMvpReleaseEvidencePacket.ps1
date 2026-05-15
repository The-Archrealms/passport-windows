param(
    [string]$OutputDirectory = "artifacts\release\production-mvp-release-evidence-packet",

    [string]$PreMvpReportPath = "artifacts\release\pre-mvp-internal-verification-report.json",

    [string]$ReadinessReportPath = "artifacts\release\production-mvp-readiness-report.json",

    [string]$ProvisioningPacketReportPath = "artifacts\release\production-provisioning-packet-validation-report.json",

    [string]$ProvisioningPacketManifestPath = "artifacts\release\production-provisioning-packet-working\production-provisioning-packet.manifest.json",

    [string]$EnvironmentFile = "",

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
        return $null
    }

    return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
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

function Clear-OutputChild {
    param(
        [string]$Root,
        [string]$Child
    )

    $target = [System.IO.Path]::GetFullPath((Join-Path $Root $Child))
    $rootWithSeparator = $Root.TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
    if (-not $target.StartsWith($rootWithSeparator, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to clear a path outside the evidence packet root: $target"
    }

    if (Test-Path -LiteralPath $target) {
        Remove-Item -LiteralPath $target -Recurse -Force
    }
}

function New-EvidenceFile {
    param(
        [string]$Id,
        [string]$Path,
        [string]$CopyRoot
    )

    $exists = Test-Path -LiteralPath $Path -PathType Leaf
    $copyPath = ""
    if ($exists) {
        $fileName = Split-Path -Leaf $Path
        $copyPath = Join-Path $CopyRoot $fileName
        Copy-Item -LiteralPath $Path -Destination $copyPath -Force
    }

    return [pscustomobject][ordered]@{
        id = $Id
        source_path = $Path
        copied_path = $copyPath
        exists = [bool]$exists
        sha256 = Get-Sha256Hex -Path $Path
    }
}

function Import-RedactedEnvironmentFile {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return @()
    }

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "EnvironmentFile was not found: $Path"
    }

    $records = @()
    foreach ($line in Get-Content -LiteralPath $Path) {
        $trimmed = $line.Trim()
        if ([string]::IsNullOrWhiteSpace($trimmed) -or $trimmed.StartsWith("#")) {
            continue
        }

        $separator = $trimmed.IndexOf("=")
        if ($separator -le 0) {
            continue
        }

        $name = $trimmed.Substring(0, $separator).Trim()
        $value = $trimmed.Substring($separator + 1).Trim()
        if (($value.StartsWith('"') -and $value.EndsWith('"')) -or ($value.StartsWith("'") -and $value.EndsWith("'"))) {
            $value = $value.Substring(1, $value.Length - 2)
        }

        $records += [pscustomobject][ordered]@{
            name = $name
            configured = -not [string]::IsNullOrWhiteSpace($value)
            value_redacted = $true
            value_length = $value.Length
        }
    }

    return $records
}

$resolvedOutput = Resolve-RepoPath -Path $OutputDirectory
if ((Test-Path -LiteralPath $resolvedOutput) -and -not $Force) {
    throw "OutputDirectory already exists. Use -Force to update it: $resolvedOutput"
}

New-Item -ItemType Directory -Force -Path $resolvedOutput | Out-Null
if ($Force) {
    Clear-OutputChild -Root $resolvedOutput -Child "reports"
    Clear-OutputChild -Root $resolvedOutput -Child "manifests"
    Clear-OutputChild -Root $resolvedOutput -Child "release-evidence.manifest.json"
    Clear-OutputChild -Root $resolvedOutput -Child "release-evidence-summary.md"
}

$reportsRoot = Join-Path $resolvedOutput "reports"
$manifestsRoot = Join-Path $resolvedOutput "manifests"
New-Item -ItemType Directory -Force -Path $reportsRoot | Out-Null
New-Item -ItemType Directory -Force -Path $manifestsRoot | Out-Null

$resolvedPreMvpReport = Resolve-RepoPath -Path $PreMvpReportPath
$resolvedReadinessReport = Resolve-RepoPath -Path $ReadinessReportPath
$resolvedProvisioningPacketReport = Resolve-RepoPath -Path $ProvisioningPacketReportPath
$resolvedProvisioningPacketManifest = Resolve-RepoPath -Path $ProvisioningPacketManifestPath
$resolvedEnvironmentFile = Resolve-RepoPath -Path $EnvironmentFile

$evidenceFiles = @(
    New-EvidenceFile -Id "pre_mvp_internal_verification_report" -Path $resolvedPreMvpReport -CopyRoot $reportsRoot
    New-EvidenceFile -Id "production_mvp_readiness_report" -Path $resolvedReadinessReport -CopyRoot $reportsRoot
    New-EvidenceFile -Id "production_provisioning_packet_validation_report" -Path $resolvedProvisioningPacketReport -CopyRoot $reportsRoot
    New-EvidenceFile -Id "production_provisioning_packet_manifest" -Path $resolvedProvisioningPacketManifest -CopyRoot $manifestsRoot
)

$preMvp = Read-JsonFile -Path $resolvedPreMvpReport
$readiness = Read-JsonFile -Path $resolvedReadinessReport
$provisioning = Read-JsonFile -Path $resolvedProvisioningPacketReport
$packetManifest = Read-JsonFile -Path $resolvedProvisioningPacketManifest
$environment = Import-RedactedEnvironmentFile -Path $resolvedEnvironmentFile

$readinessGates = @()
if ($null -ne $readiness -and $null -ne $readiness.gates) {
    foreach ($gate in $readiness.gates) {
        $readinessGates += [pscustomobject][ordered]@{
            id = $gate.id
            passed = [bool]$gate.passed
            missing = @($gate.missing)
        }
    }
}

$preMvpFailedCheckCount = $null
$preMvpFailedRequirementCount = $null
if ($null -ne $preMvp) {
    $preMvpFailedCheckCount = [int]$preMvp.failed_check_count
    $preMvpFailedRequirementCount = [int]$preMvp.failed_requirement_count
}

$provisioningFailedCheckCount = $null
$provisioningPacketRoot = ""
if ($null -ne $provisioning) {
    $provisioningFailedCheckCount = [int]$provisioning.failed_check_count
    $provisioningPacketRoot = $provisioning.packet_root
}

$packetScaffoldSourceCommit = ""
if ($null -ne $packetManifest) {
    $packetScaffoldSourceCommit = $packetManifest.source_commit
}

$readinessFailedGateCount = $null
if ($null -ne $readiness) {
    $readinessFailedGateCount = [int]$readiness.failed_gate_count
}

$manifest = [pscustomobject][ordered]@{
    schema = "archrealms.passport.production_mvp_release_evidence_packet.v1"
    created_utc = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
    repo_root = $repoRoot
    source_commit = Get-SourceCommit
    output_directory = $resolvedOutput
    secrets_included = $false
    evidence_files = $evidenceFiles
    environment_file = [pscustomobject][ordered]@{
        source_path = $resolvedEnvironmentFile
        included = -not [string]::IsNullOrWhiteSpace($resolvedEnvironmentFile)
        values_redacted = $true
        variable_count = $environment.Count
        variables = $environment
    }
    pre_mvp_internal_verification = [pscustomobject][ordered]@{
        passed = ($null -ne $preMvp -and [bool]$preMvp.passed)
        fake_balance_migration_blocked = ($null -ne $preMvp -and [bool]$preMvp.fake_balance_migration_blocked)
        failed_check_count = $preMvpFailedCheckCount
        failed_requirement_count = $preMvpFailedRequirementCount
    }
    production_provisioning_packet = [pscustomobject][ordered]@{
        passed = ($null -ne $provisioning -and [bool]$provisioning.passed)
        failed_check_count = $provisioningFailedCheckCount
        packet_root = $provisioningPacketRoot
        scaffold_source_commit = $packetScaffoldSourceCommit
    }
    production_mvp_readiness = [pscustomobject][ordered]@{
        ready = ($null -ne $readiness -and [bool]$readiness.ready)
        failed_gate_count = $readinessFailedGateCount
        gates = $readinessGates
    }
    approval_packet_status = [pscustomobject][ordered]@{
        complete_for_production_testing = ($null -ne $readiness -and [bool]$readiness.ready)
        reviewable_for_signoff = (
            ($null -ne $preMvp -and [bool]$preMvp.passed) -and
            ($null -ne $provisioning -and [bool]$provisioning.passed) -and
            ($null -ne $readiness)
        )
    }
}

$manifestPath = Join-Path $resolvedOutput "release-evidence.manifest.json"
$manifestJson = $manifest | ConvertTo-Json -Depth 10
Set-Content -LiteralPath $manifestPath -Value $manifestJson -Encoding UTF8

$blockingGateLines = @()
foreach ($gate in $readinessGates | Where-Object { -not $_.passed }) {
    $missing = "not specified"
    if ($gate.missing.Count -gt 0) {
        $missing = $gate.missing -join "; "
    }

    $blockingGateLines += "- ``$($gate.id)``: $missing"
}
if ($blockingGateLines.Count -eq 0) {
    $blockingGateLines += "- None"
}

$summaryLines = @(
    "# Archrealms Passport Production MVP Release Evidence",
    "",
    "- Created UTC: $($manifest.created_utc)",
    "- App commit: $($manifest.source_commit)",
    "- Secrets included: false",
    "- Pre-MVP verification passed: $($manifest.pre_mvp_internal_verification.passed)",
    "- Production provisioning packet passed: $($manifest.production_provisioning_packet.passed)",
    "- Production readiness ready: $($manifest.production_mvp_readiness.ready)",
    "- Production readiness failed gates: $($manifest.production_mvp_readiness.failed_gate_count)",
    "",
    "## Evidence Hashes",
    ""
)
foreach ($file in $evidenceFiles) {
    $summaryLines += "- ``$($file.id)``: exists=$($file.exists); sha256=``$($file.sha256)``"
}
$summaryLines += ""
$summaryLines += "## Blocking Gates"
$summaryLines += ""
$summaryLines += $blockingGateLines

$summaryPath = Join-Path $resolvedOutput "release-evidence-summary.md"
Set-Content -LiteralPath $summaryPath -Value ($summaryLines -join [Environment]::NewLine) -Encoding UTF8

$manifest
