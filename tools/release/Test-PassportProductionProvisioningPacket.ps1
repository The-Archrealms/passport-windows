param(
    [string]$OutputPath = "artifacts\release\production-provisioning-packet-validation-report.json",

    [string]$PackageSigningPath = "deploy\package-signing",

    [string]$EndpointProvisioningPath = "deploy\release-lane-endpoints",

    [string]$ManagedStoragePath = "deploy\managed-storage",

    [string]$ManagedSigningCustodyPath = "deploy\managed-signing-custody",

    [string]$ProductionOpsPath = "deploy\production-ops",

    [string]$ProductionMonetaryPath = "deploy\production-monetary",

    [string]$OpenWeightVllmComposePath = "deploy\open-weight-ai-runtime\docker-compose.vllm.yml",

    [string]$OpenWeightTgiComposePath = "deploy\open-weight-ai-runtime\docker-compose.tgi.yml",

    [string]$OpenWeightEnvTemplatePath = "deploy\open-weight-ai-runtime\open-weight-ai-runtime.env.template",

    [string]$OpenWeightReadmePath = "deploy\open-weight-ai-runtime\README.md",

    [string]$OpenWeightModelApprovalPath = "deploy\open-weight-ai-runtime\model-approval-request.template.md",

    [string]$OpenWeightVectorStoreProvisioningPath = "deploy\open-weight-ai-runtime\vector-store-provisioning.template.md",

    [string]$OpenWeightRuntimeReadinessEvidencePath = "deploy\open-weight-ai-runtime\ai-runtime-readiness-evidence.template.md",

    [switch]$RequireNoPlaceholders,

    [switch]$SkipPublish,

    [switch]$BuildHostedDockerImage,

    [switch]$ProbeManagedSigningEndpoint,

    [switch]$ProbeAiRuntime,

    [switch]$CreateHostedMonetaryRecords,

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

function Invoke-ValidationScript {
    param(
        [string]$Id,
        [string]$Description,
        [string]$ScriptRelativePath,
        [string[]]$Arguments,
        [string]$ReportRelativePath
    )

    $powershell = Get-Command powershell -ErrorAction Stop
    $scriptPath = Resolve-RepoPath -Path $ScriptRelativePath
    $reportPath = Resolve-RepoPath -Path $ReportRelativePath
    $reportParent = Split-Path -Parent $reportPath
    if ($reportParent) {
        New-Item -ItemType Directory -Force -Path $reportParent | Out-Null
    }

    $normalizedArguments = @()
    if ($Arguments) {
        $normalizedArguments += @($Arguments | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    }

    $fullArguments = @(
        "-NoProfile",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        $scriptPath
    ) + $normalizedArguments + @(
        "-OutputPath",
        $reportPath
    )

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $powershell.Source
    $psi.Arguments = ($fullArguments | ForEach-Object { Format-CommandArgument -Argument $_ }) -join " "
    $psi.WorkingDirectory = $repoRoot
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false

    $process = [System.Diagnostics.Process]::Start($psi)
    $stdout = $process.StandardOutput.ReadToEnd()
    $stderr = $process.StandardError.ReadToEnd()
    $process.WaitForExit()

    $childReport = $null
    $reportFailures = @()
    if (Test-Path -LiteralPath $reportPath -PathType Leaf) {
        try {
            $childReport = Get-Content -LiteralPath $reportPath -Raw | ConvertFrom-Json
        }
        catch {
            $reportFailures += "child report could not be parsed as JSON: $($_.Exception.Message)"
        }
    }
    else {
        $reportFailures += "child report was not written: $reportPath"
    }

    $failures = @()
    if ($process.ExitCode -ne 0) {
        $failures += "$Id exited with code $($process.ExitCode)."
    }
    if ($childReport -and $childReport.PSObject.Properties["passed"] -and $childReport.passed -ne $true) {
        $failures += "$Id child report did not pass."
    }
    $failures += $reportFailures

    $output = (($stdout + $stderr) -replace "`r", "").Trim()
    if ($output.Length -gt 4000) {
        $output = $output.Substring($output.Length - 4000)
    }

    return [pscustomobject][ordered]@{
        id = $Id
        description = $Description
        passed = ($failures.Count -eq 0)
        failures = @($failures | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        evidence = [pscustomobject][ordered]@{
            command = (($fullArguments | ForEach-Object { Format-CommandArgument -Argument $_ }) -join " ")
            exit_code = [int]$process.ExitCode
            output_excerpt = $output
            report_path = $reportPath
            child_schema = if ($childReport -and $childReport.PSObject.Properties["schema"]) { [string]$childReport.schema } else { "" }
            child_passed = if ($childReport -and $childReport.PSObject.Properties["passed"]) { [bool]$childReport.passed } else { $false }
            child_failed_check_count = if ($childReport -and $childReport.PSObject.Properties["failed_check_count"]) { [int]$childReport.failed_check_count } else { $null }
        }
    }
}

function Add-SwitchArgument {
    param(
        [string[]]$Arguments,
        [string]$Name,
        [bool]$Enabled
    )

    $normalized = @()
    if ($Arguments) {
        $normalized += @($Arguments | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    }

    if ($Enabled) {
        return @($normalized + @($Name))
    }

    return @($normalized)
}

$childReportRoot = "artifacts\release\production-provisioning-packet"
$checks = @()

$placeholderArgs = @()
$placeholderArgs = Add-SwitchArgument -Arguments $placeholderArgs -Name "-RequireNoPlaceholders" -Enabled ([bool]$RequireNoPlaceholders)

$checks += Invoke-ValidationScript `
    -Id "package_signing_provisioning" `
    -Description "MSIX package-signing request, sideload trust policy, and Microsoft Store signing policy are reviewable and internally consistent." `
    -ScriptRelativePath "tools\release\Test-PassportPackageSigningProvisioning.ps1" `
    -Arguments (@("-PackageSigningPath", $PackageSigningPath) + $placeholderArgs) `
    -ReportRelativePath (Join-Path $childReportRoot "package-signing-provisioning-validation-report.json")

$checks += Invoke-ValidationScript `
    -Id "release_lane_endpoint_provisioning" `
    -Description "Production API and AI gateway endpoint, DNS, TLS, route exposure, and readiness-evidence packet is reviewable." `
    -ScriptRelativePath "tools\release\Test-PassportReleaseLaneEndpointProvisioning.ps1" `
    -Arguments (@("-EndpointProvisioningPath", $EndpointProvisioningPath) + $placeholderArgs) `
    -ReportRelativePath (Join-Path $childReportRoot "release-lane-endpoint-provisioning-validation-report.json")

$checks += Invoke-ValidationScript `
    -Id "managed_storage_provisioning" `
    -Description "Managed storage, backup manifest, restore runbook linkage, and storage readiness-evidence packet is reviewable." `
    -ScriptRelativePath "tools\release\Test-PassportManagedStorageProvisioning.ps1" `
    -Arguments (@("-ManagedStoragePath", $ManagedStoragePath) + $placeholderArgs) `
    -ReportRelativePath (Join-Path $childReportRoot "managed-storage-provisioning-validation-report.json")

$checks += Invoke-ValidationScript `
    -Id "managed_signing_custody_provisioning" `
    -Description "Managed KMS/HSM signing custody request, endpoint policy, and signing readiness-evidence packet is reviewable." `
    -ScriptRelativePath "tools\release\Test-PassportManagedSigningCustodyProvisioning.ps1" `
    -Arguments (@("-ManagedSigningCustodyPath", $ManagedSigningCustodyPath) + $placeholderArgs) `
    -ReportRelativePath (Join-Path $childReportRoot "managed-signing-custody-provisioning-validation-report.json")

$hostedServicesArgs = @()
$hostedServicesArgs = Add-SwitchArgument -Arguments $hostedServicesArgs -Name "-SkipPublish" -Enabled ([bool]$SkipPublish)
$hostedServicesArgs = Add-SwitchArgument -Arguments $hostedServicesArgs -Name "-BuildDockerImage" -Enabled ([bool]$BuildHostedDockerImage)
$checks += Invoke-ValidationScript `
    -Id "hosted_services_deployment" `
    -Description "Hosted API and AI gateway deployment package validates container posture, environment contract, and Release publish output unless skipped." `
    -ScriptRelativePath "tools\release\Test-PassportHostedServicesDeployment.ps1" `
    -Arguments $hostedServicesArgs `
    -ReportRelativePath (Join-Path $childReportRoot "hosted-services-deployment-validation-report.json")

$managedSigningArgs = @()
$managedSigningArgs = Add-SwitchArgument -Arguments $managedSigningArgs -Name "-SkipPublish" -Enabled ([bool]$SkipPublish)
$managedSigningArgs = Add-SwitchArgument -Arguments $managedSigningArgs -Name "-ProbeEndpoint" -Enabled ([bool]$ProbeManagedSigningEndpoint)
$checks += Invoke-ValidationScript `
    -Id "managed_signing_deployment" `
    -Description "Managed signing endpoint deployment package validates container posture, endpoint contract, and Release publish output unless skipped." `
    -ScriptRelativePath "tools\release\Test-PassportManagedSigningDeployment.ps1" `
    -Arguments $managedSigningArgs `
    -ReportRelativePath (Join-Path $childReportRoot "managed-signing-deployment-validation-report.json")

$openWeightArgs = @(
    "-VllmComposePath", $OpenWeightVllmComposePath,
    "-TgiComposePath", $OpenWeightTgiComposePath,
    "-EnvTemplatePath", $OpenWeightEnvTemplatePath,
    "-ReadmePath", $OpenWeightReadmePath,
    "-ModelApprovalPath", $OpenWeightModelApprovalPath,
    "-VectorStoreProvisioningPath", $OpenWeightVectorStoreProvisioningPath,
    "-RuntimeReadinessEvidencePath", $OpenWeightRuntimeReadinessEvidencePath
)
$openWeightArgs = Add-SwitchArgument -Arguments $openWeightArgs -Name "-RequireNoPlaceholders" -Enabled ([bool]$RequireNoPlaceholders)
$openWeightArgs = Add-SwitchArgument -Arguments $openWeightArgs -Name "-ProbeRuntime" -Enabled ([bool]$ProbeAiRuntime)
$checks += Invoke-ValidationScript `
    -Id "open_weight_ai_runtime_deployment" `
    -Description "Open-weight AI runtime package validates vLLM/TGI posture, model approval, vector-store approval, knowledge approval, and optional runtime probe wiring." `
    -ScriptRelativePath "tools\release\Test-PassportOpenWeightAiRuntimeDeployment.ps1" `
    -Arguments $openWeightArgs `
    -ReportRelativePath (Join-Path $childReportRoot "open-weight-ai-runtime-deployment-validation-report.json")

$checks += Invoke-ValidationScript `
    -Id "production_ops_documents" `
    -Description "Backup, restore, telemetry retention, incident response, and release-approval production documents are reviewable." `
    -ScriptRelativePath "tools\release\Test-PassportProductionOpsDocuments.ps1" `
    -Arguments (@("-ProductionOpsPath", $ProductionOpsPath) + $placeholderArgs) `
    -ReportRelativePath (Join-Path $childReportRoot "production-ops-documents-validation-report.json")

$monetaryArgs = @("-ProductionMonetaryPath", $ProductionMonetaryPath) + $placeholderArgs
$monetaryArgs = Add-SwitchArgument -Arguments $monetaryArgs -Name "-CreateHostedRecords" -Enabled ([bool]$CreateHostedMonetaryRecords)
$checks += Invoke-ValidationScript `
    -Id "production_monetary_provisioning" `
    -Description "ARCH genesis, Crown Credit capacity, issuer authority, and production ledger namespace provisioning packet is reviewable." `
    -ScriptRelativePath "tools\release\Test-PassportProductionMonetaryProvisioning.ps1" `
    -Arguments $monetaryArgs `
    -ReportRelativePath (Join-Path $childReportRoot "production-monetary-provisioning-validation-report.json")

$failed = @($checks | Where-Object { -not $_.passed })
$report = [pscustomobject][ordered]@{
    schema = "archrealms.passport.production_provisioning_packet_validation.v1"
    created_utc = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
    repo_root = $repoRoot
    require_no_placeholders = [bool]$RequireNoPlaceholders
    skip_publish = [bool]$SkipPublish
    build_hosted_docker_image = [bool]$BuildHostedDockerImage
    probe_managed_signing_endpoint = [bool]$ProbeManagedSigningEndpoint
    probe_ai_runtime = [bool]$ProbeAiRuntime
    create_hosted_monetary_records = [bool]$CreateHostedMonetaryRecords
    passed = $failed.Count -eq 0
    failed_check_count = $failed.Count
    checks = $checks
}

$resolvedOutput = Resolve-RepoPath -Path $OutputPath
$parent = Split-Path -Parent $resolvedOutput
if ($parent) {
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
}

$json = $report | ConvertTo-Json -Depth 8
Set-Content -LiteralPath $resolvedOutput -Value $json -Encoding UTF8
$json

if ($failed.Count -gt 0 -and -not $NoFail) {
    throw "Production provisioning packet validation failed. Missing gates: " + (($failed | ForEach-Object { $_.id }) -join ", ")
}
