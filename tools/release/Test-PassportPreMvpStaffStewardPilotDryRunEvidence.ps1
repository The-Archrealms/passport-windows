param(
    [string]$ReportPath,
    [string]$OutputPath = "artifacts\release\pre-mvp-staff-steward-pilot-dry-run-validation-report.json",
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

function Read-JsonFile {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $null
    }

    return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
}

function Read-ObjectString {
    param(
        [object]$Object,
        [string]$Name
    )

    if ($null -eq $Object -or -not $Object.PSObject.Properties[$Name]) {
        return ""
    }

    return ([string]$Object.$Name).Trim()
}

function Read-ObjectBool {
    param(
        [object]$Object,
        [string]$Name
    )

    if ($null -eq $Object -or -not $Object.PSObject.Properties[$Name]) {
        return $false
    }

    return [bool]$Object.$Name
}

function Get-Sha256Hex {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return ""
    }

    return (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant()
}

function Test-NotPlaceholder {
    param(
        [string]$Name,
        [string]$Value
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return "$Name is required"
    }

    if ($Value -match '<[^>]+>' -or $Value -match '^\s*set value\s*$') {
        return "$Name contains a placeholder value"
    }

    return ""
}

function Test-FileRecord {
    param(
        [object]$Record,
        [string]$Description
    )

    $failures = @()
    $required = Read-ObjectBool -Object $Record -Name "required"
    $exists = Read-ObjectBool -Object $Record -Name "exists"
    $path = Read-ObjectString -Object $Record -Name "path"
    $sha256 = Read-ObjectString -Object $Record -Name "sha256"

    if (-not $required -and [string]::IsNullOrWhiteSpace($path)) {
        return $failures
    }

    if ($required -or $exists) {
        if ([string]::IsNullOrWhiteSpace($path) -or -not (Test-Path -LiteralPath $path -PathType Leaf)) {
            $failures += "$Description file is missing: $path"
            return $failures
        }

        if ($sha256 -notmatch '^[0-9a-f]{64}$') {
            $failures += "$Description SHA-256 is missing or invalid"
            return $failures
        }

        $actual = Get-Sha256Hex -Path $path
        if ($actual -ne $sha256) {
            $failures += "$Description SHA-256 mismatch: expected $sha256 actual $actual"
        }
    }

    return $failures
}

