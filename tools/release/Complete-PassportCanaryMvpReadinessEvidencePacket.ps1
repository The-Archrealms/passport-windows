param(
    [string]$PacketRoot = "artifacts\release\canary-mvp-readiness-evidence",
    [string]$OutputDirectory = "artifacts\release\canary-mvp-readiness-closeout",
    [string]$CanaryMvpReadinessReportPath = "artifacts\release\canary-mvp-readiness-report.json",
    [string]$EnvironmentFile,
    [string]$StagingReadinessReportPath,
    [string]$StagingReadinessReportSha256,
    [string]$CanaryArtifactValidationReportPath,
    [string]$CanaryArtifactValidationReportSha256,
    [switch]$UseGeneratedFixture,
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

function Get-Sha256Hex {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return ""
    }

    return (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant()
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

function Find-EvidenceFile {
    param(
        [string]$Root,
        [string]$BaseName
    )

    $candidate = Join-Path $Root "$BaseName.json"
    if (Test-Path -LiteralPath $candidate -PathType Leaf) {
        return [System.IO.Path]::GetFullPath($candidate)
    }

    $templateCandidate = Join-Path $Root "$BaseName.template.json"
    if (Test-Path -LiteralPath $templateCandidate -PathType Leaf) {
        return [System.IO.Path]::GetFullPath($templateCandidate)
    }

    return [System.IO.Path]::GetFullPath($candidate)
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

function Read-EnvironmentFile {
    param([string]$Path)

    $values = [ordered]@{}
    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $values
    }

    $resolved = Resolve-RepoPath -Path $Path
    if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) {
        throw "Environment file was not found: $resolved"
    }

    foreach ($line in Get-Content -LiteralPath $resolved) {
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

        if (-not [string]::IsNullOrWhiteSpace($name)) {
            $values[$name] = $value
        }
    }

    return $values
}

function Write-EnvironmentFile {
    param(
        [string]$Path,
        [System.Collections.IDictionary]$Values
    )

    $parent = Split-Path -Parent $Path
    if ($parent) {
        New-Item -ItemType Directory -Force -Path $parent | Out-Null
    }

    $lines = @(
        "# Archrealms Passport Canary MVP readiness closeout environment",
        "# Generated from a filled canary readiness evidence packet. Do not commit populated env files.",
        ""
    )

    foreach ($key in $Values.Keys) {
        $lines += "$key=$($Values[$key])"
    }

    Set-Content -LiteralPath $Path -Value ($lines -join [Environment]::NewLine) -Encoding UTF8
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
        failed_check_count = $(if ($null -ne $json -and $json.PSObject.Properties["failed_check_count"]) { [int]$json.failed_check_count } else { $null })
        failed_gate_count = $(if ($null -ne $json -and $json.PSObject.Properties["failed_gate_count"]) { [int]$json.failed_gate_count } else { $null })
    }
}

