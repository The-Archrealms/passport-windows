function Get-PassportWindowsDefaultKuboVersion {
    return "v0.41.0"
}

function Normalize-PassportWindowsKuboVersion {
    param(
        [string]$Version
    )

    if (-not $Version) {
        $Version = Get-PassportWindowsDefaultKuboVersion
    }

    $normalized = $Version.Trim()
    if ($normalized -notmatch '^[vV]') {
        $normalized = "v$normalized"
    }

    return $normalized
}

function Resolve-PassportWindowsKuboArch {
    param(
        [string]$Platform,
        [string]$RuntimeIdentifier
    )

    $candidate = $Platform
    if (-not $candidate -and $RuntimeIdentifier) {
        if ($RuntimeIdentifier -match '^win-(.+)$') {
            $candidate = $Matches[1]
        }
    }

    switch -Regex ($candidate) {
        '^(x64|amd64)$' { return "amd64" }
        '^(arm64)$' { return "arm64" }
        default {
            throw "Kubo does not publish a Windows runtime for platform '$candidate'. Use x64/amd64 or arm64."
        }
    }
}

function Resolve-PassportWindowsIpfsCliSourcePath {
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
        (Join-Path $env:LOCALAPPDATA "Programs\IPFS Desktop\resources\app.asar.unpacked\node_modules\kubo\kubo\ipfs.exe"),
        (Join-Path $env:ProgramFiles "IPFS Desktop\resources\app.asar.unpacked\node_modules\kubo\kubo\ipfs.exe"),
        (Join-Path ${env:ProgramFiles(x86)} "IPFS Desktop\resources\app.asar.unpacked\node_modules\kubo\kubo\ipfs.exe")
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }

    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }

    return ""
}

