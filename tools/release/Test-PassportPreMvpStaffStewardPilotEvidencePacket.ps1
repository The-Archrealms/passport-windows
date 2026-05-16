param(
    [string]$PacketRoot = "deploy\pre-mvp-internal-verification",
    [string]$OutputPath = "artifacts\release\pre-mvp-staff-steward-pilot-evidence-validation-report.json",
    [switch]$RequireNoPlaceholders,
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

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $null
    }

    return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
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

function Read-ObjectInt {
    param(
        [object]$Object,
        [string]$Name
    )

    if ($null -eq $Object -or -not $Object.PSObject.Properties[$Name]) {
        return 0
    }

    try {
        return [int]$Object.$Name
    }
    catch {
        return 0
    }
}

function Test-NotPlaceholder {
    param(
        [string]$Name,
        [string]$Value,
        [bool]$Required = $true
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        if ($Required) {
            return "$Name is required"
        }

        return ""
    }

    if ($RequireNoPlaceholders -and ($Value -match '<[^>]+>' -or $Value -match '^\s*set value\s*$')) {
        return "$Name contains a placeholder value"
    }

    return ""
}

function Test-Sha256 {
    param(
        [string]$Name,
        [string]$Value,
        [bool]$Required = $true
    )

    $failure = Test-NotPlaceholder -Name $Name -Value $Value -Required:$Required
    if ($failure) {
        return $failure
    }

    if (-not [string]::IsNullOrWhiteSpace($Value) -and $Value -notmatch '^[0-9a-fA-F]{64}$') {
        if ($RequireNoPlaceholders -or $Value -notmatch '<[^>]+>') {
            return "$Name must be a SHA-256 hex string"
        }
    }

    return ""
}

function Test-ReferencedFileHash {
    param(
        [string]$Name,
        [string]$PathValue,
        [string]$Sha256Value,
        [bool]$Required = $false
    )

    $failures = @()
    $pathFailure = Test-NotPlaceholder -Name "$Name path" -Value $PathValue -Required:$Required
    if ($pathFailure) {
        $failures += $pathFailure
    }

    $shaFailure = Test-Sha256 -Name "$Name sha256" -Value $Sha256Value -Required:$Required
    if ($shaFailure) {
        $failures += $shaFailure
    }

    if ($failures.Count -gt 0) {
        return $failures
    }

    if ([string]::IsNullOrWhiteSpace($PathValue) -or $PathValue -match '<[^>]+>') {
        return $failures
    }

    $resolvedPath = Resolve-RepoPath -Path $PathValue
    if (-not (Test-Path -LiteralPath $resolvedPath -PathType Leaf)) {
        if ($Required -or $RequireNoPlaceholders) {
            $failures += "$Name referenced file is missing: $resolvedPath"
        }

        return $failures
    }

    if (-not [string]::IsNullOrWhiteSpace($Sha256Value) -and $Sha256Value -match '^[0-9a-fA-F]{64}$') {
        $actualSha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $resolvedPath).Hash.ToLowerInvariant()
        if ($actualSha256 -ne $Sha256Value.ToLowerInvariant()) {
            $failures += "$Name SHA-256 mismatch: expected $($Sha256Value.ToLowerInvariant()) actual $actualSha256"
        }
    }

    return $failures
}

function Test-RequiredTrue {
    param(
        [object]$Object,
        [string]$Name,
        [string]$Description
    )

    if ($RequireNoPlaceholders -and -not (Read-ObjectBool -Object $Object -Name $Name)) {
        return "$Description must be true"
    }

    if ($null -eq $Object -or -not $Object.PSObject.Properties[$Name]) {
        return "$Description field is required"
    }

    return ""
}

function Find-EvidenceFile {
    param(
        [string]$Root,
        [string]$BaseName
    )

    $candidate = Join-Path $Root "$BaseName.json"
    if (Test-Path -LiteralPath $candidate -PathType Leaf) {
        return $candidate
    }

    $templateCandidate = Join-Path $Root "$BaseName.template.json"
    if (Test-Path -LiteralPath $templateCandidate -PathType Leaf) {
        return $templateCandidate
    }

    return $candidate
}

