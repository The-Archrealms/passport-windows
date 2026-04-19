param(
    [string]$DotnetPath,
    [string]$RuntimeIdentifier = "win-x64",
    [string]$Configuration = "Release",
    [string]$Version,
    [string]$OutputRoot,
    [bool]$SelfContained = $true
)

$ErrorActionPreference = "Stop"

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

$appProject = Join-Path $repoRoot "src\ArchrealmsPassport.Windows\ArchrealmsPassport.Windows.csproj"
$publishRoot = Join-Path $OutputRoot ("passport-windows-" + $RuntimeIdentifier)
$publishDir = Join-Path $publishRoot "publish"
$zipPath = Join-Path $publishRoot ("passport-windows-" + $RuntimeIdentifier + ".zip")
$manifestPath = Join-Path $publishRoot "release-manifest.json"
$selfContainedValue = if ($SelfContained) { "true" } else { "false" }

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

if ($Version) {
    $publishArgs += @("-p:Version=" + $Version)
}

& $dotnet @publishArgs
if ($LASTEXITCODE -ne 0) {
    throw "Passport publish failed."
}

if (Test-Path -LiteralPath $zipPath) {
    Remove-Item -Force $zipPath
}

Compress-Archive -Path (Join-Path $publishDir "*") -DestinationPath $zipPath

$gitCommit = ""
try {
    $gitCommit = (git -C $repoRoot rev-parse HEAD).Trim()
}
catch {
}

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
    dotnet = $dotnet
    runtime_identifier = $RuntimeIdentifier
    configuration = $Configuration
    self_contained = $SelfContained
    version = $Version
    git_commit = $gitCommit
    publish_dir = $publishDir
    zip_path = $zipPath
    file_count = @($files).Count
    files = $files
}

$manifest | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $manifestPath -Encoding UTF8
Get-Content -LiteralPath $manifestPath