function New-GeneratedFixture {
    param([string]$FixtureRoot)

    New-Item -ItemType Directory -Force -Path $FixtureRoot | Out-Null
    $packetRoot = Join-Path $FixtureRoot "packet"
    New-Item -ItemType Directory -Force -Path $packetRoot | Out-Null
    $createdUtc = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
    $ledgerNamespace = "archrealms-passport-canary-closeout-validation"

    $stagingPath = Join-Path $FixtureRoot "staging-readiness-report.json"
    Write-JsonFile -Path $stagingPath -Value ([pscustomobject][ordered]@{
        schema = "archrealms.passport.staging_readiness.v1"
        created_utc = $createdUtc
        ready = $true
        staging_is_mvp = $false
        synthetic_fixtures_used = $false
        canary_or_production_release_approved = $true
        failed_gate_count = 0
        gates = @()
    })

    $artifactPath = Join-Path $FixtureRoot "canary-artifact-validation-report.json"
    Write-JsonFile -Path $artifactPath -Value ([pscustomobject][ordered]@{
        verified_utc = $createdUtc
        passed = $true
        failed_artifact_count = 0
        artifacts = @(
            [pscustomobject][ordered]@{
                manifest_path = "synthetic-canary-release-manifest.json"
                artifact_root = "synthetic-canary-artifact"
                package_path = ""
                zip_path = "synthetic-canary.zip"
                lane = "canary-mvp"
                ledger_namespace = $ledgerNamespace
                failures = @()
                passed = $true
            }
        )
    })

    $policyPath = Join-Path $packetRoot "canary-policy.json"
    $incidentPath = Join-Path $packetRoot "canary-incident-review.json"
    $balancePath = Join-Path $packetRoot "canary-balance-reconciliation.json"
    $servicePath = Join-Path $packetRoot "canary-service-delivery-reconciliation.json"
    $supportPath = Join-Path $packetRoot "canary-support-readiness.json"
    $approvalPath = Join-Path $packetRoot "canary-production-approval-record.json"

    Write-JsonFile -Path $policyPath -Value ([pscustomobject][ordered]@{
        schema = "archrealms.passport.canary_policy.v1"
        created_utc = $createdUtc
        lane = "canary-mvp"
        policy_id = "canary-policy-closeout-validation"
        production_intended = $true
        production_ledger = $true
        allowlisted_citizens_only = $true
        production_ledger_namespace = $ledgerNamespace
        max_citizens = 5
        max_arch_per_citizen_base_units = 1000000
        max_cc_outstanding_base_units = 1000000
        max_conversion_quote_base_units = 100000
        allowed_service_classes = @("storage_standard")
        external_wallet_transfers_enabled = $false
        fiat_rails_enabled = $false
        unrestricted_cc_payments_enabled = $false
        guaranteed_conversion_claims_enabled = $false
        stable_value_claims_enabled = $false
        yield_or_staking_enabled = $false
        token_governance_enabled = $false
        support_owner = "canary-closeout-support"
        incident_response_owner = "canary-closeout-incident"
        rollback_policy_id = "canary-closeout-rollback"
        evidence_refs = @("controlled-evidence://canary/policy")
    })

    Write-JsonFile -Path $incidentPath -Value ([pscustomobject][ordered]@{
        schema = "archrealms.passport.canary_incident_review.v1"
        created_utc = $createdUtc
        lane = "canary-mvp"
        incident_review_id = "canary-incident-review-closeout-validation"
        completed = $true
        incident_review_completed = $true
        no_unresolved_critical_incidents = $true
        no_unresolved_high_incidents = $true
        incident_response_owner = "canary-closeout-incident"
        incident_count = 0
        unresolved_critical_incident_count = 0
        unresolved_high_incident_count = 0
        evidence_refs = @("controlled-evidence://canary/incidents")
    })

    Write-JsonFile -Path $balancePath -Value ([pscustomobject][ordered]@{
        schema = "archrealms.passport.canary_balance_reconciliation.v1"
        created_utc = $createdUtc
        lane = "canary-mvp"
        balance_reconciliation_id = "canary-balance-closeout-validation"
        completed = $true
        production_ledger_namespace = $ledgerNamespace
        arch_balances_reconciled = $true
        cc_balances_reconciled = $true
        escrow_reconciled = $true
        burn_refund_recredit_reconciled = $true
        crown_reserve_reconciled = $true
        no_negative_balances = $true
        no_unapproved_issuance = $true
        no_staging_records_detected = $true
        evidence_refs = @("controlled-evidence://canary/balance")
    })

    Write-JsonFile -Path $servicePath -Value ([pscustomobject][ordered]@{
        schema = "archrealms.passport.canary_service_delivery_reconciliation.v1"
        created_utc = $createdUtc
        lane = "canary-mvp"
        service_delivery_reconciliation_id = "canary-service-closeout-validation"
        completed = $true
        service_delivery_reconciled = $true
        storage_redemptions_reconciled = $true
        storage_proofs_reconciled = $true
        burns_match_verified_epochs = $true
        refunds_recredits_extensions_reconciled = $true
        unresolved_failed_epoch_count = 0
        evidence_refs = @("controlled-evidence://canary/service-delivery")
    })

    Write-JsonFile -Path $supportPath -Value ([pscustomobject][ordered]@{
        schema = "archrealms.passport.canary_support_readiness.v1"
        created_utc = $createdUtc
        lane = "canary-mvp"
        support_readiness_id = "canary-support-closeout-validation"
        completed = $true
        support_ready = $true
        support_queue_reviewed = $true
        recovery_support_ready = $true
        escalation_path_ready = $true
        support_access_controls_validated = $true
        support_owner = "canary-closeout-support"
        incident_response_owner = "canary-closeout-incident"
        evidence_refs = @("controlled-evidence://canary/support")
    })

    $stagingHash = Get-Sha256Hex -Path $stagingPath
    $artifactHash = Get-Sha256Hex -Path $artifactPath
    $policyHash = Get-Sha256Hex -Path $policyPath
    $incidentHash = Get-Sha256Hex -Path $incidentPath
    $balanceHash = Get-Sha256Hex -Path $balancePath
    $serviceHash = Get-Sha256Hex -Path $servicePath
    $supportHash = Get-Sha256Hex -Path $supportPath

    Write-JsonFile -Path $approvalPath -Value ([pscustomobject][ordered]@{
        schema = "archrealms.passport.canary_production_approval.v1"
        created_utc = $createdUtc
        lane = "canary-mvp"
        production_approval_id = "canary-production-approval-closeout-validation"
        approve_production_mvp_release = $true
        product_approval_id = "canary-production-approval-closeout-validation"
        engineering_signoff_id = "canary-engineering-closeout-validation"
        security_privacy_signoff_id = "canary-security-closeout-validation"
        crown_monetary_authority_signoff_id = "canary-crown-closeout-validation"
        staging_readiness_report_sha256 = $stagingHash
        canary_artifact_validation_report_sha256 = $artifactHash
        canary_policy_report_sha256 = $policyHash
        canary_incident_review_report_sha256 = $incidentHash
        canary_balance_reconciliation_report_sha256 = $balanceHash
        canary_service_delivery_reconciliation_report_sha256 = $serviceHash
        canary_support_readiness_report_sha256 = $supportHash
        approval_notes = "canary closeout validation fixture"
    })

    return [pscustomobject][ordered]@{
        packet_root = $packetRoot
        staging_readiness_report_path = $stagingPath
        staging_readiness_report_sha256 = $stagingHash
        canary_artifact_validation_report_path = $artifactPath
        canary_artifact_validation_report_sha256 = $artifactHash
    }
}

