param(
    [string]$ReportPath,
    [string]$ReportSha256,
    [string]$OutputPath = "artifacts\release\pre-mvp-staff-steward-pilot-report-validation-report.json",
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

function Read-ObjectInt {
    param(
        [object]$Object,
        [string]$Name
    )

    if ($null -eq $Object -or -not $Object.PSObject.Properties[$Name]) {
        return 0
    }

    try {
        return [int]$Object.$Name
    }
    catch {
        return 0
    }
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

function Invoke-Tool {
    param(
        [string]$FilePath,
        [string[]]$Arguments
    )

    $output = @()
    $exitCode = 0
    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        $output = & powershell -NoProfile -ExecutionPolicy Bypass -File $FilePath @Arguments 2>&1
        $exitCode = $LASTEXITCODE
    }
    catch {
        $exitCode = 1
        $output = @($_.Exception.Message)
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }

    return [pscustomobject][ordered]@{
        command = ("powershell -NoProfile -ExecutionPolicy Bypass -File `"{0}`" {1}" -f $FilePath, ($Arguments -join " "))
        exit_code = $exitCode
        output = @($output | ForEach-Object { [string]$_ })
    }
}

function New-GeneratedFixture {
    $fixtureRoot = Resolve-RepoPath -Path "artifacts\release\pre-mvp-staff-steward-pilot-report-validation"
    $packetRoot = Join-Path $fixtureRoot "pilot-evidence"
    $reportPath = Join-Path $fixtureRoot "pre-mvp-staff-steward-pilot-report.json"
    New-Item -ItemType Directory -Force -Path $packetRoot | Out-Null

    $createdUtc = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
    $pilotId = "pre-mvp-staff-steward-pilot-report-validation"
    $pilotOwner = "pre-mvp-validation-owner"
    $policyVersion = "token-ready-passport-mvp-pre-mvp-internal-verification-v1"
    $sourceEvidenceRoot = Join-Path $fixtureRoot "source-evidence"
    $artifactManifestPath = Join-Path $sourceEvidenceRoot "internal-verification-artifact-manifest.json"
    $productionReadinessReportPath = Join-Path $sourceEvidenceRoot "production-mvp-readiness-report.json"

    Write-JsonFile -Path $artifactManifestPath -Value ([pscustomobject][ordered]@{
        schema = "archrealms.passport.release_manifest.fixture.v1"
        lane = "internal-verification"
        app_commit = Get-CurrentCommit
    })

    Write-JsonFile -Path $productionReadinessReportPath -Value ([pscustomobject][ordered]@{
        schema = "archrealms.passport.production_mvp_readiness.fixture.v1"
        ready = $false
        gates = @(
            [pscustomobject][ordered]@{
                id = "controlled-production-readiness-values-still-required"
                passed = $false
            }
        )
    })

    $scenarios = @(
        "identity_create_or_recover",
        "device_authorization",
        "wallet_key_binding",
        "recovery_revocation",
        "storage_contribution_opt_in_revocation",
        "ledger_export_verification",
        "hosted_ai_privacy",
        "production_blocker_review"
    )

    $session = [pscustomobject][ordered]@{
        schema = "archrealms.passport.pre_mvp_staff_steward_pilot_session.v1"
        created_utc = $createdUtc
        lane = "internal-verification"
        pilot_id = $pilotId
        pilot_owner = $pilotOwner
        policy_version = $policyVersion
        app_commit = Get-CurrentCommit
        artifact_manifest_path = $artifactManifestPath
        artifact_manifest_sha256 = Get-Sha256Hex -Path $artifactManifestPath
        session_started_utc = $createdUtc
        session_ended_utc = $createdUtc
        pilot_participant_count = 1
        crown_owned_device_ids = @("crown-owned-device-validation-001")
        synthetic_or_fake_balances_used = $true
        no_citizen_production_tokens_used = $true
        no_production_records_created = $true
        scenarios = @($scenarios | ForEach-Object {
            [pscustomobject][ordered]@{
                id = $_
                passed = $true
                evidence_reference = "controlled-evidence://$pilotId/$($_)"
            }
        })
    }

    $signoff = [pscustomobject][ordered]@{
        schema = "archrealms.passport.pre_mvp_staff_steward_participant_signoff.v1"
        created_utc = $createdUtc
        lane = "internal-verification"
        pilot_id = $pilotId
        pilot_owner = $pilotOwner
        policy_version = $policyVersion
        signoffs = @(
            [pscustomobject][ordered]@{
                participant_id = "staff-steward-validation-001"
                participant_role = "staff-steward-validator"
                staff_or_steward_participant = $true
                crown_owned_device_used = $true
                no_citizen_production_tokens_used = $true
                no_production_records_created = $true
                signed_utc = $createdUtc
                signoff_reference = "controlled-signoff://$pilotId/staff-steward-validation-001"
            }
        )
    }

    $issueReview = [pscustomobject][ordered]@{
        schema = "archrealms.passport.pre_mvp_staff_steward_pilot_issue_review.v1"
        created_utc = $createdUtc
        lane = "internal-verification"
        pilot_id = $pilotId
        pilot_owner = $pilotOwner
        policy_version = $policyVersion
        production_readiness_report_path = $productionReadinessReportPath
        production_readiness_report_sha256 = Get-Sha256Hex -Path $productionReadinessReportPath
        production_readiness_blockers_reviewed = $true
        pilot_signoff_signed = $true
        no_pilot_blocking_defects = $true
        no_production_records_created = $true
        pilot_blockers = @()
        remaining_production_blockers = @("controlled-production-readiness-values-still-required")
        review_signoff_reference = "controlled-review://$pilotId/issue-review"
    }

    Write-JsonFile -Path (Join-Path $packetRoot "pilot-session-record.json") -Value $session
    Write-JsonFile -Path (Join-Path $packetRoot "participant-signoff.json") -Value $signoff
    Write-JsonFile -Path (Join-Path $packetRoot "pilot-issue-review.json") -Value $issueReview

    $generatorPath = Join-Path $scriptRoot "New-PassportPreMvpStaffStewardPilotReport.ps1"
    $generation = Invoke-Tool -FilePath $generatorPath -Arguments @(
        "-OutputPath", $reportPath,
        "-PilotId", $pilotId,
        "-PilotOwner", $pilotOwner,
        "-ParticipantCount", "1",
        "-EvidencePacketPath", $packetRoot,
        "-ConfirmCompleted",
        "-ConfirmStaffOrStewardParticipants",
        "-ConfirmCrownOwnedDevices",
        "-ConfirmNoCitizenProductionTokens",
        "-ConfirmRecoveryRevocationValidated",
        "-ConfirmStorageContributionValidated",
        "-ConfirmLedgerExportValidated",
        "-ConfirmHostedAiPrivacyValidated",
        "-ConfirmProductionReadinessBlockersReviewed",
        "-ConfirmPilotSignoffSigned",
        "-ConfirmNoProductionRecordsCreated"
    )

    if ($generation.exit_code -ne 0) {
        throw "Generated staff/steward pilot report fixture failed with exit code $($generation.exit_code): $($generation.output -join [Environment]::NewLine)"
    }

    return [pscustomobject][ordered]@{
        report_path = $reportPath
        packet_root = $packetRoot
        generation = $generation
    }
}

$generationResult = $null
$generatedFixture = [bool]($UseGeneratedFixture -or [string]::IsNullOrWhiteSpace($ReportPath))
if ($generatedFixture) {
    $generationResult = New-GeneratedFixture
    $ReportPath = $generationResult.report_path
    $ReportSha256 = Get-Sha256Hex -Path $ReportPath
}

$resolvedReportPath = Resolve-RepoPath -Path $ReportPath
$resolvedOutput = Resolve-RepoPath -Path $OutputPath
$report = Read-JsonFile -Path $resolvedReportPath
$checks = @()

$fileFailures = @()
$actualReportSha256 = Get-Sha256Hex -Path $resolvedReportPath
if ([string]::IsNullOrWhiteSpace($resolvedReportPath) -or -not (Test-Path -LiteralPath $resolvedReportPath -PathType Leaf)) {
    $fileFailures += "staff/steward pilot report is missing: $resolvedReportPath"
}
elseif ([string]::IsNullOrWhiteSpace($actualReportSha256)) {
    $fileFailures += "staff/steward pilot report SHA-256 could not be computed"
}

if (-not [string]::IsNullOrWhiteSpace($ReportSha256)) {
    if ($ReportSha256 -notmatch '^[0-9a-fA-F]{64}$') {
        $fileFailures += "staff/steward pilot report expected SHA-256 must be a SHA-256 hex string"
    }
    elseif ($actualReportSha256 -and -not [string]::Equals($actualReportSha256, $ReportSha256, [System.StringComparison]::OrdinalIgnoreCase)) {
        $fileFailures += "staff/steward pilot report SHA-256 mismatch: expected $ReportSha256 actual $actualReportSha256"
    }
}

if ($null -eq $report) {
    $fileFailures += "staff/steward pilot report is not valid JSON"
}

$checks += New-Check -Id "report_file" -Failures $fileFailures -Evidence @{
    path = $resolvedReportPath
    expected_sha256 = $ReportSha256
    actual_sha256 = $actualReportSha256
}

$schemaFailures = @()
if ($null -ne $report) {
    if ((Read-ObjectString -Object $report -Name "schema") -ne "archrealms.passport.pre_mvp_staff_steward_pilot.v1") {
        $schemaFailures += "staff/steward pilot report has unexpected schema"
    }

    if ((Read-ObjectString -Object $report -Name "lane") -ne "internal-verification") {
        $schemaFailures += "staff/steward pilot report must use internal-verification lane"
    }

    foreach ($field in @("created_utc", "staff_steward_pilot_id", "pilot_owner", "policy_version")) {
        $failure = Test-NotPlaceholder -Name "staff/steward pilot report $field" -Value (Read-ObjectString -Object $report -Name $field)
        if ($failure) { $schemaFailures += $failure }
    }
}

$checks += New-Check -Id "report_schema" -Failures $schemaFailures

$confirmationFailures = @()
if ($null -ne $report) {
    if ((Read-ObjectInt -Object $report -Name "pilot_participant_count") -lt 1) {
        $confirmationFailures += "staff/steward pilot report must include at least one participant"
    }

    foreach ($field in @(
        "completed",
        "staff_or_steward_participants_confirmed",
        "crown_owned_devices_used",
        "no_citizen_production_tokens_used",
        "recovery_revocation_validated",
        "storage_contribution_validated",
        "ledger_export_validated",
        "hosted_ai_privacy_validated",
        "production_readiness_blockers_reviewed",
        "pilot_signoff_signed",
        "no_production_records_created"
    )) {
        if (-not (Read-ObjectBool -Object $report -Name $field)) {
            $confirmationFailures += "staff/steward pilot report must confirm $field"
        }
    }
}

$checks += New-Check -Id "report_confirmations" -Failures $confirmationFailures

$referenceFailures = @()
if ($null -ne $report) {
    $references = @($report.evidence_references | ForEach-Object { ([string]$_).Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($references.Count -lt 3) {
        $referenceFailures += "staff/steward pilot report must include at least three evidence references"
    }

    for ($index = 0; $index -lt $references.Count; $index++) {
        $failure = Test-NotPlaceholder -Name "staff/steward pilot report evidence reference $($index + 1)" -Value $references[$index]
        if ($failure) { $referenceFailures += $failure }
    }
}

$checks += New-Check -Id "report_evidence_references" -Failures $referenceFailures

$evidenceFileFailures = @()
$evidenceFilePaths = @()
if ($null -ne $report) {
    $evidenceFiles = @($report.evidence_files)
    if ($evidenceFiles.Count -lt 3) {
        $evidenceFileFailures += "staff/steward pilot report must include at least three hashed evidence files"
    }

    for ($index = 0; $index -lt $evidenceFiles.Count; $index++) {
        $file = $evidenceFiles[$index]
        $id = Read-ObjectString -Object $file -Name "id"
        $path = Read-ObjectString -Object $file -Name "path"
        $sha256 = Read-ObjectString -Object $file -Name "sha256"

        foreach ($failure in @(
            Test-NotPlaceholder -Name "staff/steward pilot report evidence file $($index + 1) id" -Value $id
            Test-NotPlaceholder -Name "staff/steward pilot report evidence file $($index + 1) path" -Value $path
            Test-NotPlaceholder -Name "staff/steward pilot report evidence file $($index + 1) sha256" -Value $sha256
        )) {
            if ($failure) { $evidenceFileFailures += $failure }
        }

        if (-not [string]::IsNullOrWhiteSpace($sha256) -and $sha256 -notmatch '^[0-9a-fA-F]{64}$') {
            $evidenceFileFailures += "staff/steward pilot report evidence file $($index + 1) SHA-256 must be a SHA-256 hex string"
        }

        if (-not [string]::IsNullOrWhiteSpace($path)) {
            $resolvedEvidencePath = Resolve-RepoPath -Path $path
            if (-not (Test-Path -LiteralPath $resolvedEvidencePath -PathType Leaf)) {
                $evidenceFileFailures += "staff/steward pilot report evidence file $($index + 1) was not found: $resolvedEvidencePath"
            }
            else {
                $evidenceFilePaths += [System.IO.Path]::GetFullPath($resolvedEvidencePath)
                $actualEvidenceHash = Get-Sha256Hex -Path $resolvedEvidencePath
                if ($sha256 -match '^[0-9a-fA-F]{64}$' -and -not [string]::Equals($actualEvidenceHash, $sha256, [System.StringComparison]::OrdinalIgnoreCase)) {
                    $evidenceFileFailures += "staff/steward pilot report evidence file $($index + 1) SHA-256 mismatch"
                }
            }
        }
    }
}

$checks += New-Check -Id "report_evidence_files" -Failures $evidenceFileFailures

$packetFailures = @()
$packetValidation = $null
if ($evidenceFilePaths.Count -ge 3) {
    $packetRoots = @($evidenceFilePaths | ForEach-Object { Split-Path -Parent $_ } | Select-Object -Unique)
    if ($packetRoots.Count -ne 1) {
        $packetFailures += "staff/steward pilot report evidence files must come from one pilot evidence packet folder"
    }
    else {
        $packetValidatorPath = Join-Path $scriptRoot "Test-PassportPreMvpStaffStewardPilotEvidencePacket.ps1"
        if (-not (Test-Path -LiteralPath $packetValidatorPath -PathType Leaf)) {
            $packetFailures += "staff/steward pilot evidence packet validator was not found: $packetValidatorPath"
        }
        else {
            $packetValidationOutputDirectory = Split-Path -Parent $resolvedOutput
            if ([string]::IsNullOrWhiteSpace($packetValidationOutputDirectory)) {
                $packetValidationOutputDirectory = Split-Path -Parent $resolvedReportPath
            }

            if ([string]::IsNullOrWhiteSpace($packetValidationOutputDirectory)) {
                $packetValidationOutputDirectory = $repoRoot
            }

            $packetValidationOutputPath = Join-Path $packetValidationOutputDirectory "pre-mvp-staff-steward-pilot-report-packet-validation-report.json"
            $packetValidationResult = Invoke-Tool -FilePath $packetValidatorPath -Arguments @("-PacketRoot", $packetRoots[0], "-RequireNoPlaceholders", "-NoFail", "-OutputPath", $packetValidationOutputPath)
            if ($packetValidationResult.exit_code -ne 0) {
                $packetFailures += "staff/steward pilot evidence packet validator failed with exit code $($packetValidationResult.exit_code)"
            }

            try {
                $packetValidation = Read-JsonFile -Path $packetValidationOutputPath
                if ($null -eq $packetValidation) {
                    $packetValidation = ($packetValidationResult.output -join [Environment]::NewLine) | ConvertFrom-Json
                }

                if (-not [bool]$packetValidation.passed) {
                    $validationFailures = @($packetValidation.checks | ForEach-Object { @($_.failures) } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
                    if ($validationFailures.Count -eq 0) {
                        $validationFailures += "packet validation did not pass"
                    }

                    foreach ($failure in $validationFailures) {
                        $packetFailures += "staff/steward pilot evidence packet validation: $failure"
                    }
                }
            }
            catch {
                $packetFailures += "staff/steward pilot evidence packet validator returned unreadable JSON: $($_.Exception.Message)"
            }
        }
    }
}
elseif ($null -ne $report) {
    $packetFailures += "staff/steward pilot report does not include enough existing evidence files for packet validation"
}

$checks += New-Check -Id "report_packet_validation" -Failures $packetFailures -Evidence $packetValidation

$failed = @($checks | Where-Object { -not $_.passed })
$validation = [pscustomobject][ordered]@{
    schema = "archrealms.passport.pre_mvp_staff_steward_pilot_report_validation.v1"
    created_utc = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
    report_path = $resolvedReportPath
    report_sha256 = $actualReportSha256
    generated_fixture = $generatedFixture
    generation = $generationResult
    passed = ($failed.Count -eq 0)
    failed_check_count = $failed.Count
    checks = $checks
}

$json = $validation | ConvertTo-Json -Depth 14
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