function New-Check {
    param(
        [string]$Id,
        [string[]]$Failures,
        [object]$Evidence = $null
    )

    $cleanFailures = @($Failures | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    return [pscustomobject][ordered]@{
        id = $Id
        passed = ($cleanFailures.Count -eq 0)
        failures = $cleanFailures
        evidence = $Evidence
    }
}

function Invoke-Tool {
    param(
        [string]$FilePath,
        [string[]]$Arguments
    )

    $output = & powershell -NoProfile -ExecutionPolicy Bypass -File $FilePath @Arguments 2>&1
    return [pscustomobject][ordered]@{
        command = ("powershell -NoProfile -ExecutionPolicy Bypass -File `"{0}`" {1}" -f $FilePath, ($Arguments -join " "))
        exit_code = $LASTEXITCODE
        output = @($output | ForEach-Object { [string]$_ })
    }
}

$generationResult = $null
$generatedFixture = [bool]($UseGeneratedFixture -or [string]::IsNullOrWhiteSpace($ReportPath))
if ($generatedFixture) {
    $fixtureRoot = "artifacts\release\pre-mvp-staff-steward-pilot-dry-run-validation"
    $generatorPath = Join-Path $scriptRoot "New-PassportPreMvpStaffStewardPilotDryRunEvidence.ps1"
    $generationResult = Invoke-Tool -FilePath $generatorPath -Arguments @(
        "-OutputDirectory", (Resolve-RepoPath -Path $fixtureRoot),
        "-PilotId", "pre-mvp-staff-steward-pilot-dry-run-validation",
        "-PilotOwner", "pre-mvp-validation-owner",
        "-Force"
    )

    if ($generationResult.exit_code -ne 0) {
        throw "Staff/steward pilot dry-run fixture generation failed with exit code $($generationResult.exit_code): $($generationResult.output -join [Environment]::NewLine)"
    }

    $ReportPath = Join-Path (Resolve-RepoPath -Path $fixtureRoot) "staff-steward-pilot-dry-run-evidence.json"
}

$resolvedReportPath = Resolve-RepoPath -Path $ReportPath
$resolvedOutput = Resolve-RepoPath -Path $OutputPath
$report = Read-JsonFile -Path $resolvedReportPath
$checks = @()

$schemaFailures = @()
if ($null -eq $report) {
    $schemaFailures += "staff/steward pilot dry-run report is missing or unreadable: $resolvedReportPath"
}
else {
    if ((Read-ObjectString -Object $report -Name "schema") -ne "archrealms.passport.pre_mvp_staff_steward_pilot_dry_run.v1") {
        $schemaFailures += "staff/steward pilot dry-run report has unexpected schema"
    }

    if ((Read-ObjectString -Object $report -Name "lane") -ne "internal-verification") {
        $schemaFailures += "staff/steward pilot dry-run report must use internal-verification lane"
    }

    foreach ($field in @("created_utc", "app_commit", "pilot_id", "pilot_owner", "policy_version", "packet_reference_guidance")) {
        $failure = Test-NotPlaceholder -Name "staff/steward pilot dry-run $field" -Value (Read-ObjectString -Object $report -Name $field)
        if ($failure) { $schemaFailures += $failure }
    }
}

$checks += New-Check -Id "dry_run_schema" -Failures $schemaFailures -Evidence @{ path = $resolvedReportPath }

$boundaryFailures = @()
if ($null -ne $report) {
    if (-not (Read-ObjectBool -Object $report -Name "not_a_passing_staff_steward_pilot_report")) {
        $boundaryFailures += "dry-run report must explicitly state it is not a passing staff/steward pilot report"
    }

    if (-not (Read-ObjectBool -Object $report -Name "controlled_staff_steward_signoff_required")) {
        $boundaryFailures += "dry-run report must require controlled staff/steward signoff"
    }

    if (-not (Read-ObjectBool -Object $report -Name "no_citizen_production_tokens_used")) {
        $boundaryFailures += "dry-run report must confirm no citizen production tokens were used"
    }

    if (-not (Read-ObjectBool -Object $report -Name "no_production_records_created")) {
        $boundaryFailures += "dry-run report must confirm no production records were created"
    }

    if ((Read-ObjectString -Object $report -Name "packet_reference_guidance") -notmatch "supporting evidence_reference") {
        $boundaryFailures += "dry-run report must tell operators it is only supporting evidence_reference material"
    }
}

$checks += New-Check -Id "dry_run_boundary_flags" -Failures $boundaryFailures

$scenarioFailures = @()
$requiredScenarios = @(
    "identity_create_or_recover",
    "device_authorization",
    "wallet_key_binding",
    "recovery_revocation",
    "storage_contribution_opt_in_revocation",
    "ledger_export_verification",
    "hosted_ai_privacy",
    "production_blocker_review"
)
if ($null -ne $report) {
    $scenarioMap = @{}
    foreach ($scenario in @($report.scenario_evidence)) {
        $id = Read-ObjectString -Object $scenario -Name "id"
        if ($id) {
            $scenarioMap[$id] = $scenario
        }
    }

    foreach ($scenarioId in $requiredScenarios) {
        if (-not $scenarioMap.ContainsKey($scenarioId)) {
            $scenarioFailures += "dry-run report missing required scenario evidence: $scenarioId"
            continue
        }

        $operatorAction = Read-ObjectString -Object $scenarioMap[$scenarioId] -Name "operator_action_required"
        if ([string]::IsNullOrWhiteSpace($operatorAction)) {
            $scenarioFailures += "dry-run scenario must include operator_action_required: $scenarioId"
        }

        $coveredBy = @($scenarioMap[$scenarioId].covered_by)
        if ($coveredBy.Count -lt 2) {
            $scenarioFailures += "dry-run scenario must include at least two coverage references: $scenarioId"
        }
    }
}

$checks += New-Check -Id "dry_run_scenario_coverage" -Failures $scenarioFailures

$fileFailures = @()
if ($null -ne $report) {
    foreach ($record in @($report.evidence_files)) {
        $fileFailures += Test-FileRecord -Record $record -Description "dry-run evidence file $((Read-ObjectString -Object $record -Name "id"))"
    }
}

$checks += New-Check -Id "dry_run_file_hashes" -Failures $fileFailures

$commandFailures = @()
if ($null -ne $report) {
    foreach ($command in @($report.command_results)) {
        if ($command.result -and -not [bool]$command.result.passed) {
            $commandFailures += "dry-run command failed: $($command.id)"
        }

        if ($command.result -and $command.result.log_path) {
            if (-not (Test-Path -LiteralPath $command.result.log_path -PathType Leaf)) {
                $commandFailures += "dry-run command log missing: $($command.result.log_path)"
            }
            elseif ($command.result.log_sha256 -ne (Get-Sha256Hex -Path $command.result.log_path)) {
                $commandFailures += "dry-run command log SHA-256 mismatch: $($command.id)"
            }
        }
    }
}

$checks += New-Check -Id "dry_run_command_results" -Failures $commandFailures

$failed = @($checks | Where-Object { -not $_.passed })
$validation = [pscustomobject][ordered]@{
    schema = "archrealms.passport.pre_mvp_staff_steward_pilot_dry_run_validation.v1"
    created_utc = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
    report_path = $resolvedReportPath
    generated_fixture = $generatedFixture
    generation = $generationResult
    passed = ($failed.Count -eq 0)
    failed_check_count = $failed.Count
    checks = $checks
}

$json = $validation | ConvertTo-Json -Depth 12
if (-not [string]::IsNullOrWhiteSpace($resolvedOutput)) {
    $parent = Split-Path -Parent $resolvedOutput
    if ($parent) {
        New-Item -ItemType Directory -Force -Path $parent | Out-Null
    }

    Set-Content -LiteralPath $resolvedOutput -Value $json -Encoding UTF8
}

$json

if ($failed.Count -gt 0 -and -not $NoFail) {
    exit 1
}