function New-Check {
    param(
        [string]$Id,
        [string[]]$Failures,
        [object]$Evidence = $null
    )

    $cleanFailures = @($Failures | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    return [pscustomobject][ordered]@{
        id = $Id
        passed = ($cleanFailures.Count -eq 0)
        failures = $cleanFailures
        evidence = $Evidence
    }
}

$resolvedPacketRoot = Resolve-RepoPath -Path $PacketRoot
$resolvedOutput = Resolve-RepoPath -Path $OutputPath

$paths = [ordered]@{
    session = Find-EvidenceFile -Root $resolvedPacketRoot -BaseName "pilot-session-record"
    signoff = Find-EvidenceFile -Root $resolvedPacketRoot -BaseName "participant-signoff"
    issue_review = Find-EvidenceFile -Root $resolvedPacketRoot -BaseName "pilot-issue-review"
}

$requiredScenarios = @(
    "identity_create_or_recover",
    "device_authorization",
    "wallet_key_binding",
    "recovery_revocation",
    "storage_contribution_opt_in_revocation",
    "ledger_export_verification",
    "hosted_ai_privacy",
    "production_blocker_review"
)

$session = Read-JsonFile -Path $paths.session
$sessionFailures = @()
if ($null -eq $session) {
    $sessionFailures += "missing or unreadable pilot session record: $($paths.session)"
}
else {
    if ((Read-ObjectString -Object $session -Name "schema") -ne "archrealms.passport.pre_mvp_staff_steward_pilot_session.v1") {
        $sessionFailures += "pilot session record has unexpected schema"
    }

    if ((Read-ObjectString -Object $session -Name "lane") -ne "internal-verification") {
        $sessionFailures += "pilot session record must use internal-verification lane"
    }

    foreach ($field in @("created_utc", "pilot_id", "pilot_owner", "policy_version", "app_commit", "session_started_utc", "session_ended_utc")) {
        $failure = Test-NotPlaceholder -Name "pilot session $field" -Value (Read-ObjectString -Object $session -Name $field)
        if ($failure) { $sessionFailures += $failure }
    }

    foreach ($failure in @(
        Test-ReferencedFileHash -Name "pilot session artifact manifest" -PathValue (Read-ObjectString -Object $session -Name "artifact_manifest_path") -Sha256Value (Read-ObjectString -Object $session -Name "artifact_manifest_sha256") -Required:$RequireNoPlaceholders
        Test-RequiredTrue -Object $session -Name "synthetic_or_fake_balances_used" -Description "synthetic or fake balances used"
        Test-RequiredTrue -Object $session -Name "no_citizen_production_tokens_used" -Description "no citizen production tokens used"
        Test-RequiredTrue -Object $session -Name "no_production_records_created" -Description "no production records created"
    )) {
        if ($failure) { $sessionFailures += $failure }
    }

    if ((Read-ObjectInt -Object $session -Name "pilot_participant_count") -lt 1) {
        $sessionFailures += "pilot session must include at least one participant"
    }

    $devices = @($session.crown_owned_device_ids)
    if ($devices.Count -lt 1) {
        $sessionFailures += "pilot session must list at least one Crown-owned device"
    }

    for ($index = 0; $index -lt $devices.Count; $index++) {
        $failure = Test-NotPlaceholder -Name "pilot session Crown-owned device $($index + 1)" -Value ([string]$devices[$index])
        if ($failure) { $sessionFailures += $failure }
    }

    $scenarioMap = @{}
    foreach ($scenario in @($session.scenarios)) {
        $id = Read-ObjectString -Object $scenario -Name "id"
        if ($id) {
            $scenarioMap[$id] = $scenario
        }
    }

    foreach ($requiredScenario in $requiredScenarios) {
        if (-not $scenarioMap.ContainsKey($requiredScenario)) {
            $sessionFailures += "pilot session missing required scenario: $requiredScenario"
            continue
        }

        $scenario = $scenarioMap[$requiredScenario]
        if ($RequireNoPlaceholders -and -not (Read-ObjectBool -Object $scenario -Name "passed")) {
            $sessionFailures += "pilot session scenario must pass: $requiredScenario"
        }

        $failure = Test-NotPlaceholder -Name "pilot session scenario $requiredScenario evidence_reference" -Value (Read-ObjectString -Object $scenario -Name "evidence_reference")
        if ($failure) { $sessionFailures += $failure }
    }
}

$signoff = Read-JsonFile -Path $paths.signoff
$signoffFailures = @()
if ($null -eq $signoff) {
    $signoffFailures += "missing or unreadable participant signoff record: $($paths.signoff)"
}
else {
    if ((Read-ObjectString -Object $signoff -Name "schema") -ne "archrealms.passport.pre_mvp_staff_steward_participant_signoff.v1") {
        $signoffFailures += "participant signoff record has unexpected schema"
    }

    if ((Read-ObjectString -Object $signoff -Name "lane") -ne "internal-verification") {
        $signoffFailures += "participant signoff record must use internal-verification lane"
    }

    foreach ($field in @("created_utc", "pilot_id", "pilot_owner", "policy_version")) {
        $failure = Test-NotPlaceholder -Name "participant signoff $field" -Value (Read-ObjectString -Object $signoff -Name $field)
        if ($failure) { $signoffFailures += $failure }
    }

    $signoffs = @($signoff.signoffs)
    if ($signoffs.Count -lt 1) {
        $signoffFailures += "participant signoff record must include at least one signoff"
    }

    for ($index = 0; $index -lt $signoffs.Count; $index++) {
        $entry = $signoffs[$index]
        foreach ($field in @("participant_id", "participant_role", "signed_utc", "signoff_reference")) {
            $failure = Test-NotPlaceholder -Name "participant signoff $($index + 1) $field" -Value (Read-ObjectString -Object $entry -Name $field)
            if ($failure) { $signoffFailures += $failure }
        }

        foreach ($failure in @(
            Test-RequiredTrue -Object $entry -Name "staff_or_steward_participant" -Description "participant signoff $($index + 1) staff/steward confirmation"
            Test-RequiredTrue -Object $entry -Name "crown_owned_device_used" -Description "participant signoff $($index + 1) Crown-owned device"
            Test-RequiredTrue -Object $entry -Name "no_citizen_production_tokens_used" -Description "participant signoff $($index + 1) no citizen production tokens"
            Test-RequiredTrue -Object $entry -Name "no_production_records_created" -Description "participant signoff $($index + 1) no production records"
        )) {
            if ($failure) { $signoffFailures += $failure }
        }
    }
}

$issueReview = Read-JsonFile -Path $paths.issue_review
$issueFailures = @()
if ($null -eq $issueReview) {
    $issueFailures += "missing or unreadable pilot issue review record: $($paths.issue_review)"
}
else {
    if ((Read-ObjectString -Object $issueReview -Name "schema") -ne "archrealms.passport.pre_mvp_staff_steward_pilot_issue_review.v1") {
        $issueFailures += "pilot issue review record has unexpected schema"
    }

    if ((Read-ObjectString -Object $issueReview -Name "lane") -ne "internal-verification") {
        $issueFailures += "pilot issue review record must use internal-verification lane"
    }

    foreach ($field in @("created_utc", "pilot_id", "pilot_owner", "policy_version", "review_signoff_reference")) {
        $failure = Test-NotPlaceholder -Name "pilot issue review $field" -Value (Read-ObjectString -Object $issueReview -Name $field)
        if ($failure) { $issueFailures += $failure }
    }

    foreach ($failure in @(
        Test-ReferencedFileHash -Name "pilot issue review production readiness report" -PathValue (Read-ObjectString -Object $issueReview -Name "production_readiness_report_path") -Sha256Value (Read-ObjectString -Object $issueReview -Name "production_readiness_report_sha256") -Required:$RequireNoPlaceholders
        Test-RequiredTrue -Object $issueReview -Name "production_readiness_blockers_reviewed" -Description "production readiness blockers reviewed"
        Test-RequiredTrue -Object $issueReview -Name "pilot_signoff_signed" -Description "pilot signoff signed"
        Test-RequiredTrue -Object $issueReview -Name "no_pilot_blocking_defects" -Description "no pilot blocking defects"
        Test-RequiredTrue -Object $issueReview -Name "no_production_records_created" -Description "no production records created"
    )) {
        if ($failure) { $issueFailures += $failure }
    }
}

$checks = @(
    New-Check -Id "pilot_session_record" -Failures $sessionFailures -Evidence @{ path = $paths.session }
    New-Check -Id "participant_signoff_record" -Failures $signoffFailures -Evidence @{ path = $paths.signoff }
    New-Check -Id "pilot_issue_review_record" -Failures $issueFailures -Evidence @{ path = $paths.issue_review }
)

$placeholderFailures = @()
if ($RequireNoPlaceholders) {
    foreach ($key in $paths.Keys) {
        $path = $paths[$key]
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            $text = Get-Content -LiteralPath $path -Raw
            if ($text -match '<[^>\r\n]+>' -or $text -match '\\u003c[^"]+\\u003e') {
                $placeholderFailures += "$key evidence file contains placeholder text"
            }

            if ($text -match '(?im)^\s*\"?[a-z0-9_ -]+\"?\s*:\s*\"?set value\"?\s*[,}]?') {
                $placeholderFailures += "$key evidence file contains set value placeholder text"
            }
        }
    }
}

