param(
    [string]$EnvironmentFile = "artifacts\release\production-mvp.env",
    [string]$ProductionProvisioningPacketRoot = "artifacts\release\production-provisioning-packet-working",
    [string]$OutputDirectory = "artifacts\release\production-mvp-closeout",
    [string]$ProductionMvpReadinessReportPath = "artifacts\release\production-mvp-readiness-report.json",
    [string]$ReleaseEvidencePacketDirectory = "artifacts\release\production-mvp-release-evidence-packet",
    [string]$OutstandingWorkReportPath = "artifacts\release\production-mvp-outstanding-work-report.json",
    [string]$OutstandingWorkMarkdownPath = "artifacts\release\production-mvp-outstanding-work-report.md",
    [string]$OutstandingWorkValidationReportPath = "artifacts\release\production-mvp-outstanding-work-validation-report.json",
    [string]$NextActionPacketDirectory = "artifacts\release\production-mvp-next-action-packet",
    [string]$NextActionPacketValidationReportPath = "artifacts\release\production-mvp-next-action-packet-validation-report.json",
    [string]$PreMvpReportPath = "artifacts\release\pre-mvp-internal-verification-report.json",
    [string]$StagingReadinessReportPath = "artifacts\release\staging-readiness-report.json",
    [string]$CanaryMvpReadinessReportPath = "artifacts\release\canary-mvp-readiness-report.json",
    [string]$ProvisioningPacketReportPath = "artifacts\release\production-provisioning-packet-validation-report.json",
    [string]$ProvisioningPacketManifestPath = "artifacts\release\production-provisioning-packet-working\production-provisioning-packet.manifest.json",
    [int]$EndpointTimeoutSeconds = 10,
    [switch]$UseExistingReadinessReport,
    [switch]$UseGeneratedFixture,
    [switch]$UseGeneratedFailureFixture,
    [switch]$SkipFailureHandoff,
    [switch]$Force,
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

function Get-Sha256Hex {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return ""
    }

    return (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant()
}

function Get-Sha256Text {
    param([string]$Text)

    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
        return [System.BitConverter]::ToString($sha256.ComputeHash($bytes)).Replace("-", "").ToLowerInvariant()
    }
    finally {
        $sha256.Dispose()
    }
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

function Invoke-Tool {
    param(
        [string]$FilePath,
        [string[]]$Arguments,
        [string]$LogPath
    )

    $started = [DateTimeOffset]::UtcNow
    $output = & powershell -NoProfile -ExecutionPolicy Bypass -File $FilePath @Arguments 2>&1
    $exitCode = $LASTEXITCODE
    if ($null -eq $exitCode) {
        $exitCode = 0
    }
    $ended = [DateTimeOffset]::UtcNow

    $parent = Split-Path -Parent $LogPath
    if ($parent) {
        New-Item -ItemType Directory -Force -Path $parent | Out-Null
    }

    $command = "powershell -NoProfile -ExecutionPolicy Bypass -File `"$FilePath`" $($Arguments -join ' ')"
    $lines = @(
        "started_utc=$($started.ToString("yyyy-MM-ddTHH:mm:ssZ"))",
        "ended_utc=$($ended.ToString("yyyy-MM-ddTHH:mm:ssZ"))",
        "exit_code=$exitCode",
        "command=$command",
        ""
    ) + @($output | ForEach-Object { [string]$_ })
    Set-Content -LiteralPath $LogPath -Value ($lines -join [Environment]::NewLine) -Encoding UTF8

    return [pscustomobject][ordered]@{
        command = $command
        started_utc = $started.ToString("yyyy-MM-ddTHH:mm:ssZ")
        ended_utc = $ended.ToString("yyyy-MM-ddTHH:mm:ssZ")
        exit_code = [int]$exitCode
        passed = ($exitCode -eq 0)
        log_path = [System.IO.Path]::GetFullPath($LogPath)
        log_sha256 = Get-Sha256Hex -Path $LogPath
    }
}

function Get-ToolReportState {
    param(
        [string]$Id,
        [string]$Path
    )

    $file = New-FileRecord -Id $Id -Path $Path
    $json = Read-JsonFile -Path $file.path
    return [pscustomobject][ordered]@{
        id = $Id
        file = $file
        passed = $(if ($null -ne $json -and $json.PSObject.Properties["passed"]) { [bool]$json.passed } else { $false })
        ready = $(if ($null -ne $json -and $json.PSObject.Properties["ready"]) { [bool]$json.ready } else { $false })
        reviewable_for_signoff = $(if ($null -ne $json -and $json.PSObject.Properties["checks"]) {
            $check = @($json.checks) | Where-Object { $_.id -eq "reviewable_for_signoff" } | Select-Object -First 1
            $null -ne $check -and [bool]$check.passed
        } else { $false })
        failed_check_count = $(if ($null -ne $json -and $json.PSObject.Properties["failed_check_count"]) { [int]$json.failed_check_count } else { $null })
        failed_gate_count = $(if ($null -ne $json -and $json.PSObject.Properties["failed_gate_count"]) { [int]$json.failed_gate_count } else { $null })
    }
}

function New-PassingGate {
    param([string]$Id)

    return [pscustomobject][ordered]@{
        id = $Id
        passed = $true
        missing = @()
    }
}

function New-GeneratedFixture {
    param(
        [string]$FixtureRoot,
        [bool]$Passing = $true
    )

    New-Item -ItemType Directory -Force -Path $FixtureRoot | Out-Null
    $createdUtc = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
    $operatorSecret = "synthetic-operator-key-must-not-appear"
    $failedCount = $(if ($Passing) { 0 } else { 1 })

    $preMvpPath = Join-Path $FixtureRoot "pre-mvp-internal-verification-report.json"
    Write-JsonFile -Path $preMvpPath -Value ([pscustomobject][ordered]@{
        schema = "archrealms.passport.pre_mvp_internal_verification.v1"
        created_utc = $createdUtc
        pre_mvp_testing_is_mvp = $false
        citizen_facing_token_release = $false
        fake_balance_migration_blocked = $true
        passed = $Passing
        failed_check_count = $failedCount
        failed_requirement_count = $failedCount
        checks = @()
        requirements = @()
    })

    $stagingPath = Join-Path $FixtureRoot "staging-readiness-report.json"
    Write-JsonFile -Path $stagingPath -Value ([pscustomobject][ordered]@{
        schema = "archrealms.passport.staging_readiness.v1"
        created_utc = $createdUtc
        ready = $Passing
        staging_is_mvp = $false
        synthetic_fixtures_used = $false
        canary_or_production_release_approved = $Passing
        failed_gate_count = $failedCount
        gates = @(
            $(if ($Passing) { New-PassingGate -Id "pre_mvp_internal_verification" } else { [pscustomobject][ordered]@{ id = "pre_mvp_internal_verification"; passed = $false; missing = @("synthetic failure fixture pre-MVP evidence missing") } })
            New-PassingGate -Id "staging_package_artifact"
            New-PassingGate -Id "staging_lane_endpoints"
            New-PassingGate -Id "staging_ledger_telemetry"
            New-PassingGate -Id "staging_operational_drill"
            New-PassingGate -Id "staging_rollback_drill"
            New-PassingGate -Id "staging_promotion_approvals"
            New-PassingGate -Id "no_staging_to_production_migration"
        )
    })

    $canaryPath = Join-Path $FixtureRoot "canary-mvp-readiness-report.json"
    Write-JsonFile -Path $canaryPath -Value ([pscustomobject][ordered]@{
        schema = "archrealms.passport.canary_mvp_readiness.v1"
        created_utc = $createdUtc
        lane = "canary-mvp"
        canary_is_mvp = $true
        ready = $Passing
        failed_gate_count = $failedCount
        synthetic_fixtures_used = $false
        production_release_approved = $Passing
        gates = @(
            $(if ($Passing) { New-PassingGate -Id "staging_readiness" } else { [pscustomobject][ordered]@{ id = "staging_readiness"; passed = $false; missing = @("synthetic failure fixture staging readiness missing") } })
            New-PassingGate -Id "canary_package_artifact"
            New-PassingGate -Id "canary_policy_limits"
            New-PassingGate -Id "canary_incident_review"
            New-PassingGate -Id "canary_balance_reconciliation"
            New-PassingGate -Id "canary_service_delivery_reconciliation"
            New-PassingGate -Id "canary_support_readiness"
            New-PassingGate -Id "canary_production_approvals"
        )
    })

    $provisioningPath = Join-Path $FixtureRoot "production-provisioning-packet-validation-report.json"
    Write-JsonFile -Path $provisioningPath -Value ([pscustomobject][ordered]@{
        schema = "archrealms.passport.production_provisioning_packet_validation.v1"
        created_utc = $createdUtc
        packet_root = "synthetic-production-provisioning-packet"
        passed = $Passing
        failed_check_count = $failedCount
        checks = $(if ($Passing) {
            @()
        } else {
            @(
                [pscustomobject][ordered]@{
                    id = "package_signing_provisioning"
                    description = "Synthetic failure fixture package-signing provisioning."
                    passed = $false
                    failures = @("synthetic failure fixture package-signing evidence missing")
                    evidence = $null
                }
            )
        })
    })

    $provisioningManifestPath = Join-Path $FixtureRoot "production-provisioning-packet.manifest.json"
    Write-JsonFile -Path $provisioningManifestPath -Value ([pscustomobject][ordered]@{
        schema = "archrealms.passport.production_provisioning_packet_scaffold.v1"
        created_utc = $createdUtc
        source_commit = "synthetic-fixture"
        copied_items = @()
    })

    $readinessPath = Join-Path $FixtureRoot "production-mvp-readiness-report.json"
    Write-JsonFile -Path $readinessPath -Value ([pscustomobject][ordered]@{
        schema = "archrealms.passport.production_mvp_readiness.v1"
        created_utc = $createdUtc
        repo_root = $repoRoot
        lane = "production-mvp"
        environment_file_loaded = $true
        environment_file_variable_count = 1
        environment_file_variables = @("ARCHREALMS_PASSPORT_HOSTED_OPERATOR_API_KEY")
        endpoint_timeout_seconds = 10
        ready = $Passing
        failed_gate_count = $failedCount
        package_signing_certificate = [pscustomobject][ordered]@{
            source = "synthetic-fixture"
            expected_publisher = "CN=The Archrealms"
            timestamp_url = "https://timestamp.example.invalid"
            minimum_days_valid = 30
            disallow_self_signed = $false
            certificate = [pscustomobject][ordered]@{
                subject = "CN=The Archrealms"
                issuer = "CN=Example Issuing CA"
                thumbprint = "0123456789ABCDEF0123456789ABCDEF01234567"
                not_before_utc = "2026-01-01T00:00:00Z"
                not_after_utc = "2027-01-01T00:00:00Z"
                days_remaining = 200
                has_private_key = $true
                code_signing_eku_present = $true
                enhanced_key_usage_oids = @("1.3.6.1.5.5.7.3.3")
                self_signed = $false
            }
            warnings = @()
            failures = @()
            passed = $true
        }
        gates = @(
            $(if ($Passing) { New-PassingGate -Id "pre_mvp_internal_verification" } else { [pscustomobject][ordered]@{ id = "pre_mvp_internal_verification"; passed = $false; missing = @("synthetic failure fixture pre-MVP evidence missing") } })
            New-PassingGate -Id "staging_readiness"
            New-PassingGate -Id "canary_mvp_readiness"
            New-PassingGate -Id "package_signing"
            New-PassingGate -Id "release_lane_endpoints"
            New-PassingGate -Id "hosted_runtime_status"
            New-PassingGate -Id "hosted_ai_runtime_probe"
            New-PassingGate -Id "hosted_operator_gate"
            New-PassingGate -Id "hosted_operator_status"
            New-PassingGate -Id "managed_storage_backups"
            New-PassingGate -Id "managed_storage_status"
            New-PassingGate -Id "managed_signing_key_custody"
            New-PassingGate -Id "managed_signing_endpoint_probe"
            New-PassingGate -Id "issuer_capacity_genesis_secrets"
            New-PassingGate -Id "open_weight_ai_runtime"
            New-PassingGate -Id "telemetry_incident_response"
            New-PassingGate -Id "production_release_approvals"
        )
    })

    $envPath = Join-Path $FixtureRoot "production-mvp.env"
    Set-Content -LiteralPath $envPath -Encoding UTF8 -Value @(
        "ARCHREALMS_PASSPORT_PRE_MVP_VERIFICATION_REPORT_PATH=$preMvpPath",
        "ARCHREALMS_PASSPORT_PRE_MVP_VERIFICATION_REPORT_SHA256=$(Get-Sha256Hex -Path $preMvpPath)",
        "ARCHREALMS_PASSPORT_STAGING_READINESS_REPORT_PATH=$stagingPath",
        "ARCHREALMS_PASSPORT_STAGING_READINESS_REPORT_SHA256=$(Get-Sha256Hex -Path $stagingPath)",
        "ARCHREALMS_PASSPORT_CANARY_MVP_READINESS_REPORT_PATH=$canaryPath",
        "ARCHREALMS_PASSPORT_CANARY_MVP_READINESS_REPORT_SHA256=$(Get-Sha256Hex -Path $canaryPath)",
        "ARCHREALMS_PASSPORT_HOSTED_OPERATOR_API_KEY=$operatorSecret",
        "ARCHREALMS_PASSPORT_HOSTED_OPERATOR_API_KEY_SHA256=$(Get-Sha256Text -Text $operatorSecret)"
    )

    return [pscustomobject][ordered]@{
        environment_file = $envPath
        pre_mvp_report_path = $preMvpPath
        staging_readiness_report_path = $stagingPath
        canary_mvp_readiness_report_path = $canaryPath
        readiness_report_path = $readinessPath
        provisioning_report_path = $provisioningPath
        provisioning_manifest_path = $provisioningManifestPath
        release_evidence_packet_directory = (Join-Path $FixtureRoot "release-evidence-packet")
        closeout_output_directory = (Join-Path $FixtureRoot "closeout")
    }
}

if ($UseGeneratedFixture) {
    if ($UseGeneratedFailureFixture) {
        throw "-UseGeneratedFixture and -UseGeneratedFailureFixture are mutually exclusive."
    }

    $fixtureRoot = Resolve-RepoPath -Path "artifacts\release\production-mvp-closeout-fixture"
    $fixture = New-GeneratedFixture -FixtureRoot $fixtureRoot -Passing $true
    $EnvironmentFile = $fixture.environment_file
    $OutputDirectory = $fixture.closeout_output_directory
    $ProductionMvpReadinessReportPath = $fixture.readiness_report_path
    $ReleaseEvidencePacketDirectory = $fixture.release_evidence_packet_directory
    $PreMvpReportPath = $fixture.pre_mvp_report_path
    $StagingReadinessReportPath = $fixture.staging_readiness_report_path
    $CanaryMvpReadinessReportPath = $fixture.canary_mvp_readiness_report_path
    $ProvisioningPacketReportPath = $fixture.provisioning_report_path
    $ProvisioningPacketManifestPath = $fixture.provisioning_manifest_path
    $UseExistingReadinessReport = $true
    $Force = $true
}

if ($UseGeneratedFailureFixture) {
    $fixtureRoot = Resolve-RepoPath -Path "artifacts\release\production-mvp-closeout-failure-fixture"
    $fixture = New-GeneratedFixture -FixtureRoot $fixtureRoot -Passing $false
    $EnvironmentFile = $fixture.environment_file
    $OutputDirectory = $fixture.closeout_output_directory
    $ProductionMvpReadinessReportPath = $fixture.readiness_report_path
    $ReleaseEvidencePacketDirectory = $fixture.release_evidence_packet_directory
    $OutstandingWorkReportPath = Join-Path $fixtureRoot "production-mvp-outstanding-work-report.json"
    $OutstandingWorkMarkdownPath = Join-Path $fixtureRoot "production-mvp-outstanding-work-report.md"
    $OutstandingWorkValidationReportPath = Join-Path $fixtureRoot "production-mvp-outstanding-work-validation-report.json"
    $NextActionPacketDirectory = Join-Path $fixtureRoot "production-mvp-next-action-packet"
    $NextActionPacketValidationReportPath = Join-Path $fixtureRoot "production-mvp-next-action-packet-validation-report.json"
    $PreMvpReportPath = $fixture.pre_mvp_report_path
    $StagingReadinessReportPath = $fixture.staging_readiness_report_path
    $CanaryMvpReadinessReportPath = $fixture.canary_mvp_readiness_report_path
    $ProvisioningPacketReportPath = $fixture.provisioning_report_path
    $ProvisioningPacketManifestPath = $fixture.provisioning_manifest_path
    $UseExistingReadinessReport = $true
    $Force = $true
}

$resolvedOutput = Resolve-RepoPath -Path $OutputDirectory
if ((Test-Path -LiteralPath $resolvedOutput -PathType Container) -and -not $Force) {
    $existing = @(Get-ChildItem -LiteralPath $resolvedOutput -Force)
    if ($existing.Count -gt 0) {
        throw "Refusing to overwrite existing Production MVP closeout directory without -Force: $resolvedOutput"
    }
}

New-Item -ItemType Directory -Force -Path $resolvedOutput | Out-Null

$resolvedEnvironmentFile = Resolve-RepoPath -Path $EnvironmentFile
$resolvedProvisioningRoot = Resolve-RepoPath -Path $ProductionProvisioningPacketRoot
$resolvedReadinessReportPath = Resolve-RepoPath -Path $ProductionMvpReadinessReportPath
$resolvedReleaseEvidenceDirectory = Resolve-RepoPath -Path $ReleaseEvidencePacketDirectory
$resolvedOutstandingWorkReportPath = Resolve-RepoPath -Path $OutstandingWorkReportPath
$resolvedOutstandingWorkMarkdownPath = Resolve-RepoPath -Path $OutstandingWorkMarkdownPath
$resolvedOutstandingWorkValidationReportPath = Resolve-RepoPath -Path $OutstandingWorkValidationReportPath
$resolvedNextActionPacketDirectory = Resolve-RepoPath -Path $NextActionPacketDirectory
$resolvedNextActionPacketValidationReportPath = Resolve-RepoPath -Path $NextActionPacketValidationReportPath
$resolvedPreMvpReportPath = Resolve-RepoPath -Path $PreMvpReportPath
$resolvedStagingReadinessReportPath = Resolve-RepoPath -Path $StagingReadinessReportPath
$resolvedCanaryMvpReadinessReportPath = Resolve-RepoPath -Path $CanaryMvpReadinessReportPath
$resolvedProvisioningReportPath = Resolve-RepoPath -Path $ProvisioningPacketReportPath
$resolvedProvisioningManifestPath = Resolve-RepoPath -Path $ProvisioningPacketManifestPath

$failures = @()
$provisioningValidation = $null
$provisioningState = $null

$generatedFixtureMode = [bool]($UseGeneratedFixture -or $UseGeneratedFailureFixture)

if ($generatedFixtureMode) {
    $provisioningValidation = [pscustomobject][ordered]@{
        command = "synthetic fixture provisioning validation"
        started_utc = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
        ended_utc = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
        exit_code = 0
        passed = $true
        log_path = ""
        log_sha256 = ""
    }
    $provisioningState = Get-ToolReportState -Id "production_provisioning_packet_validation" -Path $resolvedProvisioningReportPath
    if (-not [bool]$provisioningState.passed) {
        $failures += "Filled production provisioning packet did not pass -RequireNoPlaceholders validation."
    }
}
else {
    $provisioningValidation = Invoke-Tool `
        -FilePath (Join-Path $scriptRoot "Test-PassportProductionProvisioningPacket.ps1") `
        -Arguments @("-PacketRoot", $resolvedProvisioningRoot, "-RequireNoPlaceholders", "-NoFail", "-OutputPath", $resolvedProvisioningReportPath) `
        -LogPath (Join-Path $resolvedOutput "production-provisioning-packet-validation.log")
    $provisioningState = Get-ToolReportState -Id "production_provisioning_packet_validation" -Path $resolvedProvisioningReportPath
    if ($provisioningValidation.exit_code -ne 0 -or -not [bool]$provisioningState.passed) {
        $failures += "Filled production provisioning packet did not pass -RequireNoPlaceholders validation."
    }
}

$readinessRun = $null
if ($UseExistingReadinessReport) {
    $readinessRun = [pscustomobject][ordered]@{
        command = "existing ProductionMvp readiness report supplied"
        started_utc = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
        ended_utc = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
        exit_code = 0
        passed = $true
        log_path = ""
        log_sha256 = ""
    }
}
else {
    $readinessRun = Invoke-Tool `
        -FilePath (Join-Path $scriptRoot "Test-PassportProductionMvpReadiness.ps1") `
        -Arguments @("-EnvironmentFile", $resolvedEnvironmentFile, "-EndpointTimeoutSeconds", ([string]$EndpointTimeoutSeconds), "-OutputPath", $resolvedReadinessReportPath, "-NoFail") `
        -LogPath (Join-Path $resolvedOutput "production-mvp-readiness-run.log")
}

$readinessState = Get-ToolReportState -Id "production_mvp_readiness" -Path $resolvedReadinessReportPath
if ($readinessRun.exit_code -ne 0 -or -not [bool]$readinessState.ready) {
    $failures += "Production MVP readiness did not pass."
}

$releaseGeneration = Invoke-Tool `
    -FilePath (Join-Path $scriptRoot "New-PassportProductionMvpReleaseEvidencePacket.ps1") `
    -Arguments @(
        "-EnvironmentFile", $resolvedEnvironmentFile,
        "-OutputDirectory", $resolvedReleaseEvidenceDirectory,
        "-PreMvpReportPath", $resolvedPreMvpReportPath,
        "-ReadinessReportPath", $resolvedReadinessReportPath,
        "-StagingReadinessReportPath", $resolvedStagingReadinessReportPath,
        "-CanaryMvpReadinessReportPath", $resolvedCanaryMvpReadinessReportPath,
        "-ProvisioningPacketReportPath", $resolvedProvisioningReportPath,
        "-ProvisioningPacketManifestPath", $resolvedProvisioningManifestPath,
        "-Force"
    ) `
    -LogPath (Join-Path $resolvedOutput "production-mvp-release-evidence-generation.log")
if ($releaseGeneration.exit_code -ne 0) {
    $failures += "Production MVP release evidence packet generation failed."
}

$releaseValidationPath = Join-Path $resolvedOutput "production-mvp-release-evidence-validation-report.json"
$releaseValidation = Invoke-Tool `
    -FilePath (Join-Path $scriptRoot "Test-PassportProductionMvpReleaseEvidencePacket.ps1") `
    -Arguments @(
        "-EvidencePacketRoot", $resolvedReleaseEvidenceDirectory,
        "-PreMvpReportPath", $resolvedPreMvpReportPath,
        "-ReadinessReportPath", $resolvedReadinessReportPath,
        "-StagingReadinessReportPath", $resolvedStagingReadinessReportPath,
        "-CanaryMvpReadinessReportPath", $resolvedCanaryMvpReadinessReportPath,
        "-ProvisioningPacketReportPath", $resolvedProvisioningReportPath,
        "-ProvisioningPacketManifestPath", $resolvedProvisioningManifestPath,
        "-EnvironmentFile", $resolvedEnvironmentFile,
        "-RequireReady",
        "-NoFail",
        "-OutputPath", $releaseValidationPath
    ) `
    -LogPath (Join-Path $resolvedOutput "production-mvp-release-evidence-validation.log")
$releaseValidationState = Get-ToolReportState -Id "production_mvp_release_evidence_validation" -Path $releaseValidationPath
if ($releaseValidation.exit_code -ne 0 -or -not [bool]$releaseValidationState.passed) {
    $failures += "Production MVP release evidence packet did not pass -RequireReady validation."
}

$readinessReportSha256 = Get-Sha256Hex -Path $resolvedReadinessReportPath
$releaseManifestPath = Join-Path $resolvedReleaseEvidenceDirectory "release-evidence.manifest.json"
$releaseSummaryPath = Join-Path $resolvedReleaseEvidenceDirectory "release-evidence-summary.md"
$closeoutPassed = ($failures.Count -eq 0)
$manifest = [pscustomobject][ordered]@{
    schema = "archrealms.passport.production_mvp_closeout.v1"
    created_utc = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
    lane = "production-mvp"
    app_commit = Get-CurrentCommit
    generated_fixture = [bool]$UseGeneratedFixture
    used_existing_readiness_report = [bool]$UseExistingReadinessReport
    passed = $closeoutPassed
    failures = @($failures)
    output_directory = $resolvedOutput
    environment_file = New-FileRecord -Id "production_mvp_environment_file" -Path $resolvedEnvironmentFile
    production_provisioning_packet_root = $resolvedProvisioningRoot
    production_mvp_readiness_report = New-FileRecord -Id "production_mvp_readiness_report" -Path $resolvedReadinessReportPath
    production_mvp_readiness_report_sha256 = $readinessReportSha256
    release_evidence_packet_directory = $resolvedReleaseEvidenceDirectory
    release_evidence_manifest = New-FileRecord -Id "production_mvp_release_evidence_manifest" -Path $releaseManifestPath
    release_evidence_summary = New-FileRecord -Id "production_mvp_release_evidence_summary" -Path $releaseSummaryPath
    input_reports = [pscustomobject][ordered]@{
        pre_mvp_internal_verification = New-FileRecord -Id "pre_mvp_internal_verification_report" -Path $resolvedPreMvpReportPath
        staging_readiness = New-FileRecord -Id "staging_readiness_report" -Path $resolvedStagingReadinessReportPath
        canary_mvp_readiness = New-FileRecord -Id "canary_mvp_readiness_report" -Path $resolvedCanaryMvpReadinessReportPath
        production_provisioning_packet_validation = New-FileRecord -Id "production_provisioning_packet_validation_report" -Path $resolvedProvisioningReportPath
        production_provisioning_packet_manifest = New-FileRecord -Id "production_provisioning_packet_manifest" -Path $resolvedProvisioningManifestPath
    }
    steps = [pscustomobject][ordered]@{
        production_provisioning_packet_validation = [pscustomobject][ordered]@{
            command = $provisioningValidation
            report = $provisioningState
        }
        production_mvp_readiness = [pscustomobject][ordered]@{
            command = $readinessRun
            report = $readinessState
        }
        release_evidence_generation = $releaseGeneration
        release_evidence_validation = [pscustomobject][ordered]@{
            command = $releaseValidation
            report = $releaseValidationState
        }
    }
    downstream_artifacts = [pscustomobject][ordered]@{
        production_mvp_readiness_report_path = $resolvedReadinessReportPath
        production_mvp_readiness_report_sha256 = $readinessReportSha256
        release_evidence_manifest_path = (Resolve-RepoPath -Path $releaseManifestPath)
        release_evidence_manifest_sha256 = Get-Sha256Hex -Path $releaseManifestPath
        release_evidence_summary_path = (Resolve-RepoPath -Path $releaseSummaryPath)
        release_evidence_summary_sha256 = Get-Sha256Hex -Path $releaseSummaryPath
    }
}

$manifestPath = Join-Path $resolvedOutput "production-mvp-closeout.manifest.json"
Write-JsonFile -Path $manifestPath -Value $manifest
$manifestRecord = New-FileRecord -Id "production_mvp_closeout_manifest" -Path $manifestPath

$failureHandoff = $null
if (-not $closeoutPassed -and -not $SkipFailureHandoff) {
    $outstandingGeneration = Invoke-Tool `
        -FilePath (Join-Path $scriptRoot "New-PassportProductionMvpOutstandingWorkReport.ps1") `
        -Arguments @(
            "-CloseoutManifestPath", $manifestPath,
            "-ProductionMvpReadinessReportPath", $resolvedReadinessReportPath,
            "-ProductionProvisioningPacketReportPath", $resolvedProvisioningReportPath,
            "-ReleaseEvidenceValidationReportPath", $releaseValidationPath,
            "-OutputPath", $resolvedOutstandingWorkReportPath,
            "-MarkdownOutputPath", $resolvedOutstandingWorkMarkdownPath,
            "-NoFail"
        ) `
        -LogPath (Join-Path $resolvedOutput "production-mvp-outstanding-work-generation.log")

    $outstandingValidation = Invoke-Tool `
        -FilePath (Join-Path $scriptRoot "Test-PassportProductionMvpOutstandingWorkReport.ps1") `
        -Arguments @(
            "-ReportPath", $resolvedOutstandingWorkReportPath,
            "-MarkdownPath", $resolvedOutstandingWorkMarkdownPath,
            "-OutputPath", $resolvedOutstandingWorkValidationReportPath,
            "-NoFail"
        ) `
        -LogPath (Join-Path $resolvedOutput "production-mvp-outstanding-work-validation.log")
    $outstandingValidationState = Get-ToolReportState -Id "production_mvp_outstanding_work_validation" -Path $resolvedOutstandingWorkValidationReportPath

    $nextActionValidation = Invoke-Tool `
        -FilePath (Join-Path $scriptRoot "Test-PassportProductionMvpNextActionPacket.ps1") `
        -Arguments @(
            "-Generate",
            "-PacketRoot", $resolvedNextActionPacketDirectory,
            "-OutstandingWorkReportPath", $resolvedOutstandingWorkReportPath,
            "-OutputPath", $resolvedNextActionPacketValidationReportPath,
            "-NoFail"
        ) `
        -LogPath (Join-Path $resolvedOutput "production-mvp-next-action-packet-validation.log")
    $nextActionValidationState = Get-ToolReportState -Id "production_mvp_next_action_packet_validation" -Path $resolvedNextActionPacketValidationReportPath

    $nextActionManifestPath = Join-Path $resolvedNextActionPacketDirectory "production-mvp-next-action-packet.manifest.json"
    $nextActionPlanPath = Join-Path $resolvedNextActionPacketDirectory "next-action-plan.json"
    $nextActionMarkdownPath = Join-Path $resolvedNextActionPacketDirectory "next-action-plan.md"
    $nextActionCommandsPath = Join-Path $resolvedNextActionPacketDirectory "operator-commands.ps1"

    $failureHandoffPassed = (
        $outstandingGeneration.exit_code -eq 0 -and
        $outstandingValidation.exit_code -eq 0 -and
        [bool]$outstandingValidationState.passed -and
        $nextActionValidation.exit_code -eq 0 -and
        [bool]$nextActionValidationState.passed
    )

    $failureHandoff = [pscustomobject][ordered]@{
        generated = $true
        passed = $failureHandoffPassed
        outstanding_work_generation = $outstandingGeneration
        outstanding_work_validation = [pscustomobject][ordered]@{
            command = $outstandingValidation
            report = $outstandingValidationState
        }
        next_action_packet_validation = [pscustomobject][ordered]@{
            command = $nextActionValidation
            report = $nextActionValidationState
        }
        outstanding_work = [pscustomobject][ordered]@{
            report = New-FileRecord -Id "production_mvp_outstanding_work_report" -Path $resolvedOutstandingWorkReportPath
            markdown = New-FileRecord -Id "production_mvp_outstanding_work_markdown" -Path $resolvedOutstandingWorkMarkdownPath
            validation_report = New-FileRecord -Id "production_mvp_outstanding_work_validation_report" -Path $resolvedOutstandingWorkValidationReportPath
        }
        next_action_packet = [pscustomobject][ordered]@{
            directory = $resolvedNextActionPacketDirectory
            validation_report = New-FileRecord -Id "production_mvp_next_action_packet_validation_report" -Path $resolvedNextActionPacketValidationReportPath
            manifest = New-FileRecord -Id "production_mvp_next_action_packet_manifest" -Path $nextActionManifestPath
            plan_json = New-FileRecord -Id "production_mvp_next_action_plan_json" -Path $nextActionPlanPath
            plan_markdown = New-FileRecord -Id "production_mvp_next_action_plan_markdown" -Path $nextActionMarkdownPath
            operator_commands = New-FileRecord -Id "production_mvp_next_action_operator_commands" -Path $nextActionCommandsPath
        }
    }
}
elseif (-not $closeoutPassed) {
    $failureHandoff = [pscustomobject][ordered]@{
        generated = $false
        passed = $false
        skipped = $true
        reason = "Failure handoff generation was skipped by -SkipFailureHandoff."
    }
}

$result = [pscustomobject][ordered]@{
    schema = "archrealms.passport.production_mvp_closeout_result.v1"
    passed = $closeoutPassed
    failures = @($failures)
    manifest_path = $manifestRecord.path
    manifest_sha256 = $manifestRecord.sha256
    production_mvp_readiness_report_path = $resolvedReadinessReportPath
    production_mvp_readiness_report_sha256 = $readinessReportSha256
    release_evidence_manifest_path = (Resolve-RepoPath -Path $releaseManifestPath)
    release_evidence_manifest_sha256 = Get-Sha256Hex -Path $releaseManifestPath
    failure_handoff = $failureHandoff
    next_step = $(if ($closeoutPassed) { "Run Publish-PassportWindowsMsix.ps1 -Lane ProductionMvp -EnvironmentFile <production-env> without bypass, then validate and hand off the signed ProductionMvp package." } elseif ($null -ne $failureHandoff -and [bool]$failureHandoff.passed) { "Review the generated failure_handoff outstanding-work report and next-action packet, resolve the listed blockers, then rerun Production MVP closeout." } else { "Resolve the listed failures, inspect failure handoff logs if present, then rerun Production MVP closeout." })
}

$json = $result | ConvertTo-Json -Depth 8
$json

$failureFixtureHandoffFailed = (
    [bool]$UseGeneratedFailureFixture -and
    ($null -eq $failureHandoff -or -not [bool]$failureHandoff.passed)
)
if ($failureFixtureHandoffFailed) {
    exit 1
}

if (-not $closeoutPassed -and -not $NoFail) {
    exit 1
}
