param(
    [string]$DotnetPath,
    [string]$RuntimeIdentifier = "win-x64",
    [string]$Configuration = "Release",
    [string]$Version,
    [ValidateSet("Dev", "InternalVerification", "Staging", "CanaryMvp", "ProductionMvp")]
    [string]$Lane = "Staging",
    [string]$IpfsCliPath,
    [string]$KuboVersion = "v0.41.0",
    [string]$OutputRoot,
    [bool]$SelfContained = $true,
    [switch]$SkipIpfsRuntimeBootstrap
)

$ErrorActionPreference = "Stop"
Import-Module (Join-Path $PSScriptRoot "PassportWindowsRelease.psm1") -Force -DisableNameChecking

function Resolve-IpfsCliSourcePath {
    param(
        [string]$PreferredPath
    )

    if (-not $PreferredPath -and $env:ARCHREALMS_IPFS_CLI) {
        $PreferredPath = $env:ARCHREALMS_IPFS_CLI
    }

    if ($PreferredPath) {
        if (-not (Test-Path -LiteralPath $PreferredPath)) {
            throw "The requested IPFS CLI path does not exist: $PreferredPath"
        }

        return (Resolve-Path -LiteralPath $PreferredPath).Path
    }

    $command = Get-Command ipfs -ErrorAction SilentlyContinue
    if ($command) {
        return $command.Source
    }

    $candidates = @(
        (Join-Path $env:LOCALAPPDATA "Programs\\IPFS Desktop\\resources\\app.asar.unpacked\\node_modules\\kubo\\kubo\\ipfs.exe"),
        (Join-Path $env:ProgramFiles "IPFS Desktop\\resources\\app.asar.unpacked\\node_modules\\kubo\\kubo\\ipfs.exe"),
        (Join-Path ${env:ProgramFiles(x86)} "IPFS Desktop\\resources\\app.asar.unpacked\\node_modules\\kubo\\kubo\\ipfs.exe")
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }

    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }

    return ""
}

function Stage-BundledIpfsRuntime {
    param(
        [string]$PublishDir,
        [string]$PreferredPath,
        [string]$RuntimeIdentifier,
        [string]$KuboVersion,
        [string]$DownloadRoot,
        [switch]$DownloadIfMissing
    )

    return Stage-PassportWindowsBundledIpfsRuntime `
        -PublishDir $PublishDir `
        -PreferredPath $PreferredPath `
        -RuntimeIdentifier $RuntimeIdentifier `
        -KuboVersion $KuboVersion `
        -DownloadRoot $DownloadRoot `
        -DownloadIfMissing:$DownloadIfMissing
}

if (-not $DotnetPath -and $env:ARCHREALMS_DOTNET) {
    $DotnetPath = $env:ARCHREALMS_DOTNET
}

if ($DotnetPath) {
    $dotnet = (Resolve-Path -LiteralPath $DotnetPath).Path
}
else {
    $dotnet = (Get-Command dotnet -ErrorAction Stop).Source
}

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
if (-not $OutputRoot) {
    $OutputRoot = Join-Path $repoRoot "artifacts\release"
}
$OutputRoot = [System.IO.Path]::GetFullPath($OutputRoot)

$appProject = Join-Path $repoRoot "src\ArchrealmsPassport.Windows\ArchrealmsPassport.Windows.csproj"
$laneSlug = Get-PassportWindowsReleaseLaneSlug -Lane $Lane
$publishRoot = Join-Path $OutputRoot ("passport-windows-" + $RuntimeIdentifier)
$publishDir = Join-Path $publishRoot "publish"
$zipPath = Join-Path $publishRoot ("passport-windows-" + $RuntimeIdentifier + "-" + $laneSlug + ".zip")
$manifestPath = Join-Path $publishRoot "release-manifest.json"
$selfContainedValue = if ($SelfContained) { "true" } else { "false" }
$packageVersion = $Version
if ($packageVersion -and $packageVersion -match '^[vV](.+)$') {
    $packageVersion = $Matches[1]
}

New-Item -ItemType Directory -Force $publishRoot | Out-Null
if (Test-Path -LiteralPath $publishDir) {
    Remove-Item -Recurse -Force $publishDir
}

$publishArgs = @(
    "publish", $appProject,
    "-c", $Configuration,
    "-r", $RuntimeIdentifier,
    "-o", $publishDir,
    "--self-contained", $selfContainedValue,
    "-p:UseSharedCompilation=false"
)