function Install-PassportWindowsKuboRuntime {
    param(
        [string]$DownloadRoot,
        [string]$KuboVersion,
        [string]$Platform,
        [string]$RuntimeIdentifier
    )

    if (-not $DownloadRoot) {
        $DownloadRoot = Join-Path ([System.IO.Path]::GetTempPath()) "archrealms-passport-kubo"
    }

    $version = Normalize-PassportWindowsKuboVersion -Version $KuboVersion
    $arch = Resolve-PassportWindowsKuboArch -Platform $Platform -RuntimeIdentifier $RuntimeIdentifier
    $baseUrl = "https://dist.ipfs.tech/kubo/$version"
    $distJsonUrl = "$baseUrl/dist.json"

    New-Item -ItemType Directory -Force -Path $DownloadRoot | Out-Null

    $dist = Invoke-RestMethod -Uri $distJsonUrl
    $windows = $dist.platforms.windows
    if (-not $windows) {
        throw "Kubo distribution metadata does not contain a Windows platform entry for $version."
    }

    $archProperty = $windows.archs.PSObject.Properties[$arch]
    if (-not $archProperty) {
        throw "Kubo distribution metadata does not contain a Windows $arch entry for $version."
    }

    $entry = $archProperty.Value
    $archiveUrl = $baseUrl + $entry.link
    $expectedSha512 = [string]$entry.sha512
    $archiveName = Split-Path -Leaf $entry.link
    $archivePath = Join-Path $DownloadRoot $archiveName

    $needsDownload = $true
    if (Test-Path -LiteralPath $archivePath) {
        $existingSha512 = (Get-FileHash -Algorithm SHA512 -LiteralPath $archivePath).Hash.ToLowerInvariant()
        $needsDownload = -not [string]::Equals($existingSha512, $expectedSha512, [System.StringComparison]::OrdinalIgnoreCase)
    }

    if ($needsDownload) {
        Invoke-WebRequest -Uri $archiveUrl -OutFile $archivePath
    }

    $actualSha512 = (Get-FileHash -Algorithm SHA512 -LiteralPath $archivePath).Hash.ToLowerInvariant()
    if (-not [string]::Equals($actualSha512, $expectedSha512, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Downloaded Kubo archive hash mismatch. Expected $expectedSha512 but got $actualSha512."
    }

    $extractRoot = Join-Path $DownloadRoot ("kubo-$version-windows-$arch")
    if (Test-Path -LiteralPath $extractRoot) {
        Remove-Item -Recurse -Force -LiteralPath $extractRoot
    }

    Expand-Archive -LiteralPath $archivePath -DestinationPath $extractRoot -Force

    $ipfsCli = Get-ChildItem -LiteralPath $extractRoot -Recurse -File -Filter "ipfs.exe" | Select-Object -First 1
    if (-not $ipfsCli) {
        throw "Downloaded Kubo archive did not contain ipfs.exe."
    }

    $versionText = ""
    try {
        $versionOutput = & $ipfsCli.FullName --version 2>&1
        if ($versionOutput) {
            $versionText = ($versionOutput | Select-Object -First 1).ToString().Trim()
        }
    }
    catch {
        $versionText = $_.Exception.Message
    }

    return [pscustomobject]@{
        source_type = "downloaded-kubo"
        kubo_version = $version
        platform = "windows"
        arch = $arch
        dist_json_url = $distJsonUrl
        download_url = $archiveUrl
        archive_path = $archivePath
        archive_sha512 = $actualSha512
        extract_root = $extractRoot
        ipfs_cli_path = $ipfsCli.FullName
        ipfs_cli_version = $versionText
    }
}

function Stage-PassportWindowsBundledIpfsRuntime {
    param(
        [string]$PublishDir,
        [string]$PreferredPath,
        [string]$Platform,
        [string]$RuntimeIdentifier,
        [string]$KuboVersion,
        [string]$DownloadRoot,
        [switch]$DownloadIfMissing
)

    $explicitPath = $PreferredPath
    if (-not $explicitPath -and $env:ARCHREALMS_IPFS_CLI) {
        $explicitPath = $env:ARCHREALMS_IPFS_CLI
    }

    $sourcePath = ""
    $runtimeInfo = $null

    if ($explicitPath) {
        $sourcePath = Resolve-PassportWindowsIpfsCliSourcePath -PreferredPath $explicitPath
        $versionText = ""
        try {
            $versionOutput = & $sourcePath --version 2>&1
            if ($versionOutput) {
                $versionText = ($versionOutput | Select-Object -First 1).ToString().Trim()
            }
        }
        catch {
            $versionText = $_.Exception.Message
        }

        $runtimeInfo = [pscustomobject]@{
            source_type = "local"
            kubo_version = ""
            platform = ""
            arch = ""
            dist_json_url = ""
            download_url = ""
            archive_path = ""
            archive_sha512 = ""
            extract_root = ""
            ipfs_cli_path = $sourcePath
            ipfs_cli_version = $versionText
        }
    }
    elseif ($DownloadIfMissing) {
        $runtimeInfo = Install-PassportWindowsKuboRuntime `
            -DownloadRoot $DownloadRoot `
            -KuboVersion $KuboVersion `
            -Platform $Platform `
            -RuntimeIdentifier $RuntimeIdentifier
        $sourcePath = $runtimeInfo.ipfs_cli_path
    }
    else {
        $sourcePath = Resolve-PassportWindowsIpfsCliSourcePath -PreferredPath ""
        if ($sourcePath) {
            $versionText = ""
            try {
                $versionOutput = & $sourcePath --version 2>&1
                if ($versionOutput) {
                    $versionText = ($versionOutput | Select-Object -First 1).ToString().Trim()
                }
            }
            catch {
                $versionText = $_.Exception.Message
            }

            $runtimeInfo = [pscustomobject]@{
                source_type = "local"
                kubo_version = ""
                platform = ""
                arch = ""
                dist_json_url = ""
                download_url = ""
                archive_path = ""
                archive_sha512 = ""
                extract_root = ""
                ipfs_cli_path = $sourcePath
                ipfs_cli_version = $versionText
            }
        }
        else {
            Write-Warning "No IPFS CLI was found. The Passport package will rely on an external IPFS runtime."
            return $null
        }
    }

    $destinationPath = Join-Path $PublishDir "tools\ipfs\runtime\ipfs.exe"
    $destinationRoot = Split-Path -Parent $destinationPath
    New-Item -ItemType Directory -Force $destinationRoot | Out-Null
    Copy-Item -LiteralPath $sourcePath -Destination $destinationPath -Force

    $licenseFiles = @()
    $sourceRoot = Split-Path -Parent $sourcePath
    foreach ($license in Get-ChildItem -LiteralPath $sourceRoot -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -like "LICENSE*" -or $_.Name -ieq "README.md" }) {
        $destinationLicense = Join-Path $destinationRoot $license.Name
        Copy-Item -LiteralPath $license.FullName -Destination $destinationLicense -Force
        $licenseFiles += $destinationLicense
    }

    return [pscustomobject]@{
        source_type = $runtimeInfo.source_type
        source_path = $sourcePath
        bundled_path = $destinationPath
        kubo_version = $runtimeInfo.kubo_version
        ipfs_cli_version = $runtimeInfo.ipfs_cli_version
        download_url = $runtimeInfo.download_url
        dist_json_url = $runtimeInfo.dist_json_url
        archive_path = $runtimeInfo.archive_path
        archive_sha512 = $runtimeInfo.archive_sha512
        license_files = $licenseFiles
    }
}

