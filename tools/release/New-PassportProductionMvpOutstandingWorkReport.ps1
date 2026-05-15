param(
    [string]$CloseoutManifestPath = "artifacts\release\production-mvp-closeout\production-mvp-closeout.manifest.json",
    [string]$ProductionMvpReadinessReportPath = "artifacts\release\production-mvp-readiness-report.json",
    [string]$ProductionProvisioningPacketReportPath = "artifacts\release\production-provisioning-packet-validation-report.json",
    [string]$ReleaseEvidenceValidationReportPath = "artifacts\release\production-mvp-closeout\production-mvp-release-evidence-validation-report.json",
    [string]$OutputPath = "artifacts\release\production-mvp-outstanding-work-report.json",
    [string]$MarkdownOutputPath = "artifacts\release\production-mvp-outstanding-work-report.md",
    [switch]$UseGeneratedFixture,
    [switch]$NoFail
)

$ErrorActionPreference = "Stop"
$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\.."))

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

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return ""
    }

    return (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant()
}

function Read-JsonFile {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $null
    }

    return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
}

function Read-JsonPayloadFromLog {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $null
    }

    $text = Get-Content -LiteralPath $Path -Raw
    $start = $text.IndexOf("{")
    if ($start -lt 0) {
        return $null
    }

    try {
        return $text.Substring($start) | ConvertFrom-Json
    }
    catch {
        return $null
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

function ConvertTo-ReportText {
    param([object]$Value)

    if ($null -eq $Value) {
        return ""
    }

    $text = ([string]$Value).Trim()
    $text = $text -replace "(`r`n|`n|`r)+", " "
    $text = $text -replace "(?i)\b(password|secret|token|api[_-]?key|private[_-]?key|pfx[_-]?password)\b\s*[:=]\s*[^;,\s]+", '$1=<redacted>'

    if ($text.Length -gt 500) {
        return $text.Substring(0, 497) + "..."
    }

    return $text
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

function Get-FailedChildChecks {
    param([string]$Path)

    $resolved = Resolve-RepoPath -Path $Path
    $childReport = Read-JsonFile -Path $resolved
    if ($null -eq $childReport -or -not $childReport.PSObject.Properties["checks"]) {
        return @()
    }

    $failed = @()
    foreach ($childCheck in @($childReport.checks | Where-Object { $_.passed -ne $true })) {
        $failed += [pscustomobject][ordered]@{
            id = [string]$childCheck.id
            failures = @($childCheck.failures | ForEach-Object { ConvertTo-ReportText -Value $_ })
            evidence_path = $(if ($childCheck.evidence -and $childCheck.evidence.PSObject.Properties["path"]) { [string]$childCheck.evidence.path } else { "" })
        }
    }

    return $failed
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

function New-Action {
    param(
        [string]$Id,
        [string]$Title,
        [string]$Action,
        [string[]]$Commands = @()
    )

    return [pscustomobject][ordered]@{
        id = $Id
        title = $Title
        action = $Action
        commands = @($Commands)
    }
}

$readinessActionMap = @{
    pre_mvp_internal_verification = New-Action `
        -Id "pre_mvp_internal_verification" `
        -Title "Complete staff/steward pilot evidence" `
        -Action "Fill the controlled staff/steward pilot packet, validate it with no placeholders, generate the final pilot report, and rerun pre-MVP internal verification with the report path and SHA-256."
    staging_readiness = New-Action `
        -Id "staging_readiness" `
        -Title "Close out staging readiness" `
        -Action "Fill staging endpoint, ledger/telemetry, operational drill, rollback drill, and promotion approval evidence; then run the staging closeout command with real non-synthetic values."
    canary_mvp_readiness = New-Action `
        -Id "canary_mvp_readiness" `
        -Title "Close out canary MVP readiness" `
        -Action "Fill the canary policy, incident review, balance reconciliation, service-delivery reconciliation, support readiness, and production-promotion evidence; then run the canary closeout command."
    package_signing = New-Action `
        -Id "package_signing" `
        -Title "Configure production package signing" `
        -Action "Acquire the production MSIX signing certificate, configure PFX material or secure PFX path plus password, set publisher and timestamp URL, and validate the signing certificate report."
    release_lane_endpoints = New-Action `
        -Id "release_lane_endpoints" `
        -Title "Provision production API and AI gateway endpoints" `
        -Action "Deploy stable HTTPS production API and AI gateway endpoints, fill endpoint provisioning evidence, and load approved URLs into the production environment."
    hosted_runtime_status = New-Action `
        -Id "hosted_runtime_status" `
        -Title "Make hosted runtime status ready" `
        -Action "Ensure the production hosted API and AI gateway report ready runtime status using the approved endpoints and non-secret operations configuration."
    hosted_ai_runtime_probe = New-Action `
        -Id "hosted_ai_runtime_probe" `
        -Title "Make hosted AI runtime probe pass" `
        -Action "Deploy the approved open-weight inference endpoint and configure the hosted AI gateway so the operator-authenticated non-mutating probe receives an answer."
    hosted_operator_status = New-Action `
        -Id "hosted_operator_status" `
        -Title "Verify hosted operator authentication" `
        -Action "Configure the production hosted API URL and operator key hash, provide the operator secret only to the secure readiness environment, and confirm /ops/operator/status authorizes it."
    managed_storage_backups = New-Action `
        -Id "managed_storage_backups" `
        -Title "Provision managed storage and backups" `
        -Action "Fill managed data-root, storage provider, backup policy, and restore runbook values, then validate managed storage provisioning with no placeholders."
    managed_storage_status = New-Action `
        -Id "managed_storage_status" `
        -Title "Make managed storage status ready" `
        -Action "Bring the production hosted API online with durable records and append-log roots, then verify /ops/storage/status write/delete and backup-manifest enumeration probes."
    managed_signing_key_custody = New-Action `
        -Id "managed_signing_key_custody" `
        -Title "Provision managed signing custody" `
        -Action "Move hosted service signing and Crown authority signing keys into managed, KMS, HSM, managed-HSM, or cloud-KMS custody and fill the custody evidence packet."
    managed_signing_endpoint_probe = New-Action `
        -Id "managed_signing_endpoint_probe" `
        -Title "Make managed signing endpoint probe pass" `
        -Action "Deploy an HTTPS managed signing endpoint that returns non-local RSA signature and public-key evidence for the ProductionMvp readiness probe."
    issuer_capacity_genesis_secrets = New-Action `
        -Id "issuer_capacity_genesis_secrets" `
        -Title "Configure issuer, capacity, genesis, and ledger IDs" `
        -Action "Approve and load the CC issuer authority ID, capacity report issuer ID, ARCH genesis manifest ID, and production ledger namespace."
    open_weight_ai_runtime = New-Action `
        -Id "open_weight_ai_runtime" `
        -Title "Provision approved open-weight AI runtime" `
        -Action "Approve the model artifact/license, deploy vLLM or TGI-compatible inference, configure vector store and knowledge approval root, and validate the runtime deployment/probe."
    telemetry_incident_response = New-Action `
        -Id "telemetry_incident_response" `
        -Title "Configure telemetry and incident response" `
        -Action "Fill the telemetry destination, retention policy URI, incident-response runbook URI, and incident owner, then validate production ops documents."
    production_release_approvals = New-Action `
        -Id "production_release_approvals" `
        -Title "Record production release approvals" `
        -Action "Record product, engineering, security/privacy, and Crown monetary authority signoff IDs in the approved release-approval record."
}

$provisioningActionMap = @{
    package_signing_provisioning = "Fill and approve production MSIX signing request, sideload trust policy, and Store signing policy."
    release_lane_endpoint_provisioning = "Fill and approve production endpoint, TLS/DNS/routing, and endpoint readiness evidence."
    managed_storage_provisioning = "Fill and approve managed storage, backup schedule, and storage readiness evidence."
    managed_signing_custody_provisioning = "Fill and approve key custody, signing endpoint policy, and signing readiness evidence."
    canary_readiness_provisioning = "Fill and approve the canary policy, incident, reconciliation, support, and production-promotion evidence templates."
    canary_readiness_evidence_packet = "Complete and validate the canary readiness evidence packet with no placeholders."
    open_weight_ai_runtime_deployment = "Fill model approval, vector store, runtime readiness evidence, and runtime env values for the approved open-weight deployment."
    production_ops_documents = "Fill backup, restore, telemetry retention, incident response, and release approval documents."
    production_monetary_provisioning = "Fill issuer/capacity/genesis provisioning, ARCH genesis request, and CC capacity request records."
}

if ($UseGeneratedFixture) {
    $fixtureRoot = Resolve-RepoPath -Path "artifacts\release\production-mvp-outstanding-work-fixture"
    New-Item -ItemType Directory -Force -Path $fixtureRoot | Out-Null
    $createdUtc = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")

    $CloseoutManifestPath = Join-Path $fixtureRoot "production-mvp-closeout.manifest.json"
    $ProductionMvpReadinessReportPath = Join-Path $fixtureRoot "production-mvp-readiness-report.json"
    $ProductionProvisioningPacketReportPath = Join-Path $fixtureRoot "production-provisioning-packet-validation-report.json"
    $ReleaseEvidenceValidationReportPath = Join-Path $fixtureRoot "production-mvp-release-evidence-validation-report.json"
    $childProvisioningReportPath = Join-Path $fixtureRoot "synthetic-package-signing-provisioning-validation-report.json"
    $OutputPath = Join-Path $fixtureRoot "production-mvp-outstanding-work-report.json"
    $MarkdownOutputPath = Join-Path $fixtureRoot "production-mvp-outstanding-work-report.md"
    $NoFail = $true

    Write-JsonFile -Path $CloseoutManifestPath -Value ([pscustomobject][ordered]@{
        schema = "archrealms.passport.production_mvp_closeout.v1"
        created_utc = $createdUtc
        app_commit = Get-CurrentCommit
        generated_fixture = $true
        passed = $false
        failures = @(
            "Filled production provisioning packet did not pass -RequireNoPlaceholders validation.",
            "Production MVP readiness did not pass.",
            "Production MVP release evidence packet did not pass -RequireReady validation."
        )
    })

    Write-JsonFile -Path $ProductionMvpReadinessReportPath -Value ([pscustomobject][ordered]@{
        schema = "archrealms.passport.production_mvp_readiness.v1"
        created_utc = $createdUtc
        ready = $false
        failed_gate_count = 1
        gates = @(
            [pscustomobject][ordered]@{
                id = "package_signing"
                description = "Production MVP package signing uses a stable certificate and timestamping, not a generated test certificate."
                passed = $false
                missing = @("production package signing certificate is not configured")
            },
            [pscustomobject][ordered]@{
                id = "hosted_operator_gate"
                description = "Authority-bearing hosted endpoints require a configured operator key hash."
                passed = $true
                missing = @()
            }
        )
    })

    Write-JsonFile -Path $childProvisioningReportPath -Value ([pscustomobject][ordered]@{
        schema = "archrealms.passport.package_signing_provisioning_validation.v1"
        created_utc = $createdUtc
        passed = $false
        failed_check_count = 3
        checks = @(
            [pscustomobject][ordered]@{
                id = "production_msix_signing_request_contract"
                passed = $false
                failures = @("placeholder values remain in production-msix-signing-request.template.md")
                evidence = [pscustomobject][ordered]@{
                    path = "production-msix-signing-request.template.md"
                }
            },
            [pscustomobject][ordered]@{
                id = "sideload_trust_policy_contract"
                passed = $false
                failures = @("placeholder values remain in sideload-trust-policy.template.md")
                evidence = [pscustomobject][ordered]@{
                    path = "sideload-trust-policy.template.md"
                }
            },
            [pscustomobject][ordered]@{
                id = "store_signing_policy_contract"
                passed = $false
                failures = @("placeholder values remain in store-signing-policy.template.md")
                evidence = [pscustomobject][ordered]@{
                    path = "store-signing-policy.template.md"
                }
            }
        )
    })

    Write-JsonFile -Path $ProductionProvisioningPacketReportPath -Value ([pscustomobject][ordered]@{
        schema = "archrealms.passport.production_provisioning_packet_validation.v1"
        created_utc = $createdUtc
        passed = $false
        failed_check_count = 1
        checks = @(
            [pscustomobject][ordered]@{
                id = "package_signing_provisioning"
                description = "MSIX package-signing request, sideload trust policy, and Microsoft Store signing policy are reviewable and internally consistent."
                passed = $false
                failures = @("package_signing_provisioning child report did not pass.")
                evidence = [pscustomobject][ordered]@{
                    report_path = $childProvisioningReportPath
                    child_failed_check_count = 3
                }
            }
        )
    })

    Write-JsonFile -Path $ReleaseEvidenceValidationReportPath -Value ([pscustomobject][ordered]@{
        schema = "archrealms.passport.production_mvp_release_evidence_packet_validation.v1"
        created_utc = $createdUtc
        require_ready = $true
        passed = $false
        failed_check_count = 1
        checks = @(
            [pscustomobject][ordered]@{
                id = "readiness_ready"
                passed = $false
                failures = @("production readiness is not ready")
            }
        )
    })
}

$files = [ordered]@{
    closeout_manifest = New-FileRecord -Id "closeout_manifest" -Path $CloseoutManifestPath
    production_mvp_readiness_report = New-FileRecord -Id "production_mvp_readiness_report" -Path $ProductionMvpReadinessReportPath
    production_provisioning_packet_report = New-FileRecord -Id "production_provisioning_packet_report" -Path $ProductionProvisioningPacketReportPath
    release_evidence_validation_report = New-FileRecord -Id "release_evidence_validation_report" -Path $ReleaseEvidenceValidationReportPath
}

$closeout = Read-JsonFile -Path $files.closeout_manifest.path
$readiness = Read-JsonFile -Path $files.production_mvp_readiness_report.path
$provisioning = Read-JsonFile -Path $files.production_provisioning_packet_report.path
$releaseEvidence = Read-JsonFile -Path $files.release_evidence_validation_report.path
$provisioningReportSource = "report_file"
$inputWarnings = @()

if ($null -ne $closeout -and
    $closeout.PSObject.Properties["steps"] -and
    $closeout.steps.PSObject.Properties["production_provisioning_packet_validation"]) {
    $provisioningStep = $closeout.steps.production_provisioning_packet_validation
    $expectedProvisioningHash = ""
    if ($provisioningStep.PSObject.Properties["report"] -and
        $provisioningStep.report.PSObject.Properties["file"] -and
        $provisioningStep.report.file.PSObject.Properties["sha256"]) {
        $expectedProvisioningHash = [string]$provisioningStep.report.file.sha256
    }

    $currentProvisioningHash = [string]$files.production_provisioning_packet_report.sha256
    if (-not [string]::IsNullOrWhiteSpace($expectedProvisioningHash) -and
        -not [string]::IsNullOrWhiteSpace($currentProvisioningHash) -and
        $expectedProvisioningHash -ne $currentProvisioningHash) {
        $logPath = ""
        if ($provisioningStep.PSObject.Properties["command"] -and
            $provisioningStep.command.PSObject.Properties["log_path"]) {
            $logPath = [string]$provisioningStep.command.log_path
        }

        if (-not [string]::IsNullOrWhiteSpace($logPath)) {
            $files.production_provisioning_packet_closeout_log = New-FileRecord -Id "production_provisioning_packet_closeout_log" -Path $logPath
            $loggedProvisioning = Read-JsonPayloadFromLog -Path $files.production_provisioning_packet_closeout_log.path
            if ($null -ne $loggedProvisioning) {
                $provisioning = $loggedProvisioning
                $provisioningReportSource = "closeout_log_embedded_report"
                $inputWarnings += "The provisioning report path no longer matches the closeout hash; using the closeout log embedded provisioning report."
            }
            else {
                $inputWarnings += "The provisioning report path no longer matches the closeout hash and the closeout log could not be parsed."
            }
        }
        else {
            $inputWarnings += "The provisioning report path no longer matches the closeout hash and no closeout log path was recorded."
        }
    }
}

$inputFailures = @()
foreach ($record in $files.Values) {
    if (-not $record.exists) {
        $inputFailures += "Missing required input file: $($record.path)"
    }
}

$closeoutFailures = @()
if ($null -ne $closeout -and $closeout.PSObject.Properties["failures"]) {
    $closeoutFailures = @($closeout.failures | ForEach-Object { ConvertTo-ReportText -Value $_ })
}

$failedReadinessGates = @()
if ($null -ne $readiness -and $readiness.PSObject.Properties["gates"]) {
    foreach ($gate in @($readiness.gates | Where-Object { $_.passed -ne $true })) {
        $action = $readinessActionMap[[string]$gate.id]
        $failedReadinessGates += [pscustomobject][ordered]@{
            id = [string]$gate.id
            description = ConvertTo-ReportText -Value $gate.description
            missing = @($gate.missing | ForEach-Object { ConvertTo-ReportText -Value $_ })
            operator_action = $(if ($null -ne $action) { $action } else { $null })
        }
    }
}

$failedProvisioningChecks = @()
if ($null -ne $provisioning -and $provisioning.PSObject.Properties["checks"]) {
    foreach ($check in @($provisioning.checks | Where-Object { $_.passed -ne $true })) {
        $childReportPath = $(if ($check.evidence -and $check.evidence.PSObject.Properties["report_path"]) { [string]$check.evidence.report_path } else { "" })
        $resolvedChildReportPath = Resolve-RepoPath -Path $childReportPath
        $childReportExists = (-not [string]::IsNullOrWhiteSpace($resolvedChildReportPath)) -and (Test-Path -LiteralPath $resolvedChildReportPath -PathType Leaf)
        $childFailedChecks = if ($childReportExists) { @(Get-FailedChildChecks -Path $resolvedChildReportPath) } else { @() }

        $failedProvisioningChecks += [pscustomobject][ordered]@{
            id = [string]$check.id
            description = ConvertTo-ReportText -Value $check.description
            failures = @($check.failures | ForEach-Object { ConvertTo-ReportText -Value $_ })
            operator_action = $(if ($provisioningActionMap.ContainsKey([string]$check.id)) { [string]$provisioningActionMap[[string]$check.id] } else { "" })
            child_report_path = $childReportPath
            child_report_exists = $childReportExists
            child_report_sha256 = $(if ($childReportExists) { Get-Sha256Hex -Path $resolvedChildReportPath } else { "" })
            child_failed_check_count = $(if ($check.evidence -and $check.evidence.PSObject.Properties["child_failed_check_count"]) { [int]$check.evidence.child_failed_check_count } else { $null })
            child_failed_checks = $childFailedChecks
        }
    }
}

$failedReleaseEvidenceChecks = @()
if ($null -ne $releaseEvidence -and $releaseEvidence.PSObject.Properties["checks"]) {
    foreach ($check in @($releaseEvidence.checks | Where-Object { $_.passed -ne $true })) {
        $failedReleaseEvidenceChecks += [pscustomobject][ordered]@{
            id = [string]$check.id
            failures = @($check.failures | ForEach-Object { ConvertTo-ReportText -Value $_ })
        }
    }
}

$readyForProductionTesting = (
    $inputFailures.Count -eq 0 -and
    $null -ne $closeout -and
    $closeout.PSObject.Properties["passed"] -and
    [bool]$closeout.passed -eq $true
)

$report = [pscustomobject][ordered]@{
    schema = "archrealms.passport.production_mvp_outstanding_work_report.v1"
    created_utc = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
    app_commit = Get-CurrentCommit
    ready_for_production_testing = $readyForProductionTesting
    input_failures = $inputFailures
    input_warnings = @($inputWarnings | ForEach-Object { ConvertTo-ReportText -Value $_ })
    source_files = $files
    provisioning_report_source = $provisioningReportSource
    summary = [pscustomobject][ordered]@{
        closeout_passed = $(if ($null -ne $closeout -and $closeout.PSObject.Properties["passed"]) { [bool]$closeout.passed } else { $false })
        readiness_ready = $(if ($null -ne $readiness -and $readiness.PSObject.Properties["ready"]) { [bool]$readiness.ready } else { $false })
        readiness_failed_gate_count = $(if ($null -ne $readiness -and $readiness.PSObject.Properties["failed_gate_count"]) { [int]$readiness.failed_gate_count } else { $null })
        provisioning_passed = $(if ($null -ne $provisioning -and $provisioning.PSObject.Properties["passed"]) { [bool]$provisioning.passed } else { $false })
        provisioning_failed_check_count = $(if ($null -ne $provisioning -and $provisioning.PSObject.Properties["failed_check_count"]) { [int]$provisioning.failed_check_count } else { $null })
        release_evidence_passed = $(if ($null -ne $releaseEvidence -and $releaseEvidence.PSObject.Properties["passed"]) { [bool]$releaseEvidence.passed } else { $false })
        release_evidence_failed_check_count = $(if ($null -ne $releaseEvidence -and $releaseEvidence.PSObject.Properties["failed_check_count"]) { [int]$releaseEvidence.failed_check_count } else { $null })
        closeout_failure_count = $closeoutFailures.Count
        failed_readiness_gate_count = $failedReadinessGates.Count
        failed_provisioning_check_count = $failedProvisioningChecks.Count
        failed_release_evidence_check_count = $failedReleaseEvidenceChecks.Count
    }
    closeout_failures = $closeoutFailures
    failed_readiness_gates = $failedReadinessGates
    failed_provisioning_checks = $failedProvisioningChecks
    failed_release_evidence_checks = $failedReleaseEvidenceChecks
    next_closeout_command = "powershell -NoProfile -ExecutionPolicy Bypass -File tools\release\Complete-PassportProductionMvpCloseout.ps1 -EnvironmentFile artifacts\release\production-mvp.env -ProductionProvisioningPacketRoot <controlled-production-packet-root> -OutputDirectory artifacts\release\production-mvp-closeout -Force"
}

$resolvedOutputPath = Resolve-RepoPath -Path $OutputPath
$outputDirectory = Split-Path -Parent $resolvedOutputPath
if ($outputDirectory) {
    New-Item -ItemType Directory -Force -Path $outputDirectory | Out-Null
}

$report | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $resolvedOutputPath -Encoding UTF8

if (-not [string]::IsNullOrWhiteSpace($MarkdownOutputPath)) {
    $resolvedMarkdownPath = Resolve-RepoPath -Path $MarkdownOutputPath
    $markdownDirectory = Split-Path -Parent $resolvedMarkdownPath
    if ($markdownDirectory) {
        New-Item -ItemType Directory -Force -Path $markdownDirectory | Out-Null
    }

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("# Production MVP Outstanding Work")
    $lines.Add("")
    $lines.Add("- Generated UTC: $($report.created_utc)")
    $lines.Add("- App commit: $($report.app_commit)")
    $lines.Add("- Ready for production testing: $($report.ready_for_production_testing.ToString().ToLowerInvariant())")
    $lines.Add("- Failed readiness gates: $($failedReadinessGates.Count)")
    $lines.Add("- Failed provisioning checks: $($failedProvisioningChecks.Count)")
    $lines.Add("- Failed release-evidence checks: $($failedReleaseEvidenceChecks.Count)")
    $lines.Add("- Provisioning report source: $provisioningReportSource")
    $lines.Add("")
    if ($inputWarnings.Count -gt 0) {
        $lines.Add("## Input Warnings")
        foreach ($warning in $inputWarnings) {
            $lines.Add("- $(ConvertTo-ReportText -Value $warning)")
        }
        $lines.Add("")
    }

    $lines.Add("## Closeout Failures")
    if ($closeoutFailures.Count -eq 0) {
        $lines.Add("- None")
    }
    else {
        foreach ($failure in $closeoutFailures) {
            $lines.Add("- $failure")
        }
    }

    $lines.Add("")
    $lines.Add("## Readiness Gates")
    if ($failedReadinessGates.Count -eq 0) {
        $lines.Add("- None")
    }
    else {
        foreach ($gate in $failedReadinessGates) {
            $title = if ($null -ne $gate.operator_action -and -not [string]::IsNullOrWhiteSpace($gate.operator_action.title)) { $gate.operator_action.title } else { $gate.description }
            $lines.Add("- ``$($gate.id)``: $title")
            foreach ($missing in @($gate.missing | Select-Object -First 5)) {
                $lines.Add("  - $missing")
            }
        }
    }

    $lines.Add("")
    $lines.Add("## Provisioning Packet")
    if ($failedProvisioningChecks.Count -eq 0) {
        $lines.Add("- None")
    }
    else {
        foreach ($check in $failedProvisioningChecks) {
            $detail = if ([string]::IsNullOrWhiteSpace($check.operator_action)) { $check.description } else { $check.operator_action }
            $lines.Add("- ``$($check.id)``: $detail")
            if (-not [string]::IsNullOrWhiteSpace($check.child_report_path)) {
                $lines.Add("  - Child report: $($check.child_report_path)")
            }
            foreach ($child in @($check.child_failed_checks | Select-Object -First 5)) {
                $message = (@($child.failures) -join "; ")
                if ([string]::IsNullOrWhiteSpace($message)) {
                    $message = "failed"
                }
                $lines.Add("  - ``$($child.id)``: $message")
            }
        }
    }

    $lines.Add("")
    $lines.Add("## Release Evidence")
    if ($failedReleaseEvidenceChecks.Count -eq 0) {
        $lines.Add("- None")
    }
    else {
        foreach ($check in $failedReleaseEvidenceChecks) {
            $message = (@($check.failures) -join "; ")
            $lines.Add("- ``$($check.id)``: $message")
        }
    }

    $lines.Add("")
    $lines.Add("## Next Command")
    $lines.Add("")
    $lines.Add('```powershell')
    $lines.Add($report.next_closeout_command)
    $lines.Add('```')

    Set-Content -LiteralPath $resolvedMarkdownPath -Value $lines -Encoding UTF8
}

$result = [pscustomobject][ordered]@{
    schema = "archrealms.passport.production_mvp_outstanding_work_result.v1"
    ready_for_production_testing = $report.ready_for_production_testing
    output_path = $resolvedOutputPath
    output_sha256 = Get-Sha256Hex -Path $resolvedOutputPath
    markdown_output_path = $(if ([string]::IsNullOrWhiteSpace($MarkdownOutputPath)) { "" } else { Resolve-RepoPath -Path $MarkdownOutputPath })
    markdown_output_sha256 = $(if ([string]::IsNullOrWhiteSpace($MarkdownOutputPath)) { "" } else { Get-Sha256Hex -Path (Resolve-RepoPath -Path $MarkdownOutputPath) })
    failed_readiness_gate_count = $failedReadinessGates.Count
    failed_provisioning_check_count = $failedProvisioningChecks.Count
    failed_release_evidence_check_count = $failedReleaseEvidenceChecks.Count
}

$result | ConvertTo-Json -Depth 4

if (-not $NoFail -and -not $report.ready_for_production_testing) {
    throw "Production MVP still has outstanding work. See $resolvedOutputPath."
}
