param(
    [string]$DockerfilePath = "deploy\hosted-services\Dockerfile",

    [string]$ComposePath = "deploy\hosted-services\docker-compose.staging.yml",

    [string]$EnvTemplatePath = "deploy\hosted-services\hosted-services-staging-env.template",

    [string]$OutputPath = "artifacts\release\hosted-services-deployment-validation-report.json",

    [string]$ImageTag = "archrealms/passport-hosted-services:local-validation",

    [switch]$SkipPublish,

    [switch]$BuildDockerImage
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

function New-Check {
    param(
        [string]$Id,
        [bool]$Passed,
        [string[]]$Failures = @(),
        [object]$Evidence = $null
    )

    $normalizedFailures = @($Failures | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })

    return [pscustomobject][ordered]@{
        id = $Id
        passed = $Passed
        failures = $normalizedFailures
        evidence = $Evidence
    }
}

function Test-TextContains {
    param(
        [string]$Text,
        [string[]]$Required,
        [string[]]$Forbidden = @()
    )

    $failures = New-Object System.Collections.Generic.List[string]
    foreach ($requiredText in $Required) {
        if ($Text.IndexOf($requiredText, [StringComparison]::OrdinalIgnoreCase) -lt 0) {
            $failures.Add("missing text: $requiredText")
        }
    }

    foreach ($forbiddenText in $Forbidden) {
        if ($Text.IndexOf($forbiddenText, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
            $failures.Add("forbidden text: $forbiddenText")
        }
    }

    return $failures.ToArray()
}

function Invoke-CommandCapture {
    param(
        [string]$FilePath,
        [string[]]$Arguments,
        [string]$WorkingDirectory
    )

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $FilePath
    $psi.Arguments = ($Arguments | ForEach-Object { '"' + ($_ -replace '"', '\"') + '"' }) -join " "
    $psi.WorkingDirectory = $WorkingDirectory
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false

    $process = [System.Diagnostics.Process]::Start($psi)
    $stdout = $process.StandardOutput.ReadToEnd()
    $stderr = $process.StandardError.ReadToEnd()
    $process.WaitForExit()

    return [pscustomobject][ordered]@{
        exit_code = $process.ExitCode
        stdout = $stdout
        stderr = $stderr
    }
}

$checks = New-Object System.Collections.Generic.List[object]

$resolvedDockerfile = Resolve-RepoPath $DockerfilePath
$resolvedCompose = Resolve-RepoPath $ComposePath
$resolvedEnvTemplate = Resolve-RepoPath $EnvTemplatePath
$resolvedOutput = Resolve-RepoPath $OutputPath
$publishOutput = Resolve-RepoPath "artifacts\release\hosted-services-publish-validation"
$releaseArtifactsRoot = Resolve-RepoPath "artifacts\release"

$deploymentFilesMissing = @()
foreach ($path in @($resolvedDockerfile, $resolvedCompose, $resolvedEnvTemplate)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        $deploymentFilesMissing += $path
    }
}
$checks.Add((New-Check -Id "deployment_files_exist" -Passed ($deploymentFilesMissing.Count -eq 0) -Failures $deploymentFilesMissing -Evidence @{
    dockerfile = $resolvedDockerfile
    compose = $resolvedCompose
    env_template = $resolvedEnvTemplate
}))

