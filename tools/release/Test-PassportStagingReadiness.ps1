param(
    [string]$OutputPath = "artifacts\release\staging-readiness-report.json",
    [string]$EnvironmentFile,
    [switch]$UseSyntheticFixtures,
    [switch]$NoFail
)

$ErrorActionPreference = "Stop"
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path

function Import-EnvironmentFile {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return @()
    }

    $resolvedPath = (Resolve-Path -LiteralPath $Path).Path
    $loaded = @()
    foreach ($line in Get-Content -LiteralPath $resolvedPath) {
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
        if ([string]::IsNullOrWhiteSpace($name)) {
            continue
        }

        if (($value.StartsWith('"') -and $value.EndsWith('"')) -or ($value.StartsWith("'") -and $value.EndsWith("'"))) {
            $value = $value.Substring(1, $value.Length - 2)
        }

        [System.Environment]::SetEnvironmentVariable($name, $value, "Process")
        $loaded += $name
    }

    return $loaded
}

function Get-Sha256Hex {
    param([byte[]]$Bytes)

    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        return [System.BitConverter]::ToString($sha256.ComputeHash($Bytes)).Replace("-", "").ToLowerInvariant()
    }
    finally {
        $sha256.Dispose()
    }
}

function Test-NonEmptyEnvironment {
    param([string]$Name)

    return -not [string]::IsNullOrWhiteSpace([System.Environment]::GetEnvironmentVariable($Name))
}

function Get-EnvironmentValue {
    param([string]$Name)

    $value = [System.Environment]::GetEnvironmentVariable($Name)
    if ($null -eq $value) {
        return ""
    }

    return $value.Trim()
}

function Test-HexSha256Environment {
    param([string]$Name)

    $value = Get-EnvironmentValue -Name $Name
    if ([string]::IsNullOrWhiteSpace($value)) {
        return ""
    }

    if ($value -notmatch '^[0-9a-fA-F]{64}$') {
        return "$Name must be a SHA-256 hex string"
    }

    return ""
}

function Test-NotPlaceholder {
    param(
        [string]$Name,
        [string]$Value
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return ""
    }

    $trimmed = $Value.Trim()
    if ($trimmed -match '<[^>]+>' -or $trimmed -match '^\s*set value\s*$') {
        return "$Name contains a placeholder value"
    }

    return ""
}

function Test-StagingUrl {
    param(
        [string]$Name,
        [string]$Value
    )

    $failures = @()
    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $failures
    }

    $placeholderFailure = Test-NotPlaceholder -Name $Name -Value $Value
    if ($placeholderFailure) {
        $failures += $placeholderFailure
        return $failures
    }

    $uri = $null
    if (-not [System.Uri]::TryCreate($Value.Trim(), [System.UriKind]::Absolute, [ref]$uri)) {
        $failures += "$Name must be an absolute URL"
        return $failures
    }

    $isHttps = [string]::Equals($uri.Scheme, [System.Uri]::UriSchemeHttps, [System.StringComparison]::OrdinalIgnoreCase)
    if (-not $isHttps -and -not $uri.IsLoopback) {
        $failures += "$Name must use HTTPS unless it is a loopback validation URL"
    }

    if ($uri.AbsoluteUri -match 'production-mvp|production_mvp') {
        $failures += "$Name must not point at a production-mvp endpoint for staging readiness"
    }

    return $failures
}

function New-Gate {
    param(
        [string]$Id,
        [string]$Description,
        [string[]]$RequiredEnvironment,
        [scriptblock]$ExtraCheck = $null
    )

    $missing = @()
    foreach ($name in $RequiredEnvironment) {
        if (-not (Test-NonEmptyEnvironment -Name $name)) {
            $missing += $name
            continue
        }

        $placeholderFailure = Test-NotPlaceholder -Name $name -Value (Get-EnvironmentValue -Name $name)
        if ($placeholderFailure) {
            $missing += $placeholderFailure
        }
    }

    if ($ExtraCheck) {
        $extraFailures = @(& $ExtraCheck)
        foreach ($failure in $extraFailures) {
            if ($failure) {
                $missing += $failure
            }
        }
    }

    return [pscustomobject][ordered]@{
        id = $Id
        description = $Description
        passed = ($missing.Count -eq 0)
        missing = $missing
    }
}

