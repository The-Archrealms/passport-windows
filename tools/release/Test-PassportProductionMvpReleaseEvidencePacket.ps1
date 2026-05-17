param(
    [string]$OutputPath = "artifacts\release\production-mvp-release-evidence-packet-validation-report.json",

    [string]$EvidencePacketRoot = "artifacts\release\production-mvp-release-evidence-packet",

    [string]$PreMvpReportPath = "artifacts\release\pre-mvp-internal-verification-report.json",

    [string]$ReadinessReportPath = "artifacts\release\production-mvp-readiness-report.json",

    [string]$StagingReadinessReportPath = "artifacts\release\staging-readiness-report.json",

    [string]$CanaryMvpReadinessReportPath = "artifacts\release\canary-mvp-readiness-report.json",

    [string]$ProvisioningPacketReportPath = "artifacts\release\production-provisioning-packet-validation-report.json",

    [string]$ProvisioningPacketManifestPath = "artifacts\release\production-provisioning-packet-working\production-provisioning-packet.manifest.json",

    [string]$EnvironmentFile = "",

    [switch]$Generate,

    [switch]$UseSyntheticFixtures,

    [switch]$RequireReady,

    [switch]$NoFail
)

$ErrorActionPreference = "Stop"

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $scriptRoot "..\.."))
$syntheticSecret = "synthetic-operator-key-must-not-appear"

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

function Write-JsonFile {
    param(
        [string]$Path,
        [object]$Value
    )

    $parent = Split-Path -Parent $Path
    if ($parent) {
        New-Item -ItemType Directory -Force -Path $parent | Out-Null
    }

    Set-Content -LiteralPath $Path -Value ($Value | ConvertTo-Json -Depth 10) -Encoding UTF8
}

function Read-JsonFile {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $null
    }

    return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
}