if ($UseGeneratedFixture) {
    $fixtureRoot = Resolve-RepoPath -Path "artifacts\release\canary-mvp-readiness-closeout-fixture"
    $fixture = New-GeneratedFixture -FixtureRoot $fixtureRoot
    $PacketRoot = $fixture.packet_root
    $OutputDirectory = Join-Path $fixtureRoot "closeout"
    $CanaryMvpReadinessReportPath = Join-Path $fixtureRoot "canary-mvp-readiness-report.json"
    $StagingReadinessReportPath = $fixture.staging_readiness_report_path
    $StagingReadinessReportSha256 = $fixture.staging_readiness_report_sha256
    $CanaryArtifactValidationReportPath = $fixture.canary_artifact_validation_report_path
    $CanaryArtifactValidationReportSha256 = $fixture.canary_artifact_validation_report_sha256
    $Force = $true
}

$resolvedPacketRoot = Resolve-RepoPath -Path $PacketRoot
$resolvedOutput = Resolve-RepoPath -Path $OutputDirectory
if ((Test-Path -LiteralPath $resolvedOutput -PathType Container) -and -not $Force) {
    $existing = @(Get-ChildItem -LiteralPath $resolvedOutput -Force)
    if ($existing.Count -gt 0) {
        throw "Refusing to overwrite existing canary closeout directory without -Force: $resolvedOutput"
    }
}

