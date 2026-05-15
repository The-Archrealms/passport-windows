param(
    [string]$OutputPath = "artifacts\release\pre-mvp-internal-verification-report.json",
    [string]$DotnetPath,
    [string]$Configuration = "Release",
    [string[]]$ManifestPath,
    [switch]$SkipDotnetTests,
    [switch]$SkipDeploymentValidation,
    [switch]$SkipArtifactValidation,
    [switch]$NoFail
)

$ErrorActionPreference = "Stop"
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path

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

function Format-Command {
    param(
        [string]$FilePath,
        [string[]]$Arguments
    )

    $parts = @($FilePath)
    foreach ($argument in $Arguments) {
        if ($argument -match '\s') {
            $parts += '"' + $argument.Replace('"', '\"') + '"'
        }
        else {
            $parts += $argument
        }
    }

    return ($parts -join " ")
}

function Get-OutputExcerpt {
    param([object[]]$Output)

    $text = (($Output | ForEach-Object { $_.ToString() }) -join [Environment]::NewLine).Trim()
    if ($text.Length -le 4000) {
        return $text
    }

    return $text.Substring($text.Length - 4000)
}

function Invoke-Tool {
    param(
        [string]$FilePath,
        [string[]]$Arguments
    )

    Push-Location $repoRoot
    try {
        $output = & $FilePath @Arguments 2>&1
        $exitCode = $LASTEXITCODE
        if ($null -eq $exitCode) {
            $exitCode = 0
        }

        return [pscustomobject][ordered]@{
            command = Format-Command -FilePath $FilePath -Arguments $Arguments
            exit_code = [int]$exitCode
            output_excerpt = Get-OutputExcerpt -Output $output
        }
    }
    finally {
        Pop-Location
    }
}

function New-Check {
    param(
        [string]$Id,
        [string]$Description,
        [bool]$Passed,
        [string[]]$Failures,
        [object]$Evidence = $null
    )

    return [pscustomobject][ordered]@{
        id = $Id
        description = $Description
        passed = $Passed
        failures = @($Failures)
        evidence = $Evidence
    }
}

