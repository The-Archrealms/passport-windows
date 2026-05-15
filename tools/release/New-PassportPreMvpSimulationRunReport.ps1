param(
    [string]$OutputPath = "artifacts\release\pre-mvp-simulation-run-report.json",
    [string]$EvidenceRoot = "artifacts\release\pre-mvp-simulation-run-evidence",
    [string]$DotnetPath,
    [string]$Configuration = "Release",
    [switch]$NoRestore,
    [switch]$SkipSmokeTest,
    [switch]$NoFail
)

$ErrorActionPreference = "Stop"
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $scriptRoot "..\.."))

function Resolve-RepoPath {
    param([string]$Path)

    if ([System.IO.Path]::IsPathRooted($Path)) {
        return [System.IO.Path]::GetFullPath($Path)
    }

    return [System.IO.Path]::GetFullPath((Join-Path $repoRoot $Path))
}

function Resolve-DotnetPath {
    param([string]$PreferredPath)

    if (-not $PreferredPath -and $env:ARCHREALMS_DOTNET) {
        $PreferredPath = $env:ARCHREALMS_DOTNET
    }

    if ($PreferredPath) {
        return (Resolve-Path -LiteralPath $PreferredPath).Path
    }

    return (Get-Command dotnet -ErrorAction Stop).Source
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

function Format-Command {
    param(
        [string]$FilePath,
        [string[]]$Arguments
    )

    return (@($FilePath) + @($Arguments | ForEach-Object { Format-CommandArgument -Argument $_ })) -join " "
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

    Set-Content -LiteralPath $Path -Value ($Value | ConvertTo-Json -Depth 12) -Encoding UTF8
}

function Invoke-SimulationCommand {
    param(
        [string]$Id,
        [string]$Description,
        [string]$FilePath,
        [string[]]$Arguments,
        [string]$LogPath
    )

    $started = [DateTimeOffset]::UtcNow
    $commandText = Format-Command -FilePath $FilePath -Arguments $Arguments
    $output = @()
    $exitCode = 0
    $exceptionMessage = ""

    Push-Location $repoRoot
    try {
        try {
            $output = & $FilePath @Arguments 2>&1
            if ($null -ne $LASTEXITCODE) {
                $exitCode = [int]$LASTEXITCODE
            }
        }
        catch {
            $exitCode = 1
            $exceptionMessage = $_.Exception.Message
            $output += $_.Exception.ToString()
        }
    }
    finally {
        Pop-Location
    }

    $ended = [DateTimeOffset]::UtcNow
    $logDirectory = Split-Path -Parent $LogPath
    if ($logDirectory) {
        New-Item -ItemType Directory -Force -Path $logDirectory | Out-Null
    }

    $header = @(
        "command_id=$Id",
        "description=$Description",
        "started_utc=$($started.ToString("yyyy-MM-ddTHH:mm:ssZ"))",
        "ended_utc=$($ended.ToString("yyyy-MM-ddTHH:mm:ssZ"))",
        "exit_code=$exitCode",
        "command=$commandText",
        ""
    )
    Set-Content -LiteralPath $LogPath -Value (($header + @($output | ForEach-Object { $_.ToString() })) -join [Environment]::NewLine) -Encoding UTF8

    $failures = @()
    if ($exitCode -ne 0) {
        $failures += "$Id exited with code $exitCode"
    }

    if (-not [string]::IsNullOrWhiteSpace($exceptionMessage)) {
        $failures += $exceptionMessage
    }

    return [pscustomobject][ordered]@{
        id = $Id
        description = $Description
        command = $commandText
        started_utc = $started.ToString("yyyy-MM-ddTHH:mm:ssZ")
        ended_utc = $ended.ToString("yyyy-MM-ddTHH:mm:ssZ")
        duration_seconds = [math]::Round(($ended - $started).TotalSeconds, 3)
        exit_code = $exitCode
        passed = ($failures.Count -eq 0)
        failures = $failures
        log_path = [System.IO.Path]::GetFullPath($LogPath)
        log_sha256 = Get-Sha256Hex -Path $LogPath
    }
}

function Test-CommandPassed {
    param(
        [object[]]$Results,
        [string[]]$Ids
    )

    foreach ($id in $Ids) {
        $result = @($Results | Where-Object { $_.id -eq $id } | Select-Object -First 1)
        if ($result.Count -eq 0 -or -not [bool]$result[0].passed) {
            return $false
        }
    }

    return $true
}

$resolvedEvidenceRoot = Resolve-RepoPath -Path $EvidenceRoot
$resolvedOutputPath = Resolve-RepoPath -Path $OutputPath
$dotnet = Resolve-DotnetPath -PreferredPath $DotnetPath
$powershell = (Get-Command powershell -ErrorAction Stop).Source

New-Item -ItemType Directory -Force -Path $resolvedEvidenceRoot | Out-Null

$testArgsSuffix = @("-c", $Configuration, "/m:1", "/nr:false", "/p:UseSharedCompilation=false")
if ($NoRestore) {
    $testArgsSuffix += "--no-restore"
}

$buildArgsSuffix = @("-c", $Configuration, "/m:1", "/nr:false", "/p:UseSharedCompilation=false")
if ($NoRestore) {
    $buildArgsSuffix += "--no-restore"
}

$commandResults = @()
$commandResults += Invoke-SimulationCommand `
    -Id "core_tests" `
    -Description "Core protocol tests cover ledger replay, fake-record migration, wallet binding, monetary semantics, registry inspection, and AI authority policy." `
    -FilePath $dotnet `
    -Arguments (@("test", "tests\ArchrealmsPassport.Core.Tests\ArchrealmsPassport.Core.Tests.csproj") + $testArgsSuffix) `
    -LogPath (Join-Path $resolvedEvidenceRoot "core-tests.log")

$commandResults += Invoke-SimulationCommand `
    -Id "hosted_service_tests" `
    -Description "Hosted service tests cover AI privacy, AI authority boundaries, operator controls, storage readiness, market/capacity policy, recovery controls, quota, and incident metadata." `
    -FilePath $dotnet `
    -Arguments (@("test", "tests\ArchrealmsPassport.HostedServices.Tests\ArchrealmsPassport.HostedServices.Tests.csproj") + $testArgsSuffix) `
    -LogPath (Join-Path $resolvedEvidenceRoot "hosted-service-tests.log")

$commandResults += Invoke-SimulationCommand `
    -Id "managed_signing_tests" `
    -Description "Managed signing tests cover signing endpoint contract, custody metadata, local-validation markers, and API-key controls." `
    -FilePath $dotnet `
    -Arguments (@("test", "tests\ArchrealmsPassport.ManagedSigning.Tests\ArchrealmsPassport.ManagedSigning.Tests.csproj") + $testArgsSuffix) `
    -LogPath (Join-Path $resolvedEvidenceRoot "managed-signing-tests.log")

$commandResults += Invoke-SimulationCommand `
    -Id "windows_tests" `
    -Description "Windows tests cover synthetic users, storage redemption, escrow/burn/refund/re-credit, recovery, revocation, bandwidth controls, conversion disclosures, wallet compromise, and identity compromise paths." `
    -FilePath $dotnet `
    -Arguments (@("test", "tests\ArchrealmsPassport.Windows.Tests\ArchrealmsPassport.Windows.Tests.csproj") + $testArgsSuffix) `
    -LogPath (Join-Path $resolvedEvidenceRoot "windows-tests.log")

$commandResults += Invoke-SimulationCommand `
    -Id "ledger_verifier_build" `
    -Description "Ledger verifier build proves the account export replay verifier can be produced for independent verification." `
    -FilePath $dotnet `
    -Arguments (@("build", "tools\ledger-verifier\Archrealms.LedgerVerifier.csproj") + $buildArgsSuffix) `
    -LogPath (Join-Path $resolvedEvidenceRoot "ledger-verifier-build.log")

if (-not $SkipSmokeTest) {
    $smokeReportPath = Join-Path $resolvedEvidenceRoot "passport-smoke-test-report.json"
    $commandResults += Invoke-SimulationCommand `
        -Id "passport_smoke_test" `
        -Description "End-to-end local smoke test covers identity creation, delegated authorization, metering records, proof packaging, admission, audit, dispute, correction, settlement handoff, and mock settlement read path." `
        -FilePath $powershell `
        -Arguments @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", (Resolve-RepoPath -Path "tools\passport\Invoke-ArchrealmsPassportSmokeTest.ps1"), "-OutputPath", $smokeReportPath) `
        -LogPath (Join-Path $resolvedEvidenceRoot "passport-smoke-test.log")
}

