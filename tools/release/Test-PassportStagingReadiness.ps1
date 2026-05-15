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

function Test-RequiredTrueField {
    param(
        [object]$Object,
        [string]$Name,
        [string]$Description
    )

    if (-not (Read-ObjectBool -Object $Object -Name $Name)) {
        return "$Description must be true"
    }

    return ""
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

function Test-StagingRollbackDrill {
    $failures = Test-ReportPathAndHash `
        -PathEnvironment "ARCHREALMS_PASSPORT_STAGING_ROLLBACK_DRILL_REPORT_PATH" `
        -HashEnvironment "ARCHREALMS_PASSPORT_STAGING_ROLLBACK_DRILL_REPORT_SHA256"
    if ($failures.Count -gt 0) {
        return $failures
    }

    $path = Get-EnvironmentValue -Name "ARCHREALMS_PASSPORT_STAGING_ROLLBACK_DRILL_REPORT_PATH"
    if ([string]::IsNullOrWhiteSpace($path)) {
        return $failures
    }

    try {
        $report = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
    }
    catch {
        return @("staging rollback drill report is not valid JSON: $($_.Exception.Message)")
    }

    $expectedId = Get-EnvironmentValue -Name "ARCHREALMS_PASSPORT_STAGING_ROLLBACK_DRILL_ID"
    if ((Read-ObjectString -Object $report -Name "schema") -ne "archrealms.passport.staging_rollback_drill.v1") {
        $failures += "staging rollback drill report has unexpected schema"
    }

    if ((Read-ObjectString -Object $report -Name "lane") -ne "staging") {
        $failures += "staging rollback drill report must be for the staging lane"
    }

    if ((Read-ObjectString -Object $report -Name "rollback_drill_id") -ne $expectedId) {
        $failures += "staging rollback drill report ID must match ARCHREALMS_PASSPORT_STAGING_ROLLBACK_DRILL_ID"
    }

    foreach ($check in @(
        @("completed", "staging rollback drill completed"),
        @("new_operations_disabled_or_routed", "rollback operation-routing control"),
        @("ledger_events_preserved", "ledger event preservation"),
        @("no_deletion_mutation_or_backdating", "rollback no-mutation control"),
        @("pending_escrow_resolved_by_policy", "pending escrow rollback policy"),
        @("export_access_preserved", "export access preservation"),
        @("production_records_untouched", "production record isolation")
    )) {
        $failure = Test-RequiredTrueField -Object $report -Name $check[0] -Description $check[1]
        if ($failure) {
            $failures += $failure
        }
    }

    foreach ($field in @("package_version", "policy_version", "reason_code", "user_facing_status")) {
        if ([string]::IsNullOrWhiteSpace((Read-ObjectString -Object $report -Name $field))) {
            $failures += "staging rollback drill report must include $field"
        }
    }

    if (@($report.approvers).Count -lt 2) {
        $failures += "staging rollback drill report must include at least two approvers"
    }

    if (@($report.affected_service_classes).Count -lt 1) {
        $failures += "staging rollback drill report must identify affected service classes"
    }

    if (@($report.affected_assets).Count -lt 1) {
        $failures += "staging rollback drill report must identify affected assets"
    }

    return $failures
}

function Test-StagingPromotionApprovals {
    $failures = Test-ReportPathAndHash `
        -PathEnvironment "ARCHREALMS_PASSPORT_STAGING_PROMOTION_APPROVAL_RECORD_PATH" `
        -HashEnvironment "ARCHREALMS_PASSPORT_STAGING_PROMOTION_APPROVAL_RECORD_SHA256"
    if ($failures.Count -gt 0) {
        return $failures
    }

    $path = Get-EnvironmentValue -Name "ARCHREALMS_PASSPORT_STAGING_PROMOTION_APPROVAL_RECORD_PATH"
    if ([string]::IsNullOrWhiteSpace($path)) {
        return $failures
    }

    try {
        $record = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
    }
    catch {
        return @("staging promotion approval record is not valid JSON: $($_.Exception.Message)")
    }

    if ((Read-ObjectString -Object $record -Name "schema") -ne "archrealms.passport.staging_promotion_approval.v1") {
        $failures += "staging promotion approval record has unexpected schema"
    }

    if ((Read-ObjectString -Object $record -Name "lane") -ne "staging") {
        $failures += "staging promotion approval record must be for the staging lane"
    }

    foreach ($match in @(
        @("promotion_approval_id", "ARCHREALMS_PASSPORT_STAGING_PROMOTION_APPROVAL_ID"),
        @("engineering_signoff_id", "ARCHREALMS_PASSPORT_STAGING_ENGINEERING_SIGNOFF_ID"),
        @("security_privacy_signoff_id", "ARCHREALMS_PASSPORT_STAGING_SECURITY_PRIVACY_SIGNOFF_ID"),
        @("crown_monetary_authority_signoff_id", "ARCHREALMS_PASSPORT_STAGING_CROWN_MONETARY_AUTHORITY_SIGNOFF_ID"),
        @("rollback_drill_id", "ARCHREALMS_PASSPORT_STAGING_ROLLBACK_DRILL_ID")
    )) {
        if ((Read-ObjectString -Object $record -Name $match[0]) -ne (Get-EnvironmentValue -Name $match[1])) {
            $failures += "staging promotion approval record field $($match[0]) must match $($match[1])"
        }
    }

    foreach ($hashMatch in @(
        @("pre_mvp_report_sha256", "ARCHREALMS_PASSPORT_PRE_MVP_VERIFICATION_REPORT_SHA256"),
        @("staging_artifact_validation_report_sha256", "ARCHREALMS_PASSPORT_STAGING_ARTIFACT_VALIDATION_REPORT_SHA256"),
        @("rollback_drill_report_sha256", "ARCHREALMS_PASSPORT_STAGING_ROLLBACK_DRILL_REPORT_SHA256")
    )) {
        if ((Read-ObjectString -Object $record -Name $hashMatch[0]) -ne (Get-EnvironmentValue -Name $hashMatch[1])) {
            $failures += "staging promotion approval record field $($hashMatch[0]) must match $($hashMatch[1])"
        }
    }

    foreach ($check in @(
        @("approve_canary_or_production_release", "canary or production release approval"),
        @("product_approval_signed", "product approval signature"),
        @("engineering_signoff_signed", "engineering signoff signature"),
        @("security_privacy_signoff_signed", "security/privacy signoff signature"),
        @("crown_monetary_authority_signoff_signed", "Crown monetary authority signoff signature")
    )) {
        $failure = Test-RequiredTrueField -Object $record -Name $check[0] -Description $check[1]
        if ($failure) {
            $failures += $failure
        }
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

    $rollbackPath = Join-Path $OutputDirectory "synthetic-staging-rollback-drill-report.json"
    $rollback = [pscustomobject][ordered]@{
        schema = "archrealms.passport.staging_rollback_drill.v1"
        created_utc = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
        lane = "staging"
        rollback_drill_id = "staging-rollback-drill-synthetic"
        completed = $true
        package_version = "synthetic-staging"
        policy_version = "passport-token-ready-mvp-v1"
        reason_code = "synthetic-validator-self-test"
        approvers = @("synthetic-engineering", "synthetic-security-privacy")
        affected_service_classes = @("identity", "wallet", "storage", "ai", "ledger-export")
        affected_assets = @("ARCH", "CC")
        user_facing_status = "synthetic rollback drill completed"
        new_operations_disabled_or_routed = $true
        ledger_events_preserved = $true
        no_deletion_mutation_or_backdating = $true
        pending_escrow_resolved_by_policy = $true
        export_access_preserved = $true
        production_records_untouched = $true
    }
    $rollback | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $rollbackPath -Encoding UTF8

    $preMvpHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $preMvpPath).Hash.ToLowerInvariant()
    $artifactHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $artifactPath).Hash.ToLowerInvariant()
    $rollbackHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $rollbackPath).Hash.ToLowerInvariant()
    $promotionPath = Join-Path $OutputDirectory "synthetic-staging-promotion-approval-record.json"
    $promotion = [pscustomobject][ordered]@{
        schema = "archrealms.passport.staging_promotion_approval.v1"
        created_utc = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
        lane = "staging"
        promotion_approval_id = "staging-promotion-synthetic"
        engineering_signoff_id = "staging-engineering-synthetic"
        security_privacy_signoff_id = "staging-security-privacy-synthetic"
        crown_monetary_authority_signoff_id = "staging-crown-monetary-synthetic"
        rollback_drill_id = "staging-rollback-drill-synthetic"
        pre_mvp_report_sha256 = $preMvpHash
        staging_artifact_validation_report_sha256 = $artifactHash
        rollback_drill_report_sha256 = $rollbackHash
        approve_canary_or_production_release = $true
        product_approval_signed = $true
        engineering_signoff_signed = $true
        security_privacy_signoff_signed = $true
        crown_monetary_authority_signoff_signed = $true
    }
    $promotion | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $promotionPath -Encoding UTF8

    [System.Environment]::SetEnvironmentVariable("ARCHREALMS_PASSPORT_PRE_MVP_VERIFICATION_REPORT_PATH", $preMvpPath, "Process")
    [System.Environment]::SetEnvironmentVariable("ARCHREALMS_PASSPORT_PRE_MVP_VERIFICATION_REPORT_SHA256", $preMvpHash, "Process")
    [System.Environment]::SetEnvironmentVariable("ARCHREALMS_PASSPORT_STAGING_ARTIFACT_VALIDATION_REPORT_PATH", $artifactPath, "Process")
    [System.Environment]::SetEnvironmentVariable("ARCHREALMS_PASSPORT_STAGING_ARTIFACT_VALIDATION_REPORT_SHA256", $artifactHash, "Process")
    [System.Environment]::SetEnvironmentVariable("PASSPORT_WINDOWS_STAGING_API_BASE_URL", "http://127.0.0.1:18080", "Process")
    [System.Environment]::SetEnvironmentVariable("PASSPORT_WINDOWS_STAGING_AI_GATEWAY_URL", "http://127.0.0.1:18081", "Process")
    [System.Environment]::SetEnvironmentVariable("ARCHREALMS_PASSPORT_STAGING_LEDGER_NAMESPACE", "archrealms-passport-staging", "Process")
    [System.Environment]::SetEnvironmentVariable("ARCHREALMS_PASSPORT_STAGING_TELEMETRY_DESTINATION", "staging-managed-telemetry", "Process")
    [System.Environment]::SetEnvironmentVariable("ARCHREALMS_PASSPORT_STAGING_ROLLBACK_DRILL_ID", "staging-rollback-drill-synthetic", "Process")
    [System.Environment]::SetEnvironmentVariable("ARCHREALMS_PASSPORT_STAGING_ROLLBACK_DRILL_REPORT_PATH", $rollbackPath, "Process")
    [System.Environment]::SetEnvironmentVariable("ARCHREALMS_PASSPORT_STAGING_ROLLBACK_DRILL_REPORT_SHA256", $rollbackHash, "Process")
    [System.Environment]::SetEnvironmentVariable("ARCHREALMS_PASSPORT_STAGING_PROMOTION_APPROVAL_ID", "staging-promotion-synthetic", "Process")
    [System.Environment]::SetEnvironmentVariable("ARCHREALMS_PASSPORT_STAGING_ENGINEERING_SIGNOFF_ID", "staging-engineering-synthetic", "Process")
    [System.Environment]::SetEnvironmentVariable("ARCHREALMS_PASSPORT_STAGING_SECURITY_PRIVACY_SIGNOFF_ID", "staging-security-privacy-synthetic", "Process")
    [System.Environment]::SetEnvironmentVariable("ARCHREALMS_PASSPORT_STAGING_CROWN_MONETARY_AUTHORITY_SIGNOFF_ID", "staging-crown-monetary-synthetic", "Process")
    [System.Environment]::SetEnvironmentVariable("ARCHREALMS_PASSPORT_STAGING_PROMOTION_APPROVAL_RECORD_PATH", $promotionPath, "Process")
    [System.Environment]::SetEnvironmentVariable("ARCHREALMS_PASSPORT_STAGING_PROMOTION_APPROVAL_RECORD_SHA256", (Get-FileHash -Algorithm SHA256 -LiteralPath $promotionPath).Hash.ToLowerInvariant(), "Process")

    return [pscustomobject][ordered]@{
        pre_mvp_report_path = $preMvpPath
        staging_artifact_validation_report_path = $artifactPath
        staging_rollback_drill_report_path = $rollbackPath
        staging_promotion_approval_record_path = $promotionPath
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
            "ARCHREALMS_PASSPORT_STAGING_ROLLBACK_DRILL_ID",
            "ARCHREALMS_PASSPORT_STAGING_ROLLBACK_DRILL_REPORT_PATH",
            "ARCHREALMS_PASSPORT_STAGING_ROLLBACK_DRILL_REPORT_SHA256"
        ) `
        -ExtraCheck ${function:Test-StagingRollbackDrill}

    New-Gate `
        -Id "staging_promotion_approvals" `
        -Description "Staging exit has product, engineering, security/privacy, and Crown monetary authority signoff references." `
        -RequiredEnvironment @(
            "ARCHREALMS_PASSPORT_STAGING_PROMOTION_APPROVAL_ID",
            "ARCHREALMS_PASSPORT_STAGING_ENGINEERING_SIGNOFF_ID",
            "ARCHREALMS_PASSPORT_STAGING_SECURITY_PRIVACY_SIGNOFF_ID",
            "ARCHREALMS_PASSPORT_STAGING_CROWN_MONETARY_AUTHORITY_SIGNOFF_ID",
            "ARCHREALMS_PASSPORT_STAGING_PROMOTION_APPROVAL_RECORD_PATH",
            "ARCHREALMS_PASSPORT_STAGING_PROMOTION_APPROVAL_RECORD_SHA256"
        ) `
        -ExtraCheck ${function:Test-StagingPromotionApprovals}

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
