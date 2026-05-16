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
    [string]$ProductionMvpNextActionPacketValidationReportPath = "artifacts\release\production-mvp-next-action-packet-validation-report.json",
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

    return ""
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
    $fixtureAppCommit = Get-CurrentCommit

    $preMvpPath = Join-Path $fixtureRoot "pre-mvp-internal-verification-report.json"
    $stagingPath = Join-Path $fixtureRoot "staging-readiness-report.json"
    $canaryPath = Join-Path $fixtureRoot "canary-mvp-readiness-report.json"
    $productionReadinessPath = Join-Path $fixtureRoot "production-mvp-readiness-report.json"
    $closeoutPath = Join-Path $fixtureRoot "production-mvp-closeout.manifest.json"
    $outstandingPath = Join-Path $fixtureRoot "production-mvp-outstanding-work-report.json"
    $nextActionManifestPath = Join-Path $fixtureRoot "production-mvp-next-action-packet.manifest.json"
    $nextActionPlanPath = Join-Path $fixtureRoot "next-action-plan.json"
    $nextActionPlanMarkdownPath = Join-Path $fixtureRoot "next-action-plan.md"
    $operatorInputMatrixPath = Join-Path $fixtureRoot "operator-input-matrix.json"
    $operatorInputMatrixMarkdownPath = Join-Path $fixtureRoot "operator-input-matrix.md"
    $operatorCommandsPath = Join-Path $fixtureRoot "operator-commands.ps1"
    $nextActionValidationPath = Join-Path $fixtureRoot "production-mvp-next-action-packet-validation-report.json"
    $reportPath = Join-Path $fixtureRoot "token-ready-mvp-completion-audit-report.json"
    $markdownPath = Join-Path $fixtureRoot "token-ready-mvp-completion-audit-report.md"
    $validationPath = Join-Path $fixtureRoot "token-ready-mvp-completion-audit-validation-report.json"

    $preMvpCheckIds = @(
        "core_tests",
        "windows_tests",
        "windows_identity_recovery_targeted_tests",
        "windows_device_authorization_targeted_tests",
        "windows_wallet_key_targeted_tests",
        "core_wallet_binding_targeted_tests",
        "windows_resource_contribution_targeted_tests",
        "hosted_service_tests",
        "ledger_verifier_build",
        "storage_redemption_targeted_tests",
        "core_monetary_protocol_targeted_tests",
        "windows_monetary_ledger_targeted_tests",
        "hosted_ai_targeted_tests",
        "windows_ai_gateway_targeted_tests",
        "production_monetary_provisioning_validation",
        "open_weight_ai_runtime_deployment_validation"
    )
    $preMvpRequirements = @(
        New-FixtureRequirement -Id "passport_core_contracts" -CheckIds @("core_tests")
        New-FixtureRequirement -Id "passport_windows_user_flows" -CheckIds @("windows_tests")
        New-FixtureRequirement -Id "identity_recovery_targeted_coverage" -CheckIds @("windows_identity_recovery_targeted_tests")
        New-FixtureRequirement -Id "device_authorization_targeted_coverage" -CheckIds @("windows_device_authorization_targeted_tests")
        New-FixtureRequirement -Id "wallet_key_binding_targeted_coverage" -CheckIds @("windows_wallet_key_targeted_tests", "core_wallet_binding_targeted_tests")
        New-FixtureRequirement -Id "resource_contribution_targeted_coverage" -CheckIds @("windows_resource_contribution_targeted_tests")
        New-FixtureRequirement -Id "hosted_ai_service_contracts" -CheckIds @("hosted_service_tests")
        New-FixtureRequirement -Id "ledger_export_verifier" -CheckIds @("ledger_verifier_build")
        New-FixtureRequirement -Id "storage_redemption_targeted_coverage" -CheckIds @("storage_redemption_targeted_tests")
        New-FixtureRequirement -Id "core_monetary_protocol_targeted_coverage" -CheckIds @("core_monetary_protocol_targeted_tests")
        New-FixtureRequirement -Id "windows_monetary_ledger_targeted_coverage" -CheckIds @("windows_monetary_ledger_targeted_tests")
        New-FixtureRequirement -Id "hosted_ai_targeted_coverage" -CheckIds @("hosted_ai_targeted_tests")
        New-FixtureRequirement -Id "windows_ai_gateway_targeted_coverage" -CheckIds @("windows_ai_gateway_targeted_tests")
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
        schema = "archrealms.passport.production_mvp_outstanding_work_report.v1"
        created_utc = $createdUtc
        app_commit = $fixtureAppCommit
        ready_for_production_testing = $true
        blockers = @()
        next_action_plan = @()
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
    $sourceReportRecord = [pscustomobject][ordered]@{
        path = $outstandingPath
        sha256 = Get-Sha256Hex -Path $outstandingPath
        app_commit = $fixtureAppCommit
        ready_for_production_testing = $true
        blocker_count = 0
        next_action_count = 0
    }

    Write-JsonFile -Path $nextActionPlanPath -Value ([pscustomobject][ordered]@{
        schema = "archrealms.passport.production_mvp_next_action_plan.v1"
        created_utc = $createdUtc
        app_commit = $fixtureAppCommit
        source_report = $sourceReportRecord
        actions = @()
    })
    Set-Content -LiteralPath $nextActionPlanMarkdownPath -Value "# Production MVP Next Action Plan`n`nNo next actions are required by the complete-state fixture." -Encoding UTF8
    Write-JsonFile -Path $operatorInputMatrixPath -Value ([pscustomobject][ordered]@{
        schema = "archrealms.passport.production_mvp_operator_input_matrix.v1"
        created_utc = $createdUtc
        app_commit = $fixtureAppCommit
        source_report = $sourceReportRecord
        summary = [pscustomobject][ordered]@{
            environment_variable_count = 0
            report_reference_refresh_count = 0
            readiness_evidence_item_count = 0
            provisioning_evidence_file_count = 0
            release_evidence_item_count = 0
        }
        environment_variables = @()
        report_reference_refreshes = @()
        readiness_evidence_items = @()
        provisioning_evidence_files = @()
        release_evidence_items = @()
    })
    Set-Content -LiteralPath $operatorInputMatrixMarkdownPath -Value "# Production MVP Operator Input Matrix`n`nNo operator inputs are required by the complete-state fixture." -Encoding UTF8
    Set-Content -LiteralPath $operatorCommandsPath -Value "# Production MVP next-action command checklist.`n# No commands are required by the complete-state fixture." -Encoding UTF8
    Write-JsonFile -Path $nextActionManifestPath -Value ([pscustomobject][ordered]@{
        schema = "archrealms.passport.production_mvp_next_action_packet_manifest.v1"
        created_utc = $createdUtc
        app_commit = $fixtureAppCommit
        source_report = $sourceReportRecord
        generated_files = @()
    })
    Write-JsonFile -Path $nextActionValidationPath -Value ([pscustomobject][ordered]@{
        schema = "archrealms.passport.production_mvp_next_action_packet_validation.v1"
        created_utc = $createdUtc
        app_commit = $fixtureAppCommit
        passed = $true
        failed_check_count = 0
        manifest_path = $nextActionManifestPath
        manifest_sha256 = Get-Sha256Hex -Path $nextActionManifestPath
        plan_path = $nextActionPlanPath
        plan_sha256 = Get-Sha256Hex -Path $nextActionPlanPath
        markdown_path = $nextActionPlanMarkdownPath
        markdown_sha256 = Get-Sha256Hex -Path $nextActionPlanMarkdownPath
        operator_input_matrix_path = $operatorInputMatrixPath
        operator_input_matrix_sha256 = Get-Sha256Hex -Path $operatorInputMatrixPath
        operator_input_matrix_markdown_path = $operatorInputMatrixMarkdownPath
        operator_input_matrix_markdown_sha256 = Get-Sha256Hex -Path $operatorInputMatrixMarkdownPath
        operator_commands_path = $operatorCommandsPath
        operator_commands_sha256 = Get-Sha256Hex -Path $operatorCommandsPath
        checks = @()
    })

    return [pscustomobject][ordered]@{
        pre_mvp_internal_verification = $preMvpPath
        staging_readiness = $stagingPath
        canary_mvp_readiness = $canaryPath
        production_mvp_readiness = $productionReadinessPath
        production_mvp_closeout = $closeoutPath
        production_mvp_outstanding_work = $outstandingPath
        production_mvp_next_action_packet_manifest = $nextActionManifestPath
        production_mvp_next_action_plan = $nextActionPlanPath
        production_mvp_next_action_plan_markdown = $nextActionPlanMarkdownPath
        production_mvp_operator_input_matrix = $operatorInputMatrixPath
        production_mvp_operator_input_matrix_markdown = $operatorInputMatrixMarkdownPath
        production_mvp_operator_commands = $operatorCommandsPath
        production_mvp_next_action_packet_validation = $nextActionValidationPath
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
        [string]$ProductionMvpNextActionPacketManifestPath,
        [string]$ProductionMvpNextActionPlanPath,
        [string]$ProductionMvpNextActionPlanMarkdownPath,
        [string]$ProductionMvpOperatorInputMatrixPath,
        [string]$ProductionMvpOperatorInputMatrixMarkdownPath,
        [string]$ProductionMvpOperatorCommandsPath,
        [string]$ProductionMvpNextActionPacketValidationPath,
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
        "-ProductionMvpNextActionPacketManifestPath",
        $ProductionMvpNextActionPacketManifestPath,
        "-ProductionMvpNextActionPlanPath",
        $ProductionMvpNextActionPlanPath,
        "-ProductionMvpNextActionPlanMarkdownPath",
        $ProductionMvpNextActionPlanMarkdownPath,
        "-ProductionMvpOperatorInputMatrixPath",
        $ProductionMvpOperatorInputMatrixPath,
        "-ProductionMvpOperatorInputMatrixMarkdownPath",
        $ProductionMvpOperatorInputMatrixMarkdownPath,
        "-ProductionMvpOperatorCommandsPath",
        $ProductionMvpOperatorCommandsPath,
        "-ProductionMvpNextActionPacketValidationReportPath",
        $ProductionMvpNextActionPacketValidationPath,
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

function Get-OperatorCommandScriptPath {
    param([string]$Command)

    if ([string]::IsNullOrWhiteSpace($Command)) {
        return ""
    }

    $match = [regex]::Match($Command, '(?i)(?:^|\s)-File\s+(?:"([^"]+)"|''([^'']+)''|([^\s]+))')
    if (-not $match.Success) {
        return ""
    }

    for ($i = 1; $i -le 3; $i++) {
        if ($match.Groups[$i].Success -and -not [string]::IsNullOrWhiteSpace($match.Groups[$i].Value)) {
            return [string]$match.Groups[$i].Value
        }
    }

    return ""
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

$resolvedPreMvpInternalVerificationReportPath = Resolve-RepoPath -Path $PreMvpInternalVerificationReportPath
$resolvedStagingReadinessReportPath = Resolve-RepoPath -Path $StagingReadinessReportPath
$resolvedCanaryMvpReadinessReportPath = Resolve-RepoPath -Path $CanaryMvpReadinessReportPath
$resolvedProductionMvpReadinessReportPath = Resolve-RepoPath -Path $ProductionMvpReadinessReportPath
$resolvedProductionMvpCloseoutManifestPath = Resolve-RepoPath -Path $ProductionMvpCloseoutManifestPath
$resolvedProductionMvpOutstandingWorkReportPath = Resolve-RepoPath -Path $ProductionMvpOutstandingWorkReportPath
$resolvedProductionMvpNextActionPacketManifestPath = Resolve-RepoPath -Path $ProductionMvpNextActionPacketManifestPath
$resolvedProductionMvpNextActionPlanPath = Resolve-RepoPath -Path $ProductionMvpNextActionPlanPath
$resolvedProductionMvpNextActionPlanMarkdownPath = Resolve-RepoPath -Path $ProductionMvpNextActionPlanMarkdownPath
$resolvedProductionMvpOperatorInputMatrixPath = Resolve-RepoPath -Path $ProductionMvpOperatorInputMatrixPath
$resolvedProductionMvpOperatorInputMatrixMarkdownPath = Resolve-RepoPath -Path $ProductionMvpOperatorInputMatrixMarkdownPath
$resolvedProductionMvpOperatorCommandsPath = Resolve-RepoPath -Path $ProductionMvpOperatorCommandsPath
$resolvedProductionMvpNextActionPacketValidationReportPath = Resolve-RepoPath -Path $ProductionMvpNextActionPacketValidationReportPath
$resolvedReportPath = Resolve-RepoPath -Path $ReportPath
$resolvedMarkdownPath = Resolve-RepoPath -Path $MarkdownPath
$resolvedOutputPath = Resolve-RepoPath -Path $OutputPath
$currentCommit = Get-CurrentCommit

if ($UseGeneratedFixture) {
    $fixture = New-CompletionAuditFixture
    $resolvedPreMvpInternalVerificationReportPath = $fixture.pre_mvp_internal_verification
    $resolvedStagingReadinessReportPath = $fixture.staging_readiness
    $resolvedCanaryMvpReadinessReportPath = $fixture.canary_mvp_readiness
    $resolvedProductionMvpReadinessReportPath = $fixture.production_mvp_readiness
    $resolvedProductionMvpCloseoutManifestPath = $fixture.production_mvp_closeout
    $resolvedProductionMvpOutstandingWorkReportPath = $fixture.production_mvp_outstanding_work
    $resolvedProductionMvpNextActionPacketManifestPath = $fixture.production_mvp_next_action_packet_manifest
    $resolvedProductionMvpNextActionPlanPath = $fixture.production_mvp_next_action_plan
    $resolvedProductionMvpNextActionPlanMarkdownPath = $fixture.production_mvp_next_action_plan_markdown
    $resolvedProductionMvpOperatorInputMatrixPath = $fixture.production_mvp_operator_input_matrix
    $resolvedProductionMvpOperatorInputMatrixMarkdownPath = $fixture.production_mvp_operator_input_matrix_markdown
    $resolvedProductionMvpOperatorCommandsPath = $fixture.production_mvp_operator_commands
    $resolvedProductionMvpNextActionPacketValidationReportPath = $fixture.production_mvp_next_action_packet_validation
    $resolvedReportPath = $fixture.completion_audit_report
    $resolvedMarkdownPath = $fixture.completion_audit_markdown
    $resolvedOutputPath = $fixture.completion_audit_validation
    $Generate = $true
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
        -ProductionMvpNextActionPacketManifestPath $resolvedProductionMvpNextActionPacketManifestPath `
        -ProductionMvpNextActionPlanPath $resolvedProductionMvpNextActionPlanPath `
        -ProductionMvpNextActionPlanMarkdownPath $resolvedProductionMvpNextActionPlanMarkdownPath `
        -ProductionMvpOperatorInputMatrixPath $resolvedProductionMvpOperatorInputMatrixPath `
        -ProductionMvpOperatorInputMatrixMarkdownPath $resolvedProductionMvpOperatorInputMatrixMarkdownPath `
        -ProductionMvpOperatorCommandsPath $resolvedProductionMvpOperatorCommandsPath `
        -ProductionMvpNextActionPacketValidationPath $resolvedProductionMvpNextActionPacketValidationReportPath `
        -JsonPath $resolvedReportPath `
        -MarkdownOutputPath $resolvedMarkdownPath
    $checks += Add-Check -Id "generator_exit_code" -Condition ($generatorResult.exit_code -eq 0) -Failure "completion audit generator failed" -Evidence $generatorResult
}

$reportExists = Test-Path -LiteralPath $resolvedReportPath -PathType Leaf
$markdownExists = Test-Path -LiteralPath $resolvedMarkdownPath -PathType Leaf
$checks += Add-Check -Id "report_exists" -Condition $reportExists -Failure "completion audit report is missing" -Evidence ([pscustomobject][ordered]@{ path = $resolvedReportPath })
$checks += Add-Check -Id "markdown_exists" -Condition $markdownExists -Failure "completion audit Markdown report is missing" -Evidence ([pscustomobject][ordered]@{ path = $resolvedMarkdownPath })

$report = Read-JsonFile -Path $resolvedReportPath
$preMvpReport = Read-JsonFile -Path $resolvedPreMvpInternalVerificationReportPath
$checks += Add-Check -Id "schema" -Condition ($null -ne $report -and [string]$report.schema -eq "archrealms.passport.token_ready_mvp_completion_audit.v1") -Failure "completion audit schema is invalid or missing"
$checks += Add-Check -Id "app_commit" -Condition ($null -ne $report -and [string]$report.app_commit -match '^[0-9a-f]{7,40}$') -Failure "app_commit is missing or not a git commit hash" -Evidence ([pscustomobject][ordered]@{ app_commit = $(if ($null -eq $report) { "" } else { [string]$report.app_commit }) })

$reportCommit = if ($null -ne $report -and $report.PSObject.Properties["app_commit"]) { [string]$report.app_commit } else { "" }
$commitFailures = @()
if ([string]::IsNullOrWhiteSpace($currentCommit)) {
    $commitFailures += "current git commit could not be resolved."
}
elseif ($reportCommit -ne $currentCommit) {
    $commitFailures += "completion audit app_commit $reportCommit does not match current app commit $currentCommit."
}
$checks += New-Check -Id "app_commit_freshness" -Passed ($commitFailures.Count -eq 0) -Failures $commitFailures -Evidence ([pscustomobject][ordered]@{ report_app_commit = $reportCommit; current_app_commit = $currentCommit })

$requiredSourceFileIds = @(
    "pre_mvp_internal_verification",
    "staging_readiness",
    "canary_mvp_readiness",
    "production_mvp_readiness",
    "production_mvp_closeout",
    "production_mvp_outstanding_work",
    "production_mvp_next_action_packet_manifest",
    "production_mvp_next_action_plan",
    "production_mvp_next_action_plan_markdown",
    "production_mvp_operator_input_matrix",
    "production_mvp_operator_input_matrix_markdown",
    "production_mvp_operator_commands",
    "production_mvp_next_action_packet_validation"
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

$sourceFreshnessFailures = @()
foreach ($sourceId in $requiredSourceFileIds) {
    $source = Get-SourceFile -Report $report -Id $sourceId
    if ($null -eq $source) {
        continue
    }

    $resolvedSourcePath = Resolve-RepoPath -Path ([string]$source.path)
    if ([string]::IsNullOrWhiteSpace($resolvedSourcePath) -or -not (Test-Path -LiteralPath $resolvedSourcePath -PathType Leaf)) {
        continue
    }

    $currentSourceSha = Get-Sha256Hex -Path $resolvedSourcePath
    $reportedSourceSha = [string]$source.sha256
    if ($reportedSourceSha -ne $currentSourceSha) {
        $sourceFreshnessFailures += "$sourceId SHA-256 $reportedSourceSha does not match current file SHA-256 $currentSourceSha."
    }
}
$checks += New-Check -Id "source_file_freshness" -Passed ($sourceFreshnessFailures.Count -eq 0) -Failures $sourceFreshnessFailures -Evidence ([pscustomobject][ordered]@{
    source_ids = $requiredSourceFileIds
})

$sourceFixtureFailures = @()
if (-not $UseGeneratedFixture) {
    foreach ($sourceId in $requiredSourceFileIds) {
        $source = Get-SourceFile -Report $report -Id $sourceId
        if ($null -eq $source) {
            continue
        }

        $resolvedSourcePath = Resolve-RepoPath -Path ([string]$source.path)
        if ($resolvedSourcePath -match '(?i)(^|[\\/])[^\\/]*fixture[^\\/]*([\\/]|$)') {
            $sourceFixtureFailures += "$sourceId points at fixture evidence in real audit mode: $resolvedSourcePath"
        }
    }
}
$checks += New-Check -Id "source_file_not_fixture" -Passed ($sourceFixtureFailures.Count -eq 0) -Failures $sourceFixtureFailures -Evidence ([pscustomobject][ordered]@{
    use_generated_fixture = [bool]$UseGeneratedFixture
    source_ids = $requiredSourceFileIds
})

$commitSourceIds = @(
    "production_mvp_outstanding_work",
    "production_mvp_next_action_packet_manifest",
    "production_mvp_next_action_plan",
    "production_mvp_operator_input_matrix",
    "production_mvp_next_action_packet_validation"
)
$sourceCommitFailures = @()
foreach ($sourceId in $commitSourceIds) {
    $source = Get-SourceFile -Report $report -Id $sourceId
    if ($null -eq $source) {
        continue
    }

    $sourceDocument = Read-JsonFile -Path ([string]$source.path)
    if ($null -eq $sourceDocument) {
        $sourceCommitFailures += "$sourceId could not be parsed for app_commit validation."
        continue
    }

    $sourceCommit = if ($sourceDocument.PSObject.Properties["app_commit"]) { [string]$sourceDocument.app_commit } else { "" }
    if ($sourceCommit -notmatch '^[0-9a-f]{7,40}$') {
        $sourceCommitFailures += "$sourceId app_commit is missing or invalid."
    }
    elseif ($sourceCommit -ne $reportCommit) {
        $sourceCommitFailures += "$sourceId app_commit $sourceCommit does not match completion audit app_commit $reportCommit."
    }
    elseif (-not [string]::IsNullOrWhiteSpace($currentCommit) -and $sourceCommit -ne $currentCommit) {
        $sourceCommitFailures += "$sourceId app_commit $sourceCommit does not match current app commit $currentCommit."
    }

    if ($sourceDocument.PSObject.Properties["source_report"]) {
        $sourceReportCommit = if ($sourceDocument.source_report.PSObject.Properties["app_commit"]) { [string]$sourceDocument.source_report.app_commit } else { "" }
        if ($sourceReportCommit -notmatch '^[0-9a-f]{7,40}$') {
            $sourceCommitFailures += "$sourceId source_report.app_commit is missing or invalid."
        }
        elseif ($sourceReportCommit -ne $reportCommit) {
            $sourceCommitFailures += "$sourceId source_report.app_commit $sourceReportCommit does not match completion audit app_commit $reportCommit."
        }
    }
}
$checks += New-Check -Id "source_app_commit_freshness" -Passed ($sourceCommitFailures.Count -eq 0) -Failures $sourceCommitFailures -Evidence ([pscustomobject][ordered]@{ source_ids = $commitSourceIds; current_app_commit = $currentCommit; report_app_commit = $reportCommit })

$packetValidationSource = Get-SourceFile -Report $report -Id "production_mvp_next_action_packet_validation"
$packetValidation = $(if ($null -ne $packetValidationSource) { Read-JsonFile -Path ([string]$packetValidationSource.path) } else { $null })
$packetPlan = $null
$packetValidationFailures = @()
if ($null -eq $packetValidation) {
    $packetValidationFailures += "next-action packet validation report is missing or unreadable"
}
else {
    if ([string]$packetValidation.schema -ne "archrealms.passport.production_mvp_next_action_packet_validation.v1") {
        $packetValidationFailures += "next-action packet validation schema is unexpected"
    }
    if ($packetValidation.passed -ne $true) {
        $packetValidationFailures += "next-action packet validation did not pass"
    }

    $packetSourceMappings = @(
        [pscustomobject]@{ source_id = "production_mvp_next_action_packet_manifest"; path_property = "manifest_path"; sha_property = "manifest_sha256" },
        [pscustomobject]@{ source_id = "production_mvp_next_action_plan"; path_property = "plan_path"; sha_property = "plan_sha256" },
        [pscustomobject]@{ source_id = "production_mvp_next_action_plan_markdown"; path_property = "markdown_path"; sha_property = "markdown_sha256" },
        [pscustomobject]@{ source_id = "production_mvp_operator_input_matrix"; path_property = "operator_input_matrix_path"; sha_property = "operator_input_matrix_sha256" },
        [pscustomobject]@{ source_id = "production_mvp_operator_input_matrix_markdown"; path_property = "operator_input_matrix_markdown_path"; sha_property = "operator_input_matrix_markdown_sha256" },
        [pscustomobject]@{ source_id = "production_mvp_operator_commands"; path_property = "operator_commands_path"; sha_property = "operator_commands_sha256" }
    )

    foreach ($mapping in $packetSourceMappings) {
        $source = Get-SourceFile -Report $report -Id $mapping.source_id
        if ($null -eq $source) {
            $packetValidationFailures += "completion audit is missing packet source file: $($mapping.source_id)"
            continue
        }

        $validationPath = if ($packetValidation.PSObject.Properties[$mapping.path_property]) { [string]$packetValidation.PSObject.Properties[$mapping.path_property].Value } else { "" }
        $validationSha = if ($packetValidation.PSObject.Properties[$mapping.sha_property]) { [string]$packetValidation.PSObject.Properties[$mapping.sha_property].Value } else { "" }
        if ([string]::IsNullOrWhiteSpace($validationPath)) {
            $packetValidationFailures += "next-action packet validation lacks $($mapping.path_property)"
        }
        elseif ([System.IO.Path]::GetFullPath($validationPath) -ne [System.IO.Path]::GetFullPath([string]$source.path)) {
            $packetValidationFailures += "$($mapping.source_id) path does not match next-action packet validation"
        }

        if ([string]::IsNullOrWhiteSpace($validationSha)) {
            $packetValidationFailures += "next-action packet validation lacks $($mapping.sha_property)"
        }
        elseif ([string]$source.sha256 -ne $validationSha) {
            $packetValidationFailures += "$($mapping.source_id) SHA-256 does not match next-action packet validation"
        }
    }

    $packetPlanSource = Get-SourceFile -Report $report -Id "production_mvp_next_action_plan"
    $packetPlan = $(if ($null -ne $packetPlanSource) { Read-JsonFile -Path ([string]$packetPlanSource.path) } else { $null })
    $hasStaffStewardPilotCommand = $false
    if ($null -ne $packetPlan) {
        foreach ($action in @(Get-ObjectArray -Object $packetPlan -Name "actions")) {
            foreach ($command in @(Get-ObjectArray -Object $action -Name "commands")) {
                if ([string]$command -match 'Complete-PassportPreMvpStaffStewardPilotHandoff\.ps1') {
                    $hasStaffStewardPilotCommand = $true
                }
            }
        }
    }

    if ($hasStaffStewardPilotCommand) {
        $hashPrefillChecks = @(Get-ObjectArray -Object $packetValidation -Name "checks" | Where-Object { [string]$_.id -eq "staff_steward_simulation_hash_prefill" })
        if ($hashPrefillChecks.Count -eq 0) {
            $packetValidationFailures += "next-action packet validation is missing staff_steward_simulation_hash_prefill while staff/steward pilot closeout commands are present"
        }
        elseif (@($hashPrefillChecks | Where-Object { $_.passed -eq $true }).Count -eq 0) {
            $packetValidationFailures += "next-action packet validation staff_steward_simulation_hash_prefill did not pass"
        }
    }
}
$checks += New-Check -Id "next_action_packet_handoff_validation" -Passed ($packetValidationFailures.Count -eq 0) -Failures $packetValidationFailures -Evidence $packetValidationSource

$reportedCompletionReady = Get-ObjectBool -Object $report -Name "completion_ready"
$reportedLocalImplementationReadyForActions = Get-ObjectBool -Object $report -Name "local_implementation_ready"
$externalActionFailures = @()
$externalActionEvidence = [pscustomobject][ordered]@{
    completion_ready = $reportedCompletionReady
    local_implementation_ready = $reportedLocalImplementationReadyForActions
    action_count = 0
}
if ($reportedLocalImplementationReadyForActions -eq $true -and $reportedCompletionReady -ne $true) {
    if ($null -eq $packetPlan) {
        $externalActionFailures += "local implementation is ready but the next-action plan could not be read."
    }
    else {
        $remainingActions = @(Get-ObjectArray -Object $packetPlan -Name "actions")
        $externalActionEvidence.action_count = $remainingActions.Count
        if ($remainingActions.Count -eq 0) {
            $externalActionFailures += "local implementation is ready and completion is not ready, but no remaining actions are present."
        }

        foreach ($action in $remainingActions) {
            $actionId = [string]$action.id
            if ([string]::IsNullOrWhiteSpace($actionId)) {
                $actionId = "<blank>"
            }

            if ($action.PSObject.Properties["operator_input_required"] -and [bool]$action.operator_input_required -ne $true) {
                $externalActionFailures += "remaining action $actionId is not marked operator_input_required=true."
            }
            elseif (-not $action.PSObject.Properties["operator_input_required"]) {
                $externalActionFailures += "remaining action $actionId is missing operator_input_required."
            }

            if (-not $action.PSObject.Properties["required_operator_input_count"]) {
                $externalActionFailures += "remaining action $actionId is missing required_operator_input_count."
            }
            elseif ([int]$action.required_operator_input_count -lt 1) {
                $externalActionFailures += "remaining action $actionId has no required operator inputs."
            }

            if ($action.PSObject.Properties["blocked_by_external_actor"] -and [bool]$action.blocked_by_external_actor -ne $true) {
                $externalActionFailures += "remaining action $actionId is not marked blocked_by_external_actor=true."
            }
            elseif (-not $action.PSObject.Properties["blocked_by_external_actor"]) {
                $externalActionFailures += "remaining action $actionId is missing blocked_by_external_actor."
            }

            $externalBlockerIds = @(Get-ObjectArray -Object $action -Name "external_blocker_ids" | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
            if ($externalBlockerIds.Count -eq 0) {
                $externalActionFailures += "remaining action $actionId does not name any external_blocker_ids."
            }

            $commands = @(Get-ObjectArray -Object $action -Name "commands" | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
            if ($commands.Count -eq 0) {
                $externalActionFailures += "remaining action $actionId has no operator command."
            }
        }
    }
}
$checks += New-Check -Id "local_ready_remaining_actions_external" -Passed ($externalActionFailures.Count -eq 0) -Failures $externalActionFailures -Evidence $externalActionEvidence

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
$allowedRemainingWorkTypes = @(
    "none",
    "external_verification",
    "staging_provisioning",
    "canary_provisioning",
    "package_signing",
    "monetary_provisioning",
    "managed_storage_provisioning",
    "ai_runtime_provisioning",
    "release_approval",
    "production_closeout",
    "implementation_gap",
    "unclassified"
)
$sourceFileSet = @{}
foreach ($sourceId in $requiredSourceFileIds) {
    $sourceFileSet[$sourceId] = $true
}

$preMvpCheckSet = @{}
$preMvpPassedCheckSet = @{}
if ($null -ne $preMvpReport -and $preMvpReport.PSObject.Properties["checks"]) {
    foreach ($preMvpCheck in @($preMvpReport.checks)) {
        $preMvpCheckId = [string]$preMvpCheck.id
        if (-not [string]::IsNullOrWhiteSpace($preMvpCheckId)) {
            $preMvpCheckSet[$preMvpCheckId] = $true
            if ($preMvpCheck.passed -eq $true) {
                $preMvpPassedCheckSet[$preMvpCheckId] = $true
            }
        }
    }
}

$requiredCoverageByChecklistId = @{
    prd_success_identity_recovery = @("windows_identity_recovery_targeted_tests")
    prd_success_device_authorization = @("windows_device_authorization_targeted_tests")
    prd_success_wallet_key_binding = @("windows_wallet_key_targeted_tests", "core_wallet_binding_targeted_tests")
    prd_success_real_arch = @("core_monetary_protocol_targeted_tests", "windows_monetary_ledger_targeted_tests")
    prd_success_real_cc = @("core_monetary_protocol_targeted_tests", "windows_monetary_ledger_targeted_tests")
    prd_success_storage_redemption = @("storage_redemption_targeted_tests", "windows_monetary_ledger_targeted_tests")
    prd_success_storage_escrow_burn_refund_recredit = @("storage_redemption_targeted_tests", "windows_monetary_ledger_targeted_tests")
    prd_success_resource_contribution = @("windows_resource_contribution_targeted_tests")
    prd_success_arch_cc_conversion = @("core_monetary_protocol_targeted_tests", "windows_monetary_ledger_targeted_tests")
    prd_success_no_post_genesis_arch_mint = @("core_monetary_protocol_targeted_tests", "windows_monetary_ledger_targeted_tests")
    prd_success_cc_capacity_constrained = @("core_monetary_protocol_targeted_tests", "windows_monetary_ledger_targeted_tests", "production_monetary_provisioning_validation")
    prd_success_cc_does_not_create_arch = @("core_monetary_protocol_targeted_tests", "windows_monetary_ledger_targeted_tests", "production_monetary_provisioning_validation")
    prd_success_ledger_export_auditability = @("core_monetary_protocol_targeted_tests", "windows_monetary_ledger_targeted_tests", "ledger_verifier_build")
    prd_success_hosted_ai = @("hosted_ai_targeted_tests", "windows_ai_gateway_targeted_tests", "open_weight_ai_runtime_deployment_validation")
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

    if ([string]::IsNullOrWhiteSpace([string]$item.summary)) {
        $itemFailures += "$id summary is missing"
    }

    if ($allowedStatuses -notcontains [string]$item.status) {
        $itemFailures += "$id status is invalid: $($item.status)"
    }

    $remainingWorkType = if ($item.PSObject.Properties["remaining_work_type"]) { [string]$item.remaining_work_type } else { "" }
    if ([string]::IsNullOrWhiteSpace($remainingWorkType)) {
        $itemFailures += "$id remaining_work_type is missing"
    }
    elseif ($allowedRemainingWorkTypes -notcontains $remainingWorkType) {
        $itemFailures += "$id remaining_work_type is invalid: $remainingWorkType"
    }

    if (-not $item.PSObject.Properties["implementation_ready"]) {
        $itemFailures += "$id implementation_ready is missing"
    }
    elseif ([string]$item.status -eq "passed" -and [bool]$item.implementation_ready -ne $true) {
        $itemFailures += "$id is passed but implementation_ready is not true"
    }

    if ([string]$item.status -eq "passed" -and -not [string]::IsNullOrWhiteSpace($remainingWorkType) -and $remainingWorkType -ne "none") {
        $itemFailures += "$id is passed but remaining_work_type is not none"
    }

    if ([string]$item.status -ne "passed" -and ($remainingWorkType -eq "none" -or $remainingWorkType -eq "unclassified")) {
        $itemFailures += "$id is not passed but remaining_work_type is $remainingWorkType"
    }

    foreach ($evidenceId in Get-ObjectArray -Object $item -Name "evidence_ids") {
        if (-not $sourceFileSet.ContainsKey([string]$evidenceId)) {
            $itemFailures += "$id references unknown evidence id: $evidenceId"
        }
    }

    $coverageCheckIds = @(Get-ObjectArray -Object $item -Name "coverage_check_ids" | ForEach-Object { [string]$_ })
    if ($requiredCoverageByChecklistId.ContainsKey($id)) {
        foreach ($requiredCoverageId in @($requiredCoverageByChecklistId[$id])) {
            if ($coverageCheckIds -notcontains $requiredCoverageId) {
                $itemFailures += "$id is missing required coverage check id: $requiredCoverageId"
            }
        }
    }

    if ($coverageCheckIds.Count -gt 0) {
        $evidenceIds = @(Get-ObjectArray -Object $item -Name "evidence_ids" | ForEach-Object { [string]$_ })
        if ($evidenceIds -notcontains "pre_mvp_internal_verification") {
            $itemFailures += "$id has coverage_check_ids but does not reference pre_mvp_internal_verification evidence"
        }

        foreach ($coverageCheckId in $coverageCheckIds) {
            if (-not $preMvpCheckSet.ContainsKey($coverageCheckId)) {
                $itemFailures += "$id references unknown pre-MVP coverage check id: $coverageCheckId"
            }
            elseif (([string]$item.status -eq "passed" -or [string]$item.status -eq "partial") -and -not $preMvpPassedCheckSet.ContainsKey($coverageCheckId)) {
                $itemFailures += "$id is $($item.status) but pre-MVP coverage check did not pass: $coverageCheckId"
            }
        }

        $coverageEvidence = @(Get-ObjectArray -Object $item -Name "coverage_evidence")
        $coverageEvidenceIds = @($coverageEvidence | ForEach-Object { [string]$_.check_id })
        $missingCoverageEvidenceIds = @($coverageCheckIds | Where-Object { $coverageEvidenceIds -notcontains $_ })
        $unexpectedCoverageEvidenceIds = @($coverageEvidenceIds | Where-Object { $coverageCheckIds -notcontains $_ })
        $duplicateCoverageEvidenceIds = @($coverageEvidenceIds | Group-Object | Where-Object { $_.Count -gt 1 } | ForEach-Object { $_.Name })

        foreach ($missingCoverageEvidenceId in $missingCoverageEvidenceIds) {
            $itemFailures += "$id is missing coverage evidence for check id: $missingCoverageEvidenceId"
        }
        foreach ($unexpectedCoverageEvidenceId in $unexpectedCoverageEvidenceIds) {
            $itemFailures += "$id includes unexpected coverage evidence for check id: $unexpectedCoverageEvidenceId"
        }
        foreach ($duplicateCoverageEvidenceId in $duplicateCoverageEvidenceIds) {
            $itemFailures += "$id includes duplicate coverage evidence for check id: $duplicateCoverageEvidenceId"
        }

        foreach ($coverage in $coverageEvidence) {
            $coverageId = [string]$coverage.check_id
            if ([string]::IsNullOrWhiteSpace($coverageId)) {
                $itemFailures += "$id coverage evidence includes a blank check_id"
                continue
            }

            $preMvpCheck = Get-Check -Report $preMvpReport -Id $coverageId
            $expectedPresent = $null -ne $preMvpCheck
            if ([bool]$coverage.present -ne $expectedPresent) {
                $itemFailures += "$id coverage evidence present flag does not match pre-MVP report for check id: $coverageId"
            }

            $expectedPassed = $expectedPresent -and $preMvpCheck.passed -eq $true
            if ([bool]$coverage.passed -ne $expectedPassed) {
                $itemFailures += "$id coverage evidence passed flag does not match pre-MVP report for check id: $coverageId"
            }

            if ($expectedPresent -and [string]::IsNullOrWhiteSpace([string]$coverage.description)) {
                $itemFailures += "$id coverage evidence description is missing for check id: $coverageId"
            }

            if ($expectedPresent -and -not $coverage.PSObject.Properties["evidence"]) {
                $itemFailures += "$id coverage evidence payload is missing for check id: $coverageId"
            }

            $coverageFailures = Get-ObjectArray -Object $coverage -Name "failures"
            if ([int]$coverage.failure_count -ne $coverageFailures.Count) {
                $itemFailures += "$id coverage evidence failure_count does not match failures length for check id: $coverageId"
            }
        }
    }

    $operatorActions = Get-ObjectArray -Object $item -Name "operator_actions"
    $operatorCommandCount = 0
    foreach ($operatorAction in $operatorActions) {
        if ([string]::IsNullOrWhiteSpace([string]$operatorAction.id)) {
            $itemFailures += "$id operator action has a blank id"
        }
        if ([string]::IsNullOrWhiteSpace([string]$operatorAction.action)) {
            $itemFailures += "$id operator action text is missing"
        }

        $operatorCommands = Get-ObjectArray -Object $operatorAction -Name "commands"
        $operatorCommandCount += $operatorCommands.Count
        foreach ($operatorCommand in $operatorCommands) {
            if ([string]::IsNullOrWhiteSpace([string]$operatorCommand)) {
                $itemFailures += "$id operator action includes a blank command"
                continue
            }

            $scriptPath = Get-OperatorCommandScriptPath -Command ([string]$operatorCommand)
            if ([string]::IsNullOrWhiteSpace($scriptPath)) {
                $itemFailures += "$id operator action command must include a PowerShell -File script path: $operatorCommand"
                continue
            }

            $normalizedScriptPath = $scriptPath -replace '/', '\'
            if ($normalizedScriptPath -notmatch '^tools\\release\\[^\\]+\.ps1$') {
                $itemFailures += "$id operator action command must target a tools\release PowerShell script: $operatorCommand"
                continue
            }

            $resolvedScriptPath = Resolve-RepoPath -Path $scriptPath
            if (-not (Test-Path -LiteralPath $resolvedScriptPath -PathType Leaf)) {
                $itemFailures += "$id operator action command references a missing script: $scriptPath"
            }
        }
    }

    $nextActionCommands = Get-ObjectArray -Object $item -Name "next_action_commands"
    foreach ($nextActionCommand in $nextActionCommands) {
        if ([string]::IsNullOrWhiteSpace([string]$nextActionCommand)) {
            $itemFailures += "$id next_action_commands includes a blank command"
            continue
        }

        $scriptPath = Get-OperatorCommandScriptPath -Command ([string]$nextActionCommand)
        if ([string]::IsNullOrWhiteSpace($scriptPath)) {
            $itemFailures += "$id next_action_commands entry must include a PowerShell -File script path: $nextActionCommand"
            continue
        }

        $normalizedScriptPath = $scriptPath -replace '/', '\'
        if ($normalizedScriptPath -notmatch '^tools\\release\\[^\\]+\.ps1$') {
            $itemFailures += "$id next_action_commands entry must target a tools\release PowerShell script: $nextActionCommand"
            continue
        }

        $resolvedScriptPath = Resolve-RepoPath -Path $scriptPath
        if (-not (Test-Path -LiteralPath $resolvedScriptPath -PathType Leaf)) {
            $itemFailures += "$id next_action_commands entry references a missing script: $scriptPath"
        }
    }

    $primaryOperatorActions = @($operatorActions | Where-Object {
            $null -ne $_ -and
            $_.PSObject.Properties["action"] -and
            -not [string]::IsNullOrWhiteSpace([string]$_.action)
        } | Select-Object -First 1)

    if ($primaryOperatorActions.Count -gt 0) {
        $primaryOperatorAction = $primaryOperatorActions[0]
        if ([string]$item.next_action -ne [string]$primaryOperatorAction.action) {
            $itemFailures += "$id next_action does not match the primary operator action"
        }
        if ($primaryOperatorAction.PSObject.Properties["id"] -and [string]$item.next_action_id -ne [string]$primaryOperatorAction.id) {
            $itemFailures += "$id next_action_id does not match the primary operator action id"
        }
        if ($primaryOperatorAction.PSObject.Properties["title"] -and [string]$item.next_action_title -ne [string]$primaryOperatorAction.title) {
            $itemFailures += "$id next_action_title does not match the primary operator action title"
        }

        $primaryCommands = @(Get-ObjectArray -Object $primaryOperatorAction -Name "commands" | ForEach-Object { [string]$_ })
        $nextCommands = @($nextActionCommands | ForEach-Object { [string]$_ })
        foreach ($primaryCommand in $primaryCommands) {
            if ($nextCommands -notcontains $primaryCommand) {
                $itemFailures += "$id next_action_commands is missing primary operator command: $primaryCommand"
            }
        }
    }
    elseif (-not [string]::IsNullOrWhiteSpace([string]$item.next_action)) {
        $itemFailures += "$id has next_action but no primary operator action"
    }

    if ([string]$item.status -ne "passed") {
        if ($operatorActions.Count -eq 0) {
            $itemFailures += "$id is not passed but has no operator actions"
        }
        elseif ($operatorCommandCount -eq 0) {
            $itemFailures += "$id is not passed but has no operator action commands"
        }

        if ([string]::IsNullOrWhiteSpace([string]$item.next_action)) {
            $itemFailures += "$id is not passed but has no next_action"
        }
        if ($nextActionCommands.Count -eq 0) {
            $itemFailures += "$id is not passed but has no next_action_commands"
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

$actualRemainingWorkCounts = @{}
foreach ($item in @($checklist | Where-Object { [string]$_.status -ne "passed" })) {
    $remainingType = if ($item.PSObject.Properties["remaining_work_type"]) { [string]$item.remaining_work_type } else { "" }
    if ([string]::IsNullOrWhiteSpace($remainingType)) {
        $remainingType = "missing"
    }

    if (-not $actualRemainingWorkCounts.ContainsKey($remainingType)) {
        $actualRemainingWorkCounts[$remainingType] = 0
    }
    $actualRemainingWorkCounts[$remainingType] = [int]$actualRemainingWorkCounts[$remainingType] + 1
}

$remainingWorkCountFailures = @()
if ($null -eq $report -or -not $report.PSObject.Properties["remaining_work_counts"]) {
    $remainingWorkCountFailures += "remaining_work_counts is missing"
}
else {
    $reportedRemainingWorkTypes = @($report.remaining_work_counts.PSObject.Properties | ForEach-Object { $_.Name })
    $actualRemainingWorkTypes = @($actualRemainingWorkCounts.Keys)
    foreach ($remainingType in @($actualRemainingWorkTypes | Where-Object { $reportedRemainingWorkTypes -notcontains $_ })) {
        $remainingWorkCountFailures += "remaining_work_counts is missing type: $remainingType"
    }
    foreach ($remainingType in @($reportedRemainingWorkTypes | Where-Object { $actualRemainingWorkTypes -notcontains $_ })) {
        $remainingWorkCountFailures += "remaining_work_counts includes unexpected type: $remainingType"
    }
    foreach ($remainingType in $actualRemainingWorkTypes) {
        if ($report.remaining_work_counts.PSObject.Properties[$remainingType]) {
            $reportedCount = [int]$report.remaining_work_counts.$remainingType
            $actualCount = [int]$actualRemainingWorkCounts[$remainingType]
            if ($reportedCount -ne $actualCount) {
                $remainingWorkCountFailures += "remaining_work_counts mismatch for $remainingType; reported=$reportedCount actual=$actualCount"
            }
        }
    }
}

$actualLocalImplementationGaps = @($checklist | Where-Object {
        [string]$_.status -ne "passed" -and
        ($_.implementation_ready -ne $true -or [string]$_.remaining_work_type -eq "implementation_gap" -or [string]$_.remaining_work_type -eq "unclassified")
    })

$reportedLocalImplementationReady = Get-ObjectBool -Object $report -Name "local_implementation_ready"
$reportedLocalImplementationGapCount = if ($null -ne $report -and $report.PSObject.Properties["local_implementation_gap_count"]) { [int]$report.local_implementation_gap_count } else { -1 }
$expectedLocalImplementationReady = ($inputFailures.Count -eq 0 -and $actualLocalImplementationGaps.Count -eq 0)
if ($reportedLocalImplementationGapCount -ne $actualLocalImplementationGaps.Count) {
    $remainingWorkCountFailures += "local_implementation_gap_count mismatch; reported=$reportedLocalImplementationGapCount actual=$($actualLocalImplementationGaps.Count)"
}
if ($reportedLocalImplementationReady -ne $expectedLocalImplementationReady) {
    $remainingWorkCountFailures += "local_implementation_ready mismatch; reported=$reportedLocalImplementationReady expected=$expectedLocalImplementationReady"
}

$checks += New-Check -Id "remaining_work_classification_contract" -Passed ($remainingWorkCountFailures.Count -eq 0) -Failures $remainingWorkCountFailures -Evidence ([pscustomobject][ordered]@{
    local_implementation_ready = $reportedLocalImplementationReady
    local_implementation_gap_count = $reportedLocalImplementationGapCount
    remaining_work_types = @($actualRemainingWorkCounts.Keys)
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
    $markdownActionFailures = @()
    if ($markdown -notmatch '# Token-Ready MVP Completion Audit') {
        $markdownFailures += "Markdown title is missing"
    }
    if ($markdown -notmatch '## Source Files') {
        $markdownFailures += "Markdown source-file section is missing"
    }
    if ($markdown -notmatch '(?m)^- Local implementation ready: ') {
        $markdownFailures += "Markdown local implementation ready summary is missing"
    }
    if ($markdown -notmatch '(?m)^- Local implementation gap items: ') {
        $markdownFailures += "Markdown local implementation gap count is missing"
    }
    foreach ($sourceId in $requiredSourceFileIds) {
        $source = Get-SourceFile -Report $report -Id $sourceId
        if ($markdown -notmatch [regex]::Escape($sourceId)) {
            $markdownFailures += "Markdown does not include source file id: $sourceId"
        }
        if ($null -ne $source -and -not [string]::IsNullOrWhiteSpace([string]$source.sha256) -and $markdown -notmatch [regex]::Escape([string]$source.sha256)) {
            $markdownFailures += "Markdown does not include source file SHA-256: $sourceId"
        }
    }
    foreach ($id in $requiredChecklistIds) {
        if ($markdown -notmatch [regex]::Escape($id)) {
            $markdownFailures += "Markdown does not include checklist id: $id"
        }
    }
    foreach ($item in $checklist) {
        if ($item.PSObject.Properties["summary"] -and -not [string]::IsNullOrWhiteSpace([string]$item.summary) -and $markdown -notmatch [regex]::Escape([string]$item.summary)) {
            $markdownFailures += "Markdown does not include checklist summary: $($item.id)"
        }
    }

    foreach ($item in @($checklist | Where-Object { [string]$_.status -ne "passed" })) {
        $itemId = [string]$item.id
        $itemPattern = "(?s)- ``$([regex]::Escape($itemId))`` \[[^\]]+\].*?(?=\r?\n- ``|\z)"
        $itemMatch = [regex]::Match($markdown, $itemPattern)
        if (-not $itemMatch.Success) {
            $markdownActionFailures += "Markdown block is missing for non-passed item: $itemId"
            continue
        }

        $itemBlock = $itemMatch.Value
        if ($itemBlock -notmatch '(?m)^\s+- Remaining work: ') {
            $markdownActionFailures += "Markdown block does not include a Remaining work line for non-passed item: $itemId"
        }
        if ($itemBlock -notmatch '(?m)^\s+- Next action: ') {
            $markdownActionFailures += "Markdown block does not include a Next action line for non-passed item: $itemId"
        }
        if ($itemBlock -notmatch '(?m)^\s+- Next action command: ') {
            $markdownActionFailures += "Markdown block does not include a Next action command line for non-passed item: $itemId"
        }
        if ($itemBlock -notmatch '(?m)^\s+- Next: ') {
            $markdownActionFailures += "Markdown block does not include a Next line for non-passed item: $itemId"
        }
        if ($itemBlock -notmatch '(?m)^\s+- Command: ') {
            $markdownActionFailures += "Markdown block does not include a Command line for non-passed item: $itemId"
        }
    }

    $checks += New-Check -Id "markdown_checklist_coverage" -Passed ($markdownFailures.Count -eq 0) -Failures $markdownFailures -Evidence ([pscustomobject][ordered]@{ path = $resolvedMarkdownPath })
    $checks += New-Check -Id "markdown_operator_action_coverage" -Passed ($markdownActionFailures.Count -eq 0) -Failures $markdownActionFailures -Evidence ([pscustomobject][ordered]@{ path = $resolvedMarkdownPath })
}
else {
    $checks += New-Check -Id "markdown_checklist_coverage" -Passed $false -Failures @("Markdown report is missing") -Evidence ([pscustomobject][ordered]@{ path = $resolvedMarkdownPath })
    $checks += New-Check -Id "markdown_operator_action_coverage" -Passed $false -Failures @("Markdown report is missing") -Evidence ([pscustomobject][ordered]@{ path = $resolvedMarkdownPath })
}

$failedChecks = @($checks | Where-Object { $_.passed -ne $true })
$reportOut = [pscustomobject][ordered]@{
    schema = "archrealms.passport.token_ready_mvp_completion_audit_validation.v1"
    created_utc = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
    repo_root = $repoRoot
    app_commit = $currentCommit
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