$allCommandsPassed = (@($commandResults | Where-Object { -not $_.passed }).Count -eq 0)
$scenarioCoverage = [ordered]@{
    synthetic_users_exercised = Test-CommandPassed -Results $commandResults -Ids @("windows_tests")
    ledger_replay_exercised = Test-CommandPassed -Results $commandResults -Ids @("core_tests", "ledger_verifier_build")
    key_recovery_attacks_exercised = Test-CommandPassed -Results $commandResults -Ids @("windows_tests", "hosted_service_tests")
    storage_proof_attacks_exercised = Test-CommandPassed -Results $commandResults -Ids @("windows_tests", "hosted_service_tests")
    storage_revocation_wipe_exercised = Test-CommandPassed -Results $commandResults -Ids @("windows_tests")
    bandwidth_limit_exercised = Test-CommandPassed -Results $commandResults -Ids @("windows_tests")
    escrow_burn_refund_recredit_exercised = Test-CommandPassed -Results $commandResults -Ids @("core_tests", "windows_tests")
    market_manipulation_exercised = Test-CommandPassed -Results $commandResults -Ids @("windows_tests", "hosted_service_tests")
    service_failure_exercised = Test-CommandPassed -Results $commandResults -Ids @("windows_tests", "hosted_service_tests")
    wallet_compromise_exercised = Test-CommandPassed -Results $commandResults -Ids @("core_tests", "windows_tests")
    identity_compromise_exercised = Test-CommandPassed -Results $commandResults -Ids @("windows_tests", "hosted_service_tests")
    ai_privacy_retention_exercised = Test-CommandPassed -Results $commandResults -Ids @("core_tests", "hosted_service_tests", "windows_tests")
}

