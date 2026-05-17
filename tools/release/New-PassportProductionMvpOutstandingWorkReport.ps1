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
    return Read-JsonPayloadFromText -Text $text
}

function Read-JsonPayloadFromText {
    param([string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $null
    }

    $text = [string]$Text
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

function Get-EnvironmentVariableNames {
    param([string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return @()
    }

    $names = @()
    foreach ($match in [regex]::Matches($Text, "\b[A-Z][A-Z0-9]+(?:_[A-Z0-9]+){2,}\b")) {
        $names += [string]$match.Value
    }

    return @($names | Select-Object -Unique)
}

function Get-EnvironmentVariableInputKind {
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

function Get-EnvironmentVariableSensitivity {
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

function Get-EnvironmentVariableValidationHint {
    param(
        [string]$InputKind,
        [string]$Sensitivity
    )

    switch ($InputKind) {
        "secret" { return "Resolve from the approved secret store; do not commit or paste the value into evidence." }
        "digest" { return "Verify it is a lowercase 64-character SHA-256 digest and matches the referenced artifact." }
        "certificate_thumbprint" { return "Verify it matches the production signing certificate thumbprint in the controlled certificate store." }
        "endpoint_url" { return "Verify it is an HTTPS endpoint owned by the production lane and reachable from the Passport client." }
        "document_uri" { return "Verify it resolves to the approved runbook, policy, or evidence document for the production lane." }
        "approval_id" { return "Verify it references a signed approval record from the required accountable owner." }
        "authority_or_resource_id" { return "Verify it maps to an approved production authority, key, model, manifest, or resource record." }
        "provider_or_mode" { return "Verify it is one of the approved production providers or operating modes for this lane." }
        "storage_or_namespace" { return "Verify it points to the approved production storage root, path, or ledger namespace." }
        "owner_contact" { return "Verify it identifies the accountable owner or escalation contact for the production lane." }
        default {
            if ($Sensitivity -eq "restricted_operational") {
                return "Verify the value is approved for the production lane and recorded in the operator handoff."
            }
            return "Verify the value is non-empty and matches the production lane configuration."
        }
    }
}

function New-EnvironmentVariableRecord {
    param(
        [string]$Name,
        [object]$TemplateVariable = $null
    )

    $inputKind = Get-EnvironmentVariableInputKind -Name $Name
    $sensitivity = Get-EnvironmentVariableSensitivity -Name $Name -InputKind $inputKind
    $templateSecret = $false
    if ($null -ne $TemplateVariable -and $TemplateVariable.PSObject.Properties["secret"]) {
        $templateSecret = [bool]$TemplateVariable.secret
    }

    if ($templateSecret) {
        $inputKind = "secret"
        $sensitivity = "secret"
    }

    return [pscustomobject][ordered]@{
        name = $Name
        sources = @()
        input_kind = $inputKind
        sensitivity = $sensitivity
        requires_secret_store = ($sensitivity -eq "secret")
        validation_hint = Get-EnvironmentVariableValidationHint -InputKind $inputKind -Sensitivity $sensitivity
        template_gate = $(if ($null -ne $TemplateVariable) { [string]$TemplateVariable.gate } else { "" })
        template_required = $(if ($null -ne $TemplateVariable) { [bool]$TemplateVariable.required } else { $null })
        template_secret = $(if ($null -ne $TemplateVariable) { [bool]$TemplateVariable.secret } else { $null })
        template_description = $(if ($null -ne $TemplateVariable) { [string]$TemplateVariable.description } else { "" })
        readiness_gate_ids = @()
        missing_texts = @()
    }
}

function Add-EnvironmentVariableSource {
    param(
        [object]$Record,
        [string]$Source
    )

    if ($null -eq $Record -or [string]::IsNullOrWhiteSpace($Source)) {
        return
    }

    if (@($Record.sources) -notcontains $Source) {
        $Record.sources = @($Record.sources + $Source)
    }
}

function Set-EnvironmentVariableTemplateMetadata {
    param(
        [object]$Record,
        [object]$TemplateVariable
    )

    if ($null -eq $Record -or $null -eq $TemplateVariable) {
        return
    }

    $Record.template_gate = [string]$TemplateVariable.gate
    $Record.template_required = [bool]$TemplateVariable.required
    $Record.template_secret = [bool]$TemplateVariable.secret
    $Record.template_description = [string]$TemplateVariable.description

    if ([bool]$TemplateVariable.secret) {
        $Record.input_kind = "secret"
        $Record.sensitivity = "secret"
        $Record.requires_secret_store = $true
        $Record.validation_hint = Get-EnvironmentVariableValidationHint -InputKind "secret" -Sensitivity "secret"
    }

    Add-EnvironmentVariableSource -Record $Record -Source "production_environment_template"
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
        if ($null -eq $template -or -not $template.PSObject.Properties["variables"]) {
            return @()
        }

        return @($template.variables)
    }
    catch {
        return @()
    }
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
    return Get-FailedChildChecksFromReport -Report $childReport
}

function Get-FailedChildChecksFromReport {
    param([object]$Report)

    $childReport = $Report
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

function Format-PowerShellQuotedValue {
    param([string]$Value)

    return '"' + (($Value -replace '`', '``') -replace '"', '`"') + '"'
}

function Get-StaffStewardPilotOwner {
    param([string]$HandoffRoot)

    $manifestPath = Resolve-RepoPath -Path (Join-Path $HandoffRoot "pilot-handoff.manifest.json")
    $manifest = Read-JsonFile -Path $manifestPath
    if ($null -ne $manifest -and $manifest.PSObject.Properties["pilot_owner"]) {
        $pilotOwner = ([string]$manifest.pilot_owner).Trim()
        if (-not [string]::IsNullOrWhiteSpace($pilotOwner) -and $pilotOwner -notmatch '<[^>]+>') {
            return $pilotOwner
        }
    }

    return "<pilot-owner>"
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

function Get-ActionCommandArray {
    param([object]$Action)

    if ($null -eq $Action -or -not $Action.PSObject.Properties["commands"]) {
        return ,[string[]]@()
    }

    $commands = @($Action.commands | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | ForEach-Object { [string]$_ })
    return ,[string[]]$commands
}

function Get-OperatorPlaceholderInputKind {
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

function Get-OperatorPlaceholderValidationHint {
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
                $inputKind = Get-OperatorPlaceholderInputKind -Name $name
                $recordsByName[$name] = [ordered]@{
                    token = $token
                    name = $name
                    input_kind = $inputKind
                    required = $true
                    validation_hint = Get-OperatorPlaceholderValidationHint -Name $name -InputKind $inputKind
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

function New-BlockerSummary {
    param(
        [string]$Title,
        [string[]]$Failures = @(),
        [object]$OperatorAction = $null
    )

    $parts = @()
    $titleText = ConvertTo-ReportText -Value $Title
    if (-not [string]::IsNullOrWhiteSpace($titleText)) {
        $parts += $titleText
    }

    $firstFailure = @($Failures | ForEach-Object { ConvertTo-ReportText -Value $_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 1)
    if ($firstFailure.Count -gt 0) {
        $parts += "Failure: $($firstFailure[0])"
    }

    if ($null -ne $OperatorAction -and $OperatorAction.PSObject.Properties["action"]) {
        $actionText = ConvertTo-ReportText -Value $OperatorAction.action
        if (-not [string]::IsNullOrWhiteSpace($actionText)) {
            $parts += "Next: $actionText"
        }
    }

    $summary = ($parts | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join " "
    return ConvertTo-ReportText -Value $summary
}

function New-Blocker {
    param(
        [string]$Id,
        [string]$Category,
        [string]$Title,
        [string]$Source,
        [string[]]$SourceIds = @(),
        [string[]]$Failures = @(),
        [object]$OperatorAction = $null
    )

    $actionCommands = Get-ActionCommandArray -Action $OperatorAction
    $actionPlaceholders = Get-CommandPlaceholders -Commands $actionCommands

    return [pscustomobject][ordered]@{
        id = $Id
        category = $Category
        title = ConvertTo-ReportText -Value $Title
        summary = New-BlockerSummary -Title $Title -Failures $Failures -OperatorAction $OperatorAction
        status = "blocked"
        source = $Source
        source_ids = @($SourceIds | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | ForEach-Object { [string]$_ })
        failures = @($Failures | ForEach-Object { ConvertTo-ReportText -Value $_ })
        operator_action_id = $(if ($null -ne $OperatorAction -and $OperatorAction.PSObject.Properties["id"]) { [string]$OperatorAction.id } else { "" })
        operator_action_title = $(if ($null -ne $OperatorAction -and $OperatorAction.PSObject.Properties["title"]) { [string]$OperatorAction.title } else { "" })
        operator_action = $(if ($null -ne $OperatorAction -and $OperatorAction.PSObject.Properties["action"]) { [string]$OperatorAction.action } else { "" })
        operator_action_commands = @($actionCommands)
        operator_action_placeholders = @($actionPlaceholders)
        next_action_id = $(if ($null -ne $OperatorAction -and $OperatorAction.PSObject.Properties["id"]) { [string]$OperatorAction.id } else { "" })
        next_action_title = $(if ($null -ne $OperatorAction -and $OperatorAction.PSObject.Properties["title"]) { [string]$OperatorAction.title } else { "" })
        next_action = $(if ($null -ne $OperatorAction -and $OperatorAction.PSObject.Properties["action"]) { [string]$OperatorAction.action } else { "" })
        next_action_commands = @($actionCommands)
        next_action_placeholders = @($actionPlaceholders)
    }
}

function Add-UniqueString {
    param(
        [System.Collections.Generic.List[string]]$List,
        [string]$Value
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return
    }

    if (-not $List.Contains($Value)) {
        $List.Add($Value)
    }
}

function Get-NextActionPhase {
    param(
        [string]$ActionId,
        [string[]]$Categories = @()
    )

    if ($ActionId -eq "restore_outstanding_work_inputs") { return @{ Order = 0; Name = "restore_inputs" } }
    if ($ActionId -match "^pre_mvp|pre_mvp") { return @{ Order = 10; Name = "pre_mvp" } }
    if ($ActionId -match "^staging|staging_") { return @{ Order = 20; Name = "staging" } }
    if ($ActionId -match "^canary|canary_") { return @{ Order = 30; Name = "canary" } }
    if ($ActionId -match "package_signing") { return @{ Order = 40; Name = "package_signing" } }
    if ($ActionId -match "release_lane|hosted_runtime|hosted_operator") { return @{ Order = 50; Name = "hosted_endpoints" } }
    if ($ActionId -match "managed_storage") { return @{ Order = 60; Name = "managed_storage" } }
    if ($ActionId -match "managed_signing") { return @{ Order = 70; Name = "managed_signing" } }
    if ($ActionId -match "issuer|capacity|genesis|monetary") { return @{ Order = 75; Name = "monetary_provisioning" } }
    if ($ActionId -match "open_weight|ai_runtime") { return @{ Order = 80; Name = "ai_runtime" } }
    if ($ActionId -match "telemetry|production_ops") { return @{ Order = 82; Name = "operations" } }
    if ($ActionId -match "approval|approved|production_release") { return @{ Order = 85; Name = "approvals" } }
    if ($ActionId -match "readiness_ready|provisioning_packet_passed|reviewable_for_signoff|_report_ready") { return @{ Order = 88; Name = "release_evidence" } }
    if ($ActionId -eq "production_mvp_closeout" -or ($Categories -contains "closeout_failure")) { return @{ Order = 90; Name = "closeout" } }

    return @{ Order = 55; Name = "production_provisioning" }
}

function Test-ExternalBlockerCategory {
    param([string]$Category)

    return @(
        "closeout_failure",
        "readiness_gate",
        "provisioning_check",
        "release_evidence_check"
    ) -contains $Category
}

function New-NextActionPlan {
    param([object[]]$Blockers = @())

    $plansById = @{}
    foreach ($blocker in @($Blockers)) {
        $actionId = [string]$blocker.next_action_id
        if ([string]::IsNullOrWhiteSpace($actionId)) {
            $actionId = "operator_action_" + [Math]::Abs(([string]$blocker.next_action).GetHashCode())
        }

        if (-not $plansById.ContainsKey($actionId)) {
            $phase = Get-NextActionPhase -ActionId $actionId -Categories @([string]$blocker.category)
            $plansById[$actionId] = [ordered]@{
                id = $actionId
                phase = [string]$phase.Name
                phase_order = [int]$phase.Order
                title = ConvertTo-ReportText -Value $blocker.next_action_title
                action = ConvertTo-ReportText -Value $blocker.next_action
                commands = New-Object System.Collections.Generic.List[string]
                blocker_ids = New-Object System.Collections.Generic.List[string]
                external_blocker_ids = New-Object System.Collections.Generic.List[string]
                categories = New-Object System.Collections.Generic.List[string]
                source_ids = New-Object System.Collections.Generic.List[string]
                summaries = New-Object System.Collections.Generic.List[string]
            }
        }

        $entry = $plansById[$actionId]
        Add-UniqueString -List $entry.blocker_ids -Value ([string]$blocker.id)
        if (Test-ExternalBlockerCategory -Category ([string]$blocker.category)) {
            Add-UniqueString -List $entry.external_blocker_ids -Value ([string]$blocker.id)
        }
        Add-UniqueString -List $entry.categories -Value ([string]$blocker.category)
        foreach ($sourceId in @($blocker.source_ids)) {
            Add-UniqueString -List $entry.source_ids -Value ([string]$sourceId)
        }
        foreach ($command in @($blocker.next_action_commands)) {
            Add-UniqueString -List $entry.commands -Value ([string]$command)
        }
        Add-UniqueString -List $entry.summaries -Value ([string]$blocker.summary)
    }

    $items = foreach ($entry in $plansById.Values) {
        $blockerSummaries = @($entry.summaries | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | ForEach-Object { ConvertTo-ReportText -Value $_ })
        $firstSummary = @($blockerSummaries | Select-Object -First 1)
        $summaryParts = @(
            [string]$entry.title,
            "Covers $(@($entry.blocker_ids).Count) blocker(s)."
        )
        if ($firstSummary.Count -gt 0) {
            $summaryParts += "First blocker: $($firstSummary[0])"
        }

        $operatorPlaceholders = @(Get-CommandPlaceholders -Commands @($entry.commands))
        $externalBlockerCount = @($entry.external_blocker_ids).Count

        [pscustomobject][ordered]@{
            id = [string]$entry.id
            phase = [string]$entry.phase
            phase_order = [int]$entry.phase_order
            title = [string]$entry.title
            summary = ConvertTo-ReportText -Value (($summaryParts | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }) -join " ")
            action = [string]$entry.action
            commands = @($entry.commands)
            operator_placeholders = @($operatorPlaceholders)
            operator_placeholder_count = @($operatorPlaceholders).Count
            operator_placeholder_occurrence_count = Get-OperatorPlaceholderOccurrenceCount -Placeholders $operatorPlaceholders
            blocker_ids = @($entry.blocker_ids)
            blocker_summaries = @($blockerSummaries)
            operator_input_required = (@($entry.blocker_ids).Count -gt 0)
            required_operator_input_count = $externalBlockerCount
            external_blocker_count = $externalBlockerCount
            blocked_by_external_actor = ($externalBlockerCount -gt 0)
            external_blocker_ids = @($entry.external_blocker_ids)
            categories = @($entry.categories)
            source_ids = @($entry.source_ids)
        }
    }

    return @($items | Sort-Object @{ Expression = "phase_order"; Ascending = $true }, @{ Expression = "title"; Ascending = $true }, @{ Expression = "id"; Ascending = $true })
}

function Get-ReportReferenceRefreshRecord {
    param(
        [string]$GateId,
        [string]$MissingText
    )

    if ([string]::IsNullOrWhiteSpace($MissingText) -or $MissingText -notmatch "SHA256 does not match") {
        return $null
    }

    $record = switch ($GateId) {
        "pre_mvp_internal_verification" {
            [pscustomobject][ordered]@{
                variable = "ARCHREALMS_PASSPORT_PRE_MVP_VERIFICATION_REPORT_SHA256"
                update_switch = "-IncludeCurrentPreMvpReport"
                title = "Refresh pre-MVP report reference"
            }
            break
        }
        "staging_readiness" {
            [pscustomobject][ordered]@{
                variable = "ARCHREALMS_PASSPORT_STAGING_READINESS_REPORT_SHA256"
                update_switch = "-IncludeCurrentStagingReadinessReport"
                title = "Refresh staging readiness report reference"
            }
            break
        }
        "canary_mvp_readiness" {
            [pscustomobject][ordered]@{
                variable = "ARCHREALMS_PASSPORT_CANARY_MVP_READINESS_REPORT_SHA256"
                update_switch = "-IncludeCurrentCanaryMvpReadinessReport"
                title = "Refresh canary MVP readiness report reference"
            }
            break
        }
        default { $null }
    }

    if ($null -eq $record -or $MissingText -notmatch [regex]::Escape($record.variable)) {
        return $null
    }

    $command = "powershell -NoProfile -ExecutionPolicy Bypass -File tools\release\Update-PassportProductionMvpReportReferences.ps1 -EnvironmentFile artifacts\release\production-mvp.env $($record.update_switch)"

    return [pscustomobject][ordered]@{
        readiness_gate_id = $GateId
        variable = $record.variable
        missing_text = $MissingText
        title = $record.title
        action = "Refresh only the report path and SHA-256 reference in the production MVP environment file, preserving unrelated endpoint, signing, and secret values."
        operator_action_commands = @($command)
    }
}

$simulationRunReportPath = "artifacts\release\pre-mvp-simulation-run-report.json"
$resolvedSimulationRunReportPath = Resolve-RepoPath -Path $simulationRunReportPath
$simulationRunReportSha256 = "<simulation-run-sha256>"
if (Test-Path -LiteralPath $resolvedSimulationRunReportPath -PathType Leaf) {
    $simulationRunReportSha256 = Get-Sha256Hex -Path $resolvedSimulationRunReportPath
}

$staffStewardPilotHandoffRoot = "artifacts\release\pre-mvp-staff-steward-pilot-handoff"
$staffStewardPilotEvidenceRoot = "$staffStewardPilotHandoffRoot\pilot-evidence"
$staffStewardPilotOwner = Get-StaffStewardPilotOwner -HandoffRoot $staffStewardPilotHandoffRoot
$staffStewardPilotOwnerArgument = Format-PowerShellQuotedValue -Value $staffStewardPilotOwner
$staffStewardPilotWorkspaceCommand = "powershell -NoProfile -ExecutionPolicy Bypass -File tools\release\Start-PassportPreMvpStaffStewardPilot.ps1 -HandoffRoot $staffStewardPilotHandoffRoot -PilotOwner $staffStewardPilotOwnerArgument -Force"
$staffStewardPilotEvidenceFillCommand = @(
    "powershell -NoProfile -ExecutionPolicy Bypass -File tools\release\Set-PassportPreMvpStaffStewardPilotEvidencePacket.ps1",
    "-PacketRoot $staffStewardPilotEvidenceRoot",
    '-PilotId "pre-mvp-staff-steward-pilot-001"',
    "-PilotOwner $staffStewardPilotOwnerArgument",
    '-ParticipantId "<staff-or-steward-id>"',
    '-ParticipantRole "<staff-or-steward-role>"',
    '-CrownOwnedDeviceId "<controlled-device-id>"',
    '-SessionStartedUtc "<yyyy-mm-ddThh:mm:ssZ>"',
    '-SessionEndedUtc "<yyyy-mm-ddThh:mm:ssZ>"',
    '-SignedUtc "<yyyy-mm-ddThh:mm:ssZ>"',
    '-SignoffReference "<signature-or-controlled-approval-id>"',
    '-ReviewSignoffReference "<signature-or-controlled-approval-id>"',
    '-IdentityCreateOrRecoverEvidenceReference "<evidence-id-or-uri>"',
    '-DeviceAuthorizationEvidenceReference "<evidence-id-or-uri>"',
    '-WalletKeyBindingEvidenceReference "<evidence-id-or-uri>"',
    '-RecoveryRevocationEvidenceReference "<evidence-id-or-uri>"',
    '-StorageContributionOptInRevocationEvidenceReference "<evidence-id-or-uri>"',
    '-LedgerExportVerificationEvidenceReference "<evidence-id-or-uri>"',
    '-HostedAiPrivacyEvidenceReference "<evidence-id-or-uri>"',
    '-ProductionBlockerReviewEvidenceReference "<evidence-id-or-uri>"',
    '-ConfirmStaffOrStewardParticipant',
    '-ConfirmCrownOwnedDeviceUsed',
    '-ConfirmSyntheticOrFakeBalancesUsed',
    '-ConfirmNoCitizenProductionTokensUsed',
    '-ConfirmNoProductionRecordsCreated',
    '-ConfirmProductionReadinessBlockersReviewed',
    '-ConfirmNoPilotBlockingDefects',
    '-ConfirmPilotSignoffSigned',
    '-Force'
) -join " "
$staffStewardPilotCloseoutCommand = "powershell -NoProfile -ExecutionPolicy Bypass -File tools\release\Complete-PassportPreMvpStaffStewardPilotHandoff.ps1 -HandoffRoot $staffStewardPilotHandoffRoot -SimulationRunReportPath $simulationRunReportPath -SimulationRunReportSha256 $simulationRunReportSha256 -Force"
$stagingEvidenceRoot = "<filled-staging-evidence-root>"
$stagingEvidenceFillCommand = "powershell -NoProfile -ExecutionPolicy Bypass -File tools\release\Set-PassportStagingReadinessEvidencePacket.ps1 -PacketRoot $stagingEvidenceRoot -OperationalDrillId ""<staging-operational-drill-id>"" -RollbackDrillId ""<staging-rollback-drill-id>"" -PromotionApprovalId ""<staging-promotion-approval-id>"" -EngineeringSignoffId ""<engineering-signoff-id>"" -SecurityPrivacySignoffId ""<security-privacy-signoff-id>"" -CrownMonetaryAuthoritySignoffId ""<crown-monetary-authority-signoff-id>"" -ApiBaseUrl ""<staging-api-base-url>"" -AiGatewayUrl ""<staging-ai-gateway-url>"" -LedgerNamespace ""<staging-ledger-namespace>"" -TelemetryDestination ""<staging-telemetry-destination>"" -PackageVersion ""<staging-package-version>"" -Operator ""<operator-id>"" -IncidentResponseOwner ""<incident-response-owner-id>"" -OperationalEvidenceReference ""<staging-operational-evidence-refs>"" -RollbackReasonCode ""<rollback-reason-code>"" -RollbackApprover ""<staging-rollback-approver-ids>"" -AffectedServiceClass ""identity;wallet;storage;ai;ledger-export"" -AffectedAsset ""ARCH;CC"" -RollbackUserFacingStatus ""<rollback-user-facing-status>"" -ConfirmOperationalDrillCompleted -ConfirmProductionCandidateUpgradeValidated -ConfirmEndpointFailoverValidated -ConfirmSigningVerificationValidated -ConfirmLedgerExportReplayValidated -ConfirmRecoveryRevocationValidated -ConfirmStorageProofValidationCompleted -ConfirmStorageRedemptionDryRunCompleted -ConfirmConversionDisclosureDryRunCompleted -ConfirmTelemetryPrivacyValidated -ConfirmIncidentResponseValidated -ConfirmSupportAccessControlsValidated -ConfirmAiGatewayAuthPrivacyValidated -ConfirmProhibitedClaimsBlocked -ConfirmRollbackDrillCompleted -ConfirmNewOperationsDisabledOrRouted -ConfirmLedgerEventsPreserved -ConfirmNoDeletionMutationOrBackdating -ConfirmPendingEscrowResolvedByPolicy -ConfirmExportAccessPreserved -ConfirmProductionRecordsUntouched -ConfirmCanaryOrProductionReleaseApproved -ConfirmProductApprovalSigned -ConfirmEngineeringSignoffSigned -ConfirmSecurityPrivacySignoffSigned -ConfirmCrownMonetaryAuthoritySignoffSigned -Force"
$stagingEvidenceCloseoutCommand = "powershell -NoProfile -ExecutionPolicy Bypass -File tools\release\Complete-PassportStagingReadinessEvidencePacket.ps1 -PacketRoot $stagingEvidenceRoot -EnvironmentFile artifacts\release\staging.env -Force"
$canaryEvidenceRoot = "<filled-canary-evidence-root>"
$canaryEvidenceFillCommand = "powershell -NoProfile -ExecutionPolicy Bypass -File tools\release\Set-PassportCanaryMvpReadinessEvidencePacket.ps1 -PacketRoot $canaryEvidenceRoot -PolicyId ""<canary-policy-id>"" -IncidentReviewId ""<canary-incident-review-id>"" -BalanceReconciliationId ""<canary-balance-reconciliation-id>"" -ServiceDeliveryReconciliationId ""<canary-service-delivery-reconciliation-id>"" -SupportReadinessId ""<canary-support-readiness-id>"" -ProductionApprovalId ""<canary-production-approval-id>"" -ProductionLedgerNamespace ""<production-mvp-ledger-namespace>"" -PolicyEvidenceReference ""<canary-policy-evidence-refs>"" -IncidentEvidenceReference ""<canary-incident-evidence-refs>"" -BalanceEvidenceReference ""<canary-balance-evidence-refs>"" -ServiceDeliveryEvidenceReference ""<canary-service-delivery-evidence-refs>"" -SupportEvidenceReference ""<canary-support-evidence-refs>"" -AllowedServiceClass ""<canary-allowed-service-classes>"" -SupportOwner ""<support-owner-id>"" -IncidentResponseOwner ""<incident-response-owner-id>"" -RollbackPolicyId ""<rollback-policy-id>"" -EngineeringSignoffId ""<engineering-signoff-id>"" -SecurityPrivacySignoffId ""<security-privacy-signoff-id>"" -CrownMonetaryAuthoritySignoffId ""<crown-monetary-authority-signoff-id>"" -ApprovalNotes ""<canary-approval-notes-or-record-id>"" -ConfirmProductionIntended -ConfirmProductionLedger -ConfirmAllowlistedCitizensOnly -ConfirmIncidentReviewCompleted -ConfirmNoUnresolvedCriticalIncidents -ConfirmNoUnresolvedHighIncidents -ConfirmBalancesReconciled -ConfirmEscrowReconciled -ConfirmBurnRefundRecreditReconciled -ConfirmCrownReserveReconciled -ConfirmNoNegativeBalances -ConfirmNoUnapprovedIssuance -ConfirmNoStagingRecordsDetected -ConfirmServiceDeliveryReconciled -ConfirmStorageRedemptionsReconciled -ConfirmStorageProofsReconciled -ConfirmBurnsMatchVerifiedEpochs -ConfirmRefundsRecreditsExtensionsReconciled -ConfirmSupportReady -ConfirmSupportQueueReviewed -ConfirmRecoverySupportReady -ConfirmEscalationPathReady -ConfirmSupportAccessControlsValidated -ConfirmProductionMvpReleaseApproved -Force"
$canaryEvidenceCloseoutCommand = "powershell -NoProfile -ExecutionPolicy Bypass -File tools\release\Complete-PassportCanaryMvpReadinessEvidencePacket.ps1 -PacketRoot $canaryEvidenceRoot -EnvironmentFile artifacts\release\canary-mvp.env -Force"
$canaryEvidenceValidationCommand = "powershell -NoProfile -ExecutionPolicy Bypass -File tools\release\Test-PassportCanaryMvpReadinessEvidencePacket.ps1 -PacketRoot $canaryEvidenceRoot -RequireNoPlaceholders"
$openWeightAiRuntimeRoot = "<filled-open-weight-ai-runtime-root>"
$openWeightAiRuntimeValidationCommand = @(
    "powershell -NoProfile -ExecutionPolicy Bypass -File tools\release\Test-PassportOpenWeightAiRuntimeDeployment.ps1",
    "-VllmComposePath $openWeightAiRuntimeRoot\docker-compose.vllm.yml",
    "-TgiComposePath $openWeightAiRuntimeRoot\docker-compose.tgi.yml",
    "-EnvTemplatePath $openWeightAiRuntimeRoot\open-weight-ai-runtime.env.template",
    "-ReadmePath $openWeightAiRuntimeRoot\README.md",
    "-ModelApprovalPath $openWeightAiRuntimeRoot\model-approval-request.template.md",
    "-VectorStoreProvisioningPath $openWeightAiRuntimeRoot\vector-store-provisioning.template.md",
    "-RuntimeReadinessEvidencePath $openWeightAiRuntimeRoot\ai-runtime-readiness-evidence.template.md",
    "-RequireNoPlaceholders",
    "-ProbeRuntime",
    '-RuntimeBaseUrl "<approved-ai-runtime-base-url>"',
    '-ModelId "<approved-ai-model-id>"'
) -join " "
$openWeightAiRuntimePacketProbeCommand = "powershell -NoProfile -ExecutionPolicy Bypass -File tools\release\Test-PassportProductionProvisioningPacket.ps1 -PacketRoot <controlled-production-packet-root> -RequireNoPlaceholders -ProbeAiRuntime"

$readinessActionMap = @{
    pre_mvp_internal_verification = New-Action `
        -Id "pre_mvp_internal_verification" `
        -Title "Complete staff/steward pilot evidence" `
        -Action "Open the staff/steward pilot workspace, perform the controlled pilot, fill the evidence packet, validate it with no placeholders, generate the final pilot report, and rerun pre-MVP internal verification with the report path and SHA-256." `
        -Commands @(
            $staffStewardPilotWorkspaceCommand,
            $staffStewardPilotEvidenceFillCommand,
            $staffStewardPilotCloseoutCommand
        )
    staging_readiness = New-Action `
        -Id "staging_readiness" `
        -Title "Close out staging readiness" `
        -Action "Fill staging endpoint, ledger/telemetry, operational drill, rollback drill, and promotion approval evidence; then run the staging closeout command with real non-synthetic values." `
        -Commands @(
            $stagingEvidenceFillCommand,
            $stagingEvidenceCloseoutCommand
        )
    canary_mvp_readiness = New-Action `
        -Id "canary_mvp_readiness" `
        -Title "Close out canary MVP readiness" `
        -Action "Fill the canary policy, incident review, balance reconciliation, service-delivery reconciliation, support readiness, and production-promotion evidence; then run the canary closeout command." `
        -Commands @(
            $canaryEvidenceFillCommand,
            $canaryEvidenceCloseoutCommand
        )
    package_signing = New-Action `
        -Id "package_signing" `
        -Title "Configure production package signing" `
        -Action "Acquire the production MSIX signing certificate, configure PFX material or secure PFX path plus password, set publisher and timestamp URL, and validate the signing certificate report." `
        -Commands @(
            "powershell -NoProfile -ExecutionPolicy Bypass -File tools\release\Test-PassportPackageSigningProvisioning.ps1 -PackageSigningPath <filled-package-signing-root> -RequireNoPlaceholders",
            "powershell -NoProfile -ExecutionPolicy Bypass -File tools\release\Test-PassportWindowsSigningCertificate.ps1 -PfxPath <approved-msix-signing-pfx-path> -PasswordFile <approved-msix-signing-password-file> -ExpectedPublisher ""CN=The Archrealms"" -TimestampUrl <approved-timestamp-url> -OutputPath artifacts\release\production-signing-certificate-report.json"
        )
    release_lane_endpoints = New-Action `
        -Id "release_lane_endpoints" `
        -Title "Provision production API and AI gateway endpoints" `
        -Action "Deploy stable HTTPS production API and AI gateway endpoints, fill endpoint provisioning evidence, and load approved URLs into the production environment." `
        -Commands @(
            "powershell -NoProfile -ExecutionPolicy Bypass -File tools\release\Test-PassportReleaseLaneEndpointProvisioning.ps1 -EndpointProvisioningPath <filled-release-lane-endpoints-root> -RequireNoPlaceholders"
        )
    hosted_runtime_status = New-Action `
        -Id "hosted_runtime_status" `
        -Title "Make hosted runtime status ready" `
        -Action "Ensure the production hosted API and AI gateway report ready runtime status using the approved endpoints and non-secret operations configuration." `
        -Commands @(
            "powershell -NoProfile -ExecutionPolicy Bypass -File tools\release\Test-PassportProductionMvpReadiness.ps1 -EnvironmentFile artifacts\release\production-mvp.env -NoFail -OutputPath artifacts\release\production-mvp-readiness-report.json"
        )
    hosted_operator_gate = New-Action `
        -Id "hosted_operator_gate" `
        -Title "Configure hosted operator key gate" `
        -Action "Create or retrieve the approved hosted operator key, provide the raw key only from a secure local secret file, provide its SHA-256 hash as production configuration, and rerun ProductionMvp readiness." `
        -Commands @(
            "powershell -NoProfile -ExecutionPolicy Bypass -File tools\release\Test-PassportProductionMvpReadiness.ps1 -EnvironmentFile artifacts\release\production-mvp.env -HostedOperatorKeyFile <approved-hosted-operator-key-file> -HostedOperatorKeySha256 <approved-hosted-operator-key-sha256> -NoFail -OutputPath artifacts\release\production-mvp-readiness-report.json"
        )
    hosted_ai_runtime_probe = New-Action `
        -Id "hosted_ai_runtime_probe" `
        -Title "Make hosted AI runtime probe pass" `
        -Action "Deploy the approved open-weight inference endpoint and configure the hosted AI gateway so the operator-authenticated non-mutating probe receives an answer." `
        -Commands @(
            $openWeightAiRuntimeValidationCommand,
            "powershell -NoProfile -ExecutionPolicy Bypass -File tools\release\Test-PassportProductionMvpReadiness.ps1 -EnvironmentFile artifacts\release\production-mvp.env -NoFail -OutputPath artifacts\release\production-mvp-readiness-report.json"
        )
    hosted_operator_status = New-Action `
        -Id "hosted_operator_status" `
        -Title "Verify hosted operator authentication" `
        -Action "Configure the production hosted API URL and operator key hash, provide the operator secret only to the secure readiness environment, and confirm /ops/operator/status authorizes it." `
        -Commands @(
            "powershell -NoProfile -ExecutionPolicy Bypass -File tools\release\Test-PassportProductionMvpReadiness.ps1 -EnvironmentFile artifacts\release\production-mvp.env -NoFail -OutputPath artifacts\release\production-mvp-readiness-report.json"
        )
    managed_storage_backups = New-Action `
        -Id "managed_storage_backups" `
        -Title "Provision managed storage and backups" `
        -Action "Fill managed data-root, storage provider, backup policy, and restore runbook values, then validate managed storage provisioning with no placeholders." `
        -Commands @(
            "powershell -NoProfile -ExecutionPolicy Bypass -File tools\release\Test-PassportManagedStorageProvisioning.ps1 -ManagedStoragePath <filled-managed-storage-root> -RequireNoPlaceholders"
        )
    managed_storage_status = New-Action `
        -Id "managed_storage_status" `
        -Title "Make managed storage status ready" `
        -Action "Bring the production hosted API online with durable records and append-log roots, then verify /ops/storage/status write/delete and backup-manifest enumeration probes." `
        -Commands @(
            "powershell -NoProfile -ExecutionPolicy Bypass -File tools\release\Test-PassportProductionMvpReadiness.ps1 -EnvironmentFile artifacts\release\production-mvp.env -NoFail -OutputPath artifacts\release\production-mvp-readiness-report.json"
        )
    managed_signing_key_custody = New-Action `
        -Id "managed_signing_key_custody" `
        -Title "Provision managed signing custody" `
        -Action "Move hosted service signing and Crown authority signing keys into managed, KMS, HSM, managed-HSM, or cloud-KMS custody and fill the custody evidence packet." `
        -Commands @(
            "powershell -NoProfile -ExecutionPolicy Bypass -File tools\release\Test-PassportManagedSigningCustodyProvisioning.ps1 -ManagedSigningCustodyPath <filled-managed-signing-custody-root> -RequireNoPlaceholders"
        )
    managed_signing_endpoint_probe = New-Action `
        -Id "managed_signing_endpoint_probe" `
        -Title "Make managed signing endpoint probe pass" `
        -Action "Deploy an HTTPS managed signing endpoint that returns non-local RSA signature and public-key evidence for the ProductionMvp readiness probe." `
        -Commands @(
            "powershell -NoProfile -ExecutionPolicy Bypass -File tools\release\Test-PassportProductionMvpReadiness.ps1 -EnvironmentFile artifacts\release\production-mvp.env -NoFail -OutputPath artifacts\release\production-mvp-readiness-report.json"
        )
    issuer_capacity_genesis_secrets = New-Action `
        -Id "issuer_capacity_genesis_secrets" `
        -Title "Configure issuer, capacity, genesis, and ledger IDs" `
        -Action "Approve and load the CC issuer authority ID, capacity report issuer ID, ARCH genesis manifest ID, and production ledger namespace." `
        -Commands @(
            "powershell -NoProfile -ExecutionPolicy Bypass -File tools\release\Test-PassportProductionMonetaryProvisioning.ps1 -ProductionMonetaryPath <filled-production-monetary-root> -RequireNoPlaceholders",
            "powershell -NoProfile -ExecutionPolicy Bypass -File tools\release\Test-PassportProductionProvisioningPacket.ps1 -PacketRoot <controlled-production-packet-root> -RequireNoPlaceholders -CreateHostedMonetaryRecords -MonetaryHostedApiBaseUrl <production-hosted-api-base-url> -MonetaryOperatorKeyFile <approved-operator-key-file>"
        )
    open_weight_ai_runtime = New-Action `
        -Id "open_weight_ai_runtime" `
        -Title "Provision approved open-weight AI runtime" `
        -Action "Approve the model artifact/license, deploy vLLM or TGI-compatible inference, configure vector store and knowledge approval root, and validate the runtime deployment/probe." `
        -Commands @(
            $openWeightAiRuntimeValidationCommand,
            $openWeightAiRuntimePacketProbeCommand
        )
    telemetry_incident_response = New-Action `
        -Id "telemetry_incident_response" `
        -Title "Configure telemetry and incident response" `
        -Action "Fill the telemetry destination, retention policy URI, incident-response runbook URI, and incident owner, then validate production ops documents." `
        -Commands @(
            "powershell -NoProfile -ExecutionPolicy Bypass -File tools\release\Test-PassportProductionOpsDocuments.ps1 -ProductionOpsPath <filled-production-ops-root> -RequireNoPlaceholders"
        )
    production_release_approvals = New-Action `
        -Id "production_release_approvals" `
        -Title "Record production release approvals" `
        -Action "Record product, engineering, security/privacy, and Crown monetary authority signoff IDs in the approved release-approval record." `
        -Commands @(
            "powershell -NoProfile -ExecutionPolicy Bypass -File tools\release\Test-PassportProductionOpsDocuments.ps1 -ProductionOpsPath <filled-production-ops-root> -RequireNoPlaceholders",
            "powershell -NoProfile -ExecutionPolicy Bypass -File tools\release\Complete-PassportProductionMvpCloseout.ps1 -EnvironmentFile artifacts\release\production-mvp.env -ProductionProvisioningPacketRoot <controlled-production-packet-root> -OutputDirectory artifacts\release\production-mvp-closeout -Force"
        )
}

$provisioningActionMap = @{
    package_signing_provisioning = New-Action `
        -Id "package_signing_provisioning" `
        -Title "Fill package-signing provisioning" `
        -Action "Fill and approve production MSIX signing request, sideload trust policy, and Store signing policy." `
        -Commands @(
            "powershell -NoProfile -ExecutionPolicy Bypass -File tools\release\Test-PassportPackageSigningProvisioning.ps1 -PackageSigningPath <filled-package-signing-root> -RequireNoPlaceholders"
        )
    release_lane_endpoint_provisioning = New-Action `
        -Id "release_lane_endpoint_provisioning" `
        -Title "Fill release-lane endpoint provisioning" `
        -Action "Fill and approve production endpoint, TLS/DNS/routing, and endpoint readiness evidence." `
        -Commands @(
            "powershell -NoProfile -ExecutionPolicy Bypass -File tools\release\Test-PassportReleaseLaneEndpointProvisioning.ps1 -EndpointProvisioningPath <filled-release-lane-endpoints-root> -RequireNoPlaceholders"
        )
    managed_storage_provisioning = New-Action `
        -Id "managed_storage_provisioning" `
        -Title "Fill managed-storage provisioning" `
        -Action "Fill and approve managed storage, backup schedule, and storage readiness evidence." `
        -Commands @(
            "powershell -NoProfile -ExecutionPolicy Bypass -File tools\release\Test-PassportManagedStorageProvisioning.ps1 -ManagedStoragePath <filled-managed-storage-root> -RequireNoPlaceholders"
        )
    managed_signing_custody_provisioning = New-Action `
        -Id "managed_signing_custody_provisioning" `
        -Title "Fill managed-signing custody provisioning" `
        -Action "Fill and approve key custody, signing endpoint policy, and signing readiness evidence." `
        -Commands @(
            "powershell -NoProfile -ExecutionPolicy Bypass -File tools\release\Test-PassportManagedSigningCustodyProvisioning.ps1 -ManagedSigningCustodyPath <filled-managed-signing-custody-root> -RequireNoPlaceholders"
        )
    canary_readiness_provisioning = New-Action `
        -Id "canary_readiness_provisioning" `
        -Title "Fill canary readiness provisioning" `
        -Action "Fill and approve the canary policy, incident, reconciliation, support, and production-promotion evidence templates." `
        -Commands @(
            "powershell -NoProfile -ExecutionPolicy Bypass -File tools\release\Test-PassportCanaryReadinessProvisioning.ps1 -CanaryReadinessPath <filled-canary-readiness-root> -RequireNoPlaceholders"
        )
    canary_readiness_evidence_packet = New-Action `
        -Id "canary_readiness_evidence_packet" `
        -Title "Complete canary readiness evidence packet" `
        -Action "Complete and validate the canary readiness evidence packet with no placeholders." `
        -Commands @(
            $canaryEvidenceFillCommand,
            $canaryEvidenceValidationCommand
        )
    open_weight_ai_runtime_deployment = New-Action `
        -Id "open_weight_ai_runtime_deployment" `
        -Title "Fill open-weight AI runtime provisioning" `
        -Action "Fill model approval, vector store, runtime readiness evidence, and runtime env values for the approved open-weight deployment." `
        -Commands @(
            $openWeightAiRuntimeValidationCommand,
            $openWeightAiRuntimePacketProbeCommand
        )
    production_ops_documents = New-Action `
        -Id "production_ops_documents" `
        -Title "Fill production ops documents" `
        -Action "Fill backup, restore, telemetry retention, incident response, and release approval documents." `
        -Commands @(
            "powershell -NoProfile -ExecutionPolicy Bypass -File tools\release\Test-PassportProductionOpsDocuments.ps1 -ProductionOpsPath <filled-production-ops-root> -RequireNoPlaceholders"
        )
    production_monetary_provisioning = New-Action `
        -Id "production_monetary_provisioning" `
        -Title "Fill production monetary provisioning" `
        -Action "Fill issuer/capacity/genesis provisioning, ARCH genesis request, and CC capacity request records, then create the hosted monetary registry records from the controlled packet." `
        -Commands @(
            "powershell -NoProfile -ExecutionPolicy Bypass -File tools\release\Test-PassportProductionMonetaryProvisioning.ps1 -ProductionMonetaryPath <filled-production-monetary-root> -RequireNoPlaceholders",
            "powershell -NoProfile -ExecutionPolicy Bypass -File tools\release\Test-PassportProductionProvisioningPacket.ps1 -PacketRoot <controlled-production-packet-root> -RequireNoPlaceholders -CreateHostedMonetaryRecords -MonetaryHostedApiBaseUrl <production-hosted-api-base-url> -MonetaryOperatorKeyFile <approved-operator-key-file>"
        )
}

$releaseEvidenceActionMap = @{
    pre_mvp_passed = New-Action `
        -Id "pre_mvp_passed" `
        -Title "Close pre-MVP evidence" `
        -Action "Open the staff/steward pilot workspace, complete the staff/steward pilot packet, and rerun pre-MVP verification until the report passes." `
        -Commands @(
            $staffStewardPilotWorkspaceCommand,
            $staffStewardPilotEvidenceFillCommand,
            $staffStewardPilotCloseoutCommand
        )
    provisioning_packet_passed = New-Action `
        -Id "provisioning_packet_passed" `
        -Title "Validate filled production provisioning" `
        -Action "Fill the controlled production provisioning packet and validate it with no placeholders." `
        -Commands @(
            "powershell -NoProfile -ExecutionPolicy Bypass -File tools\release\Test-PassportProductionProvisioningPacket.ps1 -PacketRoot <controlled-production-packet-root> -RequireNoPlaceholders",
            "powershell -NoProfile -ExecutionPolicy Bypass -File tools\release\Test-PassportProductionProvisioningPacket.ps1 -PacketRoot <controlled-production-packet-root> -RequireNoPlaceholders -CreateHostedMonetaryRecords -MonetaryHostedApiBaseUrl <production-hosted-api-base-url> -MonetaryOperatorKeyFile <approved-operator-key-file>"
        )
    reviewable_for_signoff = New-Action `
        -Id "reviewable_for_signoff" `
        -Title "Regenerate reviewable release evidence" `
        -Action "Regenerate and validate the production release evidence packet after pre-MVP, staging, canary, readiness, and provisioning inputs are complete." `
        -Commands @(
            "powershell -NoProfile -ExecutionPolicy Bypass -File tools\release\New-PassportProductionMvpReleaseEvidencePacket.ps1 -EnvironmentFile artifacts\release\production-mvp.env -OutputDirectory artifacts\release\production-mvp-release-evidence-packet -Force",
            "powershell -NoProfile -ExecutionPolicy Bypass -File tools\release\Test-PassportProductionMvpReleaseEvidencePacket.ps1 -RequireReady -OutputPath artifacts\release\production-mvp-closeout\production-mvp-release-evidence-validation-report.json"
        )
    readiness_ready = New-Action `
        -Id "readiness_ready" `
        -Title "Make production readiness pass" `
        -Action "Load approved production values and rerun the ProductionMvp readiness report until all gates pass." `
        -Commands @(
            "powershell -NoProfile -ExecutionPolicy Bypass -File tools\release\Test-PassportProductionMvpReadiness.ps1 -EnvironmentFile artifacts\release\production-mvp.env -OutputPath artifacts\release\production-mvp-readiness-report.json"
        )
    staging_readiness_report_ready = New-Action `
        -Id "staging_readiness_report_ready" `
        -Title "Close staging readiness" `
        -Action "Complete the filled staging evidence packet and produce a non-synthetic ready staging report." `
        -Commands @(
            $stagingEvidenceFillCommand,
            $stagingEvidenceCloseoutCommand
        )
    staging_readiness_report_promotion_approved = New-Action `
        -Id "staging_readiness_report_promotion_approved" `
        -Title "Approve staging promotion" `
        -Action "Record signed staging promotion approval evidence and rerun the staging closeout." `
        -Commands @(
            $stagingEvidenceFillCommand,
            $stagingEvidenceCloseoutCommand
        )
    canary_mvp_readiness_report_ready = New-Action `
        -Id "canary_mvp_readiness_report_ready" `
        -Title "Close canary MVP readiness" `
        -Action "Complete the filled canary evidence packet and produce a non-synthetic ready canary report." `
        -Commands @(
            $canaryEvidenceFillCommand,
            $canaryEvidenceCloseoutCommand
        )
    canary_mvp_readiness_report_production_approved = New-Action `
        -Id "canary_mvp_readiness_report_production_approved" `
        -Title "Approve ProductionMvp promotion" `
        -Action "Record signed canary-to-production approval evidence and rerun the canary closeout." `
        -Commands @(
            $canaryEvidenceFillCommand,
            $canaryEvidenceCloseoutCommand
        )
}

$packageSigningReleaseEvidenceAction = New-Action `
    -Id "package_signing_certificate_evidence" `
    -Title "Attach package-signing certificate evidence" `
    -Action "Validate the production MSIX signing certificate and regenerate release evidence so certificate details are included." `
    -Commands @(
        "powershell -NoProfile -ExecutionPolicy Bypass -File tools\release\Test-PassportWindowsSigningCertificate.ps1 -PfxPath <approved-msix-signing-pfx-path> -PasswordFile <approved-msix-signing-password-file> -ExpectedPublisher ""CN=The Archrealms"" -TimestampUrl <approved-timestamp-url> -OutputPath artifacts\release\production-signing-certificate-report.json",
        "powershell -NoProfile -ExecutionPolicy Bypass -File tools\release\New-PassportProductionMvpReleaseEvidencePacket.ps1 -EnvironmentFile artifacts\release\production-mvp.env -OutputDirectory artifacts\release\production-mvp-release-evidence-packet -Force"
    )

foreach ($id in @(
    "package_signing_certificate_included_when_gate_passes",
    "package_signing_certificate_passed_when_gate_passes",
    "package_signing_certificate_material",
    "package_signing_certificate_subject",
    "package_signing_certificate_thumbprint",
    "package_signing_certificate_private_key",
    "package_signing_certificate_code_signing_eku",
    "package_signing_certificate_timestamp_url",
    "package_signing_expected_publisher"
)) {
    $releaseEvidenceActionMap[$id] = $packageSigningReleaseEvidenceAction
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
        failed_gate_count = 2
        gates = @(
            [pscustomobject][ordered]@{
                id = "pre_mvp_internal_verification"
                description = "Pre-MVP internal verification must pass before citizen-facing token release."
                passed = $false
                missing = @(
                    "ARCHREALMS_PASSPORT_PRE_MVP_VERIFICATION_REPORT_SHA256 does not match the report file",
                    "pre-MVP internal verification report did not pass"
                )
            },
            [pscustomobject][ordered]@{
                id = "package_signing"
                description = "Production MVP package signing uses a stable certificate and timestamping, not a generated test certificate."
                passed = $false
                missing = @(
                    "production package signing certificate is not configured",
                    "PASSPORT_WINDOWS_MSIX_PFX_BASE64 or PASSPORT_WINDOWS_MSIX_PFX_PATH",
                    "PASSPORT_WINDOWS_MSIX_PFX_PASSWORD",
                    "PASSPORT_WINDOWS_MSIX_TIMESTAMP_URL"
                )
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
$releaseEvidence = Read-JsonFile -Path $files.release_evidence_validation_report.path
$provisioningReportSource = "report_file"
$inputWarnings = @()
$provisioningStep = $null
$expectedProvisioningHash = ""

if ($null -ne $closeout -and
    $closeout.PSObject.Properties["steps"] -and
    $closeout.steps.PSObject.Properties["production_provisioning_packet_validation"]) {
    $provisioningStep = $closeout.steps.production_provisioning_packet_validation
    if ($provisioningStep.PSObject.Properties["report"] -and
        $provisioningStep.report.PSObject.Properties["file"] -and
        $provisioningStep.report.file.PSObject.Properties["sha256"]) {
        $expectedProvisioningHash = [string]$provisioningStep.report.file.sha256
    }

    $closeoutProvisioningPath = ""
    if ($provisioningStep.PSObject.Properties["report"] -and
        $provisioningStep.report.PSObject.Properties["file"] -and
        $provisioningStep.report.file.PSObject.Properties["path"]) {
        $closeoutProvisioningPath = [string]$provisioningStep.report.file.path
    }

    if (-not [string]::IsNullOrWhiteSpace($closeoutProvisioningPath)) {
        $closeoutProvisioningFile = New-FileRecord -Id "production_provisioning_packet_report" -Path $closeoutProvisioningPath
        if ($closeoutProvisioningFile.exists -and
            ([string]::IsNullOrWhiteSpace($expectedProvisioningHash) -or $closeoutProvisioningFile.sha256 -eq $expectedProvisioningHash)) {
            $files["production_provisioning_packet_report"] = $closeoutProvisioningFile
        }
        elseif ($closeoutProvisioningFile.exists) {
            $inputWarnings += "The closeout provisioning report exists but does not match the closeout manifest hash; keeping the requested provisioning report path."
        }
        else {
            $inputWarnings += "The closeout provisioning report path does not exist; keeping the requested provisioning report path."
        }
    }

    $provisioning = Read-JsonFile -Path $files.production_provisioning_packet_report.path
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
else {
    $provisioning = Read-JsonFile -Path $files.production_provisioning_packet_report.path
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
        $childFailedChecks = @()
        $childFailedCheckSource = ""
        if ($check.evidence -and $check.evidence.PSObject.Properties["output_excerpt"]) {
            $embeddedChildReport = Read-JsonPayloadFromText -Text ([string]$check.evidence.output_excerpt)
            $embeddedChildFailedChecks = @(Get-FailedChildChecksFromReport -Report $embeddedChildReport)
            if ($embeddedChildFailedChecks.Count -gt 0) {
                $childFailedChecks = $embeddedChildFailedChecks
                $childFailedCheckSource = "provisioning_output_excerpt"
            }
        }

        if ($childFailedChecks.Count -eq 0 -and $childReportExists) {
            $childFailedChecks = @(Get-FailedChildChecks -Path $resolvedChildReportPath)
            if ($childFailedChecks.Count -gt 0) {
                $childFailedCheckSource = "child_report_file"
            }
        }

        $action = $(if ($provisioningActionMap.ContainsKey([string]$check.id)) { $provisioningActionMap[[string]$check.id] } else { $null })

        $failedProvisioningChecks += [pscustomobject][ordered]@{
            id = [string]$check.id
            description = ConvertTo-ReportText -Value $check.description
            failures = @($check.failures | ForEach-Object { ConvertTo-ReportText -Value $_ })
            operator_action = $(if ($null -ne $action) { $action } else { $null })
            operator_action_text = $(if ($null -ne $action) { [string]$action.action } else { "" })
            child_report_path = $childReportPath
            child_report_exists = $childReportExists
            child_report_sha256 = $(if ($childReportExists) { Get-Sha256Hex -Path $resolvedChildReportPath } else { "" })
            child_failed_check_count = $(if ($check.evidence -and $check.evidence.PSObject.Properties["child_failed_check_count"]) { [int]$check.evidence.child_failed_check_count } else { $null })
            child_failed_check_source = $childFailedCheckSource
            child_failed_checks = $childFailedChecks
        }
    }
}

$failedReleaseEvidenceChecks = @()
if ($null -ne $releaseEvidence -and $releaseEvidence.PSObject.Properties["checks"]) {
    foreach ($check in @($releaseEvidence.checks | Where-Object { $_.passed -ne $true })) {
        $action = $(if ($releaseEvidenceActionMap.ContainsKey([string]$check.id)) { $releaseEvidenceActionMap[[string]$check.id] } else { $null })
        $failedReleaseEvidenceChecks += [pscustomobject][ordered]@{
            id = [string]$check.id
            failures = @($check.failures | ForEach-Object { ConvertTo-ReportText -Value $_ })
            operator_action = $(if ($null -ne $action) { $action } else { $null })
            operator_action_text = $(if ($null -ne $action) { [string]$action.action } else { "" })
        }
    }
}

$environmentVariableMap = @{}
$templateEnvironmentVariables = @(Get-ProductionMvpEnvironmentTemplateVariables)
foreach ($templateVariable in $templateEnvironmentVariables) {
    $templateName = [string]$templateVariable.name
    if ([string]::IsNullOrWhiteSpace($templateName)) {
        continue
    }

    if (-not $environmentVariableMap.ContainsKey($templateName)) {
        $environmentVariableMap[$templateName] = New-EnvironmentVariableRecord -Name $templateName -TemplateVariable $templateVariable
    }

    Set-EnvironmentVariableTemplateMetadata -Record $environmentVariableMap[$templateName] -TemplateVariable $templateVariable
}

$reportReferenceRefreshMap = @{}
$readinessEvidenceItems = @()
foreach ($gate in $failedReadinessGates) {
    foreach ($missing in @($gate.missing)) {
        $refreshRecord = Get-ReportReferenceRefreshRecord -GateId ([string]$gate.id) -MissingText ([string]$missing)
        if ($null -ne $refreshRecord) {
            $refreshKey = "$($refreshRecord.readiness_gate_id)|$($refreshRecord.variable)"
            if (-not $reportReferenceRefreshMap.ContainsKey($refreshKey)) {
                $reportReferenceRefreshMap[$refreshKey] = $refreshRecord
            }
        }

        $envNames = @(Get-EnvironmentVariableNames -Text ([string]$missing))
        foreach ($envName in $envNames) {
            if (-not $environmentVariableMap.ContainsKey($envName)) {
                $environmentVariableMap[$envName] = New-EnvironmentVariableRecord -Name $envName
            }

            $record = $environmentVariableMap[$envName]
            Add-EnvironmentVariableSource -Record $record -Source "readiness_missing_text"
            if (@($record.readiness_gate_ids) -notcontains [string]$gate.id) {
                $record.readiness_gate_ids = @($record.readiness_gate_ids + [string]$gate.id)
            }
            if (@($record.missing_texts) -notcontains [string]$missing) {
                $record.missing_texts = @($record.missing_texts + [string]$missing)
            }
        }

        if ($envNames.Count -eq 0) {
            $action = $gate.operator_action
            $readinessEvidenceItems += [pscustomobject][ordered]@{
                readiness_gate_id = [string]$gate.id
                missing_text = [string]$missing
                operator_action = $(if ($null -ne $action) { [string]$action.action } else { "" })
                operator_action_detail = $(if ($null -ne $action) { $action } else { $null })
                operator_action_commands = Get-ActionCommandArray -Action $action
            }
        }
    }
}

$requiredEnvironmentVariables = @($environmentVariableMap.Keys | Sort-Object | ForEach-Object { $environmentVariableMap[$_] })
$reportReferenceRefreshes = @($reportReferenceRefreshMap.Keys | Sort-Object | ForEach-Object { $reportReferenceRefreshMap[$_] })

$requiredProvisioningEvidenceFiles = @()
foreach ($check in $failedProvisioningChecks) {
    foreach ($child in @($check.child_failed_checks)) {
        if (-not [string]::IsNullOrWhiteSpace($child.evidence_path)) {
            $requiredProvisioningEvidenceFiles += [pscustomobject][ordered]@{
                provisioning_check_id = [string]$check.id
                child_check_id = [string]$child.id
                evidence_path = [string]$child.evidence_path
                failures = @($child.failures)
            }
        }
    }
}

$releaseEvidenceItems = @()
foreach ($check in $failedReleaseEvidenceChecks) {
    $releaseEvidenceItems += [pscustomobject][ordered]@{
        id = [string]$check.id
        failures = @($check.failures)
        operator_action = [string]$check.operator_action_text
        operator_action_detail = $(if ($null -ne $check.operator_action) { $check.operator_action } else { $null })
        operator_action_commands = Get-ActionCommandArray -Action $check.operator_action
    }
}

$failedProvisioningChildCheckCount = (@($failedProvisioningChecks | ForEach-Object {
    if ($null -ne $_.child_failed_check_count) {
        [int]$_.child_failed_check_count
    }
    else {
        @($_.child_failed_checks).Count
    }
}) | Measure-Object -Sum).Sum
if ($null -eq $failedProvisioningChildCheckCount) {
    $failedProvisioningChildCheckCount = 0
}

$nextCloseoutCommand = "powershell -NoProfile -ExecutionPolicy Bypass -File tools\release\Complete-PassportProductionMvpCloseout.ps1 -EnvironmentFile artifacts\release\production-mvp.env -ProductionProvisioningPacketRoot <controlled-production-packet-root> -OutputDirectory artifacts\release\production-mvp-closeout -Force"
$inputFailureAction = New-Action `
    -Id "restore_outstanding_work_inputs" `
    -Title "Restore outstanding-work input reports" `
    -Action "Regenerate the missing production closeout, readiness, provisioning, or release-evidence reports before rerunning the outstanding-work report." `
    -Commands @($nextCloseoutCommand)
$closeoutFailureAction = New-Action `
    -Id "production_mvp_closeout" `
    -Title "Rerun production MVP closeout" `
    -Action "Resolve the upstream readiness, provisioning, and release-evidence blockers, then rerun the production closeout command." `
    -Commands @($nextCloseoutCommand)

$blockers = @()
for ($index = 0; $index -lt $inputFailures.Count; $index++) {
    $blockers += New-Blocker `
        -Id ("input_failure_{0:000}" -f ($index + 1)) `
        -Category "input_failure" `
        -Title "Restore required outstanding-work input" `
        -Source "outstanding_work_report_inputs" `
        -SourceIds @("input_failures") `
        -Failures @([string]$inputFailures[$index]) `
        -OperatorAction $inputFailureAction
}

for ($index = 0; $index -lt $closeoutFailures.Count; $index++) {
    $blockers += New-Blocker `
        -Id ("closeout_failure_{0:000}" -f ($index + 1)) `
        -Category "closeout_failure" `
        -Title "Resolve production MVP closeout failure" `
        -Source "closeout_failures" `
        -SourceIds @("production_mvp_closeout") `
        -Failures @([string]$closeoutFailures[$index]) `
        -OperatorAction $closeoutFailureAction
}

foreach ($gate in $failedReadinessGates) {
    $title = if ($null -ne $gate.operator_action -and -not [string]::IsNullOrWhiteSpace([string]$gate.operator_action.title)) { [string]$gate.operator_action.title } else { [string]$gate.description }
    $blockers += New-Blocker `
        -Id "readiness_gate_$($gate.id)" `
        -Category "readiness_gate" `
        -Title $title `
        -Source "failed_readiness_gates" `
        -SourceIds @([string]$gate.id) `
        -Failures @($gate.missing) `
        -OperatorAction $gate.operator_action
}

foreach ($check in $failedProvisioningChecks) {
    $failures = @($check.failures)
    foreach ($child in @($check.child_failed_checks)) {
        $childMessage = (@($child.failures) -join "; ")
        if ([string]::IsNullOrWhiteSpace($childMessage)) {
            $childMessage = "failed"
        }
        $failures += "$($child.id): $childMessage"
    }

    $title = if (-not [string]::IsNullOrWhiteSpace([string]$check.operator_action_text)) { [string]$check.operator_action_text } else { [string]$check.description }
    $blockers += New-Blocker `
        -Id "provisioning_check_$($check.id)" `
        -Category "provisioning_check" `
        -Title $title `
        -Source "failed_provisioning_checks" `
        -SourceIds @([string]$check.id) `
        -Failures $failures `
        -OperatorAction $check.operator_action
}

foreach ($check in $failedReleaseEvidenceChecks) {
    $title = if (-not [string]::IsNullOrWhiteSpace([string]$check.operator_action_text)) { [string]$check.operator_action_text } else { [string]$check.id }
    $blockers += New-Blocker `
        -Id "release_evidence_check_$($check.id)" `
        -Category "release_evidence_check" `
        -Title $title `
        -Source "failed_release_evidence_checks" `
        -SourceIds @([string]$check.id) `
        -Failures @($check.failures) `
        -OperatorAction $check.operator_action
}

$nextActionPlan = New-NextActionPlan -Blockers $blockers
$readinessEvidenceItemCommandCount = @($readinessEvidenceItems | Where-Object { @($_.operator_action_commands).Count -gt 0 }).Count
$releaseEvidenceItemCommandCount = @($releaseEvidenceItems | Where-Object { @($_.operator_action_commands).Count -gt 0 }).Count
$operatorPlaceholderCount = (@($nextActionPlan | ForEach-Object { @($_.operator_placeholders).Count }) | Measure-Object -Sum).Sum
if ($null -eq $operatorPlaceholderCount) {
    $operatorPlaceholderCount = 0
}
$operatorPlaceholderOccurrenceCount = (@($nextActionPlan | ForEach-Object { [int]$_.operator_placeholder_occurrence_count }) | Measure-Object -Sum).Sum
if ($null -eq $operatorPlaceholderOccurrenceCount) {
    $operatorPlaceholderOccurrenceCount = 0
}
$externalBlockerCount = (@($nextActionPlan | ForEach-Object { [int]$_.external_blocker_count }) | Measure-Object -Sum).Sum
if ($null -eq $externalBlockerCount) {
    $externalBlockerCount = 0
}

$contractFailures = @()
foreach ($item in @($readinessEvidenceItems)) {
    if ($item.operator_action_commands -isnot [array]) {
        $contractFailures += "readiness_evidence_items operator_action_commands must serialize as an array for $($item.readiness_gate_id)."
    }
}
foreach ($item in @($releaseEvidenceItems)) {
    if ($item.operator_action_commands -isnot [array]) {
        $contractFailures += "release_evidence_items operator_action_commands must serialize as an array for $($item.id)."
    }
}
foreach ($item in @($reportReferenceRefreshes)) {
    if ($item.operator_action_commands -isnot [array]) {
        $contractFailures += "report_reference_refreshes operator_action_commands must serialize as an array for $($item.readiness_gate_id)."
    }
}
foreach ($item in @($blockers)) {
    if ($item.operator_action_commands -isnot [array]) {
        $contractFailures += "blockers operator_action_commands must serialize as an array for $($item.id)."
    }

    if ($item.operator_action_placeholders -isnot [array]) {
        $contractFailures += "blockers operator_action_placeholders must serialize as an array for $($item.id)."
    }

    if ($item.next_action_placeholders -isnot [array]) {
        $contractFailures += "blockers next_action_placeholders must serialize as an array for $($item.id)."
    }
}
foreach ($item in @($nextActionPlan)) {
    if ($item.commands -isnot [array]) {
        $contractFailures += "next_action_plan commands must serialize as an array for $($item.id)."
    }

    if ($item.operator_placeholders -isnot [array]) {
        $contractFailures += "next_action_plan operator_placeholders must serialize as an array for $($item.id)."
    }

    if ($item.blocker_ids -isnot [array]) {
        $contractFailures += "next_action_plan blocker_ids must serialize as an array for $($item.id)."
    }
}
if ($UseGeneratedFixture -and @($reportReferenceRefreshes).Count -eq 0) {
    $contractFailures += "generated fixture must include a report reference refresh command."
}
if ($contractFailures.Count -gt 0) {
    throw "Outstanding-work report contract validation failed: $($contractFailures -join '; ')"
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
        blocker_count = $blockers.Count
        next_action_count = $nextActionPlan.Count
        operator_placeholder_count = [int]$operatorPlaceholderCount
        operator_placeholder_occurrence_count = [int]$operatorPlaceholderOccurrenceCount
        external_blocker_count = [int]$externalBlockerCount
        failed_readiness_gate_count = $failedReadinessGates.Count
        failed_provisioning_check_count = $failedProvisioningChecks.Count
        failed_provisioning_child_check_count = [int]$failedProvisioningChildCheckCount
        failed_release_evidence_check_count = $failedReleaseEvidenceChecks.Count
        required_environment_variable_count = $requiredEnvironmentVariables.Count
        report_reference_refresh_count = $reportReferenceRefreshes.Count
        required_readiness_evidence_item_count = $readinessEvidenceItems.Count
        required_readiness_evidence_item_command_count = $readinessEvidenceItemCommandCount
        required_provisioning_evidence_file_count = $requiredProvisioningEvidenceFiles.Count
        required_release_evidence_item_count = $releaseEvidenceItems.Count
        required_release_evidence_item_command_count = $releaseEvidenceItemCommandCount
    }
    closeout_failures = $closeoutFailures
    next_action_plan = $nextActionPlan
    blockers = $blockers
    failed_readiness_gates = $failedReadinessGates
    failed_provisioning_checks = $failedProvisioningChecks
    failed_release_evidence_checks = $failedReleaseEvidenceChecks
    operator_input_matrix = [pscustomobject][ordered]@{
        environment_variables = $requiredEnvironmentVariables
        report_reference_refreshes = $reportReferenceRefreshes
        readiness_evidence_items = $readinessEvidenceItems
        provisioning_evidence_files = $requiredProvisioningEvidenceFiles
        release_evidence_items = $releaseEvidenceItems
    }
    next_closeout_command = $nextCloseoutCommand
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
    $lines.Add("- Blockers: $($blockers.Count)")
    $lines.Add("- Operator command placeholders: $([int]$operatorPlaceholderCount)")
    $lines.Add("- Failed readiness gates: $($failedReadinessGates.Count)")
    $lines.Add("- Failed provisioning checks: $($failedProvisioningChecks.Count)")
    $lines.Add("- Failed provisioning child checks: $failedProvisioningChildCheckCount")
    $lines.Add("- Failed release-evidence checks: $($failedReleaseEvidenceChecks.Count)")
    $lines.Add("- Provisioning report source: $provisioningReportSource")
    $lines.Add("")
    $lines.Add("## Source Files")
    foreach ($sourceFile in @($files.Values)) {
        $existsText = ([bool]$sourceFile.exists).ToString().ToLowerInvariant()
        $lines.Add("- ``$($sourceFile.id)``")
        $lines.Add("  - Path: ``$($sourceFile.path)``")
        $lines.Add("  - Exists: $existsText")
        if (-not [string]::IsNullOrWhiteSpace([string]$sourceFile.sha256)) {
            $lines.Add("  - SHA-256: ``$($sourceFile.sha256)``")
        }
    }
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
    $lines.Add("## Next Action Plan")
    if ($nextActionPlan.Count -eq 0) {
        $lines.Add("- None")
    }
    else {
        foreach ($item in @($nextActionPlan)) {
            $lines.Add("- ``$($item.id)`` [$($item.phase)]: $($item.title)")
            if (-not [string]::IsNullOrWhiteSpace([string]$item.summary)) {
                $lines.Add("  - Summary: $($item.summary)")
            }
            if (@($item.blocker_summaries).Count -gt 0) {
                $lines.Add("  - Covered blocker summaries:")
                foreach ($summary in @($item.blocker_summaries)) {
                    $lines.Add("    - $summary")
                }
            }
            $lines.Add("  - Action: $($item.action)")
            $lines.Add("  - Blockers covered: $((@($item.blocker_ids) -join ', '))")
            $lines.Add("  - Operator input required: $(([bool]$item.operator_input_required).ToString().ToLowerInvariant())")
            $lines.Add("  - External blocker count: $($item.external_blocker_count)")
            $lines.Add("  - Placeholder token count: $($item.operator_placeholder_count)")
            $lines.Add("  - Placeholder occurrence count: $($item.operator_placeholder_occurrence_count)")
            $lines.Add("  - Blocked by external actor: $(([bool]$item.blocked_by_external_actor).ToString().ToLowerInvariant())")
            foreach ($command in @($item.commands | Select-Object -First 3)) {
                if (-not [string]::IsNullOrWhiteSpace($command)) {
                    $lines.Add("  - Command: ``$command``")
                }
            }
            foreach ($placeholder in @($item.operator_placeholders)) {
                if (-not [string]::IsNullOrWhiteSpace([string]$placeholder.token)) {
                    $lines.Add("  - Placeholder: ``$($placeholder.token)`` ($($placeholder.input_kind)) - $($placeholder.validation_hint)")
                }
            }
        }
    }

    $lines.Add("")
    $lines.Add("## Blockers")
    if ($blockers.Count -eq 0) {
        $lines.Add("- None")
    }
    else {
        foreach ($blocker in @($blockers)) {
            $lines.Add("- ``$($blocker.id)`` [$($blocker.category)]: $($blocker.title)")
            if (-not [string]::IsNullOrWhiteSpace([string]$blocker.summary)) {
                $lines.Add("  - Summary: $($blocker.summary)")
            }
            foreach ($failure in @($blocker.failures | Select-Object -First 3)) {
                if (-not [string]::IsNullOrWhiteSpace([string]$failure)) {
                    $lines.Add("  - $failure")
                }
            }
            if (-not [string]::IsNullOrWhiteSpace([string]$blocker.operator_action)) {
                $lines.Add("  - Action: $($blocker.operator_action)")
            }
            if (-not [string]::IsNullOrWhiteSpace([string]$blocker.next_action)) {
                $lines.Add("  - Next action: $($blocker.next_action)")
            }
            foreach ($command in @($blocker.next_action_commands | Select-Object -First 2)) {
                if (-not [string]::IsNullOrWhiteSpace($command)) {
                    $lines.Add("  - Next action command: ``$command``")
                }
            }
            foreach ($command in @($blocker.operator_action_commands | Select-Object -First 2)) {
                if (-not [string]::IsNullOrWhiteSpace($command)) {
                    $lines.Add("  - Next command: ``$command``")
                }
            }
            foreach ($placeholder in @($blocker.next_action_placeholders)) {
                if (-not [string]::IsNullOrWhiteSpace([string]$placeholder.token)) {
                    $lines.Add("  - Placeholder: ``$($placeholder.token)`` ($($placeholder.input_kind)) - $($placeholder.validation_hint)")
                }
            }
        }
    }

    $lines.Add("")
    $lines.Add("## Operator Input Matrix")
    $lines.Add("- Environment variables to configure: $($requiredEnvironmentVariables.Count)")
    foreach ($variable in @($requiredEnvironmentVariables | Select-Object -First 25)) {
        $lines.Add("  - ``$($variable.name)`` for ``$((@($variable.readiness_gate_ids) -join ', '))``")
    }
    if ($requiredEnvironmentVariables.Count -gt 25) {
        $lines.Add("  - ...$($requiredEnvironmentVariables.Count - 25) more in the JSON report")
    }

    $lines.Add("- Report references to refresh: $($reportReferenceRefreshes.Count)")
    foreach ($item in @($reportReferenceRefreshes | Select-Object -First 5)) {
        $lines.Add("  - ``$($item.readiness_gate_id)``: $($item.variable)")
        $lines.Add("    - Action: $($item.action)")
        foreach ($command in @($item.operator_action_commands | Select-Object -First 2)) {
            if (-not [string]::IsNullOrWhiteSpace($command)) {
                $lines.Add("    - Next command: ``$command``")
            }
        }
    }
    if ($reportReferenceRefreshes.Count -gt 5) {
        $lines.Add("  - ...$($reportReferenceRefreshes.Count - 5) more in the JSON report")
    }

    $lines.Add("- Readiness evidence items to complete: $($readinessEvidenceItems.Count)")
    foreach ($item in @($readinessEvidenceItems | Select-Object -First 10)) {
        $lines.Add("  - ``$($item.readiness_gate_id)``: $($item.missing_text)")
        if (-not [string]::IsNullOrWhiteSpace([string]$item.operator_action)) {
            $lines.Add("    - Action: $($item.operator_action)")
        }
        foreach ($command in @($item.operator_action_commands | Select-Object -First 2)) {
            if (-not [string]::IsNullOrWhiteSpace($command)) {
                $lines.Add("    - Next command: ``$command``")
            }
        }
    }
    if ($readinessEvidenceItems.Count -gt 10) {
        $lines.Add("  - ...$($readinessEvidenceItems.Count - 10) more in the JSON report")
    }

    $lines.Add("- Provisioning evidence files to fill: $($requiredProvisioningEvidenceFiles.Count)")
    foreach ($file in @($requiredProvisioningEvidenceFiles | Select-Object -First 15)) {
        $lines.Add("  - ``$($file.provisioning_check_id)/$($file.child_check_id)``: $($file.evidence_path)")
    }
    if ($requiredProvisioningEvidenceFiles.Count -gt 15) {
        $lines.Add("  - ...$($requiredProvisioningEvidenceFiles.Count - 15) more in the JSON report")
    }

    $lines.Add("- Release evidence checks to satisfy: $($releaseEvidenceItems.Count)")
    foreach ($item in @($releaseEvidenceItems | Select-Object -First 10)) {
        $message = (@($item.failures) -join "; ")
        $lines.Add("  - ``$($item.id)``: $message")
        if (-not [string]::IsNullOrWhiteSpace([string]$item.operator_action)) {
            $lines.Add("    - Action: $($item.operator_action)")
        }
        foreach ($command in @($item.operator_action_commands | Select-Object -First 2)) {
            if (-not [string]::IsNullOrWhiteSpace($command)) {
                $lines.Add("    - Next command: ``$command``")
            }
        }
    }
    if ($releaseEvidenceItems.Count -gt 10) {
        $lines.Add("  - ...$($releaseEvidenceItems.Count - 10) more in the JSON report")
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
            foreach ($command in @($gate.operator_action.commands | Select-Object -First 4)) {
                if (-not [string]::IsNullOrWhiteSpace($command)) {
                    $lines.Add("  - Next command: ``$command``")
                }
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
            $detail = if ([string]::IsNullOrWhiteSpace($check.operator_action_text)) { $check.description } else { $check.operator_action_text }
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
            foreach ($command in @($check.operator_action.commands | Select-Object -First 4)) {
                if (-not [string]::IsNullOrWhiteSpace($command)) {
                    $lines.Add("  - Next command: ``$command``")
                }
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
            if (-not [string]::IsNullOrWhiteSpace($check.operator_action_text)) {
                $lines.Add("  - Action: $($check.operator_action_text)")
            }
            foreach ($command in @($check.operator_action.commands | Select-Object -First 4)) {
                if (-not [string]::IsNullOrWhiteSpace($command)) {
                    $lines.Add("  - Next command: ``$command``")
                }
            }
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
    blocker_count = $blockers.Count
    failed_readiness_gate_count = $failedReadinessGates.Count
    failed_provisioning_check_count = $failedProvisioningChecks.Count
    failed_provisioning_child_check_count = [int]$failedProvisioningChildCheckCount
    failed_release_evidence_check_count = $failedReleaseEvidenceChecks.Count
    operator_placeholder_count = [int]$operatorPlaceholderCount
    operator_placeholder_occurrence_count = [int]$operatorPlaceholderOccurrenceCount
    external_blocker_count = [int]$externalBlockerCount
    required_environment_variable_count = $requiredEnvironmentVariables.Count
    report_reference_refresh_count = $reportReferenceRefreshes.Count
    required_readiness_evidence_item_count = $readinessEvidenceItems.Count
    required_readiness_evidence_item_command_count = $readinessEvidenceItemCommandCount
    required_provisioning_evidence_file_count = $requiredProvisioningEvidenceFiles.Count
    required_release_evidence_item_count = $releaseEvidenceItems.Count
    required_release_evidence_item_command_count = $releaseEvidenceItemCommandCount
}

$result | ConvertTo-Json -Depth 4

if (-not $NoFail -and -not $report.ready_for_production_testing) {
    throw "Production MVP still has outstanding work. See $resolvedOutputPath."
}