New-Item -ItemType Directory -Force -Path $resolvedOutput | Out-Null

$policyPath = Find-EvidenceFile -Root $resolvedPacketRoot -BaseName "canary-policy"
$incidentPath = Find-EvidenceFile -Root $resolvedPacketRoot -BaseName "canary-incident-review"
$balancePath = Find-EvidenceFile -Root $resolvedPacketRoot -BaseName "canary-balance-reconciliation"
$servicePath = Find-EvidenceFile -Root $resolvedPacketRoot -BaseName "canary-service-delivery-reconciliation"
$supportPath = Find-EvidenceFile -Root $resolvedPacketRoot -BaseName "canary-support-readiness"
$approvalPath = Find-EvidenceFile -Root $resolvedPacketRoot -BaseName "canary-production-approval-record"

$policy = Read-JsonFile -Path $policyPath
$incident = Read-JsonFile -Path $incidentPath
$balance = Read-JsonFile -Path $balancePath
$service = Read-JsonFile -Path $servicePath
$support = Read-JsonFile -Path $supportPath
$approval = Read-JsonFile -Path $approvalPath

$envValues = Read-EnvironmentFile -Path $EnvironmentFile
if (-not [string]::IsNullOrWhiteSpace($StagingReadinessReportPath)) {
    $envValues["ARCHREALMS_PASSPORT_STAGING_READINESS_REPORT_PATH"] = Resolve-RepoPath -Path $StagingReadinessReportPath
}
if (-not [string]::IsNullOrWhiteSpace($StagingReadinessReportSha256)) {
    $envValues["ARCHREALMS_PASSPORT_STAGING_READINESS_REPORT_SHA256"] = $StagingReadinessReportSha256
}
if (-not [string]::IsNullOrWhiteSpace($CanaryArtifactValidationReportPath)) {
    $envValues["ARCHREALMS_PASSPORT_CANARY_ARTIFACT_VALIDATION_REPORT_PATH"] = Resolve-RepoPath -Path $CanaryArtifactValidationReportPath
}
if (-not [string]::IsNullOrWhiteSpace($CanaryArtifactValidationReportSha256)) {
    $envValues["ARCHREALMS_PASSPORT_CANARY_ARTIFACT_VALIDATION_REPORT_SHA256"] = $CanaryArtifactValidationReportSha256
}

