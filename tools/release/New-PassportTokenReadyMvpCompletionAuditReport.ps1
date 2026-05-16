param(
    [string]$PreMvpInternalVerificationReportPath = "artifacts\release\pre-mvp-internal-verification-report.json",
    [string]$StagingReadinessReportPath = "artifacts\release\staging-readiness-report.json",
    [string]$CanaryMvpReadinessReportPath = "artifacts\release\canary-mvp-readiness-report.json",
    [string]$ProductionMvpReadinessReportPath = "artifacts\release\production-mvp-readiness-report.json",
    [string]$ProductionMvpCloseoutManifestPath = "artifacts\release\production-mvp-closeout\production-mvp-closeout.manifest.json",
    [string]$ProductionMvpOutstandingWorkReportPath = "artifacts\release\production-mvp-outstanding-work-report.json",
    [string]$ProductionMvpNextActionPacketManifestPath = "artifacts\release\production-mvp-next-action-packet\production-mvp-next-action-packet.manifest.json",
    [string]$ProductionMvpNextActionPlanPath = "artifacts\release\production-mvp-next-action-packet\next-action-plan.json",
    [string]$ProductionMvpNextActionPlanMarkdownPath = "artifacts\release\production-mvp-next-action-packet\next-action-plan.md",
    [string]$ProductionMvpOperatorInputMatrixPath = "artifacts\release\production-mvp-next-action-packet\operator-input-matrix.json",
    [string]$ProductionMvpOperatorInputMatrixMarkdownPath = "artifacts\release\production-mvp-next-action-packet\operator-input-matrix.md",
    [string]$ProductionMvpOperatorCommandsPath = "artifacts\release\production-mvp-next-action-packet\operator-commands.ps1",
    [string]$ProductionMvpOperatorCommandPhaseManifestPath = "artifacts\release\production-mvp-next-action-packet\operator-command-phases.manifest.json",
    [string]$ProductionMvpNextActionPacketValidationReportPath = "artifacts\release\production-mvp-next-action-packet-validation-report.json",
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

function Get-OutstandingProvisioningFailures {
    param(
        [object]$OutstandingReport,
        [string]$Id
    )

    if ($null -eq $OutstandingReport -or -not $OutstandingReport.PSObject.Properties["failed_provisioning_checks"]) {
        return @()
    }

    $matches = @($OutstandingReport.failed_provisioning_checks | Where-Object { [string]$_.id -eq $Id } | Select-Object -First 1)
    if ($matches.Count -eq 0) {
        return @()
    }

    $check = $matches[0]
    $summary = ConvertTo-AuditText -Value $check.summary
    if (-not [string]::IsNullOrWhiteSpace($summary)) {
        return @($summary)
    }

    return @("production provisioning check did not pass: $Id")
}

function Get-OutstandingProvisioningAction {
    param(
        [object]$OutstandingReport,
        [string]$Id
    )

    if ($null -eq $OutstandingReport -or -not $OutstandingReport.PSObject.Properties["failed_provisioning_checks"]) {
        return @()
    }

    $matches = @($OutstandingReport.failed_provisioning_checks | Where-Object { [string]$_.id -eq $Id } | Select-Object -First 1)
    if ($matches.Count -eq 0) {
        return @()
    }

    $check = $matches[0]
    if (-not $check.PSObject.Properties["operator_action"] -or $null -eq $check.operator_action) {
        return @()
    }

    $action = $check.operator_action
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

function New-AuditItemSummary {
    param(
        [string]$Requirement,
        [string]$Status,
        [string[]]$Blockers = @(),
        [object[]]$OperatorActions = @()
    )

    $parts = @()
    $requirementText = ConvertTo-AuditText -Value $Requirement
    if (-not [string]::IsNullOrWhiteSpace($requirementText)) {
        $parts += "$($Status): $requirementText"
    }

    $firstBlocker = @($Blockers | ForEach-Object { ConvertTo-AuditText -Value $_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 1)
    if ($firstBlocker.Count -gt 0) {
        $parts += "Blocker: $($firstBlocker[0])"
    }

    $firstAction = @($OperatorActions | Where-Object { $null -ne $_ -and $_.PSObject.Properties["action"] -and -not [string]::IsNullOrWhiteSpace([string]$_.action) } | Select-Object -First 1)
    if ($firstAction.Count -gt 0) {
        $parts += "Next: $(ConvertTo-AuditText -Value $firstAction[0].action)"
    }

    return ConvertTo-AuditText -Value (($parts | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join " ")
}

function Get-PrimaryOperatorAction {
    param([object[]]$OperatorActions = @())

    $actions = @($OperatorActions | Where-Object {
            $null -ne $_ -and
            $_.PSObject.Properties["action"] -and
            -not [string]::IsNullOrWhiteSpace([string]$_.action)
        } | Select-Object -First 1)

    if ($actions.Count -eq 0) {
        return $null
    }

    return $actions[0]
}

function New-AuditItem {
    param(
        [string]$Id,
        [string]$Source,
        [string]$Requirement,
        [string]$Status,
        [string[]]$EvidenceIds = @(),
        [string[]]$CoverageCheckIds = @(),
        [object[]]$CoverageEvidence = @(),
        [string[]]$EvidenceNotes = @(),
        [string[]]$Blockers = @(),
        [object[]]$OperatorActions = @(),
        [string]$RemainingWorkType = "",
        [object]$ImplementationReady = $null
    )

    $primaryAction = Get-PrimaryOperatorAction -OperatorActions $OperatorActions
    $nextActionCommands = @()
    if ($null -ne $primaryAction -and $primaryAction.PSObject.Properties["commands"]) {
        $nextActionCommands = @($primaryAction.commands | ForEach-Object { ConvertTo-AuditText -Value $_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    }

    if ($Status -eq "passed") {
        $workType = "none"
        $ready = $true
    }
    else {
        $workType = ConvertTo-AuditText -Value $RemainingWorkType
        if ([string]::IsNullOrWhiteSpace($workType)) {
            $workType = "unclassified"
        }

        $ready = if ($null -eq $ImplementationReady) { $false } else { [bool]$ImplementationReady }
    }

    return [pscustomobject][ordered]@{
        id = $Id
        source = $Source
        requirement = $Requirement
        summary = New-AuditItemSummary -Requirement $Requirement -Status $Status -Blockers $Blockers -OperatorActions $OperatorActions
        status = $Status
        remaining_work_type = $workType
        implementation_ready = $ready
        next_action_id = $(if ($null -ne $primaryAction -and $primaryAction.PSObject.Properties["id"]) { ConvertTo-AuditText -Value $primaryAction.id } else { "" })
        next_action_title = $(if ($null -ne $primaryAction -and $primaryAction.PSObject.Properties["title"]) { ConvertTo-AuditText -Value $primaryAction.title } else { "" })
        next_action = $(if ($null -ne $primaryAction) { ConvertTo-AuditText -Value $primaryAction.action } else { "" })
        next_action_commands = @($nextActionCommands)
        evidence_ids = @($EvidenceIds)
        coverage_check_ids = @($CoverageCheckIds | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
        coverage_evidence = @($CoverageEvidence)
        evidence_notes = @($EvidenceNotes | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
        blockers = @($Blockers | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
        operator_actions = @($OperatorActions)
    }
}

function Get-CoverageEvidence {
    param(
        [object]$PreMvpReport,
        [string[]]$CheckIds
    )

    $coverage = @()
    foreach ($checkId in @($CheckIds | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })) {
        $check = Get-Check -Report $PreMvpReport -Id $checkId
        if ($null -eq $check) {
            $coverage += [pscustomobject][ordered]@{
                check_id = $checkId
                present = $false
                passed = $false
                description = ""
                failure_count = 1
                failures = @("coverage check missing from pre-MVP report")
                evidence = $null
            }
            continue
        }

        $failures = @()
        if ($check.PSObject.Properties["failures"]) {
            $failures = @($check.failures | ForEach-Object { ConvertTo-AuditText -Value $_ })
        }

        $coverage += [pscustomobject][ordered]@{
            check_id = $checkId
            present = $true
            passed = ($check.passed -eq $true)
            description = ConvertTo-AuditText -Value $check.description
            failure_count = $failures.Count
            failures = $failures
            evidence = $(if ($check.PSObject.Properties["evidence"]) { $check.evidence } else { $null })
        }
    }

    return @($coverage)
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

function Test-PreMvpImplementationReady {
    param([object]$PreMvpReport)

    if ($null -eq $PreMvpReport -or -not $PreMvpReport.PSObject.Properties["checks"]) {
        return $false
    }

    $externalCheckIds = @(
        "simulation_run_evidence",
        "staff_steward_pilot_evidence"
    )
    $failedLocalChecks = @($PreMvpReport.checks | Where-Object {
            $_.passed -ne $true -and
            ($externalCheckIds -notcontains [string]$_.id)
        })

    return ($failedLocalChecks.Count -eq 0)
}

$files = [ordered]@{
    pre_mvp_internal_verification = New-FileEvidence -Id "pre_mvp_internal_verification" -Path $PreMvpInternalVerificationReportPath
    staging_readiness = New-FileEvidence -Id "staging_readiness" -Path $StagingReadinessReportPath
    canary_mvp_readiness = New-FileEvidence -Id "canary_mvp_readiness" -Path $CanaryMvpReadinessReportPath
    production_mvp_readiness = New-FileEvidence -Id "production_mvp_readiness" -Path $ProductionMvpReadinessReportPath
    production_mvp_closeout = New-FileEvidence -Id "production_mvp_closeout" -Path $ProductionMvpCloseoutManifestPath
    production_mvp_outstanding_work = New-FileEvidence -Id "production_mvp_outstanding_work" -Path $ProductionMvpOutstandingWorkReportPath
    production_mvp_next_action_packet_manifest = New-FileEvidence -Id "production_mvp_next_action_packet_manifest" -Path $ProductionMvpNextActionPacketManifestPath
    production_mvp_next_action_plan = New-FileEvidence -Id "production_mvp_next_action_plan" -Path $ProductionMvpNextActionPlanPath
    production_mvp_next_action_plan_markdown = New-FileEvidence -Id "production_mvp_next_action_plan_markdown" -Path $ProductionMvpNextActionPlanMarkdownPath
    production_mvp_operator_input_matrix = New-FileEvidence -Id "production_mvp_operator_input_matrix" -Path $ProductionMvpOperatorInputMatrixPath
    production_mvp_operator_input_matrix_markdown = New-FileEvidence -Id "production_mvp_operator_input_matrix_markdown" -Path $ProductionMvpOperatorInputMatrixMarkdownPath
    production_mvp_operator_commands = New-FileEvidence -Id "production_mvp_operator_commands" -Path $ProductionMvpOperatorCommandsPath
    production_mvp_operator_command_phase_manifest = New-FileEvidence -Id "production_mvp_operator_command_phase_manifest" -Path $ProductionMvpOperatorCommandPhaseManifestPath
    production_mvp_next_action_packet_validation = New-FileEvidence -Id "production_mvp_next_action_packet_validation" -Path $ProductionMvpNextActionPacketValidationReportPath
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
$preMvpImplementationReady = Test-PreMvpImplementationReady -PreMvpReport $preMvp

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
    -OperatorActions (Get-OutstandingGateAction -OutstandingReport $outstanding -Id "pre_mvp_internal_verification") `
    -RemainingWorkType "external_verification" `
    -ImplementationReady $preMvpImplementationReady

$items += New-AuditItem `
    -Id "prd_success_staging_readiness" `
    -Source "PRD Success Criteria" `
    -Requirement "Staging readiness has passed with isolated staging records, production-candidate package identity, production-like endpoints, rollback evidence, signed promotion approval, and no staging-to-production balance migration." `
    -Status $(if ($null -eq $staging) { "missing" } elseif ($staging.ready -eq $true) { "passed" } else { "blocked" }) `
    -EvidenceIds @("staging_readiness", "production_mvp_outstanding_work") `
    -Blockers (Get-OutstandingGateFailures -OutstandingReport $outstanding -Id "staging_readiness") `
    -OperatorActions (Get-OutstandingGateAction -OutstandingReport $outstanding -Id "staging_readiness") `
    -RemainingWorkType "staging_provisioning" `
    -ImplementationReady $preMvpImplementationReady

$items += New-AuditItem `
    -Id "prd_success_canary_readiness" `
    -Source "PRD Success Criteria" `
    -Requirement "Canary readiness has passed with controlled real-token policy limits, reconciliation, support readiness, signed production-promotion approval, and no synthetic canary evidence." `
    -Status $(if ($null -eq $canary) { "missing" } elseif ($canary.ready -eq $true) { "passed" } else { "blocked" }) `
    -EvidenceIds @("canary_mvp_readiness", "production_mvp_outstanding_work") `
    -Blockers (Get-OutstandingGateFailures -OutstandingReport $outstanding -Id "canary_mvp_readiness") `
    -OperatorActions (Get-OutstandingGateAction -OutstandingReport $outstanding -Id "canary_mvp_readiness") `
    -RemainingWorkType "canary_provisioning" `
    -ImplementationReady $preMvpImplementationReady

$items += New-AuditItem `
    -Id "prd_success_installable_passport" `
    -Source "PRD Success Criteria" `
    -Requirement "A citizen can install Passport without manual file-system work." `
    -Status $(if ((Get-Gate -Report $productionReadiness -Id "package_signing").passed -eq $true) { "passed" } else { "blocked" }) `
    -EvidenceIds @("production_mvp_readiness", "production_mvp_outstanding_work") `
    -EvidenceNotes @("Production package installation depends on the package_signing readiness gate and release artifact validation.") `
    -Blockers (Get-OutstandingGateFailures -OutstandingReport $outstanding -Id "package_signing") `
    -OperatorActions (Get-OutstandingGateAction -OutstandingReport $outstanding -Id "package_signing") `
    -RemainingWorkType "package_signing" `
    -ImplementationReady $preMvpImplementationReady

$identityCoverageCheckIds = @("windows_identity_recovery_targeted_tests")
$deviceCoverageCheckIds = @("windows_device_authorization_targeted_tests")
$walletCoverageCheckIds = @("windows_wallet_key_targeted_tests", "core_wallet_binding_targeted_tests")
$resourceCoverageCheckIds = @("windows_resource_contribution_targeted_tests")
$storageCoverageCheckIds = @("storage_redemption_targeted_tests", "windows_monetary_ledger_targeted_tests")
$monetaryCoverageCheckIds = @("core_monetary_protocol_targeted_tests", "windows_monetary_ledger_targeted_tests")
$ledgerCoverageCheckIds = @("core_monetary_protocol_targeted_tests", "windows_monetary_ledger_targeted_tests", "ledger_verifier_build")
$aiCoverageCheckIds = @("hosted_ai_targeted_tests", "windows_ai_gateway_targeted_tests", "open_weight_ai_runtime_deployment_validation")

$items += New-AuditItem -Id "prd_success_identity_recovery" -Source "PRD Success Criteria" -Requirement "A citizen can create or recover a Passport identity." -Status (Get-StatusFromCheckIds -PreMvpReport $preMvp -CheckIds $identityCoverageCheckIds) -EvidenceIds @("pre_mvp_internal_verification") -CoverageCheckIds $identityCoverageCheckIds -CoverageEvidence (Get-CoverageEvidence -PreMvpReport $preMvp -CheckIds $identityCoverageCheckIds) -EvidenceNotes @("Covered by targeted Windows identity/recovery tests in the pre-MVP report.")
$items += New-AuditItem -Id "prd_success_device_authorization" -Source "PRD Success Criteria" -Requirement "A citizen can authorize a device." -Status (Get-StatusFromCheckIds -PreMvpReport $preMvp -CheckIds $deviceCoverageCheckIds) -EvidenceIds @("pre_mvp_internal_verification") -CoverageCheckIds $deviceCoverageCheckIds -CoverageEvidence (Get-CoverageEvidence -PreMvpReport $preMvp -CheckIds $deviceCoverageCheckIds) -EvidenceNotes @("Covered by targeted Windows device authorization tests in the pre-MVP report.")
$items += New-AuditItem -Id "prd_success_wallet_key_binding" -Source "PRD Success Criteria" -Requirement "A citizen can bind a wallet key." -Status (Get-StatusFromCheckIds -PreMvpReport $preMvp -CheckIds $walletCoverageCheckIds) -EvidenceIds @("pre_mvp_internal_verification") -CoverageCheckIds $walletCoverageCheckIds -CoverageEvidence (Get-CoverageEvidence -PreMvpReport $preMvp -CheckIds $walletCoverageCheckIds) -EvidenceNotes @("Covered by targeted Windows wallet-key and Core wallet authorization tests.")

$issuerBlockers = Get-OutstandingGateFailures -OutstandingReport $outstanding -Id "issuer_capacity_genesis_secrets"
$monetaryImplementationReady = (Get-StatusFromCheckIds -PreMvpReport $preMvp -CheckIds $monetaryCoverageCheckIds) -eq "passed"
$items += New-AuditItem `
    -Id "prd_success_real_arch" `
    -Source "PRD Success Criteria" `
    -Requirement "Passport can hold, display, and export real fixed-genesis ARCH." `
    -Status $(if ((Get-Gate -Report $productionReadiness -Id "issuer_capacity_genesis_secrets").passed -eq $true) { "passed" } else { "blocked" }) `
    -EvidenceIds @("pre_mvp_internal_verification", "production_mvp_readiness", "production_mvp_outstanding_work") `
    -CoverageCheckIds $monetaryCoverageCheckIds `
    -CoverageEvidence (Get-CoverageEvidence -PreMvpReport $preMvp -CheckIds $monetaryCoverageCheckIds) `
    -EvidenceNotes @("Implementation coverage is tied to targeted monetary protocol and Windows ledger checks; production ARCH requires the approved genesis manifest and ledger namespace.") `
    -Blockers $issuerBlockers `
    -OperatorActions (Get-OutstandingGateAction -OutstandingReport $outstanding -Id "issuer_capacity_genesis_secrets") `
    -RemainingWorkType "monetary_provisioning" `
    -ImplementationReady $monetaryImplementationReady

$items += New-AuditItem `
    -Id "prd_success_real_cc" `
    -Source "PRD Success Criteria" `
    -Requirement "Passport can hold, display, and export real Crown Credit." `
    -Status $(if ((Get-Gate -Report $productionReadiness -Id "issuer_capacity_genesis_secrets").passed -eq $true) { "passed" } else { "blocked" }) `
    -EvidenceIds @("pre_mvp_internal_verification", "production_mvp_readiness", "production_mvp_outstanding_work") `
    -CoverageCheckIds $monetaryCoverageCheckIds `
    -CoverageEvidence (Get-CoverageEvidence -PreMvpReport $preMvp -CheckIds $monetaryCoverageCheckIds) `
    -EvidenceNotes @("Implementation coverage is tied to targeted monetary protocol and Windows ledger checks; production CC requires issuer/capacity/genesis and production ledger namespace values.") `
    -Blockers $issuerBlockers `
    -OperatorActions (Get-OutstandingGateAction -OutstandingReport $outstanding -Id "issuer_capacity_genesis_secrets") `
    -RemainingWorkType "monetary_provisioning" `
    -ImplementationReady $monetaryImplementationReady

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
    -CoverageEvidence (Get-CoverageEvidence -PreMvpReport $preMvp -CheckIds $storageCoverageCheckIds) `
    -EvidenceNotes @("Storage redemption implementation is covered by targeted storage-redemption and Windows monetary ledger checks; production service delivery remains gated on managed storage provisioning/status.") `
    -Blockers $storageBlockers `
    -OperatorActions $storageActions `
    -RemainingWorkType "managed_storage_provisioning" `
    -ImplementationReady ($storageStatus -eq "passed")

$items += New-AuditItem `
    -Id "prd_success_storage_escrow_burn_refund_recredit" `
    -Source "PRD Success Criteria" `
    -Requirement "CC redemption uses escrow, verified service delivery, burn, refund, and re-credit records." `
    -Status $(if ($storageStatus -eq "passed" -and $storageBlockers.Count -eq 0) { "passed" } elseif ($storageStatus -eq "passed") { "partial" } else { $storageStatus }) `
    -EvidenceIds @("pre_mvp_internal_verification", "production_mvp_readiness", "production_mvp_outstanding_work") `
    -CoverageCheckIds $storageCoverageCheckIds `
    -CoverageEvidence (Get-CoverageEvidence -PreMvpReport $preMvp -CheckIds $storageCoverageCheckIds) `
    -EvidenceNotes @("Proof-linked redemption and remedy paths are covered by targeted storage-redemption and Windows monetary ledger checks; production storage status is still blocked.") `
    -Blockers $storageBlockers `
    -OperatorActions $storageActions `
    -RemainingWorkType "managed_storage_provisioning" `
    -ImplementationReady ($storageStatus -eq "passed")

$capacityCoverageCheckIds = @($monetaryCoverageCheckIds + "production_monetary_provisioning_validation")
$items += New-AuditItem -Id "prd_success_resource_contribution" -Source "PRD Success Criteria" -Requirement "Resource contribution is optional, revocable, and disclosed." -Status (Get-StatusFromCheckIds -PreMvpReport $preMvp -CheckIds $resourceCoverageCheckIds) -EvidenceIds @("pre_mvp_internal_verification") -CoverageCheckIds $resourceCoverageCheckIds -CoverageEvidence (Get-CoverageEvidence -PreMvpReport $preMvp -CheckIds $resourceCoverageCheckIds) -EvidenceNotes @("Covered by targeted Windows resource contribution tests and lane artifact validation.")
$items += New-AuditItem -Id "prd_success_arch_cc_conversion" -Source "PRD Success Criteria" -Requirement "ARCH/CC conversion is available only where floating-rate liquidity exists and is disclosed." -Status (Get-StatusFromCheckIds -PreMvpReport $preMvp -CheckIds $monetaryCoverageCheckIds) -EvidenceIds @("pre_mvp_internal_verification") -CoverageCheckIds $monetaryCoverageCheckIds -CoverageEvidence (Get-CoverageEvidence -PreMvpReport $preMvp -CheckIds $monetaryCoverageCheckIds) -EvidenceNotes @("Conversion quote/execution validation is covered by targeted monetary protocol and Windows ledger checks; external liquidity is not required by the MVP unless configured.")
$items += New-AuditItem -Id "prd_success_no_post_genesis_arch_mint" -Source "PRD/ARD Monetary Invariants" -Requirement "No post-genesis ARCH mint path exists." -Status (Get-StatusFromCheckIds -PreMvpReport $preMvp -CheckIds $monetaryCoverageCheckIds) -EvidenceIds @("pre_mvp_internal_verification") -CoverageCheckIds $monetaryCoverageCheckIds -CoverageEvidence (Get-CoverageEvidence -PreMvpReport $preMvp -CheckIds $monetaryCoverageCheckIds)
$items += New-AuditItem -Id "prd_success_cc_capacity_constrained" -Source "PRD/ARD Monetary Invariants" -Requirement "CC issuance is constrained by conservative deliverable service capacity." -Status (Get-StatusFromCheckIds -PreMvpReport $preMvp -CheckIds $capacityCoverageCheckIds) -EvidenceIds @("pre_mvp_internal_verification") -CoverageCheckIds $capacityCoverageCheckIds -CoverageEvidence (Get-CoverageEvidence -PreMvpReport $preMvp -CheckIds $capacityCoverageCheckIds)
$items += New-AuditItem -Id "prd_success_cc_does_not_create_arch" -Source "PRD/ARD Monetary Invariants" -Requirement "CC issuance cannot create ARCH or add ARCH to Crown reserves." -Status (Get-StatusFromCheckIds -PreMvpReport $preMvp -CheckIds $capacityCoverageCheckIds) -EvidenceIds @("pre_mvp_internal_verification") -CoverageCheckIds $capacityCoverageCheckIds -CoverageEvidence (Get-CoverageEvidence -PreMvpReport $preMvp -CheckIds $capacityCoverageCheckIds)
$items += New-AuditItem -Id "prd_success_ledger_export_auditability" -Source "PRD/ARD Ledger and Export" -Requirement "Ledger events are signed, replayable, exportable, and correction-safe." -Status (Get-StatusFromCheckIds -PreMvpReport $preMvp -CheckIds $ledgerCoverageCheckIds) -EvidenceIds @("pre_mvp_internal_verification") -CoverageCheckIds $ledgerCoverageCheckIds -CoverageEvidence (Get-CoverageEvidence -PreMvpReport $preMvp -CheckIds $ledgerCoverageCheckIds)

$monetaryProvisioningBlockers = @()
$monetaryProvisioningBlockers += @($issuerBlockers)
$monetaryProvisioningBlockers += @(Get-OutstandingProvisioningFailures -OutstandingReport $outstanding -Id "production_monetary_provisioning")
$monetaryProvisioningActions = @()
$monetaryProvisioningActions += @(Get-OutstandingGateAction -OutstandingReport $outstanding -Id "issuer_capacity_genesis_secrets")
$monetaryProvisioningActions += @(Get-OutstandingProvisioningAction -OutstandingReport $outstanding -Id "production_monetary_provisioning")
$monetaryProvisioningComplete = (
    (Get-Gate -Report $productionReadiness -Id "issuer_capacity_genesis_secrets").passed -eq $true -and
    (Get-OutstandingProvisioningFailures -OutstandingReport $outstanding -Id "production_monetary_provisioning").Count -eq 0
)
$capacityImplementationReady = (Get-StatusFromCheckIds -PreMvpReport $preMvp -CheckIds $capacityCoverageCheckIds) -eq "passed"

$items += New-AuditItem `
    -Id "prd_required_arch_genesis_decision" `
    -Source "PRD Required Decisions Before MVP Release" `
    -Requirement "ARCH genesis total supply, base-unit precision, allocation, vesting or lock rules if any, treasury policy, and genesis ledger hash are defined." `
    -Status $(if ($monetaryProvisioningComplete) { "passed" } else { "blocked" }) `
    -EvidenceIds @("pre_mvp_internal_verification", "production_mvp_readiness", "production_mvp_outstanding_work", "production_mvp_operator_input_matrix") `
    -CoverageCheckIds $monetaryCoverageCheckIds `
    -CoverageEvidence (Get-CoverageEvidence -PreMvpReport $preMvp -CheckIds $monetaryCoverageCheckIds) `
    -EvidenceNotes @("The local monetary implementation is validated; production release requires approved issuer/capacity/genesis IDs and a filled production monetary provisioning packet.") `
    -Blockers $monetaryProvisioningBlockers `
    -OperatorActions $monetaryProvisioningActions `
    -RemainingWorkType "monetary_provisioning" `
    -ImplementationReady $monetaryImplementationReady

$items += New-AuditItem `
    -Id "prd_required_cc_issuance_decision" `
    -Source "PRD Required Decisions Before MVP Release" `
    -Requirement "CC issuance conservative service-capacity methodology, issuance authority, issuance records, capacity reports, and no-ARCH-creation validation are defined." `
    -Status $(if ($monetaryProvisioningComplete -and $capacityImplementationReady) { "passed" } else { "blocked" }) `
    -EvidenceIds @("pre_mvp_internal_verification", "production_mvp_readiness", "production_mvp_outstanding_work", "production_mvp_operator_input_matrix") `
    -CoverageCheckIds $capacityCoverageCheckIds `
    -CoverageEvidence (Get-CoverageEvidence -PreMvpReport $preMvp -CheckIds $capacityCoverageCheckIds) `
    -EvidenceNotes @("The conservative-capacity and no-ARCH-creation rules are locally validated; production release requires the filled monetary provisioning packet and authority identifiers.") `
    -Blockers $monetaryProvisioningBlockers `
    -OperatorActions $monetaryProvisioningActions `
    -RemainingWorkType "monetary_provisioning" `
    -ImplementationReady $capacityImplementationReady

$listedServiceBlockers = @()
$listedServiceBlockers += @(Get-OutstandingProvisioningFailures -OutstandingReport $outstanding -Id "managed_storage_provisioning")
$listedServiceBlockers += @($storageBlockers)
$listedServiceActions = @()
$listedServiceActions += @(Get-OutstandingProvisioningAction -OutstandingReport $outstanding -Id "managed_storage_provisioning")
$listedServiceActions += @($storageActions)
$listedServiceComplete = (
    (Get-OutstandingProvisioningFailures -OutstandingReport $outstanding -Id "managed_storage_provisioning").Count -eq 0 -and
    $storageBlockers.Count -eq 0
)
$items += New-AuditItem `
    -Id "prd_required_listed_services_decision" `
    -Source "PRD Required Decisions Before MVP Release" `
    -Requirement "Listed Crown-administered services, starting with storage, define service classes, quote method, proof standard, failure remedy, burn timing, and support ownership." `
    -Status $(if ($listedServiceComplete -and $storageStatus -eq "passed") { "passed" } else { "blocked" }) `
    -EvidenceIds @("pre_mvp_internal_verification", "production_mvp_readiness", "production_mvp_outstanding_work", "production_mvp_operator_input_matrix") `
    -CoverageCheckIds $storageCoverageCheckIds `
    -CoverageEvidence (Get-CoverageEvidence -PreMvpReport $preMvp -CheckIds $storageCoverageCheckIds) `
    -EvidenceNotes @("Storage redemption, escrow, burn, refund, and re-credit behavior is locally validated; production release requires managed storage provisioning and live storage status evidence.") `
    -Blockers $listedServiceBlockers `
    -OperatorActions $listedServiceActions `
    -RemainingWorkType "managed_storage_provisioning" `
    -ImplementationReady ($storageStatus -eq "passed")

$items += New-AuditItem `
    -Id "prd_required_conversion_policy_decision" `
    -Source "PRD Required Decisions Before MVP Release" `
    -Requirement "ARCH/CC conversion source, quote method, spread or fee policy, counterparty limits, liquidity limit, and disclosure wording are defined." `
    -Status $(if ($monetaryProvisioningComplete -and $monetaryImplementationReady) { "passed" } else { "blocked" }) `
    -EvidenceIds @("pre_mvp_internal_verification", "production_mvp_readiness", "production_mvp_outstanding_work", "production_mvp_operator_input_matrix") `
    -CoverageCheckIds $monetaryCoverageCheckIds `
    -CoverageEvidence (Get-CoverageEvidence -PreMvpReport $preMvp -CheckIds $monetaryCoverageCheckIds) `
    -EvidenceNotes @("Floating-rate quote and execution records are locally validated; production release requires the approved monetary provisioning packet and no fixed-rate/guaranteed-conversion claims.") `
    -Blockers $monetaryProvisioningBlockers `
    -OperatorActions $monetaryProvisioningActions `
    -RemainingWorkType "monetary_provisioning" `
    -ImplementationReady $monetaryImplementationReady

$releaseLaneBlockers = @()
$releaseLaneBlockers += @(Get-OutstandingGateFailures -OutstandingReport $outstanding -Id "staging_readiness")
$releaseLaneBlockers += @(Get-OutstandingGateFailures -OutstandingReport $outstanding -Id "canary_mvp_readiness")
$releaseLaneBlockers += @(Get-OutstandingGateFailures -OutstandingReport $outstanding -Id "package_signing")
$releaseLaneBlockers += @(Get-OutstandingGateFailures -OutstandingReport $outstanding -Id "release_lane_endpoints")
$releaseLaneBlockers += @(Get-OutstandingProvisioningFailures -OutstandingReport $outstanding -Id "release_lane_endpoint_provisioning")
$releaseLaneActions = @()
$releaseLaneActions += @(Get-OutstandingGateAction -OutstandingReport $outstanding -Id "staging_readiness")
$releaseLaneActions += @(Get-OutstandingGateAction -OutstandingReport $outstanding -Id "canary_mvp_readiness")
$releaseLaneActions += @(Get-OutstandingGateAction -OutstandingReport $outstanding -Id "package_signing")
$releaseLaneActions += @(Get-OutstandingGateAction -OutstandingReport $outstanding -Id "release_lane_endpoints")
$releaseLaneActions += @(Get-OutstandingProvisioningAction -OutstandingReport $outstanding -Id "release_lane_endpoint_provisioning")
$releaseLaneComplete = (
    (Get-Gate -Report $productionReadiness -Id "staging_readiness").passed -eq $true -and
    (Get-Gate -Report $productionReadiness -Id "canary_mvp_readiness").passed -eq $true -and
    (Get-Gate -Report $productionReadiness -Id "package_signing").passed -eq $true -and
    (Get-Gate -Report $productionReadiness -Id "release_lane_endpoints").passed -eq $true -and
    (Get-OutstandingProvisioningFailures -OutstandingReport $outstanding -Id "release_lane_endpoint_provisioning").Count -eq 0
)
$items += New-AuditItem `
    -Id "prd_required_release_lanes_decision" `
    -Source "PRD Required Decisions Before MVP Release" `
    -Requirement "Release lanes, staging isolation, canary policy, package identity, signing path, promotion approvals, rollback, stop rules, and production endpoints are defined." `
    -Status $(if ($releaseLaneComplete) { "passed" } else { "blocked" }) `
    -EvidenceIds @("staging_readiness", "canary_mvp_readiness", "production_mvp_readiness", "production_mvp_outstanding_work", "production_mvp_operator_input_matrix") `
    -EvidenceNotes @("Release-lane implementation tooling is present; production release requires real non-synthetic staging/canary evidence, package signing, and production endpoint provisioning.") `
    -Blockers $releaseLaneBlockers `
    -OperatorActions $releaseLaneActions `
    -RemainingWorkType "staging_provisioning" `
    -ImplementationReady $preMvpImplementationReady

$custodyBlockers = @()
$custodyBlockers += @(Get-OutstandingProvisioningFailures -OutstandingReport $outstanding -Id "managed_signing_custody_provisioning")
$custodyBlockers += @(Get-OutstandingGateFailures -OutstandingReport $outstanding -Id "managed_signing_key_custody")
$custodyBlockers += @(Get-OutstandingGateFailures -OutstandingReport $outstanding -Id "managed_signing_endpoint_probe")
$custodyActions = @()
$custodyActions += @(Get-OutstandingProvisioningAction -OutstandingReport $outstanding -Id "managed_signing_custody_provisioning")
$custodyActions += @(Get-OutstandingGateAction -OutstandingReport $outstanding -Id "managed_signing_key_custody")
$custodyActions += @(Get-OutstandingGateAction -OutstandingReport $outstanding -Id "managed_signing_endpoint_probe")
$custodyComplete = (
    (Get-OutstandingProvisioningFailures -OutstandingReport $outstanding -Id "managed_signing_custody_provisioning").Count -eq 0 -and
    (Get-Gate -Report $productionReadiness -Id "managed_signing_key_custody").passed -eq $true -and
    (Get-Gate -Report $productionReadiness -Id "managed_signing_endpoint_probe").passed -eq $true
)
$custodyImplementationReady = (
    (Get-StatusFromCheckIds -PreMvpReport $preMvp -CheckIds $identityCoverageCheckIds) -eq "passed" -and
    (Get-StatusFromCheckIds -PreMvpReport $preMvp -CheckIds $walletCoverageCheckIds) -eq "passed"
)
$items += New-AuditItem `
    -Id "prd_required_custody_recovery_decision" `
    -Source "PRD Required Decisions Before MVP Release" `
    -Requirement "Custody and recovery policy defines identity key recovery, wallet key recovery, device loss, compromise, rotation, revocation, freeze authority, and managed signing custody." `
    -Status $(if ($custodyComplete -and $custodyImplementationReady) { "passed" } else { "blocked" }) `
    -EvidenceIds @("pre_mvp_internal_verification", "production_mvp_readiness", "production_mvp_outstanding_work", "production_mvp_operator_input_matrix") `
    -CoverageCheckIds @($identityCoverageCheckIds + $walletCoverageCheckIds) `
    -CoverageEvidence (Get-CoverageEvidence -PreMvpReport $preMvp -CheckIds @($identityCoverageCheckIds + $walletCoverageCheckIds)) `
    -EvidenceNotes @("Identity recovery and wallet-key binding are locally validated; production release requires managed signing-key custody and endpoint evidence.") `
    -Blockers $custodyBlockers `
    -OperatorActions $custodyActions `
    -RemainingWorkType "managed_signing_provisioning" `
    -ImplementationReady $custodyImplementationReady

$releaseApprovalBlockers = Get-OutstandingGateFailures -OutstandingReport $outstanding -Id "production_release_approvals"
$releaseApprovalActions = Get-OutstandingGateAction -OutstandingReport $outstanding -Id "production_release_approvals"
$items += New-AuditItem `
    -Id "prd_required_legal_tax_accounting_custody_review" `
    -Source "PRD Required Decisions Before MVP Release" `
    -Requirement "Legal, tax, accounting, and custody review is complete before citizen-facing real ARCH or real CC release." `
    -Status $(if ((Get-Gate -Report $productionReadiness -Id "production_release_approvals").passed -eq $true) { "passed" } else { "blocked" }) `
    -EvidenceIds @("production_mvp_readiness", "production_mvp_outstanding_work", "production_mvp_operator_input_matrix", "production_mvp_next_action_packet_validation") `
    -EvidenceNotes @("This PRD-required decision is tracked separately from the ARD release gate so release signoff cannot be hidden inside a broad closeout item.") `
    -Blockers $releaseApprovalBlockers `
    -OperatorActions $releaseApprovalActions `
    -RemainingWorkType "release_approval" `
    -ImplementationReady $preMvpImplementationReady

$aiImplementationStatus = Get-StatusFromCheckIds -PreMvpReport $preMvp -CheckIds $aiCoverageCheckIds
$privacyBlockers = @()
$privacyBlockers += @(Get-OutstandingGateFailures -OutstandingReport $outstanding -Id "telemetry_incident_response")
$privacyBlockers += @(Get-OutstandingProvisioningFailures -OutstandingReport $outstanding -Id "production_ops_documents")
$privacyActions = @()
$privacyActions += @(Get-OutstandingGateAction -OutstandingReport $outstanding -Id "telemetry_incident_response")
$privacyActions += @(Get-OutstandingProvisioningAction -OutstandingReport $outstanding -Id "production_ops_documents")
$privacyComplete = (
    (Get-Gate -Report $productionReadiness -Id "telemetry_incident_response").passed -eq $true -and
    (Get-OutstandingProvisioningFailures -OutstandingReport $outstanding -Id "production_ops_documents").Count -eq 0
)
$items += New-AuditItem `
    -Id "prd_required_privacy_data_retention_decision" `
    -Source "PRD Required Decisions Before MVP Release" `
    -Requirement "Privacy, data retention, AI prompt-use policy, immutable audit log limits, support access, incident response, and user export handling are defined." `
    -Status $(if ($privacyComplete) { "passed" } else { "blocked" }) `
    -EvidenceIds @("pre_mvp_internal_verification", "production_mvp_readiness", "production_mvp_outstanding_work", "production_mvp_operator_input_matrix") `
    -CoverageCheckIds $aiCoverageCheckIds `
    -CoverageEvidence (Get-CoverageEvidence -PreMvpReport $preMvp -CheckIds $aiCoverageCheckIds) `
    -EvidenceNotes @("AI privacy, no-authority behavior, and runtime deployment packaging are locally validated; production release requires telemetry retention and incident-response evidence.") `
    -Blockers $privacyBlockers `
    -OperatorActions $privacyActions `
    -RemainingWorkType "operations_provisioning" `
    -ImplementationReady ($aiImplementationStatus -eq "passed")

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
    -CoverageEvidence (Get-CoverageEvidence -PreMvpReport $preMvp -CheckIds $aiCoverageCheckIds) `
    -EvidenceNotes @("Hosted AI implementation coverage is tied to targeted hosted AI, Windows AI gateway, and open-weight runtime deployment checks; production open-weight model runtime and live probe remain blocked until provisioned.") `
    -Blockers $aiBlockers `
    -OperatorActions $aiActions `
    -RemainingWorkType "ai_runtime_provisioning" `
    -ImplementationReady ($aiImplementationStatus -eq "passed")

$items += New-AuditItem `
    -Id "ard_ai_challenge_session_acceptance" `
    -Source "Hosted Open-Weight AI ARD Acceptance Criteria" `
    -Requirement "Passport can obtain an AI challenge, sign it with identity/device keys, reject expired/wrong-lane/revoked-device/invalid-signature challenges, and receive a short-lived AI session token separate from wallet keys." `
    -Status $aiImplementationStatus `
    -EvidenceIds @("pre_mvp_internal_verification") `
    -CoverageCheckIds @("hosted_ai_targeted_tests", "windows_ai_gateway_targeted_tests") `
    -CoverageEvidence (Get-CoverageEvidence -PreMvpReport $preMvp -CheckIds @("hosted_ai_targeted_tests", "windows_ai_gateway_targeted_tests")) `
    -EvidenceNotes @("AI challenge, session, lane, revocation, signature, and wallet-key separation behavior is covered by hosted AI and Windows AI gateway targeted tests.")

$items += New-AuditItem `
    -Id "ard_ai_prompt_secret_rejection_acceptance" `
    -Source "Hosted Open-Weight AI ARD Acceptance Criteria" `
    -Requirement "Gateway rejects wallet-key material and recovery secrets in prompts where detectable." `
    -Status $aiImplementationStatus `
    -EvidenceIds @("pre_mvp_internal_verification") `
    -CoverageCheckIds @("hosted_ai_targeted_tests", "windows_ai_gateway_targeted_tests") `
    -CoverageEvidence (Get-CoverageEvidence -PreMvpReport $preMvp -CheckIds @("hosted_ai_targeted_tests", "windows_ai_gateway_targeted_tests")) `
    -EvidenceNotes @("Secret-filtering and no-wallet-material prompt handling are covered by hosted AI and Windows AI gateway targeted tests.")

$items += New-AuditItem `
    -Id "ard_ai_knowledge_privacy_quota_acceptance" `
    -Source "Hosted Open-Weight AI ARD Acceptance Criteria" `
    -Requirement "Chat answers use approved knowledge packs with source references; private diagnostics require opt-in; raw prompt retention defaults to 30 days; quotas and rate limits are enforced." `
    -Status $aiImplementationStatus `
    -EvidenceIds @("pre_mvp_internal_verification") `
    -CoverageCheckIds @("hosted_ai_targeted_tests", "windows_ai_gateway_targeted_tests", "open_weight_ai_runtime_deployment_validation") `
    -CoverageEvidence (Get-CoverageEvidence -PreMvpReport $preMvp -CheckIds @("hosted_ai_targeted_tests", "windows_ai_gateway_targeted_tests", "open_weight_ai_runtime_deployment_validation")) `
    -EvidenceNotes @("Approved knowledge, source references, diagnostics opt-in, retention defaults, quotas, rate limits, and runtime package validation are covered by targeted AI and runtime deployment checks.")

$items += New-AuditItem `
    -Id "ard_ai_no_authority_acceptance" `
    -Source "Hosted Open-Weight AI ARD Acceptance Criteria" `
    -Requirement "AI cannot trigger wallet, recovery, ledger, storage delivery, escrow, burn, registry authority, or admin actions." `
    -Status $aiImplementationStatus `
    -EvidenceIds @("pre_mvp_internal_verification") `
    -CoverageCheckIds @("hosted_ai_targeted_tests", "windows_ai_gateway_targeted_tests") `
    -CoverageEvidence (Get-CoverageEvidence -PreMvpReport $preMvp -CheckIds @("hosted_ai_targeted_tests", "windows_ai_gateway_targeted_tests")) `
    -EvidenceNotes @("The hosted AI no-authority boundary is covered by hosted AI and Windows AI gateway targeted tests.")

$items += New-AuditItem `
    -Id "ard_ai_user_disclosure_acceptance" `
    -Source "Hosted AI Authority/Privacy ARD" `
    -Requirement "Passport states that AI can be wrong, is not legal/financial/tax/accounting/securities/custody/medical advice, cannot change wallet or credit status, and should not receive secrets or sensitive files unless explicitly requested for support." `
    -Status $aiImplementationStatus `
    -EvidenceIds @("pre_mvp_internal_verification") `
    -CoverageCheckIds @("windows_ai_gateway_targeted_tests") `
    -CoverageEvidence (Get-CoverageEvidence -PreMvpReport $preMvp -CheckIds @("windows_ai_gateway_targeted_tests")) `
    -EvidenceNotes @("The AI user disclosure is bound into the Windows AI surface and covered by the targeted Windows AI gateway tests.")

$items += New-AuditItem `
    -Id "ard_ai_lane_runtime_probe_acceptance" `
    -Source "Hosted Open-Weight AI ARD Acceptance Criteria" `
    -Requirement "Staging and production use separate endpoints, logs, model artifacts, vector stores, and telemetry; the hosted gateway exposes non-secret runtime readiness status and an operator-protected non-mutating runtime probe for the approved model runtime." `
    -Status $(if ($aiImplementationStatus -eq "passed" -and $aiBlockers.Count -eq 0) { "passed" } elseif ($aiImplementationStatus -eq "passed") { "partial" } else { $aiImplementationStatus }) `
    -EvidenceIds @("pre_mvp_internal_verification", "production_mvp_readiness", "production_mvp_outstanding_work", "production_mvp_operator_input_matrix") `
    -CoverageCheckIds $aiCoverageCheckIds `
    -CoverageEvidence (Get-CoverageEvidence -PreMvpReport $preMvp -CheckIds $aiCoverageCheckIds) `
    -EvidenceNotes @("Local lane/runtime status and probe contracts are validated; production release remains blocked until the approved open-weight runtime endpoint and live probe are provisioned.") `
    -Blockers $aiBlockers `
    -OperatorActions $aiActions `
    -RemainingWorkType "ai_runtime_provisioning" `
    -ImplementationReady ($aiImplementationStatus -eq "passed")

$items += New-AuditItem `
    -Id "ard_release_legal_tax_accounting_custody_privacy_security" `
    -Source "ARD Release Gates" `
    -Requirement "Legal, tax, accounting, custody, privacy, and security reviews are complete for citizen-facing real ARCH and real CC." `
    -Status $(if ((Get-Gate -Report $productionReadiness -Id "production_release_approvals").passed -eq $true) { "passed" } else { "blocked" }) `
    -EvidenceIds @("production_mvp_readiness", "production_mvp_outstanding_work", "production_mvp_operator_input_matrix", "production_mvp_next_action_packet_validation") `
    -Blockers $releaseApprovalBlockers `
    -OperatorActions $releaseApprovalActions `
    -RemainingWorkType "release_approval" `
    -ImplementationReady $preMvpImplementationReady

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
    -EvidenceIds @("production_mvp_closeout", "production_mvp_readiness", "production_mvp_outstanding_work", "production_mvp_next_action_packet_manifest", "production_mvp_next_action_plan", "production_mvp_operator_input_matrix", "production_mvp_operator_commands", "production_mvp_operator_command_phase_manifest", "production_mvp_next_action_packet_validation") `
    -Blockers @($closeout.failures | ForEach-Object { ConvertTo-AuditText -Value $_ }) `
    -OperatorActions $closeoutActions `
    -RemainingWorkType "production_closeout" `
    -ImplementationReady $preMvpImplementationReady

$statusGroups = $items | Group-Object -Property status
$statusCounts = [ordered]@{}
foreach ($group in $statusGroups) {
    $statusCounts[$group.Name] = $group.Count
}

$remainingWorkGroups = $items | Where-Object { $_.status -ne "passed" } | Group-Object -Property remaining_work_type
$remainingWorkCounts = [ordered]@{}
foreach ($group in $remainingWorkGroups) {
    $remainingWorkCounts[$group.Name] = $group.Count
}

$localImplementationGapItems = @($items | Where-Object {
        $_.status -ne "passed" -and
        ($_.implementation_ready -ne $true -or [string]$_.remaining_work_type -eq "implementation_gap" -or [string]$_.remaining_work_type -eq "unclassified")
    })

$completionReady = (
    $inputFailures.Count -eq 0 -and
    @($items | Where-Object { $_.status -ne "passed" }).Count -eq 0
)

$localImplementationReady = (
    $inputFailures.Count -eq 0 -and
    $localImplementationGapItems.Count -eq 0
)

$report = [pscustomobject][ordered]@{
    schema = "archrealms.passport.token_ready_mvp_completion_audit.v1"
    created_utc = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
    app_commit = Get-CurrentCommit
    completion_ready = $completionReady
    local_implementation_ready = $localImplementationReady
    local_implementation_gap_count = $localImplementationGapItems.Count
    input_failures = $inputFailures
    source_files = $files
    status_counts = $statusCounts
    remaining_work_counts = $remainingWorkCounts
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
    $lines.Add("- Local implementation ready: $($report.local_implementation_ready.ToString().ToLowerInvariant())")
    $lines.Add("- Local implementation gap items: $($report.local_implementation_gap_count)")
    foreach ($key in @($statusCounts.Keys | Sort-Object)) {
        $lines.Add("- $key items: $($statusCounts[$key])")
    }
    foreach ($key in @($remainingWorkCounts.Keys | Sort-Object)) {
        $lines.Add("- remaining ``$key`` items: $($remainingWorkCounts[$key])")
    }
    if ($inputFailures.Count -gt 0) {
        $lines.Add("")
        $lines.Add("## Input Failures")
        foreach ($failure in $inputFailures) {
            $lines.Add("- $failure")
        }
    }

    $lines.Add("")
    $lines.Add("## Source Files")
    foreach ($file in $files.Values) {
        $lines.Add("- ``$($file.id)`` exists=$($file.exists) sha256=``$($file.sha256)``")
        $lines.Add("  - Path: ``$($file.path)``")
    }

    $lines.Add("")
    $lines.Add("## Checklist")
    foreach ($item in $items) {
        $lines.Add("- ``$($item.id)`` [$($item.status)]: $($item.requirement)")
        $lines.Add("  - Remaining work: $($item.remaining_work_type); implementation_ready=$($item.implementation_ready)")
        if (-not [string]::IsNullOrWhiteSpace([string]$item.summary)) {
            $lines.Add("  - Summary: $($item.summary)")
        }
        if (-not [string]::IsNullOrWhiteSpace([string]$item.next_action)) {
            $lines.Add("  - Next action: $($item.next_action)")
        }
        foreach ($command in @($item.next_action_commands | Select-Object -First 2)) {
            $lines.Add("  - Next action command: ``$command``")
        }
        if (@($item.evidence_ids).Count -gt 0) {
            $lines.Add("  - Evidence: $((@($item.evidence_ids) -join ', '))")
        }
        if (@($item.coverage_check_ids).Count -gt 0) {
            $lines.Add("  - Coverage checks: $((@($item.coverage_check_ids) -join ', '))")
        }
        foreach ($coverage in @($item.coverage_evidence | Select-Object -First 3)) {
            $lines.Add("  - Coverage evidence: $($coverage.check_id) present=$($coverage.present) passed=$($coverage.passed)")
        }
        if (@($item.coverage_evidence).Count -gt 3) {
            $lines.Add("  - ...$(@($item.coverage_evidence).Count - 3) more coverage evidence records in JSON report")
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
    local_implementation_ready = $report.local_implementation_ready
    local_implementation_gap_count = $report.local_implementation_gap_count
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