function Test-ReportPathAndHash {
    param(
        [string]$PathEnvironment,
        [string]$HashEnvironment
    )

    $failures = @()
    $path = Get-EnvironmentValue -Name $PathEnvironment
    $expectedHash = Get-EnvironmentValue -Name $HashEnvironment

    if ([string]::IsNullOrWhiteSpace($path) -or [string]::IsNullOrWhiteSpace($expectedHash)) {
        return $failures
    }

    $hashFailure = Test-HexSha256Environment -Name $HashEnvironment
    if ($hashFailure) {
        $failures += $hashFailure
        return $failures
    }

    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        $failures += "$PathEnvironment file was not found"
        return $failures
    }

    $actualHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $path).Hash.ToLowerInvariant()
    if (-not [string]::Equals($actualHash, $expectedHash, [System.StringComparison]::OrdinalIgnoreCase)) {
        $failures += "$HashEnvironment does not match the report file"
    }

    return $failures
}

function Test-PreMvpReport {
    $failures = Test-ReportPathAndHash `
        -PathEnvironment "ARCHREALMS_PASSPORT_PRE_MVP_VERIFICATION_REPORT_PATH" `
        -HashEnvironment "ARCHREALMS_PASSPORT_PRE_MVP_VERIFICATION_REPORT_SHA256"
    if ($failures.Count -gt 0) {
        return $failures
    }

    $path = Get-EnvironmentValue -Name "ARCHREALMS_PASSPORT_PRE_MVP_VERIFICATION_REPORT_PATH"
    if ([string]::IsNullOrWhiteSpace($path)) {
        return @()
    }

    try {
        $report = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
    }
    catch {
        return @("pre-MVP internal verification report is not valid JSON: $($_.Exception.Message)")
    }

    if ($report.schema -ne "archrealms.passport.pre_mvp_internal_verification.v1") {
        $failures += "pre-MVP internal verification report has unexpected schema"
    }

    if ($report.passed -ne $true) {
        $failures += "pre-MVP internal verification report did not pass"
    }

    if ($report.pre_mvp_testing_is_mvp -ne $false) {
        $failures += "pre-MVP internal verification report must state pre-MVP testing is not the MVP"
    }

    if ($report.citizen_facing_token_release -ne $false) {
        $failures += "pre-MVP internal verification report must not mark citizen-facing token release complete"
    }

    if ($report.fake_balance_migration_blocked -ne $true) {
        $failures += "pre-MVP internal verification report must prove fake-balance migration is blocked"
    }

    return $failures
}

function Test-StagingArtifactValidationReport {
    $failures = Test-ReportPathAndHash `
        -PathEnvironment "ARCHREALMS_PASSPORT_STAGING_ARTIFACT_VALIDATION_REPORT_PATH" `
        -HashEnvironment "ARCHREALMS_PASSPORT_STAGING_ARTIFACT_VALIDATION_REPORT_SHA256"
    if ($failures.Count -gt 0) {
        return $failures
    }

    $path = Get-EnvironmentValue -Name "ARCHREALMS_PASSPORT_STAGING_ARTIFACT_VALIDATION_REPORT_PATH"
    if ([string]::IsNullOrWhiteSpace($path)) {
        return @()
    }

    try {
        $report = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
    }
    catch {
        return @("staging artifact validation report is not valid JSON: $($_.Exception.Message)")
    }

    if ($report.passed -ne $true) {
        $failures += "staging artifact validation report did not pass"
    }

    $artifacts = @($report.artifacts)
    if ($artifacts.Count -lt 1) {
        $failures += "staging artifact validation report must include at least one artifact"
    }

    foreach ($artifact in $artifacts) {
        if ($artifact.passed -ne $true) {
            $failures += "staging artifact did not pass: $($artifact.manifest_path)"
        }

        if ($artifact.lane -ne "staging") {
            $failures += "artifact $($artifact.manifest_path) is lane '$($artifact.lane)', expected 'staging'"
        }

        $ledgerNamespace = [string]$artifact.ledger_namespace
        if ([string]::IsNullOrWhiteSpace($ledgerNamespace) -or $ledgerNamespace -notmatch 'staging') {
            $failures += "artifact $($artifact.manifest_path) does not use a staging ledger namespace"
        }

        if ($ledgerNamespace -match 'production') {
            $failures += "artifact $($artifact.manifest_path) ledger namespace must not be production"
        }
    }

    return $failures
}