function New-ToolCheck {
    param(
        [string]$Id,
        [string]$Description,
        [object]$Result
    )

    $failures = @()
    if ($Result.exit_code -ne 0) {
        $failures += "$Id exited with code $($Result.exit_code)."
    }

    return New-Check `
        -Id $Id `
        -Description $Description `
        -Passed ($failures.Count -eq 0) `
        -Failures $failures `
        -Evidence $Result
}

function Get-ManifestLane {
    param([string]$Path)

    try {
        $manifest = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
        if ($manifest.PSObject.Properties["lane"] -and $manifest.lane) {
            return [string]$manifest.lane
        }
    }
    catch {
    }

    return ""
}

function Find-InternalVerificationManifestPaths {
    $candidates = @(
        "artifacts\release\passport-windows-win-x64\release-manifest.json",
        "artifacts\release\passport-windows-msix-sideload\x64\msix-package-manifest.json",
        "artifacts\release\passport-windows-msix-store\x64\msix-package-manifest.json",
        "artifacts\release\passport-windows-msix\x64\msix-package-manifest.json"
    )

    $found = @()
    foreach ($candidate in $candidates) {
        $path = Join-Path $repoRoot $candidate
        if ((Test-Path -LiteralPath $path -PathType Leaf) -and (Get-ManifestLane -Path $path) -eq "internal-verification") {
            $found += $path
        }
    }

    return $found
}

function Test-CheckPassed {
    param(
        [object[]]$Checks,
        [string]$Id
    )

    foreach ($check in $Checks) {
        if ($check.id -eq $Id) {
            return [bool]$check.passed
        }
    }

    return $false
}

function New-Requirement {
    param(
        [string]$Id,
        [string]$Description,
        [string[]]$CheckIds,
        [object[]]$Checks,
        [string]$Evidence
    )

    $missing = @()
    foreach ($checkId in $CheckIds) {
        if (-not (Test-CheckPassed -Checks $Checks -Id $checkId)) {
            $missing += $checkId
        }
    }

    return [pscustomobject][ordered]@{
        id = $Id
        description = $Description
        check_ids = $CheckIds
        passed = ($missing.Count -eq 0)
        missing_checks = $missing
        evidence = $Evidence
    }
}

$checks = @()
$dotnet = ""

if ($SkipDotnetTests) {
    $checks += New-Check `
        -Id "core_tests" `
        -Description "Platform-neutral core tests cover wallet, ledger, export, registry, and AI authority policies." `
        -Passed $false `
        -Failures @("Core tests were skipped; pre-MVP verification cannot pass with skipped tests.")
    $checks += New-Check `
        -Id "hosted_service_tests" `
        -Description "Hosted service tests cover AI gateway, quota, policy, storage, operator, and runtime readiness boundaries." `
        -Passed $false `
        -Failures @("Hosted service tests were skipped; pre-MVP verification cannot pass with skipped tests.")
    $checks += New-Check `
        -Id "managed_signing_tests" `
        -Description "Managed signing tests cover endpoint signing, custody metadata, local-validation markers, and API-key checks." `
        -Passed $false `
        -Failures @("Managed signing tests were skipped; pre-MVP verification cannot pass with skipped tests.")
    $checks += New-Check `
        -Id "windows_tests" `
        -Description "Windows Passport tests cover onboarding, wallet, ledger, recovery, storage, conversion, registry, and UI behavior." `
        -Passed $false `
        -Failures @("Windows tests were skipped; pre-MVP verification cannot pass with skipped tests.")
    $checks += New-Check `
        -Id "ledger_verifier_build" `
        -Description "Portable ledger verifier builds for independent export replay." `
        -Passed $false `
        -Failures @("Ledger verifier build was skipped; pre-MVP verification cannot pass with skipped tests.")
}
else {
    $dotnet = Resolve-DotnetPath -PreferredPath $DotnetPath
    $checks += New-ToolCheck `
        -Id "core_tests" `
        -Description "Platform-neutral core tests cover wallet, ledger, export, registry, and AI authority policies." `
        -Result (Invoke-Tool -FilePath $dotnet -Arguments @("test", "tests\ArchrealmsPassport.Core.Tests\ArchrealmsPassport.Core.Tests.csproj", "-c", $Configuration, "--no-restore"))
    $checks += New-ToolCheck `
        -Id "hosted_service_tests" `
        -Description "Hosted service tests cover AI gateway, quota, policy, storage, operator, and runtime readiness boundaries." `
        -Result (Invoke-Tool -FilePath $dotnet -Arguments @("test", "tests\ArchrealmsPassport.HostedServices.Tests\ArchrealmsPassport.HostedServices.Tests.csproj", "-c", $Configuration, "--no-restore"))
    $checks += New-ToolCheck `
        -Id "managed_signing_tests" `
        -Description "Managed signing tests cover endpoint signing, custody metadata, local-validation markers, and API-key checks." `
        -Result (Invoke-Tool -FilePath $dotnet -Arguments @("test", "tests\ArchrealmsPassport.ManagedSigning.Tests\ArchrealmsPassport.ManagedSigning.Tests.csproj", "-c", $Configuration, "--no-restore"))
    $checks += New-ToolCheck `
        -Id "windows_tests" `
        -Description "Windows Passport tests cover onboarding, wallet, ledger, recovery, storage, conversion, registry, and UI behavior." `
        -Result (Invoke-Tool -FilePath $dotnet -Arguments @("test", "tests\ArchrealmsPassport.Windows.Tests\ArchrealmsPassport.Windows.Tests.csproj", "-c", $Configuration, "--no-restore"))
    $checks += New-ToolCheck `
        -Id "ledger_verifier_build" `
        -Description "Portable ledger verifier builds for independent export replay." `
        -Result (Invoke-Tool -FilePath $dotnet -Arguments @("build", "tools\ledger-verifier\Archrealms.LedgerVerifier.csproj", "-c", $Configuration, "--no-restore"))
}

