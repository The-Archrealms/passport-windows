param(
    [string]$PreMvpInternalVerificationReportPath = "artifacts\release\pre-mvp-internal-verification-report.json",
    [string]$StagingReadinessReportPath = "artifacts\release\staging-readiness-report.json",
    [string]$CanaryMvpReadinessReportPath = "artifacts\release\canary-mvp-readiness-report.json",
    [string]$ProductionMvpReadinessReportPath = "artifacts\release\production-mvp-readiness-report.json",
    [string]$ProductionMvpCloseoutManifestPath = "artifacts\release\production-mvp-closeout\production-mvp-closeout.manifest.json",
    [string]$ProductionMvpOutstandingWorkReportPath = "artifacts\release\production-mvp-outstanding-work-report.json",
    [string]$ReportPath = "artifacts\release\token-ready-mvp-completion-audit-report.json",
    [string]$MarkdownPath = "artifacts\release\token-ready-mvp-completion-audit-report.md",
    [string]$OutputPath = "artifacts\release\token-ready-mvp-completion-audit-validation-report.json",
    [switch]$UseGeneratedFixture,
    [switch]$Generate,
    [switch]$RequireComplete,
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

function Write-JsonFile {
    param(
        [string]$Path,
        [object]$Value
    )

    $parent = Split-Path -Parent $Path
    if ($parent) {
        New-Item -ItemType Directory -Force -Path $parent | Out-Null
    }

    Set-Content -LiteralPath $Path -Value ($Value | ConvertTo-Json -Depth 12) -Encoding UTF8
}

function New-FixtureCheck {
    param([string]$Id)

    return [pscustomobject][ordered]@{
        id = $Id
        description = "Generated complete-state fixture check: $Id"
        passed = $true
        failures = @()
        evidence = [pscustomobject][ordered]@{
            fixture = $true
        }
    }
}

function New-FixtureRequirement {
    param(
        [string]$Id,
        [string[]]$CheckIds
    )

    return [pscustomobject][ordered]@{
        id = $Id
        description = "Generated complete-state fixture requirement: $Id"
        check_ids = @($CheckIds)
        passed = $true
        missing_checks = @()
        evidence = "Generated completion-audit fixture evidence."
    }
}

function New-FixtureGate {
    param([string]$Id)

    return [pscustomobject][ordered]@{
        id = $Id
        description = "Generated complete-state fixture readiness gate: $Id"
        passed = $true
        missing = @()
        evidence = [pscustomobject][ordered]@{
            fixture = $true
        }
    }
}

function New-CompletionAuditFixture {
    $fixtureRoot = Resolve-RepoPath -Path "artifacts\release\token-ready-mvp-completion-audit-fixture"
    New-Item -ItemType Directory -Force -Path $fixtureRoot | Out-Null
    $createdUtc = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")

    $preMvpPath = Join-Path $fixtureRoot "pre-mvp-internal-verification-report.json"
    $stagingPath = Join-Path $fixtureRoot "staging-readiness-report.json"
    $canaryPath = Join-Path $fixtureRoot "canary-mvp-readiness-report.json"
    $productionReadinessPath = Join-Path $fixtureRoot "production-mvp-readiness-report.json"
    $closeoutPath = Join-Path $fixtureRoot "production-mvp-closeout.manifest.json"
    $outstandingPath = Join-Path $fixtureRoot "production-mvp-outstanding-work-report.json"
    $reportPath = Join-Path $fixtureRoot "token-ready-mvp-completion-audit-report.json"
    $markdownPath = Join-Path $fixtureRoot "token-ready-mvp-completion-audit-report.md"
    $validationPath = Join-Path $fixtureRoot "token-ready-mvp-completion-audit-validation-report.json"

    $preMvpCheckIds = @(
        "core_tests",
        "windows_tests",
        "hosted_service_tests",
        "ledger_verifier_build",
        "production_monetary_provisioning_validation",
        "open_weight_ai_runtime_deployment_validation"
    )
    $preMvpRequirements = @(
        New-FixtureRequirement -Id "passport_core_contracts" -CheckIds @("core_tests")
        New-FixtureRequirement -Id "passport_windows_user_flows" -CheckIds @("windows_tests")
        New-FixtureRequirement -Id "hosted_ai_service_contracts" -CheckIds @("hosted_service_tests")
        New-FixtureRequirement -Id "ledger_export_verifier" -CheckIds @("ledger_verifier_build")
        New-FixtureRequirement -Id "production_monetary_provisioning_package" -CheckIds @("production_monetary_provisioning_validation")
        New-FixtureRequirement -Id "open_weight_ai_runtime_deployment_package" -CheckIds @("open_weight_ai_runtime_deployment_validation")
    )
    Write-JsonFile -Path $preMvpPath -Value ([pscustomobject][ordered]@{
        schema = "archrealms.passport.pre_mvp_internal_verification.v1"
        created_utc = $createdUtc
        passed = $true
        fake_balance_migration_blocked = $true
        check_count = $preMvpCheckIds.Count
        checks = @($preMvpCheckIds | ForEach-Object { New-FixtureCheck -Id $_ })
        requirement_count = $preMvpRequirements.Count
        requirements = $preMvpRequirements
    })

    Write-JsonFile -Path $stagingPath -Value ([pscustomobject][ordered]@{
        schema = "archrealms.passport.staging_readiness.v1"
        created_utc = $createdUtc
        ready = $true
        synthetic_fixtures_used = $false
        canary_or_production_release_approved = $true
        failed_gate_count = 0
        gates = @(New-FixtureGate -Id "staging_readiness")
    })

    Write-JsonFile -Path $canaryPath -Value ([pscustomobject][ordered]@{
        schema = "archrealms.passport.canary_mvp_readiness.v1"
        created_utc = $createdUtc
        ready = $true
        synthetic_fixtures_used = $false
        production_release_approved = $true
        failed_gate_count = 0
        gates = @(New-FixtureGate -Id "canary_mvp_readiness")
    })

    $productionGateIds = @(
        "pre_mvp_internal_verification",
        "staging_readiness",
        "canary_mvp_readiness",
        "package_signing",
        "release_lane_endpoints",
        "hosted_runtime_status",
        "hosted_ai_runtime_probe",
        "hosted_operator_gate",
        "hosted_operator_status",
        "managed_storage_backups",
        "managed_storage_status",
        "managed_signing_key_custody",
        "managed_signing_endpoint_probe",
        "issuer_capacity_genesis_secrets",
        "open_weight_ai_runtime",
        "telemetry_incident_response",
        "production_release_approvals"
    )
    Write-JsonFile -Path $productionReadinessPath -Value ([pscustomobject][ordered]@{
        schema = "archrealms.passport.production_mvp_readiness.v1"
        created_utc = $createdUtc
        ready = $true
        failed_gate_count = 0
        gates = @($productionGateIds | ForEach-Object { New-FixtureGate -Id $_ })
    })

    Write-JsonFile -Path $closeoutPath -Value ([pscustomobject][ordered]@{
        schema = "archrealms.passport.production_mvp_closeout.v1"
        created_utc = $createdUtc
        passed = $true
        failures = @()
    })

    Write-JsonFile -Path $outstandingPath -Value ([pscustomobject][ordered]@{
        schema = "archrealms.passport.production_mvp_outstanding_work.v1"
        created_utc = $createdUtc
        ready_for_production_testing = $true
        failed_readiness_gates = @()
        failed_provisioning_checks = @()
        failed_release_evidence_checks = @()
        summary = [pscustomobject][ordered]@{
            failed_readiness_gate_count = 0
            failed_provisioning_check_count = 0
            failed_release_evidence_check_count = 0
            failed_closeout_count = 0
        }
    })

    return [pscustomobject][ordered]@{
        pre_mvp_internal_verification = $preMvpPath
        staging_readiness = $stagingPath
        canary_mvp_readiness = $canaryPath
        production_mvp_readiness = $productionReadinessPath
        production_mvp_closeout = $closeoutPath
        production_mvp_outstanding_work = $outstandingPath
        completion_audit_report = $reportPath
        completion_audit_markdown = $markdownPath
        completion_audit_validation = $validationPath
    }
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

function Invoke-CompletionAuditGenerator {
    param(
        [string]$PreMvpInternalVerificationPath,
        [string]$StagingReadinessPath,
        [string]$CanaryMvpReadinessPath,
        [string]$ProductionMvpReadinessPath,
        [string]$ProductionMvpCloseoutPath,
        [string]$ProductionMvpOutstandingWorkPath,
        [string]$JsonPath,
        [string]$MarkdownOutputPath
    )

    $powershell = Get-Command powershell -ErrorAction Stop
    $generator = Resolve-RepoPath -Path "tools\release\New-PassportTokenReadyMvpCompletionAuditReport.ps1"
    $args = @(
        "-NoProfile",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        $generator,
        "-PreMvpInternalVerificationReportPath",
        $PreMvpInternalVerificationPath,
        "-StagingReadinessReportPath",
        $StagingReadinessPath,
        "-CanaryMvpReadinessReportPath",
        $CanaryMvpReadinessPath,
        "-ProductionMvpReadinessReportPath",
        $ProductionMvpReadinessPath,
        "-ProductionMvpCloseoutManifestPath",
        $ProductionMvpCloseoutPath,
        "-ProductionMvpOutstandingWorkReportPath",
        $ProductionMvpOutstandingWorkPath,
        "-OutputPath",
        $JsonPath,
        "-MarkdownOutputPath",
        $MarkdownOutputPath,
        "-NoFail"
    )

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

function Get-ObjectArray {
    param(
        [object]$Object,
        [string]$Name
    )

    if ($null -eq $Object -or -not $Object.PSObject.Properties[$Name]) {
        return @()
    }

    return @($Object.$Name)
}

function Get-ObjectBool {
    param(
        [object]$Object,
        [string]$Name
    )

    if ($null -eq $Object -or -not $Object.PSObject.Properties[$Name]) {
        return $false
    }

    return [bool]$Object.$Name
}

function Get-SourceFile {
    param(
        [object]$Report,
        [string]$Id
    )

    if ($null -eq $Report -or -not $Report.PSObject.Properties["source_files"]) {
        return $null
    }

    if (-not $Report.source_files.PSObject.Properties[$Id]) {
        return $null
    }

    return $Report.source_files.$Id
}

$resolvedPreMvpInternalVerificationReportPath = Resolve-RepoPath -Path $PreMvpInternalVerificationReportPath
$resolvedStagingReadinessReportPath = Resolve-RepoPath -Path $StagingReadinessReportPath
$resolvedCanaryMvpReadinessReportPath = Resolve-RepoPath -Path $CanaryMvpReadinessReportPath
$resolvedProductionMvpReadinessReportPath = Resolve-RepoPath -Path $ProductionMvpReadinessReportPath
$resolvedProductionMvpCloseoutManifestPath = Resolve-RepoPath -Path $ProductionMvpCloseoutManifestPath
$resolvedProductionMvpOutstandingWorkReportPath = Resolve-RepoPath -Path $ProductionMvpOutstandingWorkReportPath
$resolvedReportPath = Resolve-RepoPath -Path $ReportPath
$resolvedMarkdownPath = Resolve-RepoPath -Path $MarkdownPath
$resolvedOutputPath = Resolve-RepoPath -Path $OutputPath

if ($UseGeneratedFixture) {
    $fixture = New-CompletionAuditFixture
    $resolvedPreMvpInternalVerificationReportPath = $fixture.pre_mvp_internal_verification
    $resolvedStagingReadinessReportPath = $fixture.staging_readiness
    $resolvedCanaryMvpReadinessReportPath = $fixture.canary_mvp_readiness
    $resolvedProductionMvpReadinessReportPath = $fixture.production_mvp_readiness
    $resolvedProductionMvpCloseoutManifestPath = $fixture.production_mvp_closeout
    $resolvedProductionMvpOutstandingWorkReportPath = $fixture.production_mvp_outstanding_work
    $resolvedReportPath = $fixture.completion_audit_report
    $resolvedMarkdownPath = $fixture.completion_audit_markdown
    $resolvedOutputPath = $fixture.completion_audit_validation
}

$checks = @()
$generatorResult = $null
if ($Generate) {
    $generatorResult = Invoke-CompletionAuditGenerator `
        -PreMvpInternalVerificationPath $resolvedPreMvpInternalVerificationReportPath `
        -StagingReadinessPath $resolvedStagingReadinessReportPath `
        -CanaryMvpReadinessPath $resolvedCanaryMvpReadinessReportPath `
        -ProductionMvpReadinessPath $resolvedProductionMvpReadinessReportPath `
        -ProductionMvpCloseoutPath $resolvedProductionMvpCloseoutManifestPath `
        -ProductionMvpOutstandingWorkPath $resolvedProductionMvpOutstandingWorkReportPath `
        -JsonPath $resolvedReportPath `
        -MarkdownOutputPath $resolvedMarkdownPath
    $checks += Add-Check -Id "generator_exit_code" -Condition ($generatorResult.exit_code -eq 0) -Failure "completion audit generator failed" -Evidence $generatorResult
}

$reportExists = Test-Path -LiteralPath $resolvedReportPath -PathType Leaf
$markdownExists = Test-Path -LiteralPath $resolvedMarkdownPath -PathType Leaf
$checks += Add-Check -Id "report_exists" -Condition $reportExists -Failure "completion audit report is missing" -Evidence ([pscustomobject][ordered]@{ path = $resolvedReportPath })
$checks += Add-Check -Id "markdown_exists" -Condition $markdownExists -Failure "completion audit Markdown report is missing" -Evidence ([pscustomobject][ordered]@{ path = $resolvedMarkdownPath })

$report = Read-JsonFile -Path $resolvedReportPath
$checks += Add-Check -Id "schema" -Condition ($null -ne $report -and [string]$report.schema -eq "archrealms.passport.token_ready_mvp_completion_audit.v1") -Failure "completion audit schema is invalid or missing"
$checks += Add-Check -Id "app_commit" -Condition ($null -ne $report -and [string]$report.app_commit -match '^[0-9a-f]{7,40}$') -Failure "app_commit is missing or not a git commit hash" -Evidence ([pscustomobject][ordered]@{ app_commit = $(if ($null -eq $report) { "" } else { [string]$report.app_commit }) })

$requiredSourceFileIds = @(
    "pre_mvp_internal_verification",
    "staging_readiness",
    "canary_mvp_readiness",
    "production_mvp_readiness",
    "production_mvp_closeout",
    "production_mvp_outstanding_work"
)

foreach ($sourceId in $requiredSourceFileIds) {
    $source = Get-SourceFile -Report $report -Id $sourceId
    $sourceFailures = @()
    if ($null -eq $source) {
        $sourceFailures += "source file evidence is missing: $sourceId"
    }
    else {
        if ([string]$source.id -ne $sourceId) {
            $sourceFailures += "source file id does not match: $sourceId"
        }
        if ($source.exists -ne $true) {
            $sourceFailures += "source file does not exist: $sourceId"
        }
        if ([string]$source.sha256 -notmatch '^[0-9a-f]{64}$') {
            $sourceFailures += "source file SHA-256 is missing or invalid: $sourceId"
        }
    }

    $checks += New-Check -Id "source_file_$sourceId" -Passed ($sourceFailures.Count -eq 0) -Failures $sourceFailures -Evidence $source
}

$inputFailures = Get-ObjectArray -Object $report -Name "input_failures"
$checks += Add-Check -Id "input_failures_absent" -Condition ($null -ne $report -and $inputFailures.Count -eq 0) -Failure "completion audit has input failures" -Evidence $inputFailures

$requiredChecklistIds = @(
    "prd_success_pre_mvp_internal_verification",
    "prd_success_staging_readiness",
    "prd_success_canary_readiness",
    "prd_success_installable_passport",
    "prd_success_identity_recovery",
    "prd_success_device_authorization",
    "prd_success_wallet_key_binding",
    "prd_success_real_arch",
    "prd_success_real_cc",
    "prd_success_storage_redemption",
    "prd_success_storage_escrow_burn_refund_recredit",
    "prd_success_resource_contribution",
    "prd_success_arch_cc_conversion",
    "prd_success_no_post_genesis_arch_mint",
    "prd_success_cc_capacity_constrained",
    "prd_success_cc_does_not_create_arch",
    "prd_success_ledger_export_auditability",
    "prd_success_hosted_ai",
    "ard_release_legal_tax_accounting_custody_privacy_security",
    "production_mvp_closeout"
)

$checklist = Get-ObjectArray -Object $report -Name "checklist"
$checklistIds = @($checklist | ForEach-Object { [string]$_.id })
$missingChecklistIds = @($requiredChecklistIds | Where-Object { $checklistIds -notcontains $_ })
$unexpectedChecklistIds = @($checklistIds | Where-Object { $requiredChecklistIds -notcontains $_ })
$duplicateChecklistIds = @($checklistIds | Group-Object | Where-Object { $_.Count -gt 1 } | ForEach-Object { $_.Name })

$checks += New-Check `
    -Id "required_checklist_ids" `
    -Passed ($missingChecklistIds.Count -eq 0 -and $unexpectedChecklistIds.Count -eq 0 -and $duplicateChecklistIds.Count -eq 0) `
    -Failures @(
        @($missingChecklistIds | ForEach-Object { "missing checklist item: $_" })
        @($unexpectedChecklistIds | ForEach-Object { "unexpected checklist item: $_" })
        @($duplicateChecklistIds | ForEach-Object { "duplicate checklist item: $_" })
    ) `
    -Evidence ([pscustomobject][ordered]@{
        expected_count = $requiredChecklistIds.Count
        actual_count = $checklistIds.Count
    })

$allowedStatuses = @("passed", "partial", "blocked", "missing")
$sourceFileSet = @{}
foreach ($sourceId in $requiredSourceFileIds) {
    $sourceFileSet[$sourceId] = $true
}

$itemFailures = @()
foreach ($item in $checklist) {
    $id = [string]$item.id
    if ([string]::IsNullOrWhiteSpace($id)) {
        $itemFailures += "checklist item has a blank id"
        continue
    }

    if ([string]::IsNullOrWhiteSpace([string]$item.source)) {
        $itemFailures += "$id source is missing"
    }

    if ([string]::IsNullOrWhiteSpace([string]$item.requirement)) {
        $itemFailures += "$id requirement is missing"
    }

    if ($allowedStatuses -notcontains [string]$item.status) {
        $itemFailures += "$id status is invalid: $($item.status)"
    }

    foreach ($evidenceId in Get-ObjectArray -Object $item -Name "evidence_ids") {
        if (-not $sourceFileSet.ContainsKey([string]$evidenceId)) {
            $itemFailures += "$id references unknown evidence id: $evidenceId"
        }
    }
}

$checks += New-Check -Id "checklist_item_contract" -Passed ($itemFailures.Count -eq 0) -Failures $itemFailures

$actualStatusCounts = @{}
foreach ($status in $allowedStatuses) {
    $actualStatusCounts[$status] = 0
}

foreach ($item in $checklist) {
    $status = [string]$item.status
    if ($allowedStatuses -contains $status) {
        $actualStatusCounts[$status] = [int]$actualStatusCounts[$status] + 1
    }
}

$statusCountFailures = @()
if ($null -eq $report -or -not $report.PSObject.Properties["status_counts"]) {
    $statusCountFailures += "status_counts is missing"
}
else {
    foreach ($status in $allowedStatuses) {
        $reportedCount = 0
        if ($report.status_counts.PSObject.Properties[$status]) {
            $reportedCount = [int]$report.status_counts.$status
        }
        if ($reportedCount -ne [int]$actualStatusCounts[$status]) {
            $statusCountFailures += "status count mismatch for $status; reported=$reportedCount actual=$($actualStatusCounts[$status])"
        }
    }
}

$checks += New-Check -Id "status_counts_match_checklist" -Passed ($statusCountFailures.Count -eq 0) -Failures $statusCountFailures -Evidence ([pscustomobject][ordered]@{
    blocked = $actualStatusCounts["blocked"]
    partial = $actualStatusCounts["partial"]
    missing = $actualStatusCounts["missing"]
    passed = $actualStatusCounts["passed"]
})

$expectedReady = ($inputFailures.Count -eq 0 -and @($checklist | Where-Object { [string]$_.status -ne "passed" }).Count -eq 0)
$reportedReady = Get-ObjectBool -Object $report -Name "completion_ready"
$checks += Add-Check `
    -Id "completion_ready_consistency" `
    -Condition ($null -ne $report -and $reportedReady -eq $expectedReady) `
    -Failure "completion_ready does not match checklist/input failure state" `
    -Evidence ([pscustomobject][ordered]@{
        reported_completion_ready = $reportedReady
        expected_completion_ready = $expectedReady
    })

if ($RequireComplete) {
    $checks += Add-Check -Id "require_complete" -Condition ($reportedReady -eq $true) -Failure "completion audit is not complete"
}

if ($markdownExists) {
    $markdown = Get-Content -LiteralPath $resolvedMarkdownPath -Raw
    $markdownFailures = @()
    if ($markdown -notmatch '# Token-Ready MVP Completion Audit') {
        $markdownFailures += "Markdown title is missing"
    }
    foreach ($id in $requiredChecklistIds) {
        if ($markdown -notmatch [regex]::Escape($id)) {
            $markdownFailures += "Markdown does not include checklist id: $id"
        }
    }

    $checks += New-Check -Id "markdown_checklist_coverage" -Passed ($markdownFailures.Count -eq 0) -Failures $markdownFailures -Evidence ([pscustomobject][ordered]@{ path = $resolvedMarkdownPath })
}
else {
    $checks += New-Check -Id "markdown_checklist_coverage" -Passed $false -Failures @("Markdown report is missing") -Evidence ([pscustomobject][ordered]@{ path = $resolvedMarkdownPath })
}

$failedChecks = @($checks | Where-Object { $_.passed -ne $true })
$reportOut = [pscustomobject][ordered]@{
    schema = "archrealms.passport.token_ready_mvp_completion_audit_validation.v1"
    created_utc = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
    repo_root = $repoRoot
    report_path = $resolvedReportPath
    report_sha256 = Get-Sha256Hex -Path $resolvedReportPath
    markdown_path = $resolvedMarkdownPath
    markdown_sha256 = Get-Sha256Hex -Path $resolvedMarkdownPath
    generated = [bool]$Generate
    require_complete = [bool]$RequireComplete
    passed = ($failedChecks.Count -eq 0)
    failed_check_count = $failedChecks.Count
    checks = $checks
}

$outputDirectory = Split-Path -Parent $resolvedOutputPath
if ($outputDirectory) {
    New-Item -ItemType Directory -Force -Path $outputDirectory | Out-Null
}

Set-Content -LiteralPath $resolvedOutputPath -Value ($reportOut | ConvertTo-Json -Depth 12) -Encoding UTF8
$reportOut | ConvertTo-Json -Depth 12

if (-not $NoFail -and $failedChecks.Count -gt 0) {
    throw "Token-Ready MVP completion audit validation failed. See $resolvedOutputPath."
}