function Test-StagingLaneEndpoints {
    $failures = @()
    foreach ($name in @("PASSPORT_WINDOWS_STAGING_API_BASE_URL", "PASSPORT_WINDOWS_STAGING_AI_GATEWAY_URL")) {
        $failures += Test-StagingUrl -Name $name -Value (Get-EnvironmentValue -Name $name)
    }

    return $failures
}

function Test-StagingLedgerTelemetry {
    $failures = @()
    $namespace = Get-EnvironmentValue -Name "ARCHREALMS_PASSPORT_STAGING_LEDGER_NAMESPACE"
    if (-not [string]::IsNullOrWhiteSpace($namespace)) {
        if ($namespace -notmatch 'staging') {
            $failures += "ARCHREALMS_PASSPORT_STAGING_LEDGER_NAMESPACE must be a staging namespace"
        }

        if ($namespace -match 'production') {
            $failures += "ARCHREALMS_PASSPORT_STAGING_LEDGER_NAMESPACE must not be a production namespace"
        }
    }

    $telemetry = Get-EnvironmentValue -Name "ARCHREALMS_PASSPORT_STAGING_TELEMETRY_DESTINATION"
    if (-not [string]::IsNullOrWhiteSpace($telemetry) -and $telemetry -match 'production') {
        $failures += "ARCHREALMS_PASSPORT_STAGING_TELEMETRY_DESTINATION must not be production telemetry"
    }

    return $failures
}

function Test-StagingNoProductionMigration {
    $failures = @()
    $artifactPath = Get-EnvironmentValue -Name "ARCHREALMS_PASSPORT_STAGING_ARTIFACT_VALIDATION_REPORT_PATH"
    if ([string]::IsNullOrWhiteSpace($artifactPath) -or -not (Test-Path -LiteralPath $artifactPath -PathType Leaf)) {
        return $failures
    }

    $report = Get-Content -LiteralPath $artifactPath -Raw | ConvertFrom-Json
    foreach ($artifact in @($report.artifacts)) {
        foreach ($failure in @($artifact.failures)) {
            if ([string]$failure -match 'production token|production ledger|production records') {
                $failures += "staging artifact migration failure remains unresolved: $failure"
            }
        }
    }

    return $failures
}

