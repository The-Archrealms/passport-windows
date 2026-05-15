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
        -Action "Fill the controlled staff/steward pilot packet, validate it with no placeholders, generate the final pilot report, and rerun pre-MVP internal verification with the report path and SHA-256." `
        -Commands @(
            "powershell -NoProfile -ExecutionPolicy Bypass -File tools\release\Complete-PassportPreMvpStaffStewardPilotHandoff.ps1 -HandoffRoot <filled-staff-steward-handoff-root> -SimulationRunReportPath artifacts\release\pre-mvp-simulation-run-report.json -SimulationRunReportSha256 <simulation-run-sha256> -Force"
        )
    staging_readiness = New-Action `
        -Id "staging_readiness" `
        -Title "Close out staging readiness" `
        -Action "Fill staging endpoint, ledger/telemetry, operational drill, rollback drill, and promotion approval evidence; then run the staging closeout command with real non-synthetic values." `
        -Commands @(
            "powershell -NoProfile -ExecutionPolicy Bypass -File tools\release\Complete-PassportStagingReadinessEvidencePacket.ps1 -PacketRoot <filled-staging-evidence-root> -EnvironmentFile artifacts\release\staging.env -Force"
        )
    canary_mvp_readiness = New-Action `
        -Id "canary_mvp_readiness" `
        -Title "Close out canary MVP readiness" `
        -Action "Fill the canary policy, incident review, balance reconciliation, service-delivery reconciliation, support readiness, and production-promotion evidence; then run the canary closeout command." `
        -Commands @(
            "powershell -NoProfile -ExecutionPolicy Bypass -File tools\release\Complete-PassportCanaryMvpReadinessEvidencePacket.ps1 -PacketRoot <filled-canary-evidence-root> -EnvironmentFile artifacts\release\canary-mvp.env -Force"
        )
    package_signing = New-Action `
        -Id "package_signing" `
        -Title "Configure production package signing" `
        -Action "Acquire the production MSIX signing certificate, configure PFX material or secure PFX path plus password, set publisher and timestamp URL, and validate the signing certificate report." `
        -Commands @(
            "powershell -NoProfile -ExecutionPolicy Bypass -File tools\release\Test-PassportPackageSigningProvisioning.ps1 -PackageSigningPath <filled-package-signing-root> -RequireNoPlaceholders",
            "powershell -NoProfile -ExecutionPolicy Bypass -File tools\release\Test-PassportWindowsSigningCertificate.ps1 -EnvironmentFile artifacts\release\production-mvp.env -OutputPath artifacts\release\production-signing-certificate-report.json"
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
    hosted_ai_runtime_probe = New-Action `
        -Id "hosted_ai_runtime_probe" `
        -Title "Make hosted AI runtime probe pass" `
        -Action "Deploy the approved open-weight inference endpoint and configure the hosted AI gateway so the operator-authenticated non-mutating probe receives an answer." `
        -Commands @(
            "powershell -NoProfile -ExecutionPolicy Bypass -File tools\release\Test-PassportOpenWeightAiRuntimeDeployment.ps1 -RequireNoPlaceholders -ProbeRuntime",
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
            "powershell -NoProfile -ExecutionPolicy Bypass -File tools\release\Test-PassportProductionMonetaryProvisioning.ps1 -ProductionMonetaryPath <filled-production-monetary-root> -RequireNoPlaceholders"
        )
    open_weight_ai_runtime = New-Action `
        -Id "open_weight_ai_runtime" `
        -Title "Provision approved open-weight AI runtime" `
        -Action "Approve the model artifact/license, deploy vLLM or TGI-compatible inference, configure vector store and knowledge approval root, and validate the runtime deployment/probe." `
        -Commands @(
            "powershell -NoProfile -ExecutionPolicy Bypass -File tools\release\Test-PassportOpenWeightAiRuntimeDeployment.ps1 -RequireNoPlaceholders -ProbeRuntime"
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
            "powershell -NoProfile -ExecutionPolicy Bypass -File tools\release\Test-PassportCanaryMvpReadinessEvidencePacket.ps1 -PacketRoot <filled-canary-evidence-root> -RequireNoPlaceholders"
        )
    open_weight_ai_runtime_deployment = New-Action `
        -Id "open_weight_ai_runtime_deployment" `
        -Title "Fill open-weight AI runtime provisioning" `
        -Action "Fill model approval, vector store, runtime readiness evidence, and runtime env values for the approved open-weight deployment." `
        -Commands @(
            "powershell -NoProfile -ExecutionPolicy Bypass -File tools\release\Test-PassportOpenWeightAiRuntimeDeployment.ps1 -RequireNoPlaceholders -ProbeRuntime"
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
        -Action "Fill issuer/capacity/genesis provisioning, ARCH genesis request, and CC capacity request records." `
        -Commands @(
            "powershell -NoProfile -ExecutionPolicy Bypass -File tools\release\Test-PassportProductionMonetaryProvisioning.ps1 -ProductionMonetaryPath <filled-production-monetary-root> -RequireNoPlaceholders"
        )
}

