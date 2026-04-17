param(
    [string]$SubmissionPath,
    [string]$PackagePath,
    [string]$OutputPath
)

$ErrorActionPreference = "Stop"

function Resolve-PackageRoot {
    param(
        [string]$SubmissionPath,
        [string]$PackagePath
    )

    if ($PackagePath) {
        return (Resolve-Path $PackagePath).Path
    }

    if ($SubmissionPath) {
        $resolvedSubmissionPath = (Resolve-Path $SubmissionPath).Path
        if ((Get-Item -LiteralPath $resolvedSubmissionPath).PSIsContainer) {
            return $resolvedSubmissionPath
        }

        return Split-Path -Parent $resolvedSubmissionPath
    }

    throw "A SubmissionPath or PackagePath is required."
}

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$packageRoot = Resolve-PackageRoot -SubmissionPath $SubmissionPath -PackagePath $PackagePath

if (-not $OutputPath) {
    $OutputPath = Join-Path $packageRoot "verification-report.json"
}

$projectPath = Join-Path $repoRoot "tools\registry-verifier\Archrealms.RegistryVerifier.csproj"
$dotnet = (Get-Command dotnet -ErrorAction Stop).Source

& $dotnet run --project $projectPath -- $packageRoot $OutputPath
if ($LASTEXITCODE -ne 0) {
    throw "Registry submission verification failed."
}