if ($null -ne $policy) {
    $envValues["ARCHREALMS_PASSPORT_CANARY_POLICY_ID"] = Read-ObjectString -Object $policy -Name "policy_id"
    $envValues["ARCHREALMS_PASSPORT_CANARY_POLICY_REPORT_PATH"] = $policyPath
    $envValues["ARCHREALMS_PASSPORT_CANARY_POLICY_REPORT_SHA256"] = Get-Sha256Hex -Path $policyPath
}
if ($null -ne $incident) {
    $envValues["ARCHREALMS_PASSPORT_CANARY_INCIDENT_REVIEW_ID"] = Read-ObjectString -Object $incident -Name "incident_review_id"
    $envValues["ARCHREALMS_PASSPORT_CANARY_INCIDENT_REVIEW_REPORT_PATH"] = $incidentPath
    $envValues["ARCHREALMS_PASSPORT_CANARY_INCIDENT_REVIEW_REPORT_SHA256"] = Get-Sha256Hex -Path $incidentPath
}
if ($null -ne $balance) {
    $envValues["ARCHREALMS_PASSPORT_CANARY_BALANCE_RECONCILIATION_ID"] = Read-ObjectString -Object $balance -Name "balance_reconciliation_id"
    $envValues["ARCHREALMS_PASSPORT_CANARY_BALANCE_RECONCILIATION_REPORT_PATH"] = $balancePath
    $envValues["ARCHREALMS_PASSPORT_CANARY_BALANCE_RECONCILIATION_REPORT_SHA256"] = Get-Sha256Hex -Path $balancePath
}
if ($null -ne $service) {
    $envValues["ARCHREALMS_PASSPORT_CANARY_SERVICE_DELIVERY_RECONCILIATION_ID"] = Read-ObjectString -Object $service -Name "service_delivery_reconciliation_id"
    $envValues["ARCHREALMS_PASSPORT_CANARY_SERVICE_DELIVERY_RECONCILIATION_REPORT_PATH"] = $servicePath
    $envValues["ARCHREALMS_PASSPORT_CANARY_SERVICE_DELIVERY_RECONCILIATION_REPORT_SHA256"] = Get-Sha256Hex -Path $servicePath
}
if ($null -ne $support) {
    $envValues["ARCHREALMS_PASSPORT_CANARY_SUPPORT_READINESS_ID"] = Read-ObjectString -Object $support -Name "support_readiness_id"
    $envValues["ARCHREALMS_PASSPORT_CANARY_SUPPORT_READINESS_REPORT_PATH"] = $supportPath
    $envValues["ARCHREALMS_PASSPORT_CANARY_SUPPORT_READINESS_REPORT_SHA256"] = Get-Sha256Hex -Path $supportPath
}
if ($null -ne $approval) {
    $envValues["ARCHREALMS_PASSPORT_CANARY_PRODUCTION_APPROVAL_ID"] = Read-ObjectString -Object $approval -Name "production_approval_id"
    $envValues["ARCHREALMS_PASSPORT_CANARY_ENGINEERING_SIGNOFF_ID"] = Read-ObjectString -Object $approval -Name "engineering_signoff_id"
    $envValues["ARCHREALMS_PASSPORT_CANARY_SECURITY_PRIVACY_SIGNOFF_ID"] = Read-ObjectString -Object $approval -Name "security_privacy_signoff_id"
    $envValues["ARCHREALMS_PASSPORT_CANARY_CROWN_MONETARY_AUTHORITY_SIGNOFF_ID"] = Read-ObjectString -Object $approval -Name "crown_monetary_authority_signoff_id"
    $envValues["ARCHREALMS_PASSPORT_CANARY_PRODUCTION_APPROVAL_RECORD_PATH"] = $approvalPath
    $envValues["ARCHREALMS_PASSPORT_CANARY_PRODUCTION_APPROVAL_RECORD_SHA256"] = Get-Sha256Hex -Path $approvalPath
}

$closeoutEnvironmentPath = Join-Path $resolvedOutput "canary-mvp-readiness-closeout.env"
Write-EnvironmentFile -Path $closeoutEnvironmentPath -Values $envValues

$packetValidationPath = Join-Path $resolvedOutput "canary-evidence-packet-validation-report.json"
$packetValidation = Invoke-Tool `
    -FilePath (Join-Path $scriptRoot "Test-PassportCanaryMvpReadinessEvidencePacket.ps1") `
    -Arguments @("-PacketRoot", $resolvedPacketRoot, "-RequireNoPlaceholders", "-NoFail", "-OutputPath", $packetValidationPath) `
    -LogPath (Join-Path $resolvedOutput "canary-evidence-packet-validation.log")
$packetValidationState = Get-ToolReportState -Id "canary_evidence_packet_validation" -Path $packetValidationPath

$failures = @()
if ($packetValidation.exit_code -ne 0 -or -not [bool]$packetValidationState.passed) {
    $failures += "Filled Canary MVP readiness evidence packet did not pass -RequireNoPlaceholders validation."
}

$resolvedCanaryReportPath = Resolve-RepoPath -Path $CanaryMvpReadinessReportPath
$readinessRun = Invoke-Tool `
    -FilePath (Join-Path $scriptRoot "Test-PassportCanaryMvpReadiness.ps1") `
    -Arguments @("-EnvironmentFile", $closeoutEnvironmentPath, "-OutputPath", $resolvedCanaryReportPath, "-NoFail") `
    -LogPath (Join-Path $resolvedOutput "canary-mvp-readiness-run.log")
