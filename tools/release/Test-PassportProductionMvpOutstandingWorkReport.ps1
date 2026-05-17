param(
    [string]$ReportPath = "artifacts\release\production-mvp-outstanding-work-report.json",
    [string]$MarkdownPath = "artifacts\release\production-mvp-outstanding-work-report.md",
    [string]$OutputPath = "artifacts\release\production-mvp-outstanding-work-validation-report.json",
    [switch]$Generate,
    [switch]$UseGeneratedFixture,
    [switch]$RequireReady,
    [switch]$NoFail
)

$ErrorActionPreference = "Stop"
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path

function Resolve-RepoPath {
    param([string]$Path)

    if ([System.IO.Path]::IsPathRooted($Path)) {
        return $Path
    }

    return (Join-Path $repoRoot $Path)
}

function Get-Sha256Hex {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
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

function Invoke-OutstandingWorkGenerator {
    param(
        [string]$JsonPath,
        [string]$MarkdownOutputPath,
        [bool]$Fixture
    )

    $powershell = Get-Command powershell -ErrorAction Stop
    $generator = Resolve-RepoPath -Path "tools\release\New-PassportProductionMvpOutstandingWorkReport.ps1"
    $args = @(
        "-NoProfile",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        $generator,
        "-OutputPath",
        $JsonPath,
        "-MarkdownOutputPath",
        $MarkdownOutputPath,
        "-NoFail"
    )

    if ($Fixture) {
        $args += "-UseGeneratedFixture"
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

function Read-ObjectInt {
    param(
        [object]$Object,
        [string]$Name
    )

    if ($null -eq $Object -or -not $Object.PSObject.Properties[$Name]) {
        return 0
    }

    return [int]$Object.$Name
}

function Get-ExpectedOperatorPlaceholderInputKind {
    param([string]$Name)

    if ($Name -match "(?i)(SHA256|HASH)$") {
        return "digest"
    }
    if ($Name -match "(?i)^controlled-.*packet-root$") {
        return "controlled_packet_root"
    }
    if ($Name -match "(?i)^filled-.*root$") {
        return "filled_evidence_root"
    }
    if ($Name -match "(?i)(PASSWORD|SECRET|KEY).*(FILE|PATH)$") {
        return "secret_file"
    }
    if ($Name -match "(?i)(ROOT|PATH)$") {
        return "filesystem_path"
    }
    if ($Name -match "(?i)(ENV|ENVIRONMENT)") {
        return "environment_file"
    }
    if ($Name -match "(?i)(URL|URI)$") {
        return "url"
    }

    return "operator_value"
}

function Get-ExpectedOperatorPlaceholderValidationHint {
    param(
        [string]$Name,
        [string]$InputKind
    )

    switch ($InputKind) {
        "digest" { return "Replace with a lowercase 64-character SHA-256 digest that matches the referenced generated artifact." }
        "controlled_packet_root" { return "Replace with the controlled production provisioning packet root after it passes Test-PassportProductionProvisioningPacket.ps1 -RequireNoPlaceholders." }
        "filled_evidence_root" { return "Replace with the filled evidence or provisioning packet root after its owning validator passes with -RequireNoPlaceholders." }
        "secret_file" { return "Replace with an existing secure local secret file path; do not commit the file or paste its contents into the command." }
        "filesystem_path" { return "Replace with an existing absolute or repo-relative filesystem path approved for the production lane." }
        "environment_file" { return "Replace with the approved environment file path for the target release lane." }
        "url" { return "Replace with the approved HTTPS URL for the target release lane." }
        default { return "Replace with the approved production-lane operator value before running the command." }
    }
}

function Get-CommandPlaceholders {
    param([string[]]$Commands = @())

    $recordsByName = [ordered]@{}
    for ($index = 0; $index -lt @($Commands).Count; $index++) {
        $command = [string](@($Commands)[$index])
        if ([string]::IsNullOrWhiteSpace($command)) {
            continue
        }

        foreach ($match in [regex]::Matches($command, "<([A-Za-z0-9][A-Za-z0-9_.:-]*)>")) {
            $token = [string]$match.Value
            $name = [string]$match.Groups[1].Value
            if ([string]::IsNullOrWhiteSpace($name) -or $name -eq "redacted") {
                continue
            }

            if (-not $recordsByName.Contains($name)) {
                $inputKind = Get-ExpectedOperatorPlaceholderInputKind -Name $name
                $recordsByName[$name] = [ordered]@{
                    token = $token
                    name = $name
                    input_kind = $inputKind
                    required = $true
                    validation_hint = Get-ExpectedOperatorPlaceholderValidationHint -Name $name -InputKind $inputKind
                    command_indexes = New-Object System.Collections.Generic.List[int]
                    occurrence_count = 0
                }
            }

            $record = $recordsByName[$name]
            if (-not $record.command_indexes.Contains([int]$index)) {
                $record.command_indexes.Add([int]$index)
            }
            $record.occurrence_count = [int]$record.occurrence_count + 1
        }
    }

    $items = foreach ($record in $recordsByName.Values) {
        [pscustomobject][ordered]@{
            token = [string]$record.token
            name = [string]$record.name
            input_kind = [string]$record.input_kind
            required = [bool]$record.required
            validation_hint = [string]$record.validation_hint
            command_indexes = @($record.command_indexes)
            occurrence_count = [int]$record.occurrence_count
        }
    }

    return @($items | Sort-Object @{ Expression = "name"; Ascending = $true })
}

function Get-OperatorPlaceholderOccurrenceCount {
    param([object[]]$Placeholders = @())

    $count = (@($Placeholders | ForEach-Object {
        if ($null -ne $_ -and $_.PSObject.Properties["occurrence_count"]) {
            [int]$_.occurrence_count
        }
    }) | Measure-Object -Sum).Sum
    if ($null -eq $count) {
        return 0
    }

    return [int]$count
}

function Join-IntArrayForCompare {
    param([object[]]$Values)

    return (@($Values | ForEach-Object { [int]$_ }) -join ",")
}

function Test-OperatorPlaceholderRecords {
    param(
        [string]$Scope,
        [string[]]$Commands = @(),
        [object[]]$Records = @()
    )

    $failures = @()
    $expectedRecords = @(Get-CommandPlaceholders -Commands $Commands)
    $actualRecords = @($Records)

    if ($actualRecords.Count -ne $expectedRecords.Count) {
        $failures += "$Scope placeholder count mismatch: expected $($expectedRecords.Count), found $($actualRecords.Count)."
    }

    $actualByName = @{}
    foreach ($actual in $actualRecords) {
        $name = [string]$actual.name
        if ([string]::IsNullOrWhiteSpace($name)) {
            $failures += "$Scope placeholder record is missing name."
            continue
        }
        if ($actualByName.ContainsKey($name)) {
            $failures += "$Scope has duplicate placeholder record: $name"
            continue
        }
        $actualByName[$name] = $actual
    }

    foreach ($expected in $expectedRecords) {
        $name = [string]$expected.name
        if (-not $actualByName.ContainsKey($name)) {
            $failures += "$Scope missing placeholder record: $name"
            continue
        }

        $actual = $actualByName[$name]
        foreach ($field in @("token", "input_kind", "validation_hint")) {
            if ([string]$actual.$field -ne [string]$expected.$field) {
                $failures += "$Scope placeholder $name field mismatch: $field"
            }
        }
        if (-not $actual.PSObject.Properties["required"] -or [bool]$actual.required -ne [bool]$expected.required) {
            $failures += "$Scope placeholder $name required flag mismatch."
        }
        if (-not $actual.PSObject.Properties["occurrence_count"] -or [int]$actual.occurrence_count -ne [int]$expected.occurrence_count) {
            $failures += "$Scope placeholder $name occurrence_count mismatch."
        }

        $actualIndexes = @(Get-ObjectArray -Object $actual -Name "command_indexes")
        $expectedIndexes = @(Get-ObjectArray -Object $expected -Name "command_indexes")
        if ((Join-IntArrayForCompare -Values $actualIndexes) -ne (Join-IntArrayForCompare -Values $expectedIndexes)) {
            $failures += "$Scope placeholder $name command_indexes mismatch."
        }
    }

    foreach ($actual in $actualRecords) {
        $name = [string]$actual.name
        if (-not [string]::IsNullOrWhiteSpace($name) -and -not (@($expectedRecords | ForEach-Object { [string]$_.name }) -contains $name)) {
            $failures += "$Scope includes stale placeholder record not present in commands: $name"
        }
    }

    return $failures
}

function Get-ExpectedEnvironmentVariableInputKind {
    param([string]$Name)

    if ($Name -match "(?i)(SHA256|HASH)$|_SHA256$|_HASH$") {
        return "digest"
    }
    if ($Name -match "(?i)(API_KEY|SECRET|PASSWORD|PRIVATE_KEY|PFX|(^|_)TOKEN($|_))") {
        return "secret"
    }
    if ($Name -match "(?i)THUMBPRINT") {
        return "certificate_thumbprint"
    }
    if ($Name -match "(?i)(URL|BASE_URL|ENDPOINT|DESTINATION)$") {
        return "endpoint_url"
    }
    if ($Name -match "(?i)(URI|RUNBOOK_URI|POLICY_URI)$") {
        return "document_uri"
    }
    if ($Name -match "(?i)(APPROVAL_ID|SIGNOFF_ID|LICENSE_APPROVAL_ID)$") {
        return "approval_id"
    }
    if ($Name -match "(?i)(ISSUER_ID|MANIFEST_ID|AUTHORITY_ID|KEY_ID|MODEL_ID|VECTOR_STORE_ID)$") {
        return "authority_or_resource_id"
    }
    if ($Name -match "(?i)(PROVIDER|CUSTODY|MODE)$") {
        return "provider_or_mode"
    }
    if ($Name -match "(?i)(ROOT|PATH|NAMESPACE)$") {
        return "storage_or_namespace"
    }
    if ($Name -match "(?i)OWNER$") {
        return "owner_contact"
    }

    return "operator_value"
}

function Get-ExpectedEnvironmentVariableSensitivity {
    param(
        [string]$Name,
        [string]$InputKind
    )

    if ($InputKind -eq "secret") {
        return "secret"
    }
    if ($InputKind -in @("digest", "approval_id", "certificate_thumbprint")) {
        return "integrity_metadata"
    }
    if ($Name -match "(?i)(SIGNING|KEY|CUSTODY|AUTHORITY|ISSUER|LEDGER|STORAGE|AI|TELEMETRY|INCIDENT)") {
        return "restricted_operational"
    }

    return "configuration"
}

function Get-ProductionMvpEnvironmentTemplateVariables {
    $templateScriptPath = Resolve-RepoPath -Path "tools\release\New-PassportProductionMvpEnvironmentTemplate.ps1"
    if (-not (Test-Path -LiteralPath $templateScriptPath -PathType Leaf)) {
        return @()
    }

    try {
        $json = (& $templateScriptPath -Format Json -BlankUnconfiguredValues 2>$null | Out-String).Trim()
        if ([string]::IsNullOrWhiteSpace($json)) {
            return @()
        }

        $template = $json | ConvertFrom-Json
        return @(Get-ObjectArray -Object $template -Name "variables")
    }
    catch {
        return @()
    }
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

function Add-CommandRecord {
    param(
        [System.Collections.Generic.List[object]]$Records,
        [string]$Source,
        [string]$Command
    )

    if ([string]::IsNullOrWhiteSpace($Command)) {
        $Records.Add([pscustomobject][ordered]@{
            source = $Source
            command = ""
            script_path = ""
        })
        return
    }

    $Records.Add([pscustomobject][ordered]@{
        source = $Source
        command = [string]$Command
        script_path = Get-OperatorCommandScriptPath -Command ([string]$Command)
    })
}

function Add-ActionCommandRecords {
    param(
        [System.Collections.Generic.List[object]]$Records,
        [string]$Source,
        [object]$Action
    )

    foreach ($command in Get-ObjectArray -Object $Action -Name "commands") {
        Add-CommandRecord -Records $Records -Source $Source -Command ([string]$command)
    }
}

function Add-CommandArrayRecords {
    param(
        [System.Collections.Generic.List[object]]$Records,
        [string]$Source,
        [object[]]$Commands
    )

    foreach ($command in @($Commands)) {
        Add-CommandRecord -Records $Records -Source $Source -Command ([string]$command)
    }
}

function Test-CommandRecord {
    param([object]$Record)

    $failures = @()
    $command = [string]$Record.command
    $scriptPath = [string]$Record.script_path

    if ([string]::IsNullOrWhiteSpace($command)) {
        $failures += "$($Record.source) command is empty."
        return $failures
    }

    if ([string]::IsNullOrWhiteSpace($scriptPath)) {
        $failures += "$($Record.source) command must include a PowerShell -File script path: $command"
        return $failures
    }

    if ($scriptPath -match '[<>]') {
        $failures += "$($Record.source) command script path must not contain placeholder brackets: $command"
        return $failures
    }

    $resolvedScriptPath = Resolve-RepoPath -Path $scriptPath
    $releaseRoot = Resolve-RepoPath -Path "tools\release"
    $normalizedScriptPath = [System.IO.Path]::GetFullPath($resolvedScriptPath)
    $normalizedReleaseRoot = [System.IO.Path]::GetFullPath($releaseRoot).TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
    $releasePrefix = $normalizedReleaseRoot + [System.IO.Path]::DirectorySeparatorChar

    if (-not $normalizedScriptPath.StartsWith($releasePrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        $failures += "$($Record.source) command must target a tools\release PowerShell script: $command"
    }

    if ([System.IO.Path]::GetExtension($normalizedScriptPath) -ne ".ps1") {
        $failures += "$($Record.source) command must target a .ps1 script: $command"
    }

    if (-not (Test-Path -LiteralPath $normalizedScriptPath -PathType Leaf)) {
        $failures += "$($Record.source) command script does not exist: $scriptPath"
    }

    return $failures
}

if ($UseGeneratedFixture) {
    $ReportPath = "artifacts\release\production-mvp-outstanding-work-fixture\production-mvp-outstanding-work-report.json"
    $MarkdownPath = "artifacts\release\production-mvp-outstanding-work-fixture\production-mvp-outstanding-work-report.md"
}

$resolvedReportPath = Resolve-RepoPath -Path $ReportPath
$resolvedMarkdownPath = Resolve-RepoPath -Path $MarkdownPath
$resolvedOutputPath = Resolve-RepoPath -Path $OutputPath
$currentCommit = Get-CurrentCommit

$checks = @()
$generatorResult = $null
if ($Generate -or $UseGeneratedFixture) {
    $generatorResult = Invoke-OutstandingWorkGenerator -JsonPath $resolvedReportPath -MarkdownOutputPath $resolvedMarkdownPath -Fixture ([bool]$UseGeneratedFixture)
    $checks += Add-Check -Id "generator_exit_code" -Condition ($generatorResult.exit_code -eq 0) -Failure "outstanding-work generator exited with code $($generatorResult.exit_code)" -Evidence $generatorResult
}

$reportExists = Test-Path -LiteralPath $resolvedReportPath -PathType Leaf
$markdownExists = Test-Path -LiteralPath $resolvedMarkdownPath -PathType Leaf
$checks += Add-Check -Id "report_exists" -Condition $reportExists -Failure "outstanding-work JSON report is missing" -Evidence ([pscustomobject][ordered]@{ path = $resolvedReportPath })
$checks += Add-Check -Id "markdown_exists" -Condition $markdownExists -Failure "outstanding-work Markdown report is missing" -Evidence ([pscustomobject][ordered]@{ path = $resolvedMarkdownPath })

$report = $null
if ($reportExists) {
    try {
        $report = Get-Content -LiteralPath $resolvedReportPath -Raw | ConvertFrom-Json
    }
    catch {
        $checks += New-Check -Id "report_json_parse" -Passed $false -Failures @("outstanding-work JSON report could not be parsed: $($_.Exception.Message)")
    }
}

if ($null -ne $report) {
    $checks += Add-Check -Id "schema" -Condition ([string]$report.schema -eq "archrealms.passport.production_mvp_outstanding_work_report.v1") -Failure "unexpected outstanding-work report schema"
    $reportedCommit = if ($report.PSObject.Properties["app_commit"]) { [string]$report.app_commit } else { "" }
    $commitFailures = @()
    if ($reportedCommit -notmatch '^[0-9a-f]{7,40}$') {
        $commitFailures += "outstanding-work report app_commit is missing or invalid."
    }
    if ([string]::IsNullOrWhiteSpace($currentCommit)) {
        $commitFailures += "current git commit could not be resolved."
    }
    elseif ($reportedCommit -ne $currentCommit) {
        $commitFailures += "outstanding-work report app_commit $reportedCommit does not match current app commit $currentCommit."
    }
    $checks += New-Check -Id "app_commit_freshness" -Passed ($commitFailures.Count -eq 0) -Failures $commitFailures -Evidence ([pscustomobject][ordered]@{ report_app_commit = $reportedCommit; current_app_commit = $currentCommit })

    $inputFailures = @(Get-ObjectArray -Object $report -Name "input_failures")
    $checks += Add-Check -Id "input_failures_absent" -Condition ($inputFailures.Count -eq 0) -Failure "outstanding-work report has input failures"

    $blockers = @(Get-ObjectArray -Object $report -Name "blockers")
    $failedReadinessGates = @(Get-ObjectArray -Object $report -Name "failed_readiness_gates")
    $failedProvisioningChecks = @(Get-ObjectArray -Object $report -Name "failed_provisioning_checks")
    $failedReleaseEvidenceChecks = @(Get-ObjectArray -Object $report -Name "failed_release_evidence_checks")
    $closeoutFailures = @(Get-ObjectArray -Object $report -Name "closeout_failures")
    $matrix = $report.operator_input_matrix
    $environmentVariables = @(Get-ObjectArray -Object $matrix -Name "environment_variables")
    $reportReferenceRefreshes = @(Get-ObjectArray -Object $matrix -Name "report_reference_refreshes")
    $readinessEvidenceItems = @(Get-ObjectArray -Object $matrix -Name "readiness_evidence_items")
    $provisioningEvidenceFiles = @(Get-ObjectArray -Object $matrix -Name "provisioning_evidence_files")
    $releaseEvidenceItems = @(Get-ObjectArray -Object $matrix -Name "release_evidence_items")
    $nextActionPlan = @(Get-ObjectArray -Object $report -Name "next_action_plan")
    $summary = $report.summary

    $countFailures = @()
    if ((Read-ObjectInt -Object $summary -Name "closeout_failure_count") -ne $closeoutFailures.Count) { $countFailures += "closeout_failure_count does not match closeout_failures." }
    if ((Read-ObjectInt -Object $summary -Name "blocker_count") -ne $blockers.Count) { $countFailures += "blocker_count does not match blockers." }
    if ((Read-ObjectInt -Object $summary -Name "next_action_count") -ne $nextActionPlan.Count) { $countFailures += "next_action_count does not match next_action_plan." }
    if ((Read-ObjectInt -Object $summary -Name "failed_readiness_gate_count") -ne $failedReadinessGates.Count) { $countFailures += "failed_readiness_gate_count does not match failed_readiness_gates." }
    if ((Read-ObjectInt -Object $summary -Name "failed_provisioning_check_count") -ne $failedProvisioningChecks.Count) { $countFailures += "failed_provisioning_check_count does not match failed_provisioning_checks." }
    if ((Read-ObjectInt -Object $summary -Name "failed_release_evidence_check_count") -ne $failedReleaseEvidenceChecks.Count) { $countFailures += "failed_release_evidence_check_count does not match failed_release_evidence_checks." }
    if ((Read-ObjectInt -Object $summary -Name "required_environment_variable_count") -ne $environmentVariables.Count) { $countFailures += "required_environment_variable_count does not match environment_variables." }
    if ((Read-ObjectInt -Object $summary -Name "report_reference_refresh_count") -ne $reportReferenceRefreshes.Count) { $countFailures += "report_reference_refresh_count does not match report_reference_refreshes." }
    if ((Read-ObjectInt -Object $summary -Name "required_readiness_evidence_item_count") -ne $readinessEvidenceItems.Count) { $countFailures += "required_readiness_evidence_item_count does not match readiness_evidence_items." }
    if ((Read-ObjectInt -Object $summary -Name "required_provisioning_evidence_file_count") -ne $provisioningEvidenceFiles.Count) { $countFailures += "required_provisioning_evidence_file_count does not match provisioning_evidence_files." }
    if ((Read-ObjectInt -Object $summary -Name "required_release_evidence_item_count") -ne $releaseEvidenceItems.Count) { $countFailures += "required_release_evidence_item_count does not match release_evidence_items." }

    $childFailedCheckCount = 0
    foreach ($check in $failedProvisioningChecks) {
        if ($null -ne $check.PSObject.Properties["child_failed_check_count"] -and $null -ne $check.child_failed_check_count) {
            $childFailedCheckCount += [int]$check.child_failed_check_count
        }
        else {
            $childFailedCheckCount += (Get-ObjectArray -Object $check -Name "child_failed_checks").Count
        }
    }
    if ((Read-ObjectInt -Object $summary -Name "failed_provisioning_child_check_count") -ne $childFailedCheckCount) {
        $countFailures += "failed_provisioning_child_check_count does not match provisioning child failure counts."
    }

    $expectedBlockerCount = $inputFailures.Count + $closeoutFailures.Count + $failedReadinessGates.Count + $failedProvisioningChecks.Count + $failedReleaseEvidenceChecks.Count
    if ($blockers.Count -ne $expectedBlockerCount) {
        $countFailures += "blockers does not cover each input failure, closeout failure, failed readiness gate, failed provisioning check, and failed release-evidence check."
    }

    $readinessEvidenceItemsWithCommands = @($readinessEvidenceItems | Where-Object { (Get-ObjectArray -Object $_ -Name "operator_action_commands").Count -gt 0 }).Count
    $releaseEvidenceItemsWithCommands = @($releaseEvidenceItems | Where-Object { (Get-ObjectArray -Object $_ -Name "operator_action_commands").Count -gt 0 }).Count
    $operatorPlaceholderCount = (@($nextActionPlan | ForEach-Object { @(Get-ObjectArray -Object $_ -Name "operator_placeholders").Count }) | Measure-Object -Sum).Sum
    if ($null -eq $operatorPlaceholderCount) { $operatorPlaceholderCount = 0 }
    $operatorPlaceholderOccurrenceCount = (@($nextActionPlan | ForEach-Object { Get-OperatorPlaceholderOccurrenceCount -Placeholders @(Get-ObjectArray -Object $_ -Name "operator_placeholders") }) | Measure-Object -Sum).Sum
    if ($null -eq $operatorPlaceholderOccurrenceCount) { $operatorPlaceholderOccurrenceCount = 0 }
    $externalBlockerCount = (@($nextActionPlan | ForEach-Object { @(Get-ObjectArray -Object $_ -Name "external_blocker_ids").Count }) | Measure-Object -Sum).Sum
    if ($null -eq $externalBlockerCount) { $externalBlockerCount = 0 }
    if ((Read-ObjectInt -Object $summary -Name "required_readiness_evidence_item_command_count") -ne $readinessEvidenceItemsWithCommands) { $countFailures += "required_readiness_evidence_item_command_count does not match readiness evidence items with commands." }
    if ((Read-ObjectInt -Object $summary -Name "required_release_evidence_item_command_count") -ne $releaseEvidenceItemsWithCommands) { $countFailures += "required_release_evidence_item_command_count does not match release evidence items with commands." }
    if ((Read-ObjectInt -Object $summary -Name "operator_placeholder_count") -ne [int]$operatorPlaceholderCount) { $countFailures += "operator_placeholder_count does not match next_action_plan operator placeholders." }
    if ((Read-ObjectInt -Object $summary -Name "operator_placeholder_occurrence_count") -ne [int]$operatorPlaceholderOccurrenceCount) { $countFailures += "operator_placeholder_occurrence_count does not match next_action_plan operator placeholder occurrences." }
    if ((Read-ObjectInt -Object $summary -Name "external_blocker_count") -ne [int]$externalBlockerCount) { $countFailures += "external_blocker_count does not match next_action_plan external blocker ids." }

    $checks += New-Check -Id "summary_counts" -Passed ($countFailures.Count -eq 0) -Failures $countFailures

    $environmentMetadataFailures = @()
    $templateVariables = @(Get-ProductionMvpEnvironmentTemplateVariables)
    $templateVariableMap = @{}
    foreach ($templateVariable in $templateVariables) {
        $templateName = [string]$templateVariable.name
        if (-not [string]::IsNullOrWhiteSpace($templateName)) {
            $templateVariableMap[$templateName] = $templateVariable
        }
    }

    $environmentVariableMap = @{}
    foreach ($item in $environmentVariables) {
        $itemName = [string]$item.name
        if (-not [string]::IsNullOrWhiteSpace($itemName)) {
            $environmentVariableMap[$itemName] = $item
        }
    }

    foreach ($templateName in @($templateVariableMap.Keys | Sort-Object)) {
        if (-not $environmentVariableMap.ContainsKey($templateName)) {
            $environmentMetadataFailures += "environment variable matrix is missing template variable $templateName."
        }
    }

    foreach ($item in $environmentVariables) {
        $name = [string]$item.name
        if ([string]::IsNullOrWhiteSpace($name)) {
            $environmentMetadataFailures += "environment variable record has an empty name."
            continue
        }

        $templateVariable = $(if ($templateVariableMap.ContainsKey($name)) { $templateVariableMap[$name] } else { $null })
        $isTemplateVariable = $null -ne $templateVariable
        $templateSecret = $isTemplateVariable -and [bool]$templateVariable.secret

        $sources = @(Get-ObjectArray -Object $item -Name "sources")
        if ($sources.Count -eq 0) {
            $environmentMetadataFailures += "environment variable $name has no sources."
        }

        if ($isTemplateVariable -and $sources -notcontains "production_environment_template") {
            $environmentMetadataFailures += "environment variable $name is a template variable but lacks production_environment_template source."
        }

        if ((Get-ObjectArray -Object $item -Name "readiness_gate_ids").Count -gt 0 -and $sources -notcontains "readiness_missing_text") {
            $environmentMetadataFailures += "environment variable $name has readiness gates but lacks readiness_missing_text source."
        }

        $expectedKind = $(if ($templateSecret) { "secret" } else { Get-ExpectedEnvironmentVariableInputKind -Name $name })
        $actualKind = if ($item.PSObject.Properties["input_kind"]) { [string]$item.input_kind } else { "" }
        if ($actualKind -ne $expectedKind) {
            $environmentMetadataFailures += "environment variable $name input_kind is '$actualKind', expected '$expectedKind'."
        }

        $expectedSensitivity = Get-ExpectedEnvironmentVariableSensitivity -Name $name -InputKind $expectedKind
        $actualSensitivity = if ($item.PSObject.Properties["sensitivity"]) { [string]$item.sensitivity } else { "" }
        if ($actualSensitivity -ne $expectedSensitivity) {
            $environmentMetadataFailures += "environment variable $name sensitivity is '$actualSensitivity', expected '$expectedSensitivity'."
        }

        if (-not $item.PSObject.Properties["requires_secret_store"]) {
            $environmentMetadataFailures += "environment variable $name is missing requires_secret_store."
        }
        elseif ([bool]$item.requires_secret_store -ne ($expectedSensitivity -eq "secret")) {
            $environmentMetadataFailures += "environment variable $name requires_secret_store does not match its sensitivity."
        }

        $validationHint = if ($item.PSObject.Properties["validation_hint"]) { [string]$item.validation_hint } else { "" }
        if ([string]::IsNullOrWhiteSpace($validationHint)) {
            $environmentMetadataFailures += "environment variable $name is missing validation_hint."
        }

        if ($sources -contains "readiness_missing_text") {
            if ((Get-ObjectArray -Object $item -Name "readiness_gate_ids").Count -eq 0) {
                $environmentMetadataFailures += "environment variable $name has readiness_missing_text source but no readiness_gate_ids."
            }
            if ((Get-ObjectArray -Object $item -Name "missing_texts").Count -eq 0) {
                $environmentMetadataFailures += "environment variable $name has readiness_missing_text source but no missing_texts."
            }
        }

        if ($isTemplateVariable) {
            foreach ($propertyName in @("template_gate", "template_required", "template_secret", "template_description")) {
                if (-not $item.PSObject.Properties[$propertyName]) {
                    $environmentMetadataFailures += "environment variable $name is missing template metadata property $propertyName."
                }
            }

            if ([string]$item.template_gate -ne [string]$templateVariable.gate) {
                $environmentMetadataFailures += "environment variable $name template_gate does not match the environment template."
            }
            if ([bool]$item.template_required -ne [bool]$templateVariable.required) {
                $environmentMetadataFailures += "environment variable $name template_required does not match the environment template."
            }
            if ([bool]$item.template_secret -ne [bool]$templateVariable.secret) {
                $environmentMetadataFailures += "environment variable $name template_secret does not match the environment template."
            }
            if ([string]::IsNullOrWhiteSpace([string]$item.template_description)) {
                $environmentMetadataFailures += "environment variable $name is missing template_description."
            }
            if ([bool]$templateVariable.secret -and -not [bool]$item.requires_secret_store) {
                $environmentMetadataFailures += "secret template variable $name must require a secret store."
            }
            foreach ($forbiddenProperty in @("value", "example")) {
                if ($item.PSObject.Properties[$forbiddenProperty]) {
                    $environmentMetadataFailures += "environment variable $name must not expose template $forbiddenProperty in the operator matrix."
                }
            }
        }
    }
    $checks += New-Check -Id "environment_variable_metadata_contract" -Passed ($environmentMetadataFailures.Count -eq 0) -Failures $environmentMetadataFailures -Evidence ([pscustomobject][ordered]@{ environment_variable_count = $environmentVariables.Count })

    $classificationFailures = @()
    $classificationExpectations = @(
        [pscustomobject][ordered]@{
            name = "ARCHREALMS_PASSPORT_AI_MAX_OUTPUT_TOKENS"
            input_kind = "operator_value"
            sensitivity = "restricted_operational"
            requires_secret_store = $false
        },
        [pscustomobject][ordered]@{
            name = "ARCHREALMS_PASSPORT_HOSTED_OPERATOR_API_KEY_SHA256"
            input_kind = "digest"
            sensitivity = "integrity_metadata"
            requires_secret_store = $false
        }
    )
    foreach ($expectation in $classificationExpectations) {
        $item = $environmentVariableMap[[string]$expectation.name]
        if ($null -eq $item) {
            $classificationFailures += "environment variable $($expectation.name) is missing from the operator input matrix."
            continue
        }

        foreach ($propertyName in @("input_kind", "sensitivity", "requires_secret_store")) {
            $actual = if ($item.PSObject.Properties[$propertyName]) { $item.$propertyName } else { $null }
            $expected = $expectation.$propertyName
            if ($propertyName -eq "requires_secret_store") {
                if ([bool]$actual -ne [bool]$expected) {
                    $classificationFailures += "environment variable $($expectation.name) $propertyName is '$actual', expected '$expected'."
                }
            }
            elseif ([string]$actual -ne [string]$expected) {
                $classificationFailures += "environment variable $($expectation.name) $propertyName is '$actual', expected '$expected'."
            }
        }
    }
    $checks += New-Check -Id "environment_variable_classification_regressions" -Passed ($classificationFailures.Count -eq 0) -Failures $classificationFailures -Evidence ([pscustomobject][ordered]@{ expectation_count = $classificationExpectations.Count })

    $commandRecords = New-Object System.Collections.Generic.List[object]
    foreach ($gate in $failedReadinessGates) {
        Add-ActionCommandRecords -Records $commandRecords -Source "failed_readiness_gates.$($gate.id)" -Action $gate.operator_action
    }
    foreach ($check in $failedProvisioningChecks) {
        Add-ActionCommandRecords -Records $commandRecords -Source "failed_provisioning_checks.$($check.id)" -Action $check.operator_action
    }
    foreach ($check in $failedReleaseEvidenceChecks) {
        Add-ActionCommandRecords -Records $commandRecords -Source "failed_release_evidence_checks.$($check.id)" -Action $check.operator_action
    }
    foreach ($blocker in $blockers) {
        Add-CommandArrayRecords -Records $commandRecords -Source "blockers.$($blocker.id)" -Commands (Get-ObjectArray -Object $blocker -Name "operator_action_commands")
        Add-CommandArrayRecords -Records $commandRecords -Source "blockers.$($blocker.id).next_action" -Commands (Get-ObjectArray -Object $blocker -Name "next_action_commands")
    }
    foreach ($item in $nextActionPlan) {
        Add-CommandArrayRecords -Records $commandRecords -Source "next_action_plan.$($item.id)" -Commands (Get-ObjectArray -Object $item -Name "commands")
    }
    foreach ($item in $reportReferenceRefreshes) {
        Add-CommandArrayRecords -Records $commandRecords -Source "report_reference_refreshes.$($item.readiness_gate_id)" -Commands (Get-ObjectArray -Object $item -Name "operator_action_commands")
    }
    foreach ($item in $readinessEvidenceItems) {
        Add-CommandArrayRecords -Records $commandRecords -Source "readiness_evidence_items.$($item.readiness_gate_id)" -Commands (Get-ObjectArray -Object $item -Name "operator_action_commands")
    }
    foreach ($item in $releaseEvidenceItems) {
        Add-CommandArrayRecords -Records $commandRecords -Source "release_evidence_items.$($item.id)" -Commands (Get-ObjectArray -Object $item -Name "operator_action_commands")
    }
    Add-CommandRecord -Records $commandRecords -Source "next_closeout_command" -Command ([string]$report.next_closeout_command)

    $commandFailures = @()
    foreach ($record in $commandRecords) {
        $commandFailures += Test-CommandRecord -Record $record
    }
    $checks += New-Check -Id "operator_command_paths" -Passed ($commandFailures.Count -eq 0) -Failures $commandFailures -Evidence ([pscustomobject][ordered]@{ command_count = $commandRecords.Count })

    $simulationHashFailures = @()
    $simulationRunReportPath = Resolve-RepoPath -Path "artifacts\release\pre-mvp-simulation-run-report.json"
    $expectedSimulationRunSha256 = Get-Sha256Hex -Path $simulationRunReportPath
    $staffStewardPilotCommands = @($commandRecords |
        Where-Object { [string]$_.command -match 'Complete-PassportPreMvpStaffStewardPilotHandoff\.ps1' } |
        ForEach-Object { [string]$_.command })
    if ($staffStewardPilotCommands.Count -gt 0) {
        foreach ($command in $staffStewardPilotCommands) {
            if ($command -match '<simulation-run-sha256>') {
                $simulationHashFailures += "staff/steward pilot closeout command still contains <simulation-run-sha256>: $command"
            }

            if ($expectedSimulationRunSha256 -match '^[0-9a-f]{64}$' -and $command -notmatch [regex]::Escape("-SimulationRunReportSha256 $expectedSimulationRunSha256")) {
                $simulationHashFailures += "staff/steward pilot closeout command does not include current simulation-run SHA-256 $expectedSimulationRunSha256`: $command"
            }
        }
    }
    $checks += New-Check -Id "staff_steward_simulation_hash_prefill" -Passed ($simulationHashFailures.Count -eq 0) -Failures $simulationHashFailures -Evidence ([pscustomobject][ordered]@{
        simulation_run_report_path = $simulationRunReportPath
        simulation_run_report_sha256 = $expectedSimulationRunSha256
        staff_steward_command_count = $staffStewardPilotCommands.Count
    })

    $pilotOwnerFailures = @()
    $pilotHandoffManifestPath = Resolve-RepoPath -Path "artifacts\release\pre-mvp-staff-steward-pilot-handoff\pilot-handoff.manifest.json"
    $pilotHandoffManifest = Read-JsonFile -Path $pilotHandoffManifestPath
    $expectedPilotOwner = ""
    if ($null -ne $pilotHandoffManifest -and $pilotHandoffManifest.PSObject.Properties["pilot_owner"]) {
        $expectedPilotOwner = ([string]$pilotHandoffManifest.pilot_owner).Trim()
    }

    $staffStewardPilotOwnerCommands = @($commandRecords |
        Where-Object { [string]$_.command -match '(Start-PassportPreMvpStaffStewardPilot|Set-PassportPreMvpStaffStewardPilotEvidencePacket)\.ps1' } |
        ForEach-Object { [string]$_.command })
    if ($staffStewardPilotOwnerCommands.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace($expectedPilotOwner)) {
        foreach ($command in $staffStewardPilotOwnerCommands) {
            if ($command -match '<pilot-owner>') {
                $pilotOwnerFailures += "staff/steward pilot command still contains <pilot-owner>: $command"
            }

            $expectedArgument = '-PilotOwner "' + $expectedPilotOwner + '"'
            if ($command -notmatch [regex]::Escape($expectedArgument)) {
                $pilotOwnerFailures += "staff/steward pilot command does not include handoff pilot owner $expectedPilotOwner`: $command"
            }
        }
    }
    $checks += New-Check -Id "staff_steward_pilot_owner_prefill" -Passed ($pilotOwnerFailures.Count -eq 0) -Failures $pilotOwnerFailures -Evidence ([pscustomobject][ordered]@{
        handoff_manifest_path = $pilotHandoffManifestPath
        handoff_pilot_owner = $expectedPilotOwner
        staff_steward_command_count = $staffStewardPilotOwnerCommands.Count
    })

    $actionFailures = @()
    foreach ($gate in $failedReadinessGates) {
        if ((Get-ObjectArray -Object $gate.operator_action -Name "commands").Count -eq 0) {
            $actionFailures += "failed readiness gate lacks operator action command: $($gate.id)"
        }
    }
    foreach ($check in $failedProvisioningChecks) {
        if ((Get-ObjectArray -Object $check.operator_action -Name "commands").Count -eq 0) {
            $actionFailures += "failed provisioning check lacks operator action command: $($check.id)"
        }
    }
    foreach ($check in $failedReleaseEvidenceChecks) {
        if ((Get-ObjectArray -Object $check.operator_action -Name "commands").Count -eq 0) {
            $actionFailures += "failed release-evidence check lacks operator action command: $($check.id)"
        }
    }
    $checks += New-Check -Id "operator_action_command_coverage" -Passed ($actionFailures.Count -eq 0) -Failures $actionFailures

    $sourceFileFailures = @()
    if ($null -eq $report.source_files) {
        $sourceFileFailures += "source_files is missing."
    }
    else {
        foreach ($property in @($report.source_files.PSObject.Properties)) {
            $sourceFile = $property.Value
            $sourceId = [string]$sourceFile.id
            if ([string]::IsNullOrWhiteSpace($sourceId)) {
                $sourceFileFailures += "source file record $($property.Name) is missing id."
            }

            if ([string]::IsNullOrWhiteSpace([string]$sourceFile.path)) {
                $sourceFileFailures += "source file record $($property.Name) is missing path."
            }

            if ([bool]$sourceFile.exists -and [string]$sourceFile.sha256 -notmatch '^[0-9a-f]{64}$') {
                $sourceFileFailures += "source file record $($property.Name) exists but has no valid SHA-256."
            }
        }
    }
    $checks += New-Check -Id "source_file_contract" -Passed ($sourceFileFailures.Count -eq 0) -Failures $sourceFileFailures

    $provisioningSourceFailures = @()
    if ($null -ne $report.source_files -and
        $report.source_files.PSObject.Properties["closeout_manifest"] -and
        $report.source_files.PSObject.Properties["production_provisioning_packet_report"]) {
        $closeoutSourceFile = $report.source_files.closeout_manifest
        $provisioningSourceFile = $report.source_files.production_provisioning_packet_report
        $closeoutManifest = Read-JsonFile -Path ([string]$closeoutSourceFile.path)
        if ($null -ne $closeoutManifest -and
            $closeoutManifest.PSObject.Properties["steps"] -and
            $closeoutManifest.steps.PSObject.Properties["production_provisioning_packet_validation"]) {
            $provisioningStep = $closeoutManifest.steps.production_provisioning_packet_validation
            if ($provisioningStep.PSObject.Properties["report"] -and
                $provisioningStep.report.PSObject.Properties["file"]) {
                $closeoutProvisioningFile = $provisioningStep.report.file
                $closeoutProvisioningPath = Resolve-RepoPath -Path ([string]$closeoutProvisioningFile.path)
                $closeoutProvisioningSha = [string]$closeoutProvisioningFile.sha256
                $reportProvisioningPath = Resolve-RepoPath -Path ([string]$provisioningSourceFile.path)
                $reportProvisioningSha = [string]$provisioningSourceFile.sha256

                if (-not [string]::IsNullOrWhiteSpace($closeoutProvisioningPath) -and
                    [string]$report.provisioning_report_source -eq "report_file" -and
                    $reportProvisioningPath -ne $closeoutProvisioningPath) {
                    $provisioningSourceFailures += "production provisioning source file must point at the closeout-pinned validation report: $closeoutProvisioningPath"
                }

                if (-not [string]::IsNullOrWhiteSpace($closeoutProvisioningSha) -and
                    -not [string]::IsNullOrWhiteSpace($reportProvisioningSha) -and
                    $reportProvisioningSha -ne $closeoutProvisioningSha) {
                    $provisioningSourceFailures += "production provisioning source file SHA-256 does not match the closeout-pinned validation report."
                }
            }
        }
    }
    $checks += New-Check -Id "provisioning_source_pinned_to_closeout" -Passed ($provisioningSourceFailures.Count -eq 0) -Failures $provisioningSourceFailures

    $blockerContractFailures = @()
    $seenBlockerIds = @{}
    foreach ($blocker in $blockers) {
        $blockerId = [string]$blocker.id
        if ([string]::IsNullOrWhiteSpace($blockerId)) {
            $blockerContractFailures += "blocker id is missing."
        }
        elseif ($seenBlockerIds.ContainsKey($blockerId)) {
            $blockerContractFailures += "duplicate blocker id: $blockerId"
        }
        else {
            $seenBlockerIds[$blockerId] = $true
        }

        foreach ($fieldName in @("category", "title", "summary", "source")) {
            if ([string]::IsNullOrWhiteSpace([string]$blocker.$fieldName)) {
                $blockerContractFailures += "blocker $blockerId is missing $fieldName."
            }
        }
        if ([string]$blocker.status -ne "blocked") {
            $blockerContractFailures += "blocker $blockerId status must be blocked."
        }
        if ((Get-ObjectArray -Object $blocker -Name "failures").Count -eq 0) {
            $blockerContractFailures += "blocker $blockerId lacks failures."
        }
        if ((Get-ObjectArray -Object $blocker -Name "operator_action_commands").Count -eq 0) {
            $blockerContractFailures += "blocker $blockerId lacks operator action commands."
        }
        if ([string]::IsNullOrWhiteSpace([string]$blocker.next_action)) {
            $blockerContractFailures += "blocker $blockerId lacks next_action."
        }
        if ([string]$blocker.next_action -ne [string]$blocker.operator_action) {
            $blockerContractFailures += "blocker $blockerId next_action does not match operator_action."
        }
        if ([string]$blocker.next_action_id -ne [string]$blocker.operator_action_id) {
            $blockerContractFailures += "blocker $blockerId next_action_id does not match operator_action_id."
        }
        if ([string]$blocker.next_action_title -ne [string]$blocker.operator_action_title) {
            $blockerContractFailures += "blocker $blockerId next_action_title does not match operator_action_title."
        }
        $operatorCommands = @(Get-ObjectArray -Object $blocker -Name "operator_action_commands" | ForEach-Object { [string]$_ })
        $nextActionCommands = @(Get-ObjectArray -Object $blocker -Name "next_action_commands" | ForEach-Object { [string]$_ })
        $operatorPlaceholders = @(Get-ObjectArray -Object $blocker -Name "operator_action_placeholders")
        $nextActionPlaceholders = @(Get-ObjectArray -Object $blocker -Name "next_action_placeholders")
        if ($nextActionCommands.Count -eq 0) {
            $blockerContractFailures += "blocker $blockerId lacks next_action_commands."
        }
        foreach ($operatorCommand in $operatorCommands) {
            if ($nextActionCommands -notcontains $operatorCommand) {
                $blockerContractFailures += "blocker $blockerId next_action_commands is missing operator command: $operatorCommand"
            }
        }
        $blockerContractFailures += Test-OperatorPlaceholderRecords -Scope "blocker $blockerId operator_action_placeholders" -Commands $operatorCommands -Records $operatorPlaceholders
        $blockerContractFailures += Test-OperatorPlaceholderRecords -Scope "blocker $blockerId next_action_placeholders" -Commands $nextActionCommands -Records $nextActionPlaceholders
    }
    if (-not [bool]$report.ready_for_production_testing -and $blockers.Count -eq 0) {
        $blockerContractFailures += "ready_for_production_testing=false but blockers is empty."
    }
    if ([bool]$report.ready_for_production_testing -and $blockers.Count -gt 0) {
        $blockerContractFailures += "ready_for_production_testing=true but blockers is not empty."
    }
    $checks += New-Check -Id "blocker_contract" -Passed ($blockerContractFailures.Count -eq 0) -Failures $blockerContractFailures -Evidence ([pscustomobject][ordered]@{ blocker_count = $blockers.Count })

    $nextActionPlanFailures = @()
    $seenPlanIds = @{}
    $knownBlockerIds = @{}
    foreach ($blocker in $blockers) {
        $knownBlockerIds[[string]$blocker.id] = $blocker
    }

    $coveredBlockerIds = @{}
    $previousOrder = -1
    foreach ($item in $nextActionPlan) {
        $itemId = [string]$item.id
        if ([string]::IsNullOrWhiteSpace($itemId)) {
            $nextActionPlanFailures += "next_action_plan item is missing id."
        }
        elseif ($seenPlanIds.ContainsKey($itemId)) {
            $nextActionPlanFailures += "duplicate next_action_plan id: $itemId"
        }
        else {
            $seenPlanIds[$itemId] = $true
        }

        foreach ($fieldName in @("phase", "title", "summary", "action")) {
            if ([string]::IsNullOrWhiteSpace([string]$item.$fieldName)) {
                $nextActionPlanFailures += "next_action_plan $itemId is missing $fieldName."
            }
        }

        $phaseOrder = Read-ObjectInt -Object $item -Name "phase_order"
        if ($phaseOrder -lt 0) {
            $nextActionPlanFailures += "next_action_plan $itemId has invalid phase_order."
        }
        if ($phaseOrder -lt $previousOrder) {
            $nextActionPlanFailures += "next_action_plan is not sorted by phase_order at $itemId."
        }
        $previousOrder = $phaseOrder

        $commands = @(Get-ObjectArray -Object $item -Name "commands" | ForEach-Object { [string]$_ })
        if ($commands.Count -eq 0) {
            $nextActionPlanFailures += "next_action_plan $itemId lacks commands."
        }
        if (-not $item.PSObject.Properties["operator_placeholders"]) {
            $nextActionPlanFailures += "next_action_plan $itemId is missing operator_placeholders."
        }
        $operatorPlaceholders = @(Get-ObjectArray -Object $item -Name "operator_placeholders")
        $nextActionPlanFailures += Test-OperatorPlaceholderRecords -Scope "next_action_plan $itemId operator_placeholders" -Commands $commands -Records $operatorPlaceholders
        if (-not $item.PSObject.Properties["operator_placeholder_count"]) {
            $nextActionPlanFailures += "next_action_plan $itemId is missing operator_placeholder_count."
        }
        elseif ((Read-ObjectInt -Object $item -Name "operator_placeholder_count") -ne $operatorPlaceholders.Count) {
            $nextActionPlanFailures += "next_action_plan $itemId operator_placeholder_count does not match operator_placeholders count."
        }
        $operatorPlaceholderOccurrenceCount = Get-OperatorPlaceholderOccurrenceCount -Placeholders $operatorPlaceholders
        if (-not $item.PSObject.Properties["operator_placeholder_occurrence_count"]) {
            $nextActionPlanFailures += "next_action_plan $itemId is missing operator_placeholder_occurrence_count."
        }
        elseif ((Read-ObjectInt -Object $item -Name "operator_placeholder_occurrence_count") -ne $operatorPlaceholderOccurrenceCount) {
            $nextActionPlanFailures += "next_action_plan $itemId operator_placeholder_occurrence_count does not match operator_placeholders occurrence_count sum."
        }

        $itemBlockerIds = @(Get-ObjectArray -Object $item -Name "blocker_ids" | ForEach-Object { [string]$_ })
        if ($itemBlockerIds.Count -eq 0) {
            $nextActionPlanFailures += "next_action_plan $itemId lacks blocker_ids."
        }
        if (-not $item.PSObject.Properties["blocker_summaries"]) {
            $nextActionPlanFailures += "next_action_plan $itemId is missing blocker_summaries."
        }
        $itemBlockerSummaries = @(Get-ObjectArray -Object $item -Name "blocker_summaries" | ForEach-Object { [string]$_ })

        if (-not $item.PSObject.Properties["operator_input_required"]) {
            $nextActionPlanFailures += "next_action_plan $itemId is missing operator_input_required."
        }
        elseif ([bool]$item.operator_input_required -ne ($itemBlockerIds.Count -gt 0)) {
            $nextActionPlanFailures += "next_action_plan $itemId operator_input_required does not match blocker coverage."
        }

        if (-not $item.PSObject.Properties["required_operator_input_count"]) {
            $nextActionPlanFailures += "next_action_plan $itemId is missing required_operator_input_count."
        }
        $requiredOperatorInputCount = Read-ObjectInt -Object $item -Name "required_operator_input_count"
        if ($requiredOperatorInputCount -lt 0) {
            $nextActionPlanFailures += "next_action_plan $itemId has invalid required_operator_input_count."
        }

        if (-not $item.PSObject.Properties["blocked_by_external_actor"]) {
            $nextActionPlanFailures += "next_action_plan $itemId is missing blocked_by_external_actor."
        }

        $externalBlockerIds = @(Get-ObjectArray -Object $item -Name "external_blocker_ids" | ForEach-Object { [string]$_ })
        if (-not $item.PSObject.Properties["external_blocker_count"]) {
            $nextActionPlanFailures += "next_action_plan $itemId is missing external_blocker_count."
        }
        elseif ((Read-ObjectInt -Object $item -Name "external_blocker_count") -ne $externalBlockerIds.Count) {
            $nextActionPlanFailures += "next_action_plan $itemId external_blocker_count does not match external_blocker_ids count."
        }
        if ($requiredOperatorInputCount -ne $externalBlockerIds.Count) {
            $nextActionPlanFailures += "next_action_plan $itemId required_operator_input_count does not match external_blocker_ids count."
        }
        if ($item.PSObject.Properties["blocked_by_external_actor"] -and ([bool]$item.blocked_by_external_actor -ne ($externalBlockerIds.Count -gt 0))) {
            $nextActionPlanFailures += "next_action_plan $itemId blocked_by_external_actor does not match external_blocker_ids."
        }
        foreach ($externalBlockerId in $externalBlockerIds) {
            if ($itemBlockerIds -notcontains $externalBlockerId) {
                $nextActionPlanFailures += "next_action_plan $itemId external blocker is not in blocker_ids: $externalBlockerId"
            }
        }

        foreach ($blockerId in $itemBlockerIds) {
            if (-not $knownBlockerIds.ContainsKey($blockerId)) {
                $nextActionPlanFailures += "next_action_plan $itemId references unknown blocker id: $blockerId"
                continue
            }

            $coveredBlockerIds[$blockerId] = $true
            $blocker = $knownBlockerIds[$blockerId]
            if ([string]$blocker.next_action_id -ne $itemId) {
                $nextActionPlanFailures += "next_action_plan $itemId covers blocker $blockerId with mismatched next_action_id $($blocker.next_action_id)."
            }
            if ($blocker.PSObject.Properties["summary"] -and -not [string]::IsNullOrWhiteSpace([string]$blocker.summary) -and $itemBlockerSummaries -notcontains [string]$blocker.summary) {
                $nextActionPlanFailures += "next_action_plan $itemId blocker_summaries does not include covered blocker summary: $blockerId"
            }

            foreach ($blockerCommand in @(Get-ObjectArray -Object $blocker -Name "next_action_commands" | ForEach-Object { [string]$_ })) {
                if ($commands -notcontains $blockerCommand) {
                    $nextActionPlanFailures += "next_action_plan $itemId is missing blocker command for $blockerId`: $blockerCommand"
                }
            }
        }
    }

    foreach ($blocker in $blockers) {
        $blockerId = [string]$blocker.id
        if (-not $coveredBlockerIds.ContainsKey($blockerId)) {
            $nextActionPlanFailures += "blocker $blockerId is not covered by next_action_plan."
        }
    }

    if (-not [bool]$report.ready_for_production_testing -and $blockers.Count -gt 0 -and $nextActionPlan.Count -eq 0) {
        $nextActionPlanFailures += "ready_for_production_testing=false with blockers but next_action_plan is empty."
    }
    if ([bool]$report.ready_for_production_testing -and $nextActionPlan.Count -gt 0) {
        $nextActionPlanFailures += "ready_for_production_testing=true but next_action_plan is not empty."
    }
    $checks += New-Check -Id "next_action_plan_contract" -Passed ($nextActionPlanFailures.Count -eq 0) -Failures $nextActionPlanFailures -Evidence ([pscustomobject][ordered]@{ next_action_count = $nextActionPlan.Count })

    $checks += Add-Check -Id "ready_consistency" -Condition (-not [bool]$report.ready_for_production_testing -or ($blockers.Count -eq 0 -and $inputFailures.Count -eq 0 -and $closeoutFailures.Count -eq 0 -and $failedReadinessGates.Count -eq 0 -and $failedProvisioningChecks.Count -eq 0 -and $failedReleaseEvidenceChecks.Count -eq 0)) -Failure "ready_for_production_testing=true while outstanding blockers remain"
    if ($RequireReady) {
        $checks += Add-Check -Id "require_ready" -Condition ([bool]$report.ready_for_production_testing) -Failure "outstanding-work report is not ready for production testing"
    }

    if ($markdownExists) {
        $markdown = Get-Content -LiteralPath $resolvedMarkdownPath -Raw
        $markdownFailures = @()
        if ($markdown -notmatch '# Production MVP Outstanding Work') { $markdownFailures += "Markdown title is missing." }
        foreach ($section in @("## Source Files", "## Next Action Plan", "## Blockers", "## Operator Input Matrix", "## Readiness Gates", "## Provisioning Packet", "## Release Evidence", "## Next Command")) {
            if ($markdown -notmatch [regex]::Escape($section)) {
                $markdownFailures += "Markdown section is missing: $section"
            }
        }
        if ($null -ne $report.source_files) {
            foreach ($property in @($report.source_files.PSObject.Properties)) {
                $sourceFile = $property.Value
                if (-not [string]::IsNullOrWhiteSpace([string]$sourceFile.id) -and $markdown -notmatch [regex]::Escape([string]$sourceFile.id)) {
                    $markdownFailures += "Markdown does not include source file id: $($sourceFile.id)"
                }
                if (-not [string]::IsNullOrWhiteSpace([string]$sourceFile.sha256) -and $markdown -notmatch [regex]::Escape([string]$sourceFile.sha256)) {
                    $markdownFailures += "Markdown does not include source file SHA-256: $($sourceFile.id)"
                }
            }
        }
        foreach ($item in $nextActionPlan) {
            if ($markdown -notmatch [regex]::Escape([string]$item.id)) {
                $markdownFailures += "Markdown does not include next_action_plan id: $($item.id)"
            }
            foreach ($value in @(
                [string]$item.required_operator_input_count,
                [string]$item.external_blocker_count,
                [string]$item.operator_placeholder_count,
                [string]$item.operator_placeholder_occurrence_count,
                ([bool]$item.blocked_by_external_actor).ToString().ToLowerInvariant()
            )) {
                if (-not [string]::IsNullOrWhiteSpace($value) -and $markdown -notmatch [regex]::Escape($value)) {
                    $markdownFailures += "Markdown does not include next_action_plan operator metadata: $($item.id)"
                }
            }
            if (-not [string]::IsNullOrWhiteSpace([string]$item.action) -and $markdown -notmatch [regex]::Escape([string]$item.action)) {
                $markdownFailures += "Markdown does not include next_action_plan action: $($item.id)"
            }
            if (-not [string]::IsNullOrWhiteSpace([string]$item.summary) -and $markdown -notmatch [regex]::Escape([string]$item.summary)) {
                $markdownFailures += "Markdown does not include next_action_plan summary: $($item.id)"
            }
            foreach ($summary in @(Get-ObjectArray -Object $item -Name "blocker_summaries")) {
                if (-not [string]::IsNullOrWhiteSpace([string]$summary) -and $markdown -notmatch [regex]::Escape([string]$summary)) {
                    $markdownFailures += "Markdown does not include next_action_plan blocker summary: $($item.id)"
                }
            }
            foreach ($blockerId in @(Get-ObjectArray -Object $item -Name "blocker_ids")) {
                if (-not [string]::IsNullOrWhiteSpace([string]$blockerId) -and $markdown -notmatch [regex]::Escape([string]$blockerId)) {
                    $markdownFailures += "Markdown does not include next_action_plan blocker id: $($item.id)"
                }
            }
            foreach ($command in @(Get-ObjectArray -Object $item -Name "commands")) {
                if (-not [string]::IsNullOrWhiteSpace([string]$command) -and $markdown -notmatch [regex]::Escape([string]$command)) {
                    $markdownFailures += "Markdown does not include next_action_plan command: $($item.id)"
                }
            }
            foreach ($placeholder in @(Get-ObjectArray -Object $item -Name "operator_placeholders")) {
                foreach ($value in @([string]$placeholder.token, [string]$placeholder.input_kind, [string]$placeholder.validation_hint)) {
                    if (-not [string]::IsNullOrWhiteSpace($value) -and $markdown -notmatch [regex]::Escape($value)) {
                        $markdownFailures += "Markdown does not include next_action_plan placeholder metadata: $($item.id)"
                    }
                }
            }
        }
        foreach ($blocker in $blockers) {
            if ($markdown -notmatch [regex]::Escape([string]$blocker.id)) {
                $markdownFailures += "Markdown does not include blocker id: $($blocker.id)"
            }
            if ($blocker.PSObject.Properties["summary"] -and -not [string]::IsNullOrWhiteSpace([string]$blocker.summary) -and $markdown -notmatch [regex]::Escape([string]$blocker.summary)) {
                $markdownFailures += "Markdown does not include blocker summary: $($blocker.id)"
            }
            if ($blocker.PSObject.Properties["next_action"] -and -not [string]::IsNullOrWhiteSpace([string]$blocker.next_action) -and $markdown -notmatch [regex]::Escape([string]$blocker.next_action)) {
                $markdownFailures += "Markdown does not include blocker next_action: $($blocker.id)"
            }
            foreach ($command in @(Get-ObjectArray -Object $blocker -Name "next_action_commands")) {
                if (-not [string]::IsNullOrWhiteSpace([string]$command) -and $markdown -notmatch [regex]::Escape([string]$command)) {
                    $markdownFailures += "Markdown does not include blocker next_action command: $($blocker.id)"
                }
            }
            foreach ($placeholder in @(Get-ObjectArray -Object $blocker -Name "next_action_placeholders")) {
                foreach ($value in @([string]$placeholder.token, [string]$placeholder.input_kind, [string]$placeholder.validation_hint)) {
                    if (-not [string]::IsNullOrWhiteSpace($value) -and $markdown -notmatch [regex]::Escape($value)) {
                        $markdownFailures += "Markdown does not include blocker placeholder metadata: $($blocker.id)"
                    }
                }
            }
        }
        foreach ($gate in $failedReadinessGates) {
            if ($markdown -notmatch [regex]::Escape([string]$gate.id)) {
                $markdownFailures += "Markdown does not include failed readiness gate id: $($gate.id)"
            }
        }
        foreach ($check in $failedProvisioningChecks) {
            if ($markdown -notmatch [regex]::Escape([string]$check.id)) {
                $markdownFailures += "Markdown does not include failed provisioning check id: $($check.id)"
            }
        }
        foreach ($check in $failedReleaseEvidenceChecks) {
            if ($markdown -notmatch [regex]::Escape([string]$check.id)) {
                $markdownFailures += "Markdown does not include failed release-evidence check id: $($check.id)"
            }
        }
        if ($commandRecords.Count -gt 0 -and $markdown -notmatch '(?m)^\s+- Next command: ') {
            $markdownFailures += "Markdown does not include any Next command lines."
        }
        if (-not [string]::IsNullOrWhiteSpace([string]$report.next_closeout_command) -and $markdown -notmatch [regex]::Escape([string]$report.next_closeout_command)) {
            $markdownFailures += "Markdown does not include next_closeout_command."
        }
        $checks += New-Check -Id "markdown_coverage" -Passed ($markdownFailures.Count -eq 0) -Failures $markdownFailures -Evidence ([pscustomobject][ordered]@{ path = $resolvedMarkdownPath })
    }
    else {
        $checks += New-Check -Id "markdown_coverage" -Passed $false -Failures @("Markdown report is missing.") -Evidence ([pscustomobject][ordered]@{ path = $resolvedMarkdownPath })
    }
}

$failedChecks = @($checks | Where-Object { -not $_.passed })
$outputDirectory = Split-Path -Parent $resolvedOutputPath
if ($outputDirectory) {
    New-Item -ItemType Directory -Force -Path $outputDirectory | Out-Null
}

$validation = [pscustomobject][ordered]@{
    schema = "archrealms.passport.production_mvp_outstanding_work_validation.v1"
    created_utc = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
    repo_root = $repoRoot
    app_commit = $currentCommit
    report_path = $resolvedReportPath
    report_sha256 = Get-Sha256Hex -Path $resolvedReportPath
    markdown_path = $resolvedMarkdownPath
    markdown_sha256 = Get-Sha256Hex -Path $resolvedMarkdownPath
    generated = [bool]($Generate -or $UseGeneratedFixture)
    use_generated_fixture = [bool]$UseGeneratedFixture
    require_ready = [bool]$RequireReady
    passed = ($failedChecks.Count -eq 0)
    failed_check_count = $failedChecks.Count
    checks = $checks
}

$validation | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $resolvedOutputPath -Encoding UTF8
$validation | ConvertTo-Json -Depth 12

if (-not $validation.passed -and -not $NoFail) {
    throw "Production MVP outstanding-work report validation failed. See $resolvedOutputPath."
}