if ($deploymentFilesMissing.Count -eq 0) {
    $dockerfileText = Get-Content -LiteralPath $resolvedDockerfile -Raw
    $dockerfileFailures = Test-TextContains `
        -Text $dockerfileText `
        -Required @(
            "mcr.microsoft.com/dotnet/sdk:8.0",
            "mcr.microsoft.com/dotnet/aspnet:8.0",
            "src/ArchrealmsPassport.Core/ArchrealmsPassport.Core.csproj",
            "src/ArchrealmsPassport.HostedServices/ArchrealmsPassport.HostedServices.csproj",
            "dotnet publish src/ArchrealmsPassport.HostedServices/ArchrealmsPassport.HostedServices.csproj",
            "ASPNETCORE_URLS=http://+:8080",
            "ARCHREALMS_PASSPORT_HOSTED_DATA_ROOT=/var/lib/archrealms/passport-hosted",
            "USER archrealms",
            "ENTRYPOINT [""dotnet"", ""ArchrealmsPassport.HostedServices.dll""]"
        ) `
        -Forbidden @(
            "ARCHREALMS_PASSPORT_HOSTED_SIGNING_KEY_PATH",
            "ARCHREALMS_PASSPORT_HOSTED_OPERATOR_API_KEY="
        )
    $checks.Add((New-Check -Id "dockerfile_production_posture" -Passed ($dockerfileFailures.Count -eq 0) -Failures $dockerfileFailures -Evidence @{ path = $resolvedDockerfile }))

    $composeText = Get-Content -LiteralPath $resolvedCompose -Raw
    $composeFailures = Test-TextContains `
        -Text $composeText `
        -Required @(
            "deploy/hosted-services/Dockerfile",
            "hosted-services.staging.env",
            "8080:8080",
            "ARCHREALMS_PASSPORT_HOSTED_DATA_ROOT: /var/lib/archrealms/passport-hosted",
            "passport-hosted-services-data"
        ) `
        -Forbidden @(
            "ARCHREALMS_PASSPORT_HOSTED_SIGNING_KEY_PATH"
        )
    $checks.Add((New-Check -Id "compose_staging_posture" -Passed ($composeFailures.Count -eq 0) -Failures $composeFailures -Evidence @{ path = $resolvedCompose }))

    $envTemplateText = Get-Content -LiteralPath $resolvedEnvTemplate -Raw
    $envFailures = Test-TextContains `
        -Text $envTemplateText `
        -Required @(
            "ARCHREALMS_PASSPORT_HOSTED_OPERATOR_API_KEY_SHA256",
            "ARCHREALMS_PASSPORT_HOSTED_SIGNING_KEY_PROVIDER",
            "ARCHREALMS_PASSPORT_HOSTED_SIGNING_ENDPOINT",
            "ARCHREALMS_PASSPORT_AI_INFERENCE_BASE_URL",
            "ARCHREALMS_PASSPORT_AI_MODEL_ARTIFACT_SHA256",
            "ARCHREALMS_PASSPORT_AI_MODEL_LICENSE_APPROVAL_ID",
            "ARCHREALMS_PASSPORT_AI_VECTOR_STORE_PROVIDER",
            "ARCHREALMS_PASSPORT_AI_KNOWLEDGE_APPROVAL_ROOT",
            "ARCHREALMS_PASSPORT_TELEMETRY_DESTINATION",
            "ARCHREALMS_PASSPORT_INCIDENT_RESPONSE_RUNBOOK_URI"
        ) `
        -Forbidden @(
            "ARCHREALMS_PASSPORT_HOSTED_OPERATOR_API_KEY="
        )
    $checks.Add((New-Check -Id "env_template_required_variables" -Passed ($envFailures.Count -eq 0) -Failures $envFailures -Evidence @{ path = $resolvedEnvTemplate }))
}

if (-not $SkipPublish) {
    if (Test-Path -LiteralPath $publishOutput) {
        $normalizedPublishOutput = [System.IO.Path]::GetFullPath($publishOutput).TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
        $normalizedArtifactsRoot = [System.IO.Path]::GetFullPath($releaseArtifactsRoot).TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
        if (-not $normalizedPublishOutput.StartsWith($normalizedArtifactsRoot, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Refusing to remove publish output outside artifacts release root: $publishOutput"
        }

        Remove-Item -LiteralPath $publishOutput -Recurse -Force
    }

    $dotnet = Get-Command dotnet -ErrorAction SilentlyContinue
    if ($null -eq $dotnet) {
        $checks.Add((New-Check -Id "hosted_service_publish" -Passed $false -Failures @("dotnet was not found on PATH") -Evidence $null))
    }
    else {
        $publish = Invoke-CommandCapture `
            -FilePath $dotnet.Source `
            -Arguments @(
                "publish",
                "src\ArchrealmsPassport.HostedServices\ArchrealmsPassport.HostedServices.csproj",
                "-c",
                "Release",
                "-o",
                $publishOutput,
                "/p:UseAppHost=false"
            ) `
            -WorkingDirectory $repoRoot
        $publishedDll = Join-Path $publishOutput "ArchrealmsPassport.HostedServices.dll"
        $publishFailures = @()
        if ($publish.exit_code -ne 0) {
            $publishFailures += "dotnet publish exited with code $($publish.exit_code)"
        }
        if (-not (Test-Path -LiteralPath $publishedDll -PathType Leaf)) {
            $publishFailures += "published hosted service DLL was not found"
        }

        $checks.Add((New-Check -Id "hosted_service_publish" -Passed ($publishFailures.Count -eq 0) -Failures $publishFailures -Evidence @{
            command = "dotnet publish src\ArchrealmsPassport.HostedServices\ArchrealmsPassport.HostedServices.csproj -c Release -o $publishOutput /p:UseAppHost=false"
            exit_code = $publish.exit_code
            output_excerpt = (($publish.stdout + $publish.stderr) -replace "\r", "").Trim()
            published_dll = $publishedDll
        }))
    }
}

$docker = Get-Command docker -ErrorAction SilentlyContinue
$dockerEvidence = @{
    docker_available = $null -ne $docker
    image_tag = $ImageTag
}
if ($BuildDockerImage) {
    if ($null -eq $docker) {
        $checks.Add((New-Check -Id "docker_image_build" -Passed $false -Failures @("docker was not found on PATH") -Evidence $dockerEvidence))
    }
    else {
        $build = Invoke-CommandCapture `
            -FilePath $docker.Source `
            -Arguments @(
                "build",
                "-f",
                $resolvedDockerfile,
                "-t",
                $ImageTag,
                "."
            ) `
            -WorkingDirectory $repoRoot
        $buildFailures = @()
        if ($build.exit_code -ne 0) {
            $buildFailures += "docker build exited with code $($build.exit_code)"
        }
        $checks.Add((New-Check -Id "docker_image_build" -Passed ($buildFailures.Count -eq 0) -Failures $buildFailures -Evidence ($dockerEvidence + @{
            exit_code = $build.exit_code
            output_excerpt = (($build.stdout + $build.stderr) -replace "\r", "").Trim()
        })))
    }
}
else {
    $checks.Add((New-Check -Id "docker_image_build" -Passed $true -Failures @() -Evidence ($dockerEvidence + @{
        skipped = $true
        reason = "Use -BuildDockerImage to perform a local Docker image build."
    })))
}

$failed = @($checks | Where-Object { -not $_.passed })
$report = [pscustomobject][ordered]@{
    schema = "archrealms.passport.hosted_services_deployment_validation.v1"
    created_utc = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
    repo_root = $repoRoot
    passed = $failed.Count -eq 0
    failed_check_count = $failed.Count
    checks = $checks
}

$parent = Split-Path -Parent $resolvedOutput
if ($parent) {
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
}
$report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $resolvedOutput -Encoding UTF8
$report | ConvertTo-Json -Depth 8

if ($failed.Count -gt 0) {
    exit 1
}