if ($SkipDeploymentValidation) {
    $checks += New-Check `
        -Id "package_signing_provisioning_validation" `
        -Description "Package-signing provisioning templates validate MSIX signing request, sideload trust, and Store signing contracts." `
        -Passed $false `
        -Failures @("Package-signing provisioning validation was skipped; pre-MVP verification cannot pass with skipped deployment validation.")
    $checks += New-Check `
        -Id "release_lane_endpoint_provisioning_validation" `
        -Description "Release-lane endpoint provisioning templates validate production API, AI gateway, DNS, TLS, routing, and readiness evidence contracts." `
        -Passed $false `
        -Failures @("Release-lane endpoint provisioning validation was skipped; pre-MVP verification cannot pass with skipped deployment validation.")
    $checks += New-Check `
        -Id "managed_storage_provisioning_validation" `
        -Description "Managed storage provisioning templates validate hosted data root, durable provider, backup manifest, and storage readiness evidence contracts." `
        -Passed $false `
        -Failures @("Managed storage provisioning validation was skipped; pre-MVP verification cannot pass with skipped deployment validation.")
    $checks += New-Check `
        -Id "managed_signing_custody_provisioning_validation" `
        -Description "Managed signing custody provisioning templates validate KMS/HSM custody, signing endpoint policy, and readiness evidence contracts." `
        -Passed $false `
        -Failures @("Managed signing custody provisioning validation was skipped; pre-MVP verification cannot pass with skipped deployment validation.")
    $checks += New-Check `
        -Id "hosted_services_deployment_validation" `
        -Description "Hosted services deployment package validates container posture and Release publish output." `
        -Passed $false `
        -Failures @("Hosted services deployment validation was skipped; pre-MVP verification cannot pass with skipped deployment validation.")
    $checks += New-Check `
        -Id "managed_signing_deployment_validation" `
        -Description "Managed signing endpoint deployment package validates endpoint posture and Release publish output." `
        -Passed $false `
        -Failures @("Managed signing deployment validation was skipped; pre-MVP verification cannot pass with skipped deployment validation.")
    $checks += New-Check `
        -Id "open_weight_ai_runtime_deployment_validation" `
        -Description "Open-weight AI runtime deployment package validates vLLM/TGI posture and runtime probe wiring." `
        -Passed $false `
        -Failures @("Open-weight AI runtime deployment validation was skipped; pre-MVP verification cannot pass with skipped deployment validation.")
    $checks += New-Check `
        -Id "production_ops_documents_validation" `
        -Description "Production ops document templates validate backup, restore, telemetry, incident, and approval contracts." `
        -Passed $false `
        -Failures @("Production ops document validation was skipped; pre-MVP verification cannot pass with skipped deployment validation.")
    $checks += New-Check `
        -Id "production_monetary_provisioning_validation" `
        -Description "Production monetary provisioning templates validate issuer, capacity, genesis, and ledger namespace contracts." `
        -Passed $false `
        -Failures @("Production monetary provisioning validation was skipped; pre-MVP verification cannot pass with skipped deployment validation.")
    $checks += New-Check `
        -Id "production_provisioning_packet_validation" `
        -Description "Consolidated production provisioning packet validation wraps the release provisioning validators for operator handoff." `
        -Passed $false `
        -Failures @("Production provisioning packet validation was skipped; pre-MVP verification cannot pass with skipped deployment validation.")
    $checks += New-Check `
        -Id "production_provisioning_packet_scaffold_validation" `
        -Description "Production provisioning packet scaffolding creates a controlled working copy that validates through PacketRoot mode." `
        -Passed $false `
        -Failures @("Production provisioning packet scaffold validation was skipped; pre-MVP verification cannot pass with skipped deployment validation.")
    $checks += New-Check `
        -Id "production_release_evidence_packet_validation" `
        -Description "Production release evidence packet generation and redaction are validated before release signoff." `
        -Passed $false `
        -Failures @("Production release evidence packet validation was skipped; pre-MVP verification cannot pass with skipped deployment validation.")
    $checks += New-Check `
        -Id "staging_readiness_gate_validation" `
        -Description "Staging readiness gate generation and validation are exercised before production release gating can depend on it." `
        -Passed $false `
        -Failures @("Staging readiness gate validation was skipped; pre-MVP verification cannot pass with skipped deployment validation.")
    $checks += New-Check `
        -Id "production_readiness_fail_closed_validation" `
        -Description "ProductionMvp readiness fails closed when production probe inputs are absent." `
        -Passed $false `
        -Failures @("Production readiness fail-closed validation was skipped; pre-MVP verification cannot pass with skipped deployment validation.")
}
else {
    $checks += New-ToolCheck `
        -Id "package_signing_provisioning_validation" `
        -Description "Package-signing provisioning templates validate MSIX signing request, sideload trust, and Store signing contracts." `
        -Result (Invoke-Tool -FilePath "powershell" -Arguments @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "tools\release\Test-PassportPackageSigningProvisioning.ps1"))
    $checks += New-ToolCheck `
        -Id "release_lane_endpoint_provisioning_validation" `
        -Description "Release-lane endpoint provisioning templates validate production API, AI gateway, DNS, TLS, routing, and readiness evidence contracts." `
        -Result (Invoke-Tool -FilePath "powershell" -Arguments @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "tools\release\Test-PassportReleaseLaneEndpointProvisioning.ps1"))
    $checks += New-ToolCheck `
        -Id "managed_storage_provisioning_validation" `
        -Description "Managed storage provisioning templates validate hosted data root, durable provider, backup manifest, and storage readiness evidence contracts." `
        -Result (Invoke-Tool -FilePath "powershell" -Arguments @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "tools\release\Test-PassportManagedStorageProvisioning.ps1"))
    $checks += New-ToolCheck `
        -Id "managed_signing_custody_provisioning_validation" `
        -Description "Managed signing custody provisioning templates validate KMS/HSM custody, signing endpoint policy, and readiness evidence contracts." `
        -Result (Invoke-Tool -FilePath "powershell" -Arguments @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "tools\release\Test-PassportManagedSigningCustodyProvisioning.ps1"))
    $checks += New-ToolCheck `
        -Id "hosted_services_deployment_validation" `
        -Description "Hosted services deployment package validates container posture and Release publish output." `
        -Result (Invoke-Tool -FilePath "powershell" -Arguments @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "tools\release\Test-PassportHostedServicesDeployment.ps1"))
    $checks += New-ToolCheck `
        -Id "managed_signing_deployment_validation" `
        -Description "Managed signing endpoint deployment package validates endpoint posture and Release publish output." `
        -Result (Invoke-Tool -FilePath "powershell" -Arguments @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "tools\release\Test-PassportManagedSigningDeployment.ps1"))
    $checks += New-ToolCheck `
        -Id "open_weight_ai_runtime_deployment_validation" `
        -Description "Open-weight AI runtime deployment package validates vLLM/TGI posture and runtime probe wiring." `
        -Result (Invoke-Tool -FilePath "powershell" -Arguments @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "tools\release\Test-PassportOpenWeightAiRuntimeDeployment.ps1"))
    $checks += New-ToolCheck `
        -Id "production_ops_documents_validation" `
        -Description "Production ops document templates validate backup, restore, telemetry, incident, and approval contracts." `
        -Result (Invoke-Tool -FilePath "powershell" -Arguments @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "tools\release\Test-PassportProductionOpsDocuments.ps1"))
    $checks += New-ToolCheck `
        -Id "production_monetary_provisioning_validation" `
        -Description "Production monetary provisioning templates validate issuer, capacity, genesis, and ledger namespace contracts." `
        -Result (Invoke-Tool -FilePath "powershell" -Arguments @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "tools\release\Test-PassportProductionMonetaryProvisioning.ps1"))
    $checks += New-ToolCheck `
        -Id "production_provisioning_packet_validation" `
        -Description "Consolidated production provisioning packet validation wraps the release provisioning validators for operator handoff." `
        -Result (Invoke-Tool -FilePath "powershell" -Arguments @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "tools\release\Test-PassportProductionProvisioningPacket.ps1", "-SkipPublish"))
    $checks += New-ToolCheck `
        -Id "production_provisioning_packet_scaffold_validation" `
        -Description "Production provisioning packet scaffolding creates a controlled working copy that validates through PacketRoot mode." `
        -Result (Invoke-Tool -FilePath "powershell" -Arguments @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "tools\release\New-PassportProductionProvisioningPacket.ps1", "-Force", "-OutputDirectory", "artifacts\release\production-provisioning-packet-working"))
    $checks += New-ToolCheck `
        -Id "production_release_evidence_packet_validation" `
        -Description "Production release evidence packet generation and redaction are validated before release signoff." `
        -Result (Invoke-Tool -FilePath "powershell" -Arguments @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "tools\release\Test-PassportProductionMvpReleaseEvidencePacket.ps1", "-UseSyntheticFixtures", "-OutputPath", "artifacts\release\production-mvp-release-evidence-packet-validation-report.json"))
    $checks += New-ToolCheck `
        -Id "staging_readiness_gate_validation" `
        -Description "Staging readiness gate generation and validation are exercised before production release gating can depend on it." `
        -Result (Invoke-Tool -FilePath "powershell" -Arguments @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "tools\release\Test-PassportStagingReadiness.ps1", "-UseSyntheticFixtures", "-OutputPath", "artifacts\release\staging-readiness-validation-report.json"))
    $checks += New-ToolCheck `
        -Id "production_readiness_fail_closed_validation" `
        -Description "ProductionMvp readiness fails closed when production probe inputs are absent." `
        -Result (Invoke-Tool -FilePath "powershell" -Arguments @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "tools\release\Test-PassportProductionMvpReadinessFailClosed.ps1", "-OutputPath", "artifacts\release\production-mvp-readiness-fail-closed-validation-report.json"))
}