function Get-PassportWindowsReleaseLaneSlug {
    param(
        [string]$Lane
    )

    if (-not $Lane) {
        $Lane = "Staging"
    }

    switch ($Lane.Trim().ToLowerInvariant().Replace("_", "-")) {
        "dev" { return "dev" }
        "development" { return "dev" }
        "internalverification" { return "internal-verification" }
        "internal-verification" { return "internal-verification" }
        "internal" { return "internal-verification" }
        "stage" { return "staging" }
        "staging" { return "staging" }
        "canary" { return "canary-mvp" }
        "canary-mvp" { return "canary-mvp" }
        "production" { return "production-mvp" }
        "production-mvp" { return "production-mvp" }
        "prod" { return "production-mvp" }
        default { throw "Unsupported Passport release lane: $Lane" }
    }
}

function Get-PassportWindowsReleaseLaneDisplayName {
    param(
        [string]$Lane
    )

    $laneSlug = Get-PassportWindowsReleaseLaneSlug -Lane $Lane
    switch ($laneSlug) {
        "internal-verification" { return "Internal Verification" }
        "staging" { return "Staging" }
        "canary-mvp" { return "Canary MVP" }
        "production-mvp" { return "Production MVP" }
        default { return "Development" }
    }
}

function Get-PassportWindowsReleaseLaneEnvironmentValue {
    param(
        [string]$Lane,
        [string]$Name
    )

    $laneSlug = Get-PassportWindowsReleaseLaneSlug -Lane $Lane
    $lanePrefix = "PASSPORT_WINDOWS_" + ($laneSlug.ToUpperInvariant().Replace("-", "_")) + "_"
    $laneValue = [System.Environment]::GetEnvironmentVariable($lanePrefix + $Name)
    if (-not [string]::IsNullOrWhiteSpace($laneValue)) {
        return $laneValue
    }

    return [System.Environment]::GetEnvironmentVariable("PASSPORT_WINDOWS_RELEASE_LANE_" + $Name)
}

function Get-PassportWindowsDefaultMsixPackageIdentity {
    param(
        [string]$Channel,
        [string]$Lane
    )

    $laneSlug = Get-PassportWindowsReleaseLaneSlug -Lane $Lane
    $channelSuffix = if ([string]::Equals($Channel, "Store", [System.StringComparison]::Ordinal)) { "" } else { ".Sideload" }

    switch ($laneSlug) {
        "production-mvp" { return "TheArchrealms.PassportWindows" + $channelSuffix }
        "canary-mvp" { return "TheArchrealms.PassportWindows.Canary" + $channelSuffix }
        "staging" { return "TheArchrealms.PassportWindows.Staging" + $channelSuffix }
        "internal-verification" { return "TheArchrealms.PassportWindows.InternalVerification" + $channelSuffix }
        default { return "TheArchrealms.PassportWindows.Dev" + $channelSuffix }
    }
}

function Get-PassportWindowsDefaultPackageDisplayName {
    param(
        [string]$Channel,
        [string]$Lane
    )

    $laneSlug = Get-PassportWindowsReleaseLaneSlug -Lane $Lane
    $channelSuffix = if ([string]::Equals($Channel, "Store", [System.StringComparison]::Ordinal)) { "" } else { " Sideload" }

    if ([string]::Equals($laneSlug, "production-mvp", [System.StringComparison]::Ordinal)) {
        return "Archrealms Passport" + $channelSuffix
    }

    return "Archrealms Passport " + (Get-PassportWindowsReleaseLaneDisplayName -Lane $laneSlug) + $channelSuffix
}

function Get-PassportWindowsDefaultPackageDescription {
    param(
        [string]$Channel,
        [string]$Lane
    )

    $laneSlug = Get-PassportWindowsReleaseLaneSlug -Lane $Lane
    if ([string]::Equals($laneSlug, "production-mvp", [System.StringComparison]::Ordinal)) {
        return "Windows Passport client for the Archrealms."
    }

    return "Windows Passport $laneSlug lane build for the Archrealms."
}