if ($packageVersion) {
    $publishArgs += @("-p:Version=" + $packageVersion)
}

& $dotnet @publishArgs
if ($LASTEXITCODE -ne 0) {
    throw "Passport publish failed."
}

$bundledIpfsRuntime = Stage-BundledIpfsRuntime `
    -PublishDir $publishDir `
    -PreferredPath $IpfsCliPath `
    -RuntimeIdentifier $RuntimeIdentifier `
    -KuboVersion $KuboVersion `
    -DownloadRoot (Join-Path $OutputRoot "kubo-cache") `
    -DownloadIfMissing:(!$SkipIpfsRuntimeBootstrap.IsPresent)

$gitCommit = ""
try {
    $gitCommit = (git -C $repoRoot rev-parse HEAD).Trim()
}
catch {
}

$releaseLaneManifest = New-PassportWindowsReleaseLaneManifest `
    -Lane $Lane `
    -PackageChannel "zip" `
    -PackageIdentity "" `
    -PackageDisplayName "Archrealms Passport" `
    -GitCommit $gitCommit
$releaseLaneManifestPath = Join-Path $publishDir "passport-release-lane.json"
$releaseLaneManifest | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $releaseLaneManifestPath -Encoding UTF8

if (Test-Path -LiteralPath $zipPath) {
    Remove-Item -Force $zipPath
}

Compress-Archive -Path (Join-Path $publishDir "*") -DestinationPath $zipPath

$files = Get-ChildItem -File -Recurse $publishDir | Sort-Object FullName | ForEach-Object {
    $hash = Get-FileHash -Algorithm SHA256 -LiteralPath $_.FullName
    [pscustomobject]@{
        path = $_.FullName.Substring($publishDir.Length).TrimStart('\').Replace('\', '/')
        size_bytes = $_.Length
        sha256 = $hash.Hash.ToLowerInvariant()
    }
}

$manifest = [pscustomobject]@{
    created_utc = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
    lane = $laneSlug
    release_lane_manifest_path = $releaseLaneManifestPath
    ledger_namespace = $releaseLaneManifest.ledger_namespace
    telemetry_environment = $releaseLaneManifest.telemetry_environment
    issuer_key_scope = $releaseLaneManifest.issuer_key_scope
    dotnet = $dotnet
    runtime_identifier = $RuntimeIdentifier
    configuration = $Configuration
    self_contained = $SelfContained
    version = $Version
    package_version = $packageVersion
    git_commit = $gitCommit
    publish_dir = $publishDir
    zip_path = $zipPath
    ipfs_runtime_bootstrap_skipped = $SkipIpfsRuntimeBootstrap.IsPresent
    kubo_version = $KuboVersion
    bundled_ipfs_cli_included = ($null -ne $bundledIpfsRuntime)
    bundled_ipfs_cli_source_type = if ($bundledIpfsRuntime) { $bundledIpfsRuntime.source_type } else { "" }
    bundled_ipfs_cli_source_path = if ($bundledIpfsRuntime) { $bundledIpfsRuntime.source_path } else { "" }
    bundled_ipfs_cli_publish_path = if ($bundledIpfsRuntime) { $bundledIpfsRuntime.bundled_path } else { "" }
    bundled_ipfs_cli_version = if ($bundledIpfsRuntime) { $bundledIpfsRuntime.ipfs_cli_version } else { "" }
    bundled_ipfs_download_url = if ($bundledIpfsRuntime) { $bundledIpfsRuntime.download_url } else { "" }
    bundled_ipfs_dist_json_url = if ($bundledIpfsRuntime) { $bundledIpfsRuntime.dist_json_url } else { "" }
    bundled_ipfs_archive_path = if ($bundledIpfsRuntime) { $bundledIpfsRuntime.archive_path } else { "" }
    bundled_ipfs_archive_sha512 = if ($bundledIpfsRuntime) { $bundledIpfsRuntime.archive_sha512 } else { "" }
    bundled_ipfs_license_files = if ($bundledIpfsRuntime) { $bundledIpfsRuntime.license_files } else { @() }
    file_count = @($files).Count
    files = $files
}

$manifest | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $manifestPath -Encoding UTF8
Get-Content -LiteralPath $manifestPath