function Get-CurrentSourceCommit {
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

function Test-HasProperty {
    param(
        [object]$Object,
        [string]$Name
    )

    return ($null -ne $Object -and $null -ne $Object.PSObject.Properties[$Name])
}

function Get-EvidenceFileById {
    param(
        [object[]]$EvidenceFiles,
        [string]$Id
    )

    return @($EvidenceFiles | Where-Object { [string]$_.id -eq $Id } | Select-Object -First 1)
}

function Test-PathWithinRoot {
    param(
        [string]$Path,
        [string]$Root
    )

    if ([string]::IsNullOrWhiteSpace($Path) -or [string]::IsNullOrWhiteSpace($Root)) {
        return $false
    }

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $fullRoot = [System.IO.Path]::GetFullPath($Root).TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
    return $fullPath.StartsWith($fullRoot, [System.StringComparison]::OrdinalIgnoreCase)
}

function Read-EvidenceFileJson {
    param(
        [object]$EvidenceFile,
        [string]$PacketRoot
    )

    if ($null -eq $EvidenceFile -or -not (Test-HasProperty -Object $EvidenceFile -Name "copied_path")) {
        return $null
    }

    if (-not (Test-PathWithinRoot -Path ([string]$EvidenceFile.copied_path) -Root $PacketRoot)) {
        return $null
    }

    return Read-JsonFile -Path ([string]$EvidenceFile.copied_path)
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

function Invoke-Generator {
    param(
        [string]$PacketRoot,
        [string]$PreMvpPath,
        [string]$ReadinessPath,
        [string]$StagingReadinessPath,
        [string]$CanaryMvpReadinessPath,
        [string]$ProvisioningPath,
        [string]$ProvisioningManifestPath,
        [string]$EnvPath
    )

    $powershell = Get-Command powershell -ErrorAction Stop
    $generator = Resolve-RepoPath -Path "tools\release\New-PassportProductionMvpReleaseEvidencePacket.ps1"
    $args = @(
        "-NoProfile",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        $generator,
        "-Force",
        "-OutputDirectory",
        $PacketRoot,
        "-PreMvpReportPath",
        $PreMvpPath,
        "-ReadinessReportPath",
        $ReadinessPath,
        "-StagingReadinessReportPath",
        $StagingReadinessPath,
        "-CanaryMvpReadinessReportPath",
        $CanaryMvpReadinessPath,
        "-ProvisioningPacketReportPath",
        $ProvisioningPath,
        "-ProvisioningPacketManifestPath",
        $ProvisioningManifestPath
    )

    if (-not [string]::IsNullOrWhiteSpace($EnvPath)) {
        $args += @("-EnvironmentFile", $EnvPath)
    }

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $powershell.Source
    $psi.Arguments = ($args | ForEach-Object { Format-CommandArgument -Argument $_ }) -join " "
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
        command = (($args | ForEach-Object { Format-CommandArgument -Argument $_ }) -join " ")
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

if ($UseSyntheticFixtures) {
    $fixtureRoot = Resolve-RepoPath -Path "artifacts\release\production-mvp-release-evidence-fixture"
    New-Item -ItemType Directory -Force -Path $fixtureRoot | Out-Null

    if (-not $PSBoundParameters.ContainsKey("EvidencePacketRoot")) {
        $EvidencePacketRoot = "artifacts\release\production-mvp-release-evidence-packet-fixture"
    }

    $PreMvpReportPath = Join-Path $fixtureRoot "pre-mvp-internal-verification-report.json"
    $ReadinessReportPath = Join-Path $fixtureRoot "production-mvp-readiness-report.json"
    $StagingReadinessReportPath = Join-Path $fixtureRoot "staging-readiness-report.json"
    $CanaryMvpReadinessReportPath = Join-Path $fixtureRoot "canary-mvp-readiness-report.json"
    $ProvisioningPacketReportPath = Join-Path $fixtureRoot "production-provisioning-packet-validation-report.json"
    $ProvisioningPacketManifestPath = Join-Path $fixtureRoot "production-provisioning-packet.manifest.json"
    $EnvironmentFile = Join-Path $fixtureRoot "production-mvp.env"
    $Generate = $true

    Write-JsonFile -Path $PreMvpReportPath -Value ([pscustomobject][ordered]@{
        schema = "archrealms.passport.pre_mvp_internal_verification.v1"
        created_utc = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
        passed = $true
        fake_balance_migration_blocked = $true
        failed_check_count = 0
        failed_requirement_count = 0
        checks = @()
        requirements = @()
    })

    Write-JsonFile -Path $ReadinessReportPath -Value ([pscustomobject][ordered]@{
        schema = "archrealms.passport.production_mvp_readiness.v1"
        created_utc = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
        ready = $false
        failed_gate_count = 1
        gates = @(
            [pscustomobject][ordered]@{
                id = "pre_mvp_internal_verification"
                passed = $true
                missing = @()
            },
            [pscustomobject][ordered]@{
                id = "staging_readiness"
                passed = $true
                missing = @()
            },
            [pscustomobject][ordered]@{
                id = "canary_mvp_readiness"
                passed = $true
                missing = @()
            },
            [pscustomobject][ordered]@{
                id = "package_signing"
                passed = $true
                missing = @()
            },
            [pscustomobject][ordered]@{
                id = "production_release_approvals"
                passed = $false
                missing = @("ARCHREALMS_PASSPORT_PRODUCTION_RELEASE_APPROVAL_ID")
            }
        )
        package_signing_certificate = [pscustomobject][ordered]@{
            source = "pfx-base64"
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
    })

    Write-JsonFile -Path $StagingReadinessReportPath -Value ([pscustomobject][ordered]@{
        schema = "archrealms.passport.staging_readiness.v1"
        created_utc = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
        ready = $true
        staging_is_mvp = $false
        failed_gate_count = 0
        synthetic_fixtures_used = $false
        canary_or_production_release_approved = $true
        gates = @(
            [pscustomobject][ordered]@{ id = "pre_mvp_internal_verification"; passed = $true; missing = @() },
            [pscustomobject][ordered]@{ id = "staging_package_artifact"; passed = $true; missing = @() },
            [pscustomobject][ordered]@{ id = "staging_lane_endpoints"; passed = $true; missing = @() },
            [pscustomobject][ordered]@{ id = "staging_ledger_telemetry"; passed = $true; missing = @() },
            [pscustomobject][ordered]@{ id = "staging_operational_drill"; passed = $true; missing = @() },
            [pscustomobject][ordered]@{ id = "staging_rollback_drill"; passed = $true; missing = @() },
            [pscustomobject][ordered]@{ id = "staging_promotion_approvals"; passed = $true; missing = @() },
            [pscustomobject][ordered]@{ id = "no_staging_to_production_migration"; passed = $true; missing = @() }
        )
    })

    Write-JsonFile -Path $CanaryMvpReadinessReportPath -Value ([pscustomobject][ordered]@{
        schema = "archrealms.passport.canary_mvp_readiness.v1"
        created_utc = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
        lane = "canary-mvp"
        canary_is_mvp = $true
        ready = $true
        failed_gate_count = 0
        synthetic_fixtures_used = $false
        production_release_approved = $true
        gates = @(
            [pscustomobject][ordered]@{ id = "staging_readiness"; passed = $true; missing = @() },
            [pscustomobject][ordered]@{ id = "canary_package_artifact"; passed = $true; missing = @() },
            [pscustomobject][ordered]@{ id = "canary_policy_limits"; passed = $true; missing = @() },
            [pscustomobject][ordered]@{ id = "canary_incident_review"; passed = $true; missing = @() },
            [pscustomobject][ordered]@{ id = "canary_balance_reconciliation"; passed = $true; missing = @() },
            [pscustomobject][ordered]@{ id = "canary_service_delivery_reconciliation"; passed = $true; missing = @() },
            [pscustomobject][ordered]@{ id = "canary_support_readiness"; passed = $true; missing = @() },
            [pscustomobject][ordered]@{ id = "canary_production_approvals"; passed = $true; missing = @() }
        )
    })

    Write-JsonFile -Path $ProvisioningPacketReportPath -Value ([pscustomobject][ordered]@{
        schema = "archrealms.passport.production_provisioning_packet_validation.v1"
        created_utc = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
        packet_root = ""
        passed = $true
        failed_check_count = 0
        checks = @()
    })

    Write-JsonFile -Path $ProvisioningPacketManifestPath -Value ([pscustomobject][ordered]@{
        schema = "archrealms.passport.production_provisioning_packet_scaffold.v1"
        created_utc = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
        source_commit = "synthetic-fixture"
        copied_items = @()
    })

    Set-Content -LiteralPath $EnvironmentFile -Encoding UTF8 -Value @(
        "ARCHREALMS_PASSPORT_STAGING_READINESS_REPORT_PATH=$StagingReadinessReportPath",
        "ARCHREALMS_PASSPORT_STAGING_READINESS_REPORT_SHA256=$(Get-Sha256Hex -Path $StagingReadinessReportPath)",
        "ARCHREALMS_PASSPORT_CANARY_MVP_READINESS_REPORT_PATH=$CanaryMvpReadinessReportPath",
        "ARCHREALMS_PASSPORT_CANARY_MVP_READINESS_REPORT_SHA256=$(Get-Sha256Hex -Path $CanaryMvpReadinessReportPath)",
        "ARCHREALMS_PASSPORT_HOSTED_OPERATOR_API_KEY=$syntheticSecret",
        "ARCHREALMS_PASSPORT_HOSTED_OPERATOR_API_KEY_SHA256=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
        "PASSPORT_WINDOWS_PRODUCTION_MVP_API_BASE_URL=https://passport.example.invalid"
    )
}

$resolvedPacketRoot = Resolve-RepoPath -Path $EvidencePacketRoot
$resolvedPreMvpReport = Resolve-RepoPath -Path $PreMvpReportPath
$resolvedReadinessReport = Resolve-RepoPath -Path $ReadinessReportPath
$resolvedStagingReadinessReport = Resolve-RepoPath -Path $StagingReadinessReportPath
$resolvedCanaryMvpReadinessReport = Resolve-RepoPath -Path $CanaryMvpReadinessReportPath
$resolvedProvisioningPacketReport = Resolve-RepoPath -Path $ProvisioningPacketReportPath
$resolvedProvisioningPacketManifest = Resolve-RepoPath -Path $ProvisioningPacketManifestPath
$resolvedEnvironmentFile = Resolve-RepoPath -Path $EnvironmentFile

$generatorResult = $null
if ($Generate) {
    $generatorResult = Invoke-Generator `
        -PacketRoot $resolvedPacketRoot `
        -PreMvpPath $resolvedPreMvpReport `
        -ReadinessPath $resolvedReadinessReport `
        -StagingReadinessPath $resolvedStagingReadinessReport `
        -CanaryMvpReadinessPath $resolvedCanaryMvpReadinessReport `
        -ProvisioningPath $resolvedProvisioningPacketReport `
        -ProvisioningManifestPath $resolvedProvisioningPacketManifest `
        -EnvPath $resolvedEnvironmentFile
}

$manifestPath = Join-Path $resolvedPacketRoot "release-evidence.manifest.json"
$summaryPath = Join-Path $resolvedPacketRoot "release-evidence-summary.md"
$checks = @()

if ($generatorResult) {
    $checks += Add-Check -Id "generator_exit_code" -Condition ($generatorResult.exit_code -eq 0) -Failure "release evidence generator exited with code $($generatorResult.exit_code)" -Evidence $generatorResult
}

$checks += Add-Check -Id "manifest_exists" -Condition (Test-Path -LiteralPath $manifestPath -PathType Leaf) -Failure "release evidence manifest was not found: $manifestPath"
$checks += Add-Check -Id "summary_exists" -Condition (Test-Path -LiteralPath $summaryPath -PathType Leaf) -Failure "release evidence summary was not found: $summaryPath"

$manifest = $null
$summaryText = ""
try {
    if (Test-Path -LiteralPath $manifestPath -PathType Leaf) {
        $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    }
}
catch {
    $checks += New-Check -Id "manifest_parse" -Passed $false -Failures @("release evidence manifest could not be parsed: $($_.Exception.Message)")
}

if (Test-Path -LiteralPath $summaryPath -PathType Leaf) {
    $summaryText = Get-Content -LiteralPath $summaryPath -Raw
}

if ($null -ne $manifest) {
    $checks += Add-Check -Id "schema" -Condition ($manifest.schema -eq "archrealms.passport.production_mvp_release_evidence_packet.v1") -Failure "unexpected release evidence schema"
    $checks += Add-Check -Id "source_commit" -Condition (-not [string]::IsNullOrWhiteSpace($manifest.source_commit)) -Failure "source_commit is missing"
    $currentSourceCommit = Get-CurrentSourceCommit
    $checks += Add-Check -Id "source_commit_freshness" -Condition (-not [string]::IsNullOrWhiteSpace($currentSourceCommit) -and [string]$manifest.source_commit -eq $currentSourceCommit) -Failure "release evidence source_commit does not match current app commit" -Evidence ([pscustomobject][ordered]@{
        manifest_source_commit = [string]$manifest.source_commit
        current_source_commit = $currentSourceCommit
    })
    $checks += Add-Check -Id "secrets_excluded" -Condition ($manifest.secrets_included -eq $false) -Failure "release evidence packet must set secrets_included=false"
    $checks += Add-Check -Id "environment_redacted" -Condition ($manifest.environment_file.values_redacted -eq $true) -Failure "environment values must be redacted"
    $checks += Add-Check -Id "pre_mvp_passed" -Condition ($manifest.pre_mvp_internal_verification.passed -eq $true -and $manifest.pre_mvp_internal_verification.failed_check_count -eq 0 -and $manifest.pre_mvp_internal_verification.failed_requirement_count -eq 0) -Failure "pre-MVP evidence did not pass"
    $checks += Add-Check -Id "fake_balance_blocked" -Condition ($manifest.pre_mvp_internal_verification.fake_balance_migration_blocked -eq $true) -Failure "fake-balance migration flag is not true"
    $checks += Add-Check -Id "staging_readiness_summary" -Condition ($null -ne $manifest.staging_readiness) -Failure "staging readiness summary is missing"
    $checks += Add-Check -Id "canary_mvp_readiness_summary" -Condition ($null -ne $manifest.canary_mvp_readiness) -Failure "canary MVP readiness summary is missing"
    $checks += Add-Check -Id "provisioning_packet_passed" -Condition ($manifest.production_provisioning_packet.passed -eq $true -and $manifest.production_provisioning_packet.failed_check_count -eq 0) -Failure "production provisioning packet evidence did not pass"
    $checks += Add-Check -Id "reviewable_for_signoff" -Condition ($manifest.approval_packet_status.reviewable_for_signoff -eq $true) -Failure "release evidence packet is not reviewable for signoff"
    $checks += Add-Check -Id "completion_matches_readiness" -Condition ($manifest.approval_packet_status.complete_for_production_testing -eq $manifest.production_mvp_readiness.ready) -Failure "complete_for_production_testing must match readiness"

    $packageSigningGate = @($manifest.production_mvp_readiness.gates) | Where-Object { $_.id -eq "package_signing" } | Select-Object -First 1
    $packageSigningGatePassed = ($null -ne $packageSigningGate -and $packageSigningGate.passed -eq $true)
    $packageSigningCertificate = $null
    if ($manifest.PSObject.Properties["package_signing_certificate"]) {
        $packageSigningCertificate = $manifest.package_signing_certificate
    }

    if ($packageSigningGatePassed -or $RequireReady) {
        $certificate = $null
        if ($null -ne $packageSigningCertificate) {
            $certificate = $packageSigningCertificate.certificate
        }

        $timestampUrl = ""
        if ($null -ne $packageSigningCertificate) {
            $timestampUrl = [string]$packageSigningCertificate.timestamp_url
        }

        $timestampUri = $null
        $timestampUrlIsAbsolute = (
            -not [string]::IsNullOrWhiteSpace($timestampUrl) -and
            [System.Uri]::TryCreate($timestampUrl.Trim(), [System.UriKind]::Absolute, [ref]$timestampUri) -and
            $timestampUri.Scheme -in @("http", "https")
        )

        $checks += Add-Check -Id "package_signing_certificate_included_when_gate_passes" -Condition ($null -ne $packageSigningCertificate -and $packageSigningCertificate.included -eq $true) -Failure "package signing certificate summary must be included when the package_signing gate passes or readiness is required"
        $checks += Add-Check -Id "package_signing_certificate_passed_when_gate_passes" -Condition ($null -ne $packageSigningCertificate -and $packageSigningCertificate.passed -eq $true) -Failure "package signing certificate summary must show passed=true when the package_signing gate passes or readiness is required"
        $checks += Add-Check -Id "package_signing_certificate_material" -Condition ($null -ne $certificate) -Failure "package signing certificate details are missing"
        $checks += Add-Check -Id "package_signing_certificate_subject" -Condition ($null -ne $certificate -and -not [string]::IsNullOrWhiteSpace([string]$certificate.subject)) -Failure "package signing certificate subject is missing"
        $checks += Add-Check -Id "package_signing_certificate_thumbprint" -Condition ($null -ne $certificate -and [string]$certificate.thumbprint -match '^[0-9A-Fa-f]{40,}$') -Failure "package signing certificate thumbprint is missing or invalid"
        $checks += Add-Check -Id "package_signing_certificate_private_key" -Condition ($null -ne $certificate -and $certificate.has_private_key -eq $true) -Failure "package signing certificate must include private-key availability evidence"
        $checks += Add-Check -Id "package_signing_certificate_code_signing_eku" -Condition ($null -ne $certificate -and $certificate.code_signing_eku_present -eq $true) -Failure "package signing certificate must include Code Signing EKU evidence"
        $checks += Add-Check -Id "package_signing_certificate_timestamp_url" -Condition $timestampUrlIsAbsolute -Failure "package signing certificate timestamp URL must be an absolute HTTP or HTTPS URL"
        $checks += Add-Check -Id "package_signing_expected_publisher" -Condition ($null -ne $packageSigningCertificate -and -not [string]::IsNullOrWhiteSpace([string]$packageSigningCertificate.expected_publisher)) -Failure "package signing expected publisher is missing"
    }

    if ($RequireReady) {
        $checks += Add-Check -Id "readiness_ready" -Condition ($manifest.production_mvp_readiness.ready -eq $true -and $manifest.production_mvp_readiness.failed_gate_count -eq 0) -Failure "production readiness is not ready"
    }

    $evidenceFiles = @($manifest.evidence_files)
    $checks += Add-Check -Id "evidence_file_count" -Condition ($evidenceFiles.Count -ge 4) -Failure "release evidence packet should contain at least four evidence files"
    $requiredEvidenceIds = @(
        "pre_mvp_internal_verification_report",
        "production_mvp_readiness_report",
        "production_provisioning_packet_validation_report",
        "production_provisioning_packet_manifest"
    )
    foreach ($requiredId in $requiredEvidenceIds) {
        $checks += Add-Check -Id ("evidence_file_required_" + $requiredId) -Condition (($evidenceFiles | Where-Object { $_.id -eq $requiredId } | Select-Object -First 1) -ne $null) -Failure "required evidence file is missing: $requiredId"
    }

    $preMvpEvidence = Get-EvidenceFileById -EvidenceFiles $evidenceFiles -Id "pre_mvp_internal_verification_report"
    $preMvpJson = Read-EvidenceFileJson -EvidenceFile $preMvpEvidence -PacketRoot $resolvedPacketRoot
    $preMvpCrossFailures = @()
    if ($null -eq $preMvpJson) {
        $preMvpCrossFailures += "pre-MVP evidence report could not be read from copied evidence"
    }
    else {
        if ([string]$preMvpJson.schema -ne "archrealms.passport.pre_mvp_internal_verification.v1") { $preMvpCrossFailures += "pre-MVP evidence schema is unexpected" }
        if ([bool]$preMvpJson.passed -ne [bool]$manifest.pre_mvp_internal_verification.passed) { $preMvpCrossFailures += "pre-MVP passed value does not match manifest summary" }
        if ([bool]$preMvpJson.fake_balance_migration_blocked -ne [bool]$manifest.pre_mvp_internal_verification.fake_balance_migration_blocked) { $preMvpCrossFailures += "pre-MVP fake_balance_migration_blocked value does not match manifest summary" }
        if ([int]$preMvpJson.failed_check_count -ne [int]$manifest.pre_mvp_internal_verification.failed_check_count) { $preMvpCrossFailures += "pre-MVP failed_check_count does not match manifest summary" }
        if ([int]$preMvpJson.failed_requirement_count -ne [int]$manifest.pre_mvp_internal_verification.failed_requirement_count) { $preMvpCrossFailures += "pre-MVP failed_requirement_count does not match manifest summary" }
    }
    $checks += New-Check -Id "pre_mvp_evidence_matches_manifest" -Passed ($preMvpCrossFailures.Count -eq 0) -Failures $preMvpCrossFailures -Evidence $preMvpEvidence

    $readinessEvidence = Get-EvidenceFileById -EvidenceFiles $evidenceFiles -Id "production_mvp_readiness_report"
    $readinessJson = Read-EvidenceFileJson -EvidenceFile $readinessEvidence -PacketRoot $resolvedPacketRoot
    $readinessCrossFailures = @()
    if ($null -eq $readinessJson) {
        $readinessCrossFailures += "ProductionMvp readiness report could not be read from copied evidence"
    }
    else {
        if ([string]$readinessJson.schema -ne "archrealms.passport.production_mvp_readiness.v1") { $readinessCrossFailures += "ProductionMvp readiness schema is unexpected" }
        if ([bool]$readinessJson.ready -ne [bool]$manifest.production_mvp_readiness.ready) { $readinessCrossFailures += "ProductionMvp readiness ready value does not match manifest summary" }
        if ([int]$readinessJson.failed_gate_count -ne [int]$manifest.production_mvp_readiness.failed_gate_count) { $readinessCrossFailures += "ProductionMvp readiness failed_gate_count does not match manifest summary" }

        $manifestGates = @($manifest.production_mvp_readiness.gates)
        $reportGates = @($readinessJson.gates)
        if ($manifestGates.Count -ne $reportGates.Count) {
            $readinessCrossFailures += "ProductionMvp readiness gate count does not match manifest summary"
        }
        foreach ($manifestGate in $manifestGates) {
            $reportGate = @($reportGates | Where-Object { [string]$_.id -eq [string]$manifestGate.id } | Select-Object -First 1)
            if ($null -eq $reportGate) {
                $readinessCrossFailures += "ProductionMvp readiness gate missing from copied report: $($manifestGate.id)"
                continue
            }

            if ([bool]$reportGate.passed -ne [bool]$manifestGate.passed) {
                $readinessCrossFailures += "ProductionMvp readiness gate passed value mismatch: $($manifestGate.id)"
            }

            if ((@($reportGate.missing) -join "`n") -ne (@($manifestGate.missing) -join "`n")) {
                $readinessCrossFailures += "ProductionMvp readiness gate missing values mismatch: $($manifestGate.id)"
            }
        }
    }
    $checks += New-Check -Id "production_mvp_readiness_evidence_matches_manifest" -Passed ($readinessCrossFailures.Count -eq 0) -Failures $readinessCrossFailures -Evidence $readinessEvidence

    $provisioningEvidence = Get-EvidenceFileById -EvidenceFiles $evidenceFiles -Id "production_provisioning_packet_validation_report"
    $provisioningJson = Read-EvidenceFileJson -EvidenceFile $provisioningEvidence -PacketRoot $resolvedPacketRoot
    $provisioningCrossFailures = @()
    if ($null -eq $provisioningJson) {
        $provisioningCrossFailures += "production provisioning validation report could not be read from copied evidence"
    }
    else {
        if ([string]$provisioningJson.schema -ne "archrealms.passport.production_provisioning_packet_validation.v1") { $provisioningCrossFailures += "production provisioning validation schema is unexpected" }
        if ([bool]$provisioningJson.passed -ne [bool]$manifest.production_provisioning_packet.passed) { $provisioningCrossFailures += "production provisioning passed value does not match manifest summary" }
        if ([int]$provisioningJson.failed_check_count -ne [int]$manifest.production_provisioning_packet.failed_check_count) { $provisioningCrossFailures += "production provisioning failed_check_count does not match manifest summary" }
        if ([string]$provisioningJson.packet_root -ne [string]$manifest.production_provisioning_packet.packet_root) { $provisioningCrossFailures += "production provisioning packet_root does not match manifest summary" }
    }
    $checks += New-Check -Id "production_provisioning_evidence_matches_manifest" -Passed ($provisioningCrossFailures.Count -eq 0) -Failures $provisioningCrossFailures -Evidence $provisioningEvidence

    $stagingGate = @($manifest.production_mvp_readiness.gates) | Where-Object { $_.id -eq "staging_readiness" } | Select-Object -First 1
    $stagingGatePassed = ($null -ne $stagingGate -and $stagingGate.passed -eq $true)
    $stagingEvidenceFile = $evidenceFiles | Where-Object { $_.id -eq "staging_readiness_report" } | Select-Object -First 1
    if ($stagingGatePassed -or $RequireReady) {
        $checks += Add-Check -Id "staging_readiness_report_included_when_gate_passes" -Condition ($null -ne $stagingEvidenceFile -and $manifest.staging_readiness.included -eq $true) -Failure "staging readiness report must be included when staging_readiness passed or readiness is required"
        $checks += Add-Check -Id "staging_readiness_report_ready" -Condition ($manifest.staging_readiness.ready -eq $true -and $manifest.staging_readiness.failed_gate_count -eq 0) -Failure "included staging readiness report is not ready"
        $checks += Add-Check -Id "staging_readiness_report_non_synthetic" -Condition ($manifest.staging_readiness.synthetic_fixtures_used -eq $false) -Failure "release evidence cannot rely on a synthetic staging readiness report"
        $checks += Add-Check -Id "staging_readiness_report_promotion_approved" -Condition ($manifest.staging_readiness.canary_or_production_release_approved -eq $true) -Failure "included staging readiness report does not approve canary or production release promotion"
    }
    if ($manifest.staging_readiness.included -eq $true -or $null -ne $stagingEvidenceFile) {
        $stagingReadinessJson = Read-EvidenceFileJson -EvidenceFile $stagingEvidenceFile -PacketRoot $resolvedPacketRoot
        $stagingCrossFailures = @()
        if ($null -eq $stagingReadinessJson) {
            $stagingCrossFailures += "staging readiness report could not be read from copied evidence"
        }
        else {
            if ([string]$stagingReadinessJson.schema -ne "archrealms.passport.staging_readiness.v1") { $stagingCrossFailures += "staging readiness schema is unexpected" }
            if ([bool]$stagingReadinessJson.ready -ne [bool]$manifest.staging_readiness.ready) { $stagingCrossFailures += "staging readiness ready value does not match manifest summary" }
            if ([bool]$stagingReadinessJson.synthetic_fixtures_used -ne [bool]$manifest.staging_readiness.synthetic_fixtures_used) { $stagingCrossFailures += "staging readiness synthetic_fixtures_used value does not match manifest summary" }
            if ([bool]$stagingReadinessJson.canary_or_production_release_approved -ne [bool]$manifest.staging_readiness.canary_or_production_release_approved) { $stagingCrossFailures += "staging readiness promotion approval value does not match manifest summary" }
            if ([int]$stagingReadinessJson.failed_gate_count -ne [int]$manifest.staging_readiness.failed_gate_count) { $stagingCrossFailures += "staging readiness failed_gate_count does not match manifest summary" }
        }
        $checks += New-Check -Id "staging_readiness_evidence_matches_manifest" -Passed ($stagingCrossFailures.Count -eq 0) -Failures $stagingCrossFailures -Evidence $stagingEvidenceFile
    }

    $canaryGate = @($manifest.production_mvp_readiness.gates) | Where-Object { $_.id -eq "canary_mvp_readiness" } | Select-Object -First 1
    $canaryGatePassed = ($null -ne $canaryGate -and $canaryGate.passed -eq $true)
    $canaryEvidenceFile = $evidenceFiles | Where-Object { $_.id -eq "canary_mvp_readiness_report" } | Select-Object -First 1
    if ($canaryGatePassed -or $RequireReady) {
        $checks += Add-Check -Id "canary_mvp_readiness_report_included_when_gate_passes" -Condition ($null -ne $canaryEvidenceFile -and $manifest.canary_mvp_readiness.included -eq $true) -Failure "canary MVP readiness report must be included when canary_mvp_readiness passed or readiness is required"
        $checks += Add-Check -Id "canary_mvp_readiness_report_ready" -Condition ($manifest.canary_mvp_readiness.ready -eq $true -and $manifest.canary_mvp_readiness.failed_gate_count -eq 0) -Failure "included canary MVP readiness report is not ready"
        $checks += Add-Check -Id "canary_mvp_readiness_report_non_synthetic" -Condition ($manifest.canary_mvp_readiness.synthetic_fixtures_used -eq $false) -Failure "release evidence cannot rely on a synthetic canary MVP readiness report"
        $checks += Add-Check -Id "canary_mvp_readiness_report_production_approved" -Condition ($manifest.canary_mvp_readiness.production_release_approved -eq $true) -Failure "included canary MVP readiness report does not approve ProductionMvp promotion"
    }
    if ($manifest.canary_mvp_readiness.included -eq $true -or $null -ne $canaryEvidenceFile) {
        $canaryMvpReadinessJson = Read-EvidenceFileJson -EvidenceFile $canaryEvidenceFile -PacketRoot $resolvedPacketRoot
        $canaryCrossFailures = @()
        if ($null -eq $canaryMvpReadinessJson) {
            $canaryCrossFailures += "canary MVP readiness report could not be read from copied evidence"
        }
        else {
            if ([string]$canaryMvpReadinessJson.schema -ne "archrealms.passport.canary_mvp_readiness.v1") { $canaryCrossFailures += "canary MVP readiness schema is unexpected" }
            if ([bool]$canaryMvpReadinessJson.ready -ne [bool]$manifest.canary_mvp_readiness.ready) { $canaryCrossFailures += "canary MVP readiness ready value does not match manifest summary" }
            if ([bool]$canaryMvpReadinessJson.synthetic_fixtures_used -ne [bool]$manifest.canary_mvp_readiness.synthetic_fixtures_used) { $canaryCrossFailures += "canary MVP readiness synthetic_fixtures_used value does not match manifest summary" }
            if ([bool]$canaryMvpReadinessJson.production_release_approved -ne [bool]$manifest.canary_mvp_readiness.production_release_approved) { $canaryCrossFailures += "canary MVP readiness production approval value does not match manifest summary" }
            if ([int]$canaryMvpReadinessJson.failed_gate_count -ne [int]$manifest.canary_mvp_readiness.failed_gate_count) { $canaryCrossFailures += "canary MVP readiness failed_gate_count does not match manifest summary" }
        }
        $checks += New-Check -Id "canary_mvp_readiness_evidence_matches_manifest" -Passed ($canaryCrossFailures.Count -eq 0) -Failures $canaryCrossFailures -Evidence $canaryEvidenceFile
    }

    foreach ($file in $evidenceFiles) {
        $fileFailures = @()
        if ($file.exists -ne $true) {
            $fileFailures += "source file missing"
        }
        if ([string]::IsNullOrWhiteSpace($file.sha256) -or $file.sha256 -notmatch '^[0-9a-f]{64}$') {
            $fileFailures += "sha256 is missing or invalid"
        }
        if ([string]::IsNullOrWhiteSpace($file.copied_path) -or -not (Test-Path -LiteralPath $file.copied_path -PathType Leaf)) {
            $fileFailures += "copied file is missing"
        }
        elseif (-not (Test-PathWithinRoot -Path ([string]$file.copied_path) -Root $resolvedPacketRoot)) {
            $fileFailures += "copied file is outside the evidence packet root"
        }
        elseif ($file.sha256 -and ((Get-Sha256Hex -Path $file.copied_path) -ne $file.sha256)) {
            $fileFailures += "copied file hash does not match source hash"
        }

        $checks += New-Check -Id ("evidence_file_" + $file.id) -Passed ($fileFailures.Count -eq 0) -Failures $fileFailures -Evidence $file
    }

    $environmentVariables = @($manifest.environment_file.variables)
    $leakedValueProperty = $false
    foreach ($variable in $environmentVariables) {
        if ($variable.PSObject.Properties["value"]) {
            $leakedValueProperty = $true
        }
    }
    $checks += Add-Check -Id "environment_values_not_serialized" -Condition (-not $leakedValueProperty) -Failure "environment variable values must not be serialized in release evidence"
}

if (-not [string]::IsNullOrWhiteSpace($summaryText)) {
    $checks += Add-Check -Id "summary_states_secret_posture" -Condition ($summaryText -match "Secrets included: false") -Failure "release evidence summary does not state that secrets are excluded"
    $checks += Add-Check -Id "summary_states_package_signing_certificate" -Condition ($summaryText -match "Package signing certificate included:") -Failure "release evidence summary does not state package-signing certificate posture"
    if ($summaryText -match [regex]::Escape($syntheticSecret)) {
        $checks += New-Check -Id "summary_secret_leak_check" -Passed $false -Failures @("synthetic secret appeared in release evidence summary")
    }
    else {
        $checks += New-Check -Id "summary_secret_leak_check" -Passed $true -Failures @()
    }
}

if ($null -ne $manifest) {
    $manifestJson = Get-Content -LiteralPath $manifestPath -Raw
    if ($manifestJson -match [regex]::Escape($syntheticSecret)) {
        $checks += New-Check -Id "manifest_secret_leak_check" -Passed $false -Failures @("synthetic secret appeared in release evidence manifest")
    }
    else {
        $checks += New-Check -Id "manifest_secret_leak_check" -Passed $true -Failures @()
    }
}

$failed = @($checks | Where-Object { -not $_.passed })
$report = [pscustomobject][ordered]@{
    schema = "archrealms.passport.production_mvp_release_evidence_packet_validation.v1"
    created_utc = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
    repo_root = $repoRoot
    evidence_packet_root = $resolvedPacketRoot
    use_synthetic_fixtures = [bool]$UseSyntheticFixtures
    generated = [bool]$Generate
    require_ready = [bool]$RequireReady
    passed = ($failed.Count -eq 0)
    failed_check_count = $failed.Count
    checks = $checks
}

$resolvedOutput = Resolve-RepoPath -Path $OutputPath
$parent = Split-Path -Parent $resolvedOutput
if ($parent) {
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
}

$json = $report | ConvertTo-Json -Depth 10
Set-Content -LiteralPath $resolvedOutput -Value $json -Encoding UTF8
$json

if ($failed.Count -gt 0 -and -not $NoFail) {
    throw "Production MVP release evidence packet validation failed. Missing gates: " + (($failed | ForEach-Object { $_.id }) -join ", ")
}