function New-PassportWindowsReleaseLaneManifest {
    param(
        [string]$Lane,
        [string]$PackageChannel,
        [string]$PackageIdentity,
        [string]$PackageDisplayName,
        [string]$GitCommit
    )

    $laneSlug = Get-PassportWindowsReleaseLaneSlug -Lane $Lane
    $displayName = Get-PassportWindowsReleaseLaneDisplayName -Lane $laneSlug
    $productionLedger = [string]::Equals($laneSlug, "canary-mvp", [System.StringComparison]::Ordinal) -or
        [string]::Equals($laneSlug, "production-mvp", [System.StringComparison]::Ordinal)

    $ledgerNamespace = Get-PassportWindowsReleaseLaneEnvironmentValue -Lane $laneSlug -Name "LEDGER_NAMESPACE"
    if (-not $ledgerNamespace) {
        $ledgerNamespace = "archrealms-passport-$laneSlug"
    }

    $apiBaseUrl = Get-PassportWindowsReleaseLaneEnvironmentValue -Lane $laneSlug -Name "API_BASE_URL"
    $aiGatewayUrl = Get-PassportWindowsReleaseLaneEnvironmentValue -Lane $laneSlug -Name "AI_GATEWAY_URL"
    if (-not $aiGatewayUrl -and $apiBaseUrl) {
        $aiGatewayUrl = $apiBaseUrl
    }

    $telemetryEnvironment = Get-PassportWindowsReleaseLaneEnvironmentValue -Lane $laneSlug -Name "TELEMETRY_ENVIRONMENT"
    if (-not $telemetryEnvironment) {
        $telemetryEnvironment = $laneSlug
    }

    $issuerKeyScope = Get-PassportWindowsReleaseLaneEnvironmentValue -Lane $laneSlug -Name "ISSUER_KEY_SCOPE"
    if (-not $issuerKeyScope) {
        $issuerKeyScope = "passport-$laneSlug"
    }

    $featureFlagScope = Get-PassportWindowsReleaseLaneEnvironmentValue -Lane $laneSlug -Name "FEATURE_FLAG_SCOPE"
    if (-not $featureFlagScope) {
        $featureFlagScope = "passport-$laneSlug"
    }

    $policyVersion = Get-PassportWindowsReleaseLaneEnvironmentValue -Lane $laneSlug -Name "POLICY_VERSION"
    if (-not $policyVersion) {
        $policyVersion = "passport-release-lanes-v1"
    }

    return [pscustomobject][ordered]@{
        schema = "archrealms.passport.release_lane.v1"
        created_utc = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
        lane = $laneSlug
        environment = $laneSlug
        lane_display_name = $displayName
        package_channel = if ($PackageChannel) { $PackageChannel.ToLowerInvariant() } else { "unpackaged" }
        package_identity = if ($PackageIdentity) { $PackageIdentity } else { "" }
        package_display_name = if ($PackageDisplayName) { $PackageDisplayName } else { "" }
        ledger_namespace = $ledgerNamespace
        api_base_url = if ($apiBaseUrl) { $apiBaseUrl } else { "" }
        ai_gateway_url = if ($aiGatewayUrl) { $aiGatewayUrl } else { "" }
        telemetry_environment = $telemetryEnvironment
        issuer_key_scope = $issuerKeyScope
        feature_flag_scope = $featureFlagScope
        policy_version = $policyVersion
        allow_production_token_records = $productionLedger
        allow_staging_records = [string]::Equals($laneSlug, "staging", [System.StringComparison]::Ordinal)
        production_ledger = $productionLedger
        git_commit = if ($GitCommit) { $GitCommit } else { "" }
    }
}

Export-ModuleMember -Function `
    Get-PassportWindowsDefaultKuboVersion, `
    Normalize-PassportWindowsKuboVersion, `
    Resolve-PassportWindowsKuboArch, `
    Resolve-PassportWindowsIpfsCliSourcePath, `
    Install-PassportWindowsKuboRuntime, `
    Stage-PassportWindowsBundledIpfsRuntime, `
    Get-PassportWindowsReleaseLaneSlug, `
    Get-PassportWindowsReleaseLaneDisplayName, `
    Get-PassportWindowsReleaseLaneEnvironmentValue, `
    Get-PassportWindowsDefaultMsixPackageIdentity, `
    Get-PassportWindowsDefaultPackageDisplayName, `
    Get-PassportWindowsDefaultPackageDescription, `
    New-PassportWindowsReleaseLaneManifest