$readinessState = Get-ToolReportState -Id "canary_mvp_readiness" -Path $resolvedCanaryReportPath
if ($readinessRun.exit_code -ne 0 -or -not [bool]$readinessState.ready) {
    $failures += "Canary MVP readiness did not pass."
}

$canaryReportSha256 = Get-Sha256Hex -Path $resolvedCanaryReportPath
$closeoutPassed = ($failures.Count -eq 0)
$manifest = [pscustomobject][ordered]@{
    schema = "archrealms.passport.canary_mvp_readiness_closeout.v1"
    created_utc = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
    lane = "canary-mvp"
    app_commit = Get-CurrentCommit
    generated_fixture = [bool]$UseGeneratedFixture
    passed = $closeoutPassed
    failures = @($failures)
    packet_root = $resolvedPacketRoot
    output_directory = $resolvedOutput
    closeout_environment = New-FileRecord -Id "canary_mvp_readiness_closeout_environment" -Path $closeoutEnvironmentPath
    evidence_files = @(
        New-FileRecord -Id "canary_policy_report" -Path $policyPath
        New-FileRecord -Id "canary_incident_review_report" -Path $incidentPath
        New-FileRecord -Id "canary_balance_reconciliation_report" -Path $balancePath
        New-FileRecord -Id "canary_service_delivery_reconciliation_report" -Path $servicePath
        New-FileRecord -Id "canary_support_readiness_report" -Path $supportPath
        New-FileRecord -Id "canary_production_approval_record" -Path $approvalPath
    )
    input_reports = [pscustomobject][ordered]@{
        staging_readiness = New-FileRecord -Id "staging_readiness_report" -Path $envValues["ARCHREALMS_PASSPORT_STAGING_READINESS_REPORT_PATH"]
        canary_artifact_validation = New-FileRecord -Id "canary_artifact_validation_report" -Path $envValues["ARCHREALMS_PASSPORT_CANARY_ARTIFACT_VALIDATION_REPORT_PATH"]
    }
    canary_mvp_readiness_report = New-FileRecord -Id "canary_mvp_readiness_report" -Path $resolvedCanaryReportPath
    canary_mvp_readiness_report_sha256 = $canaryReportSha256
    steps = [pscustomobject][ordered]@{
        evidence_packet_validation = [pscustomobject][ordered]@{
            command = $packetValidation
            report = $packetValidationState
        }
        canary_mvp_readiness = [pscustomobject][ordered]@{
            command = $readinessRun
            report = $readinessState
        }
    }
    downstream_environment_values = [pscustomobject][ordered]@{
        ARCHREALMS_PASSPORT_CANARY_MVP_READINESS_REPORT_PATH = $resolvedCanaryReportPath
        ARCHREALMS_PASSPORT_CANARY_MVP_READINESS_REPORT_SHA256 = $canaryReportSha256
    }
}

$manifestPath = Join-Path $resolvedOutput "canary-mvp-readiness-closeout.manifest.json"
Write-JsonFile -Path $manifestPath -Value $manifest
$manifestRecord = New-FileRecord -Id "canary_mvp_readiness_closeout_manifest" -Path $manifestPath

$result = [pscustomobject][ordered]@{
    schema = "archrealms.passport.canary_mvp_readiness_closeout_result.v1"
    passed = $closeoutPassed
    failures = @($failures)
    manifest_path = $manifestRecord.path
    manifest_sha256 = $manifestRecord.sha256
    canary_mvp_readiness_report_path = $resolvedCanaryReportPath
    canary_mvp_readiness_report_sha256 = $canaryReportSha256
    next_step = $(if ($closeoutPassed) { "Load the Canary MVP readiness report path and SHA-256 into the production readiness environment." } else { "Resolve the listed failures, then rerun Canary MVP readiness closeout." })
}

$json = $result | ConvertTo-Json -Depth 8
$json

if (-not $closeoutPassed -and -not $NoFail) {
    exit 1
}