function New-SyntheticFixtureReport {
    param([string]$OutputDirectory)

    New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null

    $requiredPreMvpIds = @(
        "synthetic_users",
        "crown_owned_test_devices",
        "crown_owned_test_storage_nodes",
        "synthetic_storage_payloads",
        "fake_balances",
        "fake_arch",
        "fake_cc",
        "ledger_replay_tests",
        "key_recovery_attacks",
        "storage_proof_attacks",
        "storage_revocation_and_wipe_tests",
        "bandwidth_limit_tests",
        "escrow_burn_refund_recredit_tests",
        "market_manipulation_simulations",
        "service_failure_simulations",
        "wallet_compromise_simulations",
        "identity_compromise_simulations",
        "ai_privacy_and_retention_tests",
        "no_fake_record_migration"
    )

    $preMvpPath = Join-Path $OutputDirectory "synthetic-pre-mvp-report.json"
    $preMvp = [pscustomobject][ordered]@{
        schema = "archrealms.passport.pre_mvp_internal_verification.v1"
        created_utc = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
        pre_mvp_testing_is_mvp = $false
        citizen_facing_token_release = $false
        fake_balance_migration_blocked = $true
        passed = $true
        requirements = @($requiredPreMvpIds | ForEach-Object {
            [pscustomobject][ordered]@{
                id = $_
                passed = $true
            }
        })
    }
    $preMvp | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $preMvpPath -Encoding UTF8

    $artifactPath = Join-Path $OutputDirectory "synthetic-staging-artifact-validation-report.json"
    $artifactReport = [pscustomobject][ordered]@{
        verified_utc = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
        passed = $true
        failures = @()
        artifacts = @(
            [pscustomobject][ordered]@{
                manifest_path = "synthetic-staging-release-manifest.json"
                artifact_root = "synthetic-staging-artifact"
                package_path = ""
                zip_path = "synthetic-staging.zip"
                bundled_ipfs_cli_included = $false
                bundled_ipfs_cli_version = ""
                lane = "staging"
                ledger_namespace = "archrealms-passport-staging"
                verified_manifest_file_count = 42
                required_file_count = 10
                failures = @()
                passed = $true
            }
        )
    }
    $artifactReport | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $artifactPath -Encoding UTF8

    [System.Environment]::SetEnvironmentVariable("ARCHREALMS_PASSPORT_PRE_MVP_VERIFICATION_REPORT_PATH", $preMvpPath, "Process")
    [System.Environment]::SetEnvironmentVariable("ARCHREALMS_PASSPORT_PRE_MVP_VERIFICATION_REPORT_SHA256", (Get-FileHash -Algorithm SHA256 -LiteralPath $preMvpPath).Hash.ToLowerInvariant(), "Process")
    [System.Environment]::SetEnvironmentVariable("ARCHREALMS_PASSPORT_STAGING_ARTIFACT_VALIDATION_REPORT_PATH", $artifactPath, "Process")
    [System.Environment]::SetEnvironmentVariable("ARCHREALMS_PASSPORT_STAGING_ARTIFACT_VALIDATION_REPORT_SHA256", (Get-FileHash -Algorithm SHA256 -LiteralPath $artifactPath).Hash.ToLowerInvariant(), "Process")
    [System.Environment]::SetEnvironmentVariable("PASSPORT_WINDOWS_STAGING_API_BASE_URL", "http://127.0.0.1:18080", "Process")
    [System.Environment]::SetEnvironmentVariable("PASSPORT_WINDOWS_STAGING_AI_GATEWAY_URL", "http://127.0.0.1:18081", "Process")
    [System.Environment]::SetEnvironmentVariable("ARCHREALMS_PASSPORT_STAGING_LEDGER_NAMESPACE", "archrealms-passport-staging", "Process")
    [System.Environment]::SetEnvironmentVariable("ARCHREALMS_PASSPORT_STAGING_TELEMETRY_DESTINATION", "staging-managed-telemetry", "Process")
    [System.Environment]::SetEnvironmentVariable("ARCHREALMS_PASSPORT_STAGING_ROLLBACK_DRILL_ID", "staging-rollback-drill-synthetic", "Process")
    [System.Environment]::SetEnvironmentVariable("ARCHREALMS_PASSPORT_STAGING_PROMOTION_APPROVAL_ID", "staging-promotion-synthetic", "Process")
    [System.Environment]::SetEnvironmentVariable("ARCHREALMS_PASSPORT_STAGING_ENGINEERING_SIGNOFF_ID", "staging-engineering-synthetic", "Process")
    [System.Environment]::SetEnvironmentVariable("ARCHREALMS_PASSPORT_STAGING_SECURITY_PRIVACY_SIGNOFF_ID", "staging-security-privacy-synthetic", "Process")
    [System.Environment]::SetEnvironmentVariable("ARCHREALMS_PASSPORT_STAGING_CROWN_MONETARY_AUTHORITY_SIGNOFF_ID", "staging-crown-monetary-synthetic", "Process")

    return [pscustomobject][ordered]@{
        pre_mvp_report_path = $preMvpPath
        staging_artifact_validation_report_path = $artifactPath
    }
}

$loadedEnvironmentVariables = Import-EnvironmentFile -Path $EnvironmentFile
$syntheticFixtures = $null
if ($UseSyntheticFixtures) {
    $syntheticRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("passport-staging-readiness-fixtures-" + [Guid]::NewGuid().ToString("N"))
    $syntheticFixtures = New-SyntheticFixtureReport -OutputDirectory $syntheticRoot
}

