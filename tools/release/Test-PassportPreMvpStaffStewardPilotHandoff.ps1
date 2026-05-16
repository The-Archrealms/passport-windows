param(
    [string]$HandoffRoot,
    [string]$OutputPath = "artifacts\release\pre-mvp-staff-steward-pilot-handoff-validation-report.json",
    [switch]$UseGeneratedFixture,
    [switch]$AllowFilledEvidencePacket,
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
    $path = Read-ObjectString -Object $Record -Name "path"
    $sha256 = Read-ObjectString -Object $Record -Name "sha256"
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

    return $failures
}

function Test-ExistingFileRecord {
    param(
        [object]$Record,
        [string]$Description
    )

    $failures = @()
    $path = Read-ObjectString -Object $Record -Name "path"
    if ([string]::IsNullOrWhiteSpace($path) -or -not (Test-Path -LiteralPath $path -PathType Leaf)) {
        $failures += "$Description file is missing: $path"
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
$generatedFixture = [bool]($UseGeneratedFixture -or [string]::IsNullOrWhiteSpace($HandoffRoot))
if ($generatedFixture) {
    $HandoffRoot = "artifacts\release\pre-mvp-staff-steward-pilot-handoff-validation"
    $generatorPath = Join-Path $scriptRoot "New-PassportPreMvpStaffStewardPilotHandoff.ps1"
    $generationResult = Invoke-Tool -FilePath $generatorPath -Arguments @(
        "-OutputDirectory", (Resolve-RepoPath -Path $HandoffRoot),
        "-PilotId", "pre-mvp-staff-steward-pilot-validation",
        "-PilotOwner", "pre-mvp-validation-owner",
        "-ParticipantCount", "1",
        "-Force"
    )

    if ($generationResult.exit_code -ne 0) {
        throw "Staff/steward pilot handoff fixture generation failed with exit code $($generationResult.exit_code): $($generationResult.output -join [Environment]::NewLine)"
    }
}

$resolvedHandoffRoot = Resolve-RepoPath -Path $HandoffRoot
$resolvedOutput = Resolve-RepoPath -Path $OutputPath
$manifestPath = Join-Path $resolvedHandoffRoot "pilot-handoff.manifest.json"
$manifest = Read-JsonFile -Path $manifestPath

$checks = @()

$manifestFailures = @()
if ($null -eq $manifest) {
    $manifestFailures += "pilot handoff manifest is missing or unreadable: $manifestPath"
}
else {
    if ((Read-ObjectString -Object $manifest -Name "schema") -ne "archrealms.passport.pre_mvp_staff_steward_pilot_handoff.v1") {
        $manifestFailures += "pilot handoff manifest has unexpected schema"
    }

    if ((Read-ObjectString -Object $manifest -Name "lane") -ne "internal-verification") {
        $manifestFailures += "pilot handoff manifest must use internal-verification lane"
    }

    foreach ($field in @("created_utc", "app_commit", "pilot_id", "pilot_owner", "policy_version", "output_directory", "evidence_packet_directory")) {
        $failure = Test-NotPlaceholder -Name "pilot handoff manifest $field" -Value (Read-ObjectString -Object $manifest -Name $field)
        if ($failure) { $manifestFailures += $failure }
    }

    if (-not (Read-ObjectBool -Object $manifest -Name "pilot_report_is_required")) {
        $manifestFailures += "pilot handoff manifest must require a staff/steward pilot report"
    }

    if (Read-ObjectBool -Object $manifest -Name "citizen_facing_token_release_ready") {
        $manifestFailures += "pilot handoff manifest must not mark citizen-facing token release ready"
    }

    if (-not (Read-ObjectBool -Object $manifest -Name "production_records_must_not_be_created")) {
        $manifestFailures += "pilot handoff manifest must prohibit production record creation"
    }
}

$checks += New-Check -Id "pilot_handoff_manifest" -Failures $manifestFailures -Evidence @{ path = $manifestPath }

$fileFailures = @()
if ($null -ne $manifest) {
    foreach ($record in @($manifest.generated_evidence_files)) {
        $description = "generated evidence file $((Read-ObjectString -Object $record -Name "id"))"
        if ($AllowFilledEvidencePacket) {
            $fileFailures += Test-ExistingFileRecord -Record $record -Description $description
        }
        else {
            $fileFailures += Test-FileRecord -Record $record -Description $description
        }
    }

    foreach ($record in @($manifest.handoff_files)) {
        $fileFailures += Test-FileRecord -Record $record -Description "handoff file $((Read-ObjectString -Object $record -Name "id"))"
    }
}

$checks += New-Check -Id "pilot_handoff_file_hashes" -Failures $fileFailures

$validationFailures = @()
if ($null -ne $manifest) {
    $validation = $manifest.validation
    if (-not (Read-ObjectBool -Object $validation -Name "template_validation_passed")) {
        $validationFailures += "pilot evidence template validation must pass"
    }

    if (Read-ObjectBool -Object $validation -Name "require_no_placeholders_preview_passed") {
        $validationFailures += "RequireNoPlaceholders preview must fail before real pilot evidence is filled"
    }

    if (-not (Read-ObjectBool -Object $validation -Name "require_no_placeholders_preview_expected_to_fail")) {
        $validationFailures += "handoff must record that the final preview is expected to fail before real evidence"
    }

    $templateReportPath = Read-ObjectString -Object $validation.template_validation_report -Name "path"
    $templateReport = Read-JsonFile -Path $templateReportPath
    if ($null -eq $templateReport -or -not [bool]$templateReport.passed) {
        $validationFailures += "template validation report must exist and pass: $templateReportPath"
    }

    $previewReportPath = Read-ObjectString -Object $validation.require_no_placeholders_preview_report -Name "path"
    $previewReport = Read-JsonFile -Path $previewReportPath
    if ($null -eq $previewReport) {
        $validationFailures += "RequireNoPlaceholders preview report is missing: $previewReportPath"
    }
    elseif ([bool]$previewReport.passed) {
        $validationFailures += "RequireNoPlaceholders preview report unexpectedly passed"
    }
    elseif ([int]$previewReport.failed_check_count -lt 1) {
        $validationFailures += "RequireNoPlaceholders preview report must include at least one failed check"
    }
}

$checks += New-Check -Id "pilot_handoff_fail_closed_validation" -Failures $validationFailures

$runbookFailures = @()
$runbookPath = Join-Path $resolvedHandoffRoot "operator-runbook.md"
if (-not (Test-Path -LiteralPath $runbookPath -PathType Leaf)) {
    $runbookFailures += "operator runbook is missing: $runbookPath"
}
else {
    $runbookText = Get-Content -LiteralPath $runbookPath -Raw
    foreach ($requiredText in @(
        "Start-PassportPreMvpStaffStewardPilot.ps1",
        "Set-PassportPreMvpStaffStewardPilotEvidencePacket.ps1",
        "pilot-workspace-launch.json",
        "Test-PassportPreMvpStaffStewardPilotEvidencePacket.ps1",
        "New-PassportPreMvpStaffStewardPilotReport.ps1",
        "Test-PassportPreMvpStaffStewardPilotReport.ps1",
        "Test-PassportPreMvpInternalVerification.ps1",
        "must fail",
        "no citizen production ARCH",
        "no citizen production tokens"
    )) {
        if ($runbookText -notmatch [regex]::Escape($requiredText)) {
            $runbookFailures += "operator runbook missing required text: $requiredText"
        }
    }
}

$checks += New-Check -Id "pilot_handoff_operator_runbook" -Failures $runbookFailures -Evidence @{ path = $runbookPath }

$failed = @($checks | Where-Object { -not $_.passed })
$report = [pscustomobject][ordered]@{
    schema = "archrealms.passport.pre_mvp_staff_steward_pilot_handoff_validation.v1"
    created_utc = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
    handoff_root = $resolvedHandoffRoot
    generated_fixture = $generatedFixture
    allow_filled_evidence_packet = [bool]$AllowFilledEvidencePacket
    generation = $generationResult
    passed = ($failed.Count -eq 0)
    failed_check_count = $failed.Count
    checks = $checks
}

$json = $report | ConvertTo-Json -Depth 12
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