$checks += New-Check -Id "pilot_evidence_no_placeholders" -Failures $placeholderFailures

$identityFailures = @()
if ($session -and $signoff -and $issueReview) {
    $pilotIds = @(
        Read-ObjectString -Object $session -Name "pilot_id"
        Read-ObjectString -Object $signoff -Name "pilot_id"
        Read-ObjectString -Object $issueReview -Name "pilot_id"
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) -and $_ -notmatch '<[^>]+>' }

    if (($pilotIds | Select-Object -Unique).Count -gt 1) {
        $identityFailures += "pilot_id values must match across all pilot evidence records"
    }

    $owners = @(
        Read-ObjectString -Object $session -Name "pilot_owner"
        Read-ObjectString -Object $signoff -Name "pilot_owner"
        Read-ObjectString -Object $issueReview -Name "pilot_owner"
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) -and $_ -notmatch '<[^>]+>' }

    if (($owners | Select-Object -Unique).Count -gt 1) {
        $identityFailures += "pilot_owner values must match across all pilot evidence records"
    }
}

$checks += New-Check -Id "pilot_evidence_identity_consistency" -Failures $identityFailures

$evidenceFiles = @()
foreach ($path in $paths.Values) {
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        $evidenceFiles += [pscustomobject][ordered]@{
            id = [System.IO.Path]::GetFileNameWithoutExtension($path)
            path = $path
            sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $path).Hash.ToLowerInvariant()
        }
    }
}

$failed = @($checks | Where-Object { -not $_.passed })
$report = [pscustomobject][ordered]@{
    schema = "archrealms.passport.pre_mvp_staff_steward_pilot_evidence_validation.v1"
    created_utc = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
    packet_root = $resolvedPacketRoot
    require_no_placeholders = [bool]$RequireNoPlaceholders
    passed = ($failed.Count -eq 0)
    failed_check_count = $failed.Count
    evidence_files = $evidenceFiles
    checks = $checks
}

$json = $report | ConvertTo-Json -Depth 10
if (-not [string]::IsNullOrWhiteSpace($resolvedOutput)) {
    $parent = Split-Path -Parent $resolvedOutput
    if ($parent) {
        New-Item -ItemType Directory -Force -Path $parent | Out-Null
    }

    Set-Content -LiteralPath $resolvedOutput -Value $json -Encoding UTF8
}

$json

if ($failed.Count -gt 0 -and -not $NoFail) {
    exit 1
}