$gates = @(
    New-Gate `
        -Id "pre_mvp_internal_verification" `
        -Description "Pre-MVP internal verification has passed and fake records cannot migrate into staging or production token balances." `
        -RequiredEnvironment @(
            "ARCHREALMS_PASSPORT_PRE_MVP_VERIFICATION_REPORT_PATH",
            "ARCHREALMS_PASSPORT_PRE_MVP_VERIFICATION_REPORT_SHA256"
        ) `
        -ExtraCheck ${function:Test-PreMvpReport}

    New-Gate `
        -Id "staging_package_artifact" `
        -Description "A staging release artifact has passed artifact validation and is lane-isolated." `
        -RequiredEnvironment @(
            "ARCHREALMS_PASSPORT_STAGING_ARTIFACT_VALIDATION_REPORT_PATH",
            "ARCHREALMS_PASSPORT_STAGING_ARTIFACT_VALIDATION_REPORT_SHA256"
        ) `
        -ExtraCheck ${function:Test-StagingArtifactValidationReport}

    New-Gate `
        -Id "staging_lane_endpoints" `
        -Description "Staging API and AI gateway endpoints are configured and isolated from production." `
        -RequiredEnvironment @(
            "PASSPORT_WINDOWS_STAGING_API_BASE_URL",
            "PASSPORT_WINDOWS_STAGING_AI_GATEWAY_URL"
        ) `
        -ExtraCheck ${function:Test-StagingLaneEndpoints}

    New-Gate `
        -Id "staging_ledger_telemetry" `
        -Description "Staging ledger namespace and telemetry destination are distinct from production." `
        -RequiredEnvironment @(
            "ARCHREALMS_PASSPORT_STAGING_LEDGER_NAMESPACE",
            "ARCHREALMS_PASSPORT_STAGING_TELEMETRY_DESTINATION"
        ) `
        -ExtraCheck ${function:Test-StagingLedgerTelemetry}

    New-Gate `
        -Id "staging_rollback_drill" `
        -Description "Staging rollback drill evidence is recorded before canary promotion." `
        -RequiredEnvironment @(
            "ARCHREALMS_PASSPORT_STAGING_ROLLBACK_DRILL_ID"
        )

    New-Gate `
        -Id "staging_promotion_approvals" `
        -Description "Staging exit has product, engineering, security/privacy, and Crown monetary authority signoff references." `
        -RequiredEnvironment @(
            "ARCHREALMS_PASSPORT_STAGING_PROMOTION_APPROVAL_ID",
            "ARCHREALMS_PASSPORT_STAGING_ENGINEERING_SIGNOFF_ID",
            "ARCHREALMS_PASSPORT_STAGING_SECURITY_PRIVACY_SIGNOFF_ID",
            "ARCHREALMS_PASSPORT_STAGING_CROWN_MONETARY_AUTHORITY_SIGNOFF_ID"
        )

    New-Gate `
        -Id "no_staging_to_production_migration" `
        -Description "Staging records cannot migrate into production ARCH, CC, Crown reserve, citizen account, or service-liability records." `
        -RequiredEnvironment @(
            "ARCHREALMS_PASSPORT_STAGING_ARTIFACT_VALIDATION_REPORT_PATH"
        ) `
        -ExtraCheck ${function:Test-StagingNoProductionMigration}
)

$failed = @($gates | Where-Object { -not $_.passed })
$report = [pscustomobject][ordered]@{
    schema = "archrealms.passport.staging_readiness.v1"
    created_utc = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
    repo_root = $repoRoot
    lane = "staging"
    staging_is_mvp = $false
    canary_or_production_release_approved = ($failed.Count -eq 0 -and -not [bool]$UseSyntheticFixtures)
    environment_file_loaded = -not [string]::IsNullOrWhiteSpace($EnvironmentFile)
    environment_file_variable_count = $loadedEnvironmentVariables.Count
    environment_file_variables = @($loadedEnvironmentVariables)
    synthetic_fixtures_used = [bool]$UseSyntheticFixtures
    synthetic_fixtures = $syntheticFixtures
    ready = ($failed.Count -eq 0)
    failed_gate_count = $failed.Count
    gates = $gates
}

$json = $report | ConvertTo-Json -Depth 8
if ($OutputPath) {
    $resolvedOutputPath = [System.IO.Path]::GetFullPath($OutputPath)
    $outputDirectory = Split-Path -Parent $resolvedOutputPath
    if ($outputDirectory) {
        New-Item -ItemType Directory -Force -Path $outputDirectory | Out-Null
    }

    Set-Content -LiteralPath $resolvedOutputPath -Value $json -Encoding UTF8
}

$json
if ($failed.Count -gt 0 -and -not $NoFail) {
    throw "Staging readiness failed. Missing gates: " + (($failed | ForEach-Object { $_.id }) -join ", ")
}