if ($SkipArtifactValidation) {
    $checks += New-Check `
        -Id "internal_verification_artifact_lane" `
        -Description "InternalVerification artifacts are lane-isolated and cannot migrate fake records into production token ledgers." `
        -Passed $false `
        -Failures @("InternalVerification artifact validation was skipped; pre-MVP verification cannot pass with skipped artifact validation.")
}
else {
    $manifestPaths = @()
    if ($ManifestPath -and $ManifestPath.Count -gt 0) {
        foreach ($path in $ManifestPath) {
            $manifestPaths += (Resolve-Path -LiteralPath $path).Path
        }
    }
    else {
        $manifestPaths = Find-InternalVerificationManifestPaths
    }

    if (-not $manifestPaths -or $manifestPaths.Count -eq 0) {
        $checks += New-Check `
            -Id "internal_verification_artifact_lane" `
            -Description "InternalVerification artifacts are lane-isolated and cannot migrate fake records into production token ledgers." `
            -Passed $false `
            -Failures @("No InternalVerification release artifact manifest was found. Run tools\release\Publish-PassportWindows.ps1 or Publish-PassportWindowsMsix.ps1 with -Lane InternalVerification, or pass -ManifestPath.")
    }
    else {
        $artifactReportPath = Join-Path (Split-Path -Parent ([System.IO.Path]::GetFullPath($OutputPath))) "pre-mvp-internal-artifact-validation-report.json"
        $validationScript = Join-Path $repoRoot "tools\release\Test-PassportWindowsReleaseArtifact.ps1"
        $arguments = @("-OutputPath", $artifactReportPath, "-ManifestPath") + $manifestPaths
        $toolResult = Invoke-Tool -FilePath "powershell" -Arguments (@("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $validationScript) + $arguments)
        $failures = @()
        if ($toolResult.exit_code -ne 0) {
            $failures += "Release artifact validation exited with code $($toolResult.exit_code)."
        }

        $artifactEvidence = [ordered]@{
            command = $toolResult.command
            exit_code = $toolResult.exit_code
            output_excerpt = $toolResult.output_excerpt
            manifest_paths = $manifestPaths
            artifact_report_path = $artifactReportPath
        }

        if (Test-Path -LiteralPath $artifactReportPath -PathType Leaf) {
            $artifactReport = Get-Content -LiteralPath $artifactReportPath -Raw | ConvertFrom-Json
            foreach ($artifact in @($artifactReport.artifacts)) {
                if ($artifact.lane -ne "internal-verification") {
                    $failures += "Artifact $($artifact.manifest_path) is lane '$($artifact.lane)', expected 'internal-verification'."
                }
            }
        }
        else {
            $failures += "Artifact validation report was not written: $artifactReportPath"
        }

        $checks += New-Check `
            -Id "internal_verification_artifact_lane" `
            -Description "InternalVerification artifacts are lane-isolated and cannot migrate fake records into production token ledgers." `
            -Passed ($failures.Count -eq 0) `
            -Failures $failures `
            -Evidence $artifactEvidence
    }
}

$requirements = @(
    New-Requirement -Id "synthetic_users" -Description "Synthetic users are exercised before citizen-facing token release." -CheckIds @("windows_tests") -Checks $checks -Evidence "Windows tests use isolated PassportTestWorkspace identities and records."
    New-Requirement -Id "crown_owned_test_devices" -Description "Crown-owned test devices and device authorization flows are exercised." -CheckIds @("windows_tests", "hosted_service_tests") -Checks $checks -Evidence "Device authorization, deauthorization, and hosted recovery validation tests use synthetic device keys."
    New-Requirement -Id "crown_owned_test_storage_nodes" -Description "Crown-owned storage-node paths are exercised before citizen payloads." -CheckIds @("windows_tests", "hosted_service_tests") -Checks $checks -Evidence "Storage contribution, storage readiness, and storage delivery tests run against isolated local/hosted test roots."
    New-Requirement -Id "synthetic_storage_payloads" -Description "Storage proof and delivery tests use synthetic payloads." -CheckIds @("windows_tests") -Checks $checks -Evidence "Storage redemption tests validate manifests, proof packages, delivery metering, and failed proof handling without citizen data."
    New-Requirement -Id "fake_balances" -Description "Fake/pre-MVP balances are isolated from production balances." -CheckIds @("core_tests", "windows_tests", "internal_verification_artifact_lane") -Checks $checks -Evidence "Release-lane tests and artifact validation reject production-token permissions for non-production lanes."
    New-Requirement -Id "fake_arch" -Description "Fake ARCH cannot migrate into production fixed-genesis ARCH." -CheckIds @("core_tests", "windows_tests", "internal_verification_artifact_lane") -Checks $checks -Evidence "Ledger replay rejects cross-lane records and post-genesis mint-like events."
    New-Requirement -Id "fake_cc" -Description "Fake CC cannot migrate into production Crown Credit." -CheckIds @("core_tests", "windows_tests", "internal_verification_artifact_lane") -Checks $checks -Evidence "Ledger replay and artifact validation isolate non-production CC records from production ledger namespaces."
    New-Requirement -Id "ledger_replay_tests" -Description "Ledger replay, export, hash-chain, nonce, and tamper checks pass." -CheckIds @("core_tests", "windows_tests", "ledger_verifier_build") -Checks $checks -Evidence "Core and Windows ledger/export verifier tests cover replay-derived balances and tamper rejection."
    New-Requirement -Id "key_recovery_attacks" -Description "Key recovery attack paths are exercised." -CheckIds @("windows_tests", "hosted_service_tests") -Checks $checks -Evidence "Recovery, wallet rotation, device deauthorization, support override, and AI-approved recovery rejection tests pass."
    New-Requirement -Id "storage_proof_attacks" -Description "Storage proof attack paths are exercised." -CheckIds @("windows_tests", "hosted_service_tests") -Checks $checks -Evidence "Storage proof package, quote-rate, burn, readiness, and service-delivery policy tests pass."
    New-Requirement -Id "storage_revocation_and_wipe_tests" -Description "Storage revocation and wipe-oriented controls are exercised." -CheckIds @("windows_tests") -Checks $checks -Evidence "Home/recovery/storage tests cover storage pause scope, contribution lifecycle, and failed startup recovery paths."
    New-Requirement -Id "bandwidth_limit_tests" -Description "Bandwidth and unmetered-network controls are exercised." -CheckIds @("windows_tests") -Checks $checks -Evidence "Network usage and storage contribution tests cover unmetered-network/bandwidth behavior."
    New-Requirement -Id "escrow_burn_refund_recredit_tests" -Description "Escrow, burn, refund, and re-credit flows are exercised." -CheckIds @("core_tests", "windows_tests") -Checks $checks -Evidence "Monetary semantics and storage redemption tests cover CC escrow, burn, refund, and failed-epoch re-credit."
    New-Requirement -Id "market_manipulation_simulations" -Description "Market manipulation and thin-market issuance paths are exercised." -CheckIds @("windows_tests", "hosted_service_tests") -Checks $checks -Evidence "Capacity report tests reject thin-market zero-issuance and over-limit issuance paths."
    New-Requirement -Id "service_failure_simulations" -Description "Service failure, refund, re-credit, and extension paths are exercised." -CheckIds @("windows_tests") -Checks $checks -Evidence "Storage failure remedy tests create refund, re-credit, service-extension, and admin release records."
    New-Requirement -Id "wallet_compromise_simulations" -Description "Wallet compromise and revoked-wallet paths are exercised." -CheckIds @("windows_tests", "core_tests") -Checks $checks -Evidence "Wallet revocation and production ledger tests reject revoked wallet keys."
    New-Requirement -Id "identity_compromise_simulations" -Description "Identity compromise and device deauthorization paths are exercised." -CheckIds @("windows_tests", "hosted_service_tests") -Checks $checks -Evidence "Recovery tests cover identity_compromise freezes, device deauthorization, and hosted recovery validation."
    New-Requirement -Id "ai_privacy_and_retention_tests" -Description "AI privacy, retention, quota, and non-authority controls are exercised." -CheckIds @("core_tests", "windows_tests", "hosted_service_tests") -Checks $checks -Evidence "AI policy tests cover no-training defaults, raw-prompt retention metadata, token-hash-only records, quota enforcement, and non-authority boundaries."
    New-Requirement -Id "managed_signing_endpoint_contract_tests" -Description "Managed signing endpoint contract, key metadata, local-validation marker, and API-key controls are exercised." -CheckIds @("managed_signing_tests", "managed_signing_deployment_validation") -Checks $checks -Evidence "Managed signing tests cover response signature verification, custody metadata, local-validation marker reporting, API-key SHA-256 authorization, and deployment package posture."
    New-Requirement -Id "package_signing_provisioning_package" -Description "Package-signing provisioning templates are validated before production signing secrets are loaded into readiness." -CheckIds @("package_signing_provisioning_validation") -Checks $checks -Evidence "Package-signing provisioning validator checks MSIX signing request, sideload trust, Store signing, timestamp, publisher, and Code Signing evidence contracts."
    New-Requirement -Id "release_lane_endpoint_provisioning_package" -Description "Release-lane endpoint provisioning templates are validated before production API and AI gateway URLs are loaded into readiness." -CheckIds @("release_lane_endpoint_provisioning_validation") -Checks $checks -Evidence "Release-lane endpoint provisioning validator checks ProductionMvp API and AI gateway URLs, DNS, TLS, route exposure, operator-key protection, and readiness evidence contracts."
    New-Requirement -Id "managed_storage_provisioning_package" -Description "Managed storage provisioning templates are validated before hosted storage provider and data-root values are loaded into readiness." -CheckIds @("managed_storage_provisioning_validation") -Checks $checks -Evidence "Managed storage provisioning validator checks hosted data root, durable storage provider, backup manifest schedule, restore runbook linkage, and /ops/storage/status evidence contracts."
    New-Requirement -Id "managed_signing_custody_provisioning_package" -Description "Managed signing custody templates are validated before hosted signing key and signing endpoint values are loaded into readiness." -CheckIds @("managed_signing_custody_provisioning_validation") -Checks $checks -Evidence "Managed signing custody validator checks provider, key ID, custody mode, HTTPS signing endpoint, non-local validation, key attestation, and readiness evidence contracts."
    New-Requirement -Id "hosted_services_deployment_package" -Description "Hosted API and AI gateway deployment package is validated before ProductionMvp provisioning." -CheckIds @("hosted_services_deployment_validation") -Checks $checks -Evidence "Hosted services deployment validator checks Dockerfile posture, staging compose posture, env template variables, and Release publish output."
    New-Requirement -Id "open_weight_ai_runtime_deployment_package" -Description "Open-weight AI runtime deployment package is validated before ProductionMvp provisioning." -CheckIds @("open_weight_ai_runtime_deployment_validation") -Checks $checks -Evidence "Open-weight AI runtime validator checks vLLM/TGI compose posture, env template variables, README contract, and optional probe wiring."
    New-Requirement -Id "production_ops_documents_package" -Description "Production ops document templates are validated before their approved IDs are loaded into readiness." -CheckIds @("production_ops_documents_validation") -Checks $checks -Evidence "Production ops validator checks backup, restore, telemetry retention, incident response, and release approval templates."
    New-Requirement -Id "production_monetary_provisioning_package" -Description "Production monetary provisioning templates are validated before issuer, capacity, genesis, and ledger namespace IDs are loaded into readiness." -CheckIds @("production_monetary_provisioning_validation") -Checks $checks -Evidence "Production monetary validator checks issuer/capacity/genesis provisioning, ARCH genesis request, CC capacity request, and approval-gated hosted record creation path."
    New-Requirement -Id "production_provisioning_packet" -Description "The full production provisioning packet can be validated as one operator handoff before ProductionMvp readiness values are loaded." -CheckIds @("production_provisioning_packet_validation") -Checks $checks -Evidence "Consolidated packet validation runs signing, endpoint, storage, signing-custody, hosted-services, managed-signing, AI runtime, ops, and monetary validators."
    New-Requirement -Id "production_provisioning_packet_scaffold" -Description "The production provisioning packet can be generated as a controlled working copy and validated through PacketRoot mode." -CheckIds @("production_provisioning_packet_scaffold_validation") -Checks $checks -Evidence "Scaffolder copies production provisioning folders, writes a manifest, and validates the generated packet through Test-PassportProductionProvisioningPacket.ps1 -PacketRoot."
    New-Requirement -Id "production_release_evidence_packet" -Description "The production release evidence packet can be generated without serializing environment secrets and can summarize readiness blockers for signoff." -CheckIds @("production_release_evidence_packet_validation") -Checks $checks -Evidence "Release evidence validator uses synthetic fixtures to exercise packet generation, report copying, SHA-256 recording, environment-value redaction, and blocking-gate summary output."
    New-Requirement -Id "staging_readiness_gate" -Description "The staging readiness gate can prove staging artifact isolation, staging endpoint configuration, operational drill evidence, rollback evidence, and signed promotion approvals before canary or production release." -CheckIds @("staging_readiness_gate_validation") -Checks $checks -Evidence "Staging readiness validator uses synthetic fixtures to exercise report/hash validation, staging artifact validation, endpoint isolation, operational drill evidence, rollback evidence, promotion approvals, and no staging-to-production migration checks."
    New-Requirement -Id "production_readiness_fail_closed" -Description "The ProductionMvp readiness gate fails closed instead of passing live probes when production endpoints, operator secrets, storage status, or managed signing custody inputs are absent." -CheckIds @("production_readiness_fail_closed_validation") -Checks $checks -Evidence "Fail-closed validation clears all production readiness variables and verifies every ProductionMvp gate fails, including hosted runtime/operator/AI, managed storage, and managed signing probe gates."
    New-Requirement -Id "no_fake_record_migration" -Description "Pre-MVP fake/synthetic records cannot migrate into production ARCH, CC, Crown reserve, citizen account, or production service-liability records." -CheckIds @("core_tests", "windows_tests", "internal_verification_artifact_lane") -Checks $checks -Evidence "Release-lane artifact validation and ledger replay enforce non-production lane isolation."
)

$failedChecks = @($checks | Where-Object { -not $_.passed })
$failedRequirements = @($requirements | Where-Object { -not $_.passed })
$report = [pscustomobject][ordered]@{
    schema = "archrealms.passport.pre_mvp_internal_verification.v1"
    created_utc = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
    repo_root = $repoRoot
    configuration = $Configuration
    dotnet_path = $dotnet
    pre_mvp_testing_is_mvp = $false
    citizen_facing_token_release = $false
    fake_balance_migration_blocked = ((@($requirements | Where-Object { $_.id -eq "no_fake_record_migration" }) | Select-Object -First 1).passed -eq $true)
    passed = ($failedChecks.Count -eq 0 -and $failedRequirements.Count -eq 0)
    failed_check_count = $failedChecks.Count
    failed_requirement_count = $failedRequirements.Count
    checks = $checks
    requirements = $requirements
}

$json = $report | ConvertTo-Json -Depth 10
if ($OutputPath) {
    $resolvedOutputPath = [System.IO.Path]::GetFullPath($OutputPath)
    $outputDirectory = Split-Path -Parent $resolvedOutputPath
    if ($outputDirectory) {
        New-Item -ItemType Directory -Force -Path $outputDirectory | Out-Null
    }

    Set-Content -LiteralPath $resolvedOutputPath -Value $json -Encoding UTF8
}

$json
if (-not $report.passed -and -not $NoFail) {
    $failedIds = @($failedChecks | ForEach-Object { $_.id }) + @($failedRequirements | ForEach-Object { $_.id })
    throw "Pre-MVP internal verification failed. Missing gates: " + ($failedIds -join ", ")
}