$releaseEvidenceActionMap = @{
    pre_mvp_passed = New-Action `
        -Id "pre_mvp_passed" `
        -Title "Close pre-MVP evidence" `
        -Action "Complete the staff/steward pilot packet and rerun pre-MVP verification until the report passes." `
        -Commands @(
            "powershell -NoProfile -ExecutionPolicy Bypass -File tools\release\Complete-PassportPreMvpStaffStewardPilotHandoff.ps1 -HandoffRoot <filled-staff-steward-handoff-root> -SimulationRunReportPath artifacts\release\pre-mvp-simulation-run-report.json -SimulationRunReportSha256 <simulation-run-sha256> -Force"
        )
    provisioning_packet_passed = New-Action `
        -Id "provisioning_packet_passed" `
        -Title "Validate filled production provisioning" `
        -Action "Fill the controlled production provisioning packet and validate it with no placeholders." `
        -Commands @(
            "powershell -NoProfile -ExecutionPolicy Bypass -File tools\release\Test-PassportProductionProvisioningPacket.ps1 -PacketRoot <controlled-production-packet-root> -RequireNoPlaceholders"
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
            "powershell -NoProfile -ExecutionPolicy Bypass -File tools\release\Complete-PassportStagingReadinessEvidencePacket.ps1 -PacketRoot <filled-staging-evidence-root> -EnvironmentFile artifacts\release\staging.env -Force"
        )
    staging_readiness_report_promotion_approved = New-Action `
        -Id "staging_readiness_report_promotion_approved" `
        -Title "Approve staging promotion" `
        -Action "Record signed staging promotion approval evidence and rerun the staging closeout." `
        -Commands @(
            "powershell -NoProfile -ExecutionPolicy Bypass -File tools\release\Complete-PassportStagingReadinessEvidencePacket.ps1 -PacketRoot <filled-staging-evidence-root> -EnvironmentFile artifacts\release\staging.env -Force"
        )
    canary_mvp_readiness_report_ready = New-Action `
        -Id "canary_mvp_readiness_report_ready" `
        -Title "Close canary MVP readiness" `
        -Action "Complete the filled canary evidence packet and produce a non-synthetic ready canary report." `
        -Commands @(
            "powershell -NoProfile -ExecutionPolicy Bypass -File tools\release\Complete-PassportCanaryMvpReadinessEvidencePacket.ps1 -PacketRoot <filled-canary-evidence-root> -EnvironmentFile artifacts\release\canary-mvp.env -Force"
        )
    canary_mvp_readiness_report_production_approved = New-Action `
        -Id "canary_mvp_readiness_report_production_approved" `
        -Title "Approve ProductionMvp promotion" `
        -Action "Record signed canary-to-production approval evidence and rerun the canary closeout." `
        -Commands @(
            "powershell -NoProfile -ExecutionPolicy Bypass -File tools\release\Complete-PassportCanaryMvpReadinessEvidencePacket.ps1 -PacketRoot <filled-canary-evidence-root> -EnvironmentFile artifacts\release\canary-mvp.env -Force"
        )
}

