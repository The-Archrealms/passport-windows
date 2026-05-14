param(
    [Parameter(Mandatory = $true)]
    [string]$ExportRoot,

    [string]$OutputPath = "",

    [string]$ReleaseLane = ""
)

$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..\..")
$projectPath = Join-Path $repoRoot "tools\ledger-verifier\Archrealms.LedgerVerifier.csproj"
$resolvedExportRoot = (Resolve-Path $ExportRoot).Path

$arguments = @("run", "--project", $projectPath, "--", $resolvedExportRoot)
if (-not [string]::IsNullOrWhiteSpace($OutputPath)) {
    $arguments += $OutputPath
}

if (-not [string]::IsNullOrWhiteSpace($ReleaseLane)) {
    if ([string]::IsNullOrWhiteSpace($OutputPath)) {
        $arguments += ""
    }

    $arguments += $ReleaseLane
}

dotnet @arguments
