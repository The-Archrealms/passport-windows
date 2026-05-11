param(
    [string]$PackageRoot,
    [string]$OutputPath
)

$ErrorActionPreference = "Stop"

function Get-Sha256 {
    param([string]$Path)

    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $stream = [System.IO.File]::OpenRead($Path)
        try {
            $hash = $sha.ComputeHash($stream)
            return -join ($hash | ForEach-Object { $_.ToString("x2") })
        }
        finally {
            $stream.Dispose()
        }
    }
    finally {
        $sha.Dispose()
    }
}

if (-not $PackageRoot) {
    throw "PackageRoot is required."
}

$resolvedPackageRoot = (Resolve-Path -LiteralPath $PackageRoot).Path
$manifestPath = Join-Path $resolvedPackageRoot "manifest.json"

if (-not (Test-Path -LiteralPath $manifestPath)) {
    throw "Metering package manifest not found."
}

if (-not $OutputPath) {
    $OutputPath = Join-Path $resolvedPackageRoot "metering-package-verification-report.json"
}

$manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
$documents = New-Object System.Collections.Generic.List[object]
$allHashesValid = $true

foreach ($document in @($manifest.documents)) {
    $relativePath = [string]$document.path
    $documentPath = Join-Path $resolvedPackageRoot ($relativePath -replace '/', '\')
    $exists = Test-Path -LiteralPath $documentPath
    $actualSha256 = ""
    $hashMatches = $false

    if ($exists) {
        $actualSha256 = Get-Sha256 -Path $documentPath
        $hashMatches = $actualSha256.Equals([string]$document.sha256, [System.StringComparison]::OrdinalIgnoreCase)
    }

    if (-not $hashMatches) {
        $allHashesValid = $false
    }

    $documents.Add([pscustomobject]@{
        path = $relativePath
        exists = $exists
        expected_sha256 = [string]$document.sha256
        actual_sha256 = $actualSha256
        hash_matches = $hashMatches
    })
}

$reportPath = Join-Path $resolvedPackageRoot "package\metering-report.json"
$reportPresent = Test-Path -LiteralPath $reportPath
$acceptedProofCount = 0
$rejectedProofCount = 0

if ($reportPresent) {
    $meteringReport = Get-Content -LiteralPath $reportPath -Raw | ConvertFrom-Json
    $acceptedProofCount = [int]$meteringReport.accepted_proof_count
    $rejectedProofCount = [int]$meteringReport.rejected_proof_count
}

$verified = $allHashesValid -and $reportPresent
$verification = [pscustomobject]@{
    verified_utc = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
    package_root = $resolvedPackageRoot
    package_name = $manifest.package_name
    package_id = $manifest.package_id
    metering_report_present = $reportPresent
    document_hashes_valid = $allHashesValid
    verified = $verified
    accepted_proof_count = $acceptedProofCount
    rejected_proof_count = $rejectedProofCount
    settlement_status = "not_settled"
    documents = $documents
}

$outputDirectory = Split-Path -Parent $OutputPath
if ($outputDirectory) {
    New-Item -ItemType Directory -Force $outputDirectory | Out-Null
}

$verification | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $OutputPath -Encoding UTF8
Get-Content -LiteralPath $OutputPath