$failedScenarioIds = @()
foreach ($property in $scenarioCoverage.Keys) {
    if (-not [bool]$scenarioCoverage[$property]) {
        $failedScenarioIds += $property
    }
}

$completed = ($allCommandsPassed -and $failedScenarioIds.Count -eq 0)
$report = [pscustomobject][ordered]@{
    schema = "archrealms.passport.pre_mvp_simulation_run.v1"
    created_utc = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
    lane = "internal-verification"
    simulation_run_id = "pre-mvp-sim-" + [DateTime]::UtcNow.ToString("yyyyMMddHHmmss")
    operator = ([System.Security.Principal.WindowsIdentity]::GetCurrent().Name)
    policy_version = "token-ready-passport-mvp-pre-mvp-internal-verification-v1"
    completed = $completed
    synthetic_users_exercised = [bool]$scenarioCoverage.synthetic_users_exercised
    ledger_replay_exercised = [bool]$scenarioCoverage.ledger_replay_exercised
    key_recovery_attacks_exercised = [bool]$scenarioCoverage.key_recovery_attacks_exercised
    storage_proof_attacks_exercised = [bool]$scenarioCoverage.storage_proof_attacks_exercised
    storage_revocation_wipe_exercised = [bool]$scenarioCoverage.storage_revocation_wipe_exercised
    bandwidth_limit_exercised = [bool]$scenarioCoverage.bandwidth_limit_exercised
    escrow_burn_refund_recredit_exercised = [bool]$scenarioCoverage.escrow_burn_refund_recredit_exercised
    market_manipulation_exercised = [bool]$scenarioCoverage.market_manipulation_exercised
    service_failure_exercised = [bool]$scenarioCoverage.service_failure_exercised
    wallet_compromise_exercised = [bool]$scenarioCoverage.wallet_compromise_exercised
    identity_compromise_exercised = [bool]$scenarioCoverage.identity_compromise_exercised
    ai_privacy_retention_exercised = [bool]$scenarioCoverage.ai_privacy_retention_exercised
    no_production_records_created = $completed
    evidence_references = @($commandResults | ForEach-Object { $_.log_path })
    failed_scenarios = $failedScenarioIds
    command_results = $commandResults
}

Write-JsonFile -Path $resolvedOutputPath -Value $report
$report | ConvertTo-Json -Depth 12

if (-not $completed -and -not $NoFail) {
    $failedCommands = @($commandResults | Where-Object { -not $_.passed } | ForEach-Object { $_.id })
    throw "Pre-MVP simulation run failed. Failed commands: $($failedCommands -join ", "); failed scenarios: $($failedScenarioIds -join ", ")"
}