$packageSigningReleaseEvidenceAction = New-Action `
    -Id "package_signing_certificate_evidence" `
    -Title "Attach package-signing certificate evidence" `
    -Action "Validate the production MSIX signing certificate and regenerate release evidence so certificate details are included." `
    -Commands @(
        "powershell -NoProfile -ExecutionPolicy Bypass -File tools\release\Test-PassportWindowsSigningCertificate.ps1 -EnvironmentFile artifacts\release\production-mvp.env -OutputPath artifacts\release\production-signing-certificate-report.json",
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
        failed_gate_count = 1
        gates = @(
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
$readinessEvidenceItems = @()
foreach ($gate in $failedReadinessGates) {
    foreach ($missing in @($gate.missing)) {
        $envNames = @(Get-EnvironmentVariableNames -Text ([string]$missing))
        foreach ($envName in $envNames) {
            if (-not $environmentVariableMap.ContainsKey($envName)) {
                $environmentVariableMap[$envName] = [pscustomobject][ordered]@{
                    name = $envName
                    readiness_gate_ids = @()
                    missing_texts = @()
                }
            }

            $record = $environmentVariableMap[$envName]
            if (@($record.readiness_gate_ids) -notcontains [string]$gate.id) {
                $record.readiness_gate_ids = @($record.readiness_gate_ids + [string]$gate.id)
            }
            if (@($record.missing_texts) -notcontains [string]$missing) {
                $record.missing_texts = @($record.missing_texts + [string]$missing)
            }
        }

        if ($envNames.Count -eq 0) {
            $readinessEvidenceItems += [pscustomobject][ordered]@{
                readiness_gate_id = [string]$gate.id
                missing_text = [string]$missing
                operator_action = $(if ($null -ne $gate.operator_action) { [string]$gate.operator_action.action } else { "" })
            }
        }
    }
}

$requiredEnvironmentVariables = @($environmentVariableMap.Keys | Sort-Object | ForEach-Object { $environmentVariableMap[$_] })

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
    }
}

$failedProvisioningChildCheckCount = (@($failedProvisioningChecks | ForEach-Object { @($_.child_failed_checks).Count }) | Measure-Object -Sum).Sum
if ($null -eq $failedProvisioningChildCheckCount) {
    $failedProvisioningChildCheckCount = 0
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
        failed_provisioning_child_check_count = [int]$failedProvisioningChildCheckCount
        failed_release_evidence_check_count = $failedReleaseEvidenceChecks.Count
        required_environment_variable_count = $requiredEnvironmentVariables.Count
        required_readiness_evidence_item_count = $readinessEvidenceItems.Count
        required_provisioning_evidence_file_count = $requiredProvisioningEvidenceFiles.Count
        required_release_evidence_item_count = $releaseEvidenceItems.Count
    }
    closeout_failures = $closeoutFailures
    failed_readiness_gates = $failedReadinessGates
    failed_provisioning_checks = $failedProvisioningChecks
    failed_release_evidence_checks = $failedReleaseEvidenceChecks
    operator_input_matrix = [pscustomobject][ordered]@{
        environment_variables = $requiredEnvironmentVariables
        readiness_evidence_items = $readinessEvidenceItems
        provisioning_evidence_files = $requiredProvisioningEvidenceFiles
        release_evidence_items = $releaseEvidenceItems
    }
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
    $lines.Add("- Failed provisioning child checks: $failedProvisioningChildCheckCount")
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
    $lines.Add("## Operator Input Matrix")
    $lines.Add("- Environment variables to configure: $($requiredEnvironmentVariables.Count)")
    foreach ($variable in @($requiredEnvironmentVariables | Select-Object -First 25)) {
        $lines.Add("  - ``$($variable.name)`` for ``$((@($variable.readiness_gate_ids) -join ', '))``")
    }
    if ($requiredEnvironmentVariables.Count -gt 25) {
        $lines.Add("  - ...$($requiredEnvironmentVariables.Count - 25) more in the JSON report")
    }

    $lines.Add("- Readiness evidence items to complete: $($readinessEvidenceItems.Count)")
    foreach ($item in @($readinessEvidenceItems | Select-Object -First 10)) {
        $lines.Add("  - ``$($item.readiness_gate_id)``: $($item.missing_text)")
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
    failed_readiness_gate_count = $failedReadinessGates.Count
    failed_provisioning_check_count = $failedProvisioningChecks.Count
    failed_provisioning_child_check_count = [int]$failedProvisioningChildCheckCount
    failed_release_evidence_check_count = $failedReleaseEvidenceChecks.Count
    required_environment_variable_count = $requiredEnvironmentVariables.Count
    required_readiness_evidence_item_count = $readinessEvidenceItems.Count
    required_provisioning_evidence_file_count = $requiredProvisioningEvidenceFiles.Count
    required_release_evidence_item_count = $releaseEvidenceItems.Count
}

$result | ConvertTo-Json -Depth 4

if (-not $NoFail -and -not $report.ready_for_production_testing) {
    throw "Production MVP still has outstanding work. See $resolvedOutputPath."
}
