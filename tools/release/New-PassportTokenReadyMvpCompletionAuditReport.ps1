param(
    [string]$PreMvpInternalVerificationReportPath = "artifacts\release\pre-mvp-internal-verification-report.json",
    [string]$StagingReadinessReportPath = "artifacts\release\staging-readiness-report.json",
    [string]$CanaryMvpReadinessReportPath = "artifacts\release\canary-mvp-readiness-report.json",
    [string]$ProductionMvpReadinessReportPath = "artifacts\release\production-mvp-readiness-report.json",
    [string]$ProductionMvpCloseoutManifestPath = "artifacts\release\production-mvp-closeout\production-mvp-closeout.manifest.json",
    [string]$ProductionMvpOutstandingWorkReportPath = "artifacts\release\production-mvp-outstanding-work-report.json",
    [string]$OutputPath = "artifacts\release\token-ready-mvp-completion-audit-report.json",
    [string]$MarkdownOutputPath = "artifacts\release\token-ready-mvp-completion-audit-report.md",
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

function ConvertTo-AuditText {
    param([object]$Value)

    if ($null -eq $Value) {
        return ""
    }

    $text = ([string]$Value).Trim()
    $text = $text -replace "(`r`n|`n|`r)+", " "
    if ($text.Length -gt 600) {
        return $text.Substring(0, 597) + "..."
    }

    return $text
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

function New-FileEvidence {
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

function Get-Check {
    param(
        [object]$Report,
        [string]$Id
    )

    if ($null -eq $Report -or -not $Report.PSObject.Properties["checks"]) {
        return $null
    }

    return @($Report.checks | Where-Object { [string]$_.id -eq $Id } | Select-Object -First 1)
}

function Get-Requirement {
    param(
        [object]$Report,
        [string]$Id
    )

    if ($null -eq $Report -or -not $Report.PSObject.Properties["requirements"]) {
        return $null
    }

    return @($Report.requirements | Where-Object { [string]$_.id -eq $Id } | Select-Object -First 1)
}

function Get-Gate {
    param(
        [object]$Report,
        [string]$Id
    )

    if ($null -eq $Report -or -not $Report.PSObject.Properties["gates"]) {
        return $null
    }

    return @($Report.gates | Where-Object { [string]$_.id -eq $Id } | Select-Object -First 1)
}

function Get-OutstandingGateFailures {
    param(
        [object]$OutstandingReport,
        [string]$Id
    )

    if ($null -eq $OutstandingReport -or -not $OutstandingReport.PSObject.Properties["failed_readiness_gates"]) {
        return @()
    }

    $gateMatches = @($OutstandingReport.failed_readiness_gates | Where-Object { [string]$_.id -eq $Id } | Select-Object -First 1)
    if ($gateMatches.Count -eq 0) {
        return @()
    }

    $gate = $gateMatches[0]
    return @($gate.missing | ForEach-Object { ConvertTo-AuditText -Value $_ })
}

function Get-OutstandingGateAction {
    param(
        [object]$OutstandingReport,
        [string]$Id
    )

    if ($null -eq $OutstandingReport -or -not $OutstandingReport.PSObject.Properties["failed_readiness_gates"]) {
        return @()
    }

    $gateMatches = @($OutstandingReport.failed_readiness_gates | Where-Object { [string]$_.id -eq $Id } | Select-Object -First 1)
    if ($gateMatches.Count -eq 0) {
        return @()
    }

    $gate = $gateMatches[0]
    if (-not $gate.PSObject.Properties["operator_action"] -or $null -eq $gate.operator_action) {
        return @()
    }

    $action = $gate.operator_action
    return ,([pscustomobject][ordered]@{
        gate_id = $Id
        id = ConvertTo-AuditText -Value $action.id
        title = ConvertTo-AuditText -Value $action.title
        action = ConvertTo-AuditText -Value $action.action
        commands = @($action.commands | ForEach-Object { ConvertTo-AuditText -Value $_ })
    })
}

function New-ManualAction {
    param(
        [string]$Id,
        [string]$Title,
        [string]$Action,
        [string[]]$Commands = @()
    )

    return [pscustomobject][ordered]@{
        gate_id = $Id
        id = $Id
        title = $Title
        action = $Action
        commands = @($Commands)
    }
}

function New-AuditItem {
    param(
        [string]$Id,
        [string]$Source,
        [string]$Requirement,
        [string]$Status,
        [string[]]$EvidenceIds = @(),
        [string[]]$CoverageCheckIds = @(),
        [string[]]$EvidenceNotes = @(),
        [string[]]$Blockers = @(),
        [object[]]$OperatorActions = @()
    )

    return [pscustomobject][ordered]@{
        id = $Id
        source = $Source
        requirement = $Requirement
        status = $Status
        evidence_ids = @($EvidenceIds)
        coverage_check_ids = @($CoverageCheckIds | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
        evidence_notes = @($EvidenceNotes | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
        blockers = @($Blockers | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
        operator_actions = @($OperatorActions)
    }
}

function Get-StatusFromCheckIds {
    param(
        [object]$PreMvpReport,
        [string[]]$CheckIds
    )

    if ($null -eq $PreMvpReport) {
        return "missing"
    }

    $missing = @()
    $failed = @()
    foreach ($checkId in $CheckIds) {
        $check = Get-Check -Report $PreMvpReport -Id $checkId
        if ($null -eq $check) {
            $missing += $checkId
        }
        elseif ($check.passed -ne $true) {
            $failed += $checkId
        }
    }

    if ($missing.Count -gt 0) {
        return "missing"
    }

    if ($failed.Count -gt 0) {
        return "blocked"
    }

    return "passed"
}

$files = [ordered]@{
    pre_mvp_internal_verification = New-FileEvidence -Id "pre_mvp_internal_verification" -Path $PreMvpInternalVerificationReportPath
    staging_readiness = New-FileEvidence -Id "staging_readiness" -Path $StagingReadinessReportPath
    canary_mvp_readiness = New-FileEvidence -Id "canary_mvp_readiness" -Path $CanaryMvpReadinessReportPath
    production_mvp_readiness = New-FileEvidence -Id "production_mvp_readiness" -Path $ProductionMvpReadinessReportPath
    production_mvp_closeout = New-FileEvidence -Id "production_mvp_closeout" -Path $ProductionMvpCloseoutManifestPath
    production_mvp_outstanding_work = New-FileEvidence -Id "production_mvp_outstanding_work" -Path $ProductionMvpOutstandingWorkReportPath
}

$preMvp = Read-JsonFile -Path $files.pre_mvp_internal_verification.path
$staging = Read-JsonFile -Path $files.staging_readiness.path
$canary = Read-JsonFile -Path $files.canary_mvp_readiness.path
$productionReadiness = Read-JsonFile -Path $files.production_mvp_readiness.path
$closeout = Read-JsonFile -Path $files.production_mvp_closeout.path
$outstanding = Read-JsonFile -Path $files.production_mvp_outstanding_work.path

$inputFailures = @()
foreach ($file in $files.Values) {
    if (-not $file.exists) {
        $inputFailures += "Missing audit evidence file: $($file.path)"
    }
}

$items = @()

$preMvpBlockers = @()
if ($null -eq $preMvp) {
    $preMvpBlockers += "pre-MVP internal verification report is missing"
}
elseif ($preMvp.passed -ne $true) {
    if ($preMvp.PSObject.Properties["requirements"]) {
        foreach ($requirement in @($preMvp.requirements | Where-Object { $_.passed -ne $true })) {
            $preMvpBlockers += "pre-MVP requirement did not pass: $($requirement.id)"
        }
    }
    if ($preMvp.PSObject.Properties["checks"]) {
        foreach ($check in @($preMvp.checks | Where-Object { $_.passed -ne $true })) {
            $preMvpBlockers += "pre-MVP check did not pass: $($check.id)"
        }
    }
}

$items += New-AuditItem `
    -Id "prd_success_pre_mvp_internal_verification" `
    -Source "PRD Success Criteria" `
    -Requirement "Pre-MVP Internal Verification has passed and cannot migrate fake balances into production balances." `
    -Status $(if ($null -eq $preMvp) { "missing" } elseif ($preMvp.passed -eq $true -and $preMvp.fake_balance_migration_blocked -eq $true) { "passed" } else { "blocked" }) `
    -EvidenceIds @("pre_mvp_internal_verification") `
    -EvidenceNotes @("fake_balance_migration_blocked=$($preMvp.fake_balance_migration_blocked)") `
    -Blockers $preMvpBlockers `
    -OperatorActions (Get-OutstandingGateAction -OutstandingReport $outstanding -Id "pre_mvp_internal_verification")

$items += New-AuditItem `
    -Id "prd_success_staging_readiness" `
    -Source "PRD Success Criteria" `
    -Requirement "Staging readiness has passed with isolated staging records, production-candidate package identity, production-like endpoints, rollback evidence, signed promotion approval, and no staging-to-production balance migration." `
    -Status $(if ($null -eq $staging) { "missing" } elseif ($staging.ready -eq $true) { "passed" } else { "blocked" }) `
    -EvidenceIds @("staging_readiness", "production_mvp_outstanding_work") `
    -Blockers (Get-OutstandingGateFailures -OutstandingReport $outstanding -Id "staging_readiness") `
    -OperatorActions (Get-OutstandingGateAction -OutstandingReport $outstanding -Id "staging_readiness")

$items += New-AuditItem `
    -Id "prd_success_canary_readiness" `
    -Source "PRD Success Criteria" `
    -Requirement "Canary readiness has passed with controlled real-token policy limits, reconciliation, support readiness, signed production-promotion approval, and no synthetic canary evidence." `
    -Status $(if ($null -eq $canary) { "missing" } elseif ($canary.ready -eq $true) { "passed" } else { "blocked" }) `
    -EvidenceIds @("canary_mvp_readiness", "production_mvp_outstanding_work") `
    -Blockers (Get-OutstandingGateFailures -OutstandingReport $outstanding -Id "canary_mvp_readiness") `
    -OperatorActions (Get-OutstandingGateAction -OutstandingReport $outstanding -Id "canary_mvp_readiness")

$items += New-AuditItem `
    -Id "prd_success_installable_passport" `
    -Source "PRD Success Criteria" `
    -Requirement "A citizen can install Passport without manual file-system work." `
    -Status $(if ((Get-Gate -Report $productionReadiness -Id "package_signing").passed -eq $true) { "passed" } else { "blocked" }) `
    -EvidenceIds @("production_mvp_readiness", "production_mvp_outstanding_work") `
    -EvidenceNotes @("Production package installation depends on the package_signing readiness gate and release artifact validation.") `
    -Blockers (Get-OutstandingGateFailures -OutstandingReport $outstanding -Id "package_signing") `
    -OperatorActions (Get-OutstandingGateAction -OutstandingReport $outstanding -Id "package_signing")

$identityStatus = Get-StatusFromCheckIds -PreMvpReport $preMvp -CheckIds @("windows_tests")
$items += New-AuditItem -Id "prd_success_identity_recovery" -Source "PRD Success Criteria" -Requirement "A citizen can create or recover a Passport identity." -Status $identityStatus -EvidenceIds @("pre_mvp_internal_verification") -EvidenceNotes @("Covered by Windows Passport automated tests in the pre-MVP report.")
$items += New-AuditItem -Id "prd_success_device_authorization" -Source "PRD Success Criteria" -Requirement "A citizen can authorize a device." -Status $identityStatus -EvidenceIds @("pre_mvp_internal_verification") -EvidenceNotes @("Covered by Windows Passport automated tests in the pre-MVP report.")
$items += New-AuditItem -Id "prd_success_wallet_key_binding" -Source "PRD Success Criteria" -Requirement "A citizen can bind a wallet key." -Status $identityStatus -EvidenceIds @("pre_mvp_internal_verification") -EvidenceNotes @("Covered by Windows Passport automated tests and Core wallet authorization tests.")

$storageCoverageCheckIds = @("storage_redemption_targeted_tests", "windows_monetary_ledger_targeted_tests")
$monetaryCoverageCheckIds = @("core_monetary_protocol_targeted_tests", "windows_monetary_ledger_targeted_tests")
$ledgerCoverageCheckIds = @("core_monetary_protocol_targeted_tests", "windows_monetary_ledger_targeted_tests", "ledger_verifier_build")
$aiCoverageCheckIds = @("hosted_ai_targeted_tests", "windows_ai_gateway_targeted_tests", "open_weight_ai_runtime_deployment_validation")

$issuerBlockers = Get-OutstandingGateFailures -OutstandingReport $outstanding -Id "issuer_capacity_genesis_secrets"
$items += New-AuditItem `
    -Id "prd_success_real_arch" `
    -Source "PRD Success Criteria" `
    -Requirement "Passport can hold, display, and export real fixed-genesis ARCH." `
    -Status $(if ((Get-Gate -Report $productionReadiness -Id "issuer_capacity_genesis_secrets").passed -eq $true) { "passed" } else { "blocked" }) `
    -EvidenceIds @("pre_mvp_internal_verification", "production_mvp_readiness", "production_mvp_outstanding_work") `
    -CoverageCheckIds $monetaryCoverageCheckIds `
    -EvidenceNotes @("Implementation coverage is tied to targeted monetary protocol and Windows ledger checks; production ARCH requires the approved genesis manifest and ledger namespace.") `
    -Blockers $issuerBlockers `
    -OperatorActions (Get-OutstandingGateAction -OutstandingReport $outstanding -Id "issuer_capacity_genesis_secrets")

$items += New-AuditItem `
    -Id "prd_success_real_cc" `
    -Source "PRD Success Criteria" `
    -Requirement "Passport can hold, display, and export real Crown Credit." `
    -Status $(if ((Get-Gate -Report $productionReadiness -Id "issuer_capacity_genesis_secrets").passed -eq $true) { "passed" } else { "blocked" }) `
    -EvidenceIds @("pre_mvp_internal_verification", "production_mvp_readiness", "production_mvp_outstanding_work") `
    -CoverageCheckIds $monetaryCoverageCheckIds `
    -EvidenceNotes @("Implementation coverage is tied to targeted monetary protocol and Windows ledger checks; production CC requires issuer/capacity/genesis and production ledger namespace values.") `
    -Blockers $issuerBlockers `
    -OperatorActions (Get-OutstandingGateAction -OutstandingReport $outstanding -Id "issuer_capacity_genesis_secrets")

$storageStatus = Get-StatusFromCheckIds -PreMvpReport $preMvp -CheckIds $storageCoverageCheckIds
$storageBlockers = @()
$storageBlockers += @(Get-OutstandingGateFailures -OutstandingReport $outstanding -Id "managed_storage_status")
$storageBlockers += @(Get-OutstandingGateFailures -OutstandingReport $outstanding -Id "managed_storage_backups")
$storageActions = @()
$storageActions += @(Get-OutstandingGateAction -OutstandingReport $outstanding -Id "managed_storage_status")
$storageActions += @(Get-OutstandingGateAction -OutstandingReport $outstanding -Id "managed_storage_backups")
$items += New-AuditItem `
    -Id "prd_success_storage_redemption" `
    -Source "PRD Success Criteria" `
    -Requirement "Passport can redeem CC for listed Crown-administered storage service." `
    -Status $(if ($storageStatus -eq "passed" -and $storageBlockers.Count -eq 0) { "passed" } elseif ($storageStatus -eq "passed") { "partial" } else { $storageStatus }) `
    -EvidenceIds @("pre_mvp_internal_verification", "production_mvp_readiness", "production_mvp_outstanding_work") `
    -CoverageCheckIds $storageCoverageCheckIds `
    -EvidenceNotes @("Storage redemption implementation is covered by targeted storage-redemption and Windows monetary ledger checks; production service delivery remains gated on managed storage provisioning/status.") `
    -Blockers $storageBlockers `
    -OperatorActions $storageActions

$items += New-AuditItem `
    -Id "prd_success_storage_escrow_burn_refund_recredit" `
    -Source "PRD Success Criteria" `
    -Requirement "CC redemption uses escrow, verified service delivery, burn, refund, and re-credit records." `
    -Status $(if ($storageStatus -eq "passed" -and $storageBlockers.Count -eq 0) { "passed" } elseif ($storageStatus -eq "passed") { "partial" } else { $storageStatus }) `
    -EvidenceIds @("pre_mvp_internal_verification", "production_mvp_readiness", "production_mvp_outstanding_work") `
    -CoverageCheckIds $storageCoverageCheckIds `
    -EvidenceNotes @("Proof-linked redemption and remedy paths are covered by targeted storage-redemption and Windows monetary ledger checks; production storage status is still blocked.") `
    -Blockers $storageBlockers `
    -OperatorActions $storageActions

$items += New-AuditItem -Id "prd_success_resource_contribution" -Source "PRD Success Criteria" -Requirement "Resource contribution is optional, revocable, and disclosed." -Status $storageStatus -EvidenceIds @("pre_mvp_internal_verification") -EvidenceNotes @("Covered by Windows storage contribution tests and lane artifact validation.")
$items += New-AuditItem -Id "prd_success_arch_cc_conversion" -Source "PRD Success Criteria" -Requirement "ARCH/CC conversion is available only where floating-rate liquidity exists and is disclosed." -Status (Get-StatusFromCheckIds -PreMvpReport $preMvp -CheckIds $monetaryCoverageCheckIds) -EvidenceIds @("pre_mvp_internal_verification") -CoverageCheckIds $monetaryCoverageCheckIds -EvidenceNotes @("Conversion quote/execution validation is covered by targeted monetary protocol and Windows ledger checks; external liquidity is not required by the MVP unless configured.")
$items += New-AuditItem -Id "prd_success_no_post_genesis_arch_mint" -Source "PRD/ARD Monetary Invariants" -Requirement "No post-genesis ARCH mint path exists." -Status (Get-StatusFromCheckIds -PreMvpReport $preMvp -CheckIds $monetaryCoverageCheckIds) -EvidenceIds @("pre_mvp_internal_verification") -CoverageCheckIds $monetaryCoverageCheckIds
$items += New-AuditItem -Id "prd_success_cc_capacity_constrained" -Source "PRD/ARD Monetary Invariants" -Requirement "CC issuance is constrained by conservative deliverable service capacity." -Status (Get-StatusFromCheckIds -PreMvpReport $preMvp -CheckIds @($monetaryCoverageCheckIds + "production_monetary_provisioning_validation")) -EvidenceIds @("pre_mvp_internal_verification") -CoverageCheckIds @($monetaryCoverageCheckIds + "production_monetary_provisioning_validation")
$items += New-AuditItem -Id "prd_success_cc_does_not_create_arch" -Source "PRD/ARD Monetary Invariants" -Requirement "CC issuance cannot create ARCH or add ARCH to Crown reserves." -Status (Get-StatusFromCheckIds -PreMvpReport $preMvp -CheckIds @($monetaryCoverageCheckIds + "production_monetary_provisioning_validation")) -EvidenceIds @("pre_mvp_internal_verification") -CoverageCheckIds @($monetaryCoverageCheckIds + "production_monetary_provisioning_validation")
$items += New-AuditItem -Id "prd_success_ledger_export_auditability" -Source "PRD/ARD Ledger and Export" -Requirement "Ledger events are signed, replayable, exportable, and correction-safe." -Status (Get-StatusFromCheckIds -PreMvpReport $preMvp -CheckIds $ledgerCoverageCheckIds) -EvidenceIds @("pre_mvp_internal_verification") -CoverageCheckIds $ledgerCoverageCheckIds

$aiBlockers = @()
$aiBlockers += @(Get-OutstandingGateFailures -OutstandingReport $outstanding -Id "open_weight_ai_runtime")
$aiBlockers += @(Get-OutstandingGateFailures -OutstandingReport $outstanding -Id "hosted_ai_runtime_probe")
$aiActions = @()
$aiActions += @(Get-OutstandingGateAction -OutstandingReport $outstanding -Id "open_weight_ai_runtime")
$aiActions += @(Get-OutstandingGateAction -OutstandingReport $outstanding -Id "hosted_ai_runtime_probe")
$aiImplementationStatus = Get-StatusFromCheckIds -PreMvpReport $preMvp -CheckIds $aiCoverageCheckIds
$items += New-AuditItem `
    -Id "prd_success_hosted_ai" `
    -Source "PRD Success Criteria" `
    -Requirement "Hosted AI is authenticated, privacy-bounded, non-authoritative, and quota-controlled." `
    -Status $(if ($aiImplementationStatus -eq "passed" -and $aiBlockers.Count -eq 0) { "passed" } elseif ($aiImplementationStatus -eq "passed") { "partial" } else { $aiImplementationStatus }) `
    -EvidenceIds @("pre_mvp_internal_verification", "production_mvp_readiness", "production_mvp_outstanding_work") `
    -CoverageCheckIds $aiCoverageCheckIds `
    -EvidenceNotes @("Hosted AI implementation coverage is tied to targeted hosted AI, Windows AI gateway, and open-weight runtime deployment checks; production open-weight model runtime and live probe remain blocked until provisioned.") `
    -Blockers $aiBlockers `
    -OperatorActions $aiActions

$releaseApprovalBlockers = Get-OutstandingGateFailures -OutstandingReport $outstanding -Id "production_release_approvals"
$items += New-AuditItem `
    -Id "ard_release_legal_tax_accounting_custody_privacy_security" `
    -Source "ARD Release Gates" `
    -Requirement "Legal, tax, accounting, custody, privacy, and security reviews are complete for citizen-facing real ARCH and real CC." `
    -Status $(if ((Get-Gate -Report $productionReadiness -Id "production_release_approvals").passed -eq $true) { "passed" } else { "blocked" }) `
    -EvidenceIds @("production_mvp_readiness", "production_mvp_outstanding_work") `
    -Blockers $releaseApprovalBlockers `
    -OperatorActions (Get-OutstandingGateAction -OutstandingReport $outstanding -Id "production_release_approvals")

$closeoutActions = @()
if ($null -ne $outstanding -and $outstanding.PSObject.Properties["next_closeout_command"] -and -not [string]::IsNullOrWhiteSpace([string]$outstanding.next_closeout_command)) {
    $closeoutActions += New-ManualAction `
        -Id "production_mvp_closeout" `
        -Title "Rerun Production MVP closeout" `
        -Action "Resolve the closeout, readiness, provisioning, and release-evidence failures, then rerun the fail-closed ProductionMvp closeout." `
        -Commands @([string]$outstanding.next_closeout_command)
}

$items += New-AuditItem `
    -Id "production_mvp_closeout" `
    -Source "Final Closeout" `
    -Requirement "Production MVP closeout has passed with filled production provisioning, ready ProductionMvp report, and RequireReady release evidence." `
    -Status $(if ($null -eq $closeout) { "missing" } elseif ($closeout.passed -eq $true) { "passed" } else { "blocked" }) `
    -EvidenceIds @("production_mvp_closeout", "production_mvp_readiness", "production_mvp_outstanding_work") `
    -Blockers @($closeout.failures | ForEach-Object { ConvertTo-AuditText -Value $_ }) `
    -OperatorActions $closeoutActions

$statusGroups = $items | Group-Object -Property status
$statusCounts = [ordered]@{}
foreach ($group in $statusGroups) {
    $statusCounts[$group.Name] = $group.Count
}

$completionReady = (
    $inputFailures.Count -eq 0 -and
    @($items | Where-Object { $_.status -ne "passed" }).Count -eq 0
)

$report = [pscustomobject][ordered]@{
    schema = "archrealms.passport.token_ready_mvp_completion_audit.v1"
    created_utc = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
    app_commit = Get-CurrentCommit
    completion_ready = $completionReady
    input_failures = $inputFailures
    source_files = $files
    status_counts = $statusCounts
    checklist = $items
    outstanding_summary = $(if ($null -ne $outstanding -and $outstanding.PSObject.Properties["summary"]) { $outstanding.summary } else { $null })
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
    $lines.Add("# Token-Ready MVP Completion Audit")
    $lines.Add("")
    $lines.Add("- Generated UTC: $($report.created_utc)")
    $lines.Add("- App commit: $($report.app_commit)")
    $lines.Add("- Completion ready: $($report.completion_ready.ToString().ToLowerInvariant())")
    foreach ($key in @($statusCounts.Keys | Sort-Object)) {
        $lines.Add("- $key items: $($statusCounts[$key])")
    }
    if ($inputFailures.Count -gt 0) {
        $lines.Add("")
        $lines.Add("## Input Failures")
        foreach ($failure in $inputFailures) {
            $lines.Add("- $failure")
        }
    }

    $lines.Add("")
    $lines.Add("## Checklist")
    foreach ($item in $items) {
        $lines.Add("- ``$($item.id)`` [$($item.status)]: $($item.requirement)")
        if (@($item.evidence_ids).Count -gt 0) {
            $lines.Add("  - Evidence: $((@($item.evidence_ids) -join ', '))")
        }
        if (@($item.coverage_check_ids).Count -gt 0) {
            $lines.Add("  - Coverage checks: $((@($item.coverage_check_ids) -join ', '))")
        }
        foreach ($note in @($item.evidence_notes | Select-Object -First 2)) {
            $lines.Add("  - Note: $note")
        }
        foreach ($blocker in @($item.blockers | Select-Object -First 3)) {
            $lines.Add("  - Blocker: $blocker")
        }
        if (@($item.blockers).Count -gt 3) {
            $lines.Add("  - ...$(@($item.blockers).Count - 3) more blockers in JSON report")
        }
        foreach ($action in @($item.operator_actions | Select-Object -First 2)) {
            if (-not [string]::IsNullOrWhiteSpace([string]$action.action)) {
                $lines.Add("  - Next: $($action.action)")
            }
            foreach ($command in @($action.commands | Select-Object -First 2)) {
                $lines.Add("  - Command: ``$command``")
            }
        }
        if (@($item.operator_actions).Count -gt 2) {
            $lines.Add("  - ...$(@($item.operator_actions).Count - 2) more operator actions in JSON report")
        }
    }

    Set-Content -LiteralPath $resolvedMarkdownPath -Value $lines -Encoding UTF8
}

$result = [pscustomobject][ordered]@{
    schema = "archrealms.passport.token_ready_mvp_completion_audit_result.v1"
    completion_ready = $report.completion_ready
    output_path = $resolvedOutputPath
    output_sha256 = Get-Sha256Hex -Path $resolvedOutputPath
    markdown_output_path = $(if ([string]::IsNullOrWhiteSpace($MarkdownOutputPath)) { "" } else { Resolve-RepoPath -Path $MarkdownOutputPath })
    markdown_output_sha256 = $(if ([string]::IsNullOrWhiteSpace($MarkdownOutputPath)) { "" } else { Get-Sha256Hex -Path (Resolve-RepoPath -Path $MarkdownOutputPath) })
    status_counts = $statusCounts
}

$result | ConvertTo-Json -Depth 6

if (-not $NoFail -and -not $report.completion_ready) {
    throw "Token-Ready MVP completion audit is not complete. See $resolvedOutputPath."
}
