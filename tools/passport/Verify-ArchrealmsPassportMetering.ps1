param(
    [string]$WorkspaceRoot,
    [string]$OutputPath,
    [string]$DotnetPath
)

$ErrorActionPreference = "Stop"

if (-not $WorkspaceRoot) {
    throw "WorkspaceRoot is required."
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
$projectPath = Join-Path $repoRoot "tools\metering-verifier\Archrealms.MeteringVerifier.csproj"
$resolvedWorkspaceRoot = (Resolve-Path -LiteralPath $WorkspaceRoot).Path

if (-not $OutputPath) {
    $OutputPath = Join-Path $resolvedWorkspaceRoot "records\passport\metering\status\authoritative-metering-report.json"
}

& $dotnet run --project $projectPath -- $resolvedWorkspaceRoot $OutputPath

if ($LASTEXITCODE -ne 0) {
    throw "Passport metering verification failed."
}
