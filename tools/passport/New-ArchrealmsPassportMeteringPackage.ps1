param(
    [string]$WorkspaceRoot,
    [string]$MeteringReportPath,
    [string]$OutputRoot
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

function Get-WorkspaceRelativePath {
    param(
        [string]$WorkspaceRoot,
        [string]$Path
    )

    $root = [System.IO.Path]::GetFullPath($WorkspaceRoot).TrimEnd('\', '/')
    $full = [System.IO.Path]::GetFullPath($Path)
    if ($full.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $full.Substring($root.Length).TrimStart('\', '/').Replace('\', '/')
    }

    return $full.Replace('\', '/')
}

function Resolve-WorkspacePath {
    param(
        [string]$WorkspaceRoot,
        [string]$Path
    )

    if ([System.IO.Path]::IsPathRooted($Path)) {
        return [System.IO.Path]::GetFullPath($Path)
    }

    return [System.IO.Path]::GetFullPath((Join-Path $WorkspaceRoot ($Path -replace '/', '\')))
}

function Copy-PackageFile {
    param(
        [string]$SourcePath,
        [string]$PackageRoot,
        [string]$PackageRelativePath
    )

    $destinationPath = Join-Path $PackageRoot ($PackageRelativePath -replace '/', '\')
    $destinationDirectory = Split-Path -Parent $destinationPath
    if ($destinationDirectory) {
        New-Item -ItemType Directory -Force $destinationDirectory | Out-Null
    }

    Copy-Item -LiteralPath $SourcePath -Destination $destinationPath -Force
    return [pscustomobject]@{
        path = $PackageRelativePath
        size_bytes = (Get-Item -LiteralPath $destinationPath).Length
        sha256 = Get-Sha256 -Path $destinationPath
    }
}

if (-not $WorkspaceRoot) {
    throw "WorkspaceRoot is required."
}

$resolvedWorkspaceRoot = (Resolve-Path -LiteralPath $WorkspaceRoot).Path

if (-not $MeteringReportPath) {
    $MeteringReportPath = Join-Path $resolvedWorkspaceRoot "records\passport\metering\status\authoritative-metering-report.json"
}

$resolvedMeteringReportPath = (Resolve-Path -LiteralPath $MeteringReportPath).Path

if (-not $OutputRoot) {
    $packagesRoot = Join-Path $resolvedWorkspaceRoot "records\passport\metering\packages"
    $OutputRoot = Join-Path $packagesRoot ([DateTime]::UtcNow.ToString("yyyyMMddTHHmmssZ") + "-metering-report")
}

$resolvedOutputRoot = [System.IO.Path]::GetFullPath($OutputRoot)
New-Item -ItemType Directory -Force $resolvedOutputRoot | Out-Null

$report = Get-Content -LiteralPath $resolvedMeteringReportPath -Raw | ConvertFrom-Json
$documents = New-Object System.Collections.Generic.List[object]
$sourceRecords = New-Object System.Collections.Generic.List[object]

$documents.Add((Copy-PackageFile -SourcePath $resolvedMeteringReportPath -PackageRoot $resolvedOutputRoot -PackageRelativePath "package/metering-report.json"))

foreach ($record in @($report.records)) {
    if (-not $record.record_path) {
        continue
    }

    $recordSourcePath = Resolve-WorkspacePath -WorkspaceRoot $resolvedWorkspaceRoot -Path $record.record_path
    if (-not (Test-Path -LiteralPath $recordSourcePath)) {
        continue
    }

    $recordPackagePath = "package/source-records/" + (Get-WorkspaceRelativePath -WorkspaceRoot $resolvedWorkspaceRoot -Path $recordSourcePath)
    $documents.Add((Copy-PackageFile -SourcePath $recordSourcePath -PackageRoot $resolvedOutputRoot -PackageRelativePath $recordPackagePath))
    $sourceRecords.Add([pscustomobject]@{
        record_type = $record.record_type
        record_id = $record.record_id
        record_path = $recordPackagePath
    })

    $recordJson = Get-Content -LiteralPath $recordSourcePath -Raw | ConvertFrom-Json
    if ($recordJson.signature) {
        foreach ($relatedPath in @($recordJson.signature.signed_payload_path, $recordJson.signature.signature_path)) {
            if (-not $relatedPath) {
                continue
            }

            $relatedSourcePath = Resolve-WorkspacePath -WorkspaceRoot $resolvedWorkspaceRoot -Path $relatedPath
            if (Test-Path -LiteralPath $relatedSourcePath) {
                $relatedPackagePath = "package/source-records/" + (Get-WorkspaceRelativePath -WorkspaceRoot $resolvedWorkspaceRoot -Path $relatedSourcePath)
                $documents.Add((Copy-PackageFile -SourcePath $relatedSourcePath -PackageRoot $resolvedOutputRoot -PackageRelativePath $relatedPackagePath))
            }
        }
    }
}

$createdUtc = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
$packageId = Split-Path -Leaf $resolvedOutputRoot
$manifest = [pscustomobject]@{
    package_name = "passport-metering-report-package"
    package_id = $packageId
    created_utc = $createdUtc
    workspace_root = $resolvedWorkspaceRoot
    metering_report_path = "package/metering-report.json"
    source_records = $sourceRecords
    documents = $documents
}

$manifestPath = Join-Path $resolvedOutputRoot "manifest.json"
$manifest | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $manifestPath -Encoding UTF8

$packageRecord = [pscustomobject]@{
    schema_version = 1
    record_type = "passport_metering_report_package"
    record_id = $packageId
    created_utc = $createdUtc
    manifest_path = "manifest.json"
    document_count = $documents.Count
    settlement_status = "not_settled"
    summary = "Passport metering report package prepared for registrar/admission review. This package does not settle value."
}

$packageRecordPath = Join-Path $resolvedOutputRoot "metering-package.json"
$packageRecord | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $packageRecordPath -Encoding UTF8

[pscustomobject]@{
    package_root = $resolvedOutputRoot
    package_record_path = $packageRecordPath
    manifest_path = $manifestPath
    document_count = $documents.Count
} | ConvertTo-Json -Depth 8
