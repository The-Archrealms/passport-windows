param(
    [string]$Version,
    [ValidateSet("Sideload", "Store")]
    [string]$Channel = "Sideload",
    [ValidateSet("Dev", "InternalVerification", "Staging", "CanaryMvp", "ProductionMvp")]
    [string]$Lane = "Staging",
    [ValidateSet("x64", "x86", "arm64")]
    [string]$Platform = "x64",
    [string]$Configuration = "Release",
    [string]$OutputRoot,
    [string]$EnvironmentFile,
    [string]$DotnetPath,
    [string]$IpfsCliPath,
    [string]$KuboVersion = "v0.41.0",
    [string]$PackageIdentityName,
    [string]$PackagePublisher,
    [string]$PublisherDisplayName,
    [string]$PackageDisplayName,
    [string]$PackageDescription,
    [string]$PackageFileName,
    [string]$MakeAppxPath,
    [string]$SignToolPath,
    [string]$TimestampUrl,
    [string]$CertificatePfxPath,
    [string]$CertificatePassword,
    [string]$CertificatePfxBase64,
    [int]$ProductionMvpReadinessEndpointTimeoutSeconds = 10,
    [bool]$SelfContained = $true,
    [switch]$SkipIpfsRuntimeBootstrap,
    [switch]$SkipSignatureVerification,
    [switch]$SkipProductionMvpReadinessGate
)

$ErrorActionPreference = "Stop"
Import-Module (Join-Path $PSScriptRoot "PassportWindowsRelease.psm1") -Force -DisableNameChecking

function Import-EnvironmentFile {
    param(
        [string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return @()
    }

    $resolvedPath = (Resolve-Path -LiteralPath $Path).Path
    $loaded = @()
    foreach ($line in Get-Content -LiteralPath $resolvedPath) {
        $trimmed = $line.Trim()
        if ([string]::IsNullOrWhiteSpace($trimmed) -or $trimmed.StartsWith("#")) {
            continue
        }

        $separator = $trimmed.IndexOf("=")
        if ($separator -le 0) {
            continue
        }

        $name = $trimmed.Substring(0, $separator).Trim()
        $value = $trimmed.Substring($separator + 1).Trim()
        if ([string]::IsNullOrWhiteSpace($name)) {
            continue
        }

        if (($value.StartsWith('"') -and $value.EndsWith('"')) -or ($value.StartsWith("'") -and $value.EndsWith("'"))) {
            $value = $value.Substring(1, $value.Length - 2)
        }

        [System.Environment]::SetEnvironmentVariable($name, $value, "Process")
        $loaded += $name
    }

    return $loaded
}

$loadedEnvironmentVariables = Import-EnvironmentFile -Path $EnvironmentFile

function Resolve-DotnetPath {
    param(
        [string]$PreferredPath
    )

    if (-not $PreferredPath -and $env:ARCHREALMS_DOTNET) {
        $PreferredPath = $env:ARCHREALMS_DOTNET
    }

    if ($PreferredPath) {
        return (Resolve-Path -LiteralPath $PreferredPath).Path
    }

    return (Get-Command dotnet -ErrorAction Stop).Source
}

function Resolve-WindowsSdkTool {
    param(
        [string]$PreferredPath,
        [string]$ToolName
    )

    if ($PreferredPath) {
        return (Resolve-Path -LiteralPath $PreferredPath).Path
    }

    $tool = Get-Command $ToolName -ErrorAction SilentlyContinue
    if ($tool) {
        return $tool.Source
    }

    $kitsRoot = "C:\Program Files (x86)\Windows Kits\10\bin"
    if (-not (Test-Path -LiteralPath $kitsRoot)) {
        throw "$ToolName was not found. Install the Windows SDK or provide -$($ToolName -replace '\.exe$', 'Path')."
    }

    $candidate = Get-ChildItem -LiteralPath $kitsRoot -Directory | Sort-Object Name -Descending | ForEach-Object {
        $path = Join-Path $_.FullName ("x64\" + $ToolName)
        if (Test-Path -LiteralPath $path) {
            return $path
        }
    } | Select-Object -First 1

    if (-not $candidate) {
        throw "$ToolName was not found under the Windows SDK bin folder."
    }

    return $candidate
}

function Import-CertificateIntoCurrentUserStore {
    param(
        [System.Security.Cryptography.X509Certificates.X509Certificate2]$Certificate,
        [string]$Path,
        [string]$StoreName
    )

    $storeNameValue = [System.Enum]::Parse(
        [System.Security.Cryptography.X509Certificates.StoreName],
        $StoreName)
    $store = [System.Security.Cryptography.X509Certificates.X509Store]::new(
        $storeNameValue,
        [System.Security.Cryptography.X509Certificates.StoreLocation]::CurrentUser)
    $added = $false

    try {
        $store.Open([System.Security.Cryptography.X509Certificates.OpenFlags]::ReadOnly)
        $existing = $store.Certificates.Find(
            [System.Security.Cryptography.X509Certificates.X509FindType]::FindByThumbprint,
            $Certificate.Thumbprint,
            $false)
    }
    finally {
        $store.Close()
    }

    if ($existing.Count -eq 0) {
        Invoke-CertutilAddStore -StoreName $StoreName -Path $Path
        $added = $true
    }

    return [pscustomobject]@{
        Store = "Cert:\CurrentUser\$StoreName"
        Thumbprint = $Certificate.Thumbprint
        Added = $added
    }
}

function Invoke-CertutilAddStore {
    param(
        [string]$StoreName,
        [string]$Path
    )

    $escapedStoreName = $StoreName.Replace('"', '\"')
    $escapedPath = $Path.Replace('"', '\"')
    $processInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $processInfo.FileName = "certutil.exe"
    $processInfo.Arguments = "-user -addstore -f `"$escapedStoreName`" `"$escapedPath`""
    $processInfo.UseShellExecute = $false
    $processInfo.RedirectStandardInput = $true
    $processInfo.RedirectStandardOutput = $true
    $processInfo.RedirectStandardError = $true
    $processInfo.CreateNoWindow = $true

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $processInfo
    $null = $process.Start()
    $process.StandardInput.WriteLine("Y")
    $process.StandardInput.WriteLine("Y")
    $process.StandardInput.WriteLine("Y")
    $process.StandardInput.Close()

    if (-not $process.WaitForExit(30000)) {
        try {
            $process.Kill()
        }
        catch {
        }

        throw "Timed out importing signing certificate into CurrentUser\$StoreName."
    }

    $stdout = $process.StandardOutput.ReadToEnd()
    $stderr = $process.StandardError.ReadToEnd()
    if ($process.ExitCode -ne 0) {
        throw ("Failed to import signing certificate into CurrentUser\$StoreName. " + $stdout + " " + $stderr).Trim()
    }
}

function ConvertTo-AppxVersion {
    param(
        [string]$RawVersion
    )

    if (-not $RawVersion) {
        return "0.1.0.0"
    }

    $normalized = $RawVersion.Trim()
    if ($normalized -match '^[vV](.+)$') {
        $normalized = $Matches[1]
    }

    $normalized = ($normalized -split '[-+]')[0]
    $parts = $normalized -split '\.'
    if ($parts.Count -gt 4) {
        throw "MSIX package versions may contain at most four numeric components."
    }

    $versionParts = @()
    foreach ($part in $parts) {
        if ($part -notmatch '^\d+$') {
            throw "MSIX package versions must be numeric. Invalid component: '$part'."
        }

        $versionParts += [int]$part
    }

    while ($versionParts.Count -lt 4) {
        $versionParts += 0
    }

    return ($versionParts -join '.')
}

function ConvertTo-AssemblyVersion {
    param(
        [string]$RawVersion
    )

    if (-not $RawVersion) {
        return ""
    }

    $normalized = $RawVersion.Trim()
    if ($normalized -match '^[vV](.+)$') {
        $normalized = $Matches[1]
    }

    return ($normalized -split '[-+]')[0]
}

function Get-Sha256 {
    param(
        [string]$Path
    )

    return (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant()
}

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
        [string]$Platform,
        [string]$RuntimeIdentifier,
        [string]$KuboVersion,
        [string]$DownloadRoot,
        [switch]$DownloadIfMissing
    )

    return Stage-PassportWindowsBundledIpfsRuntime `
        -PublishDir $PublishDir `
        -PreferredPath $PreferredPath `
        -Platform $Platform `
        -RuntimeIdentifier $RuntimeIdentifier `
        -KuboVersion $KuboVersion `
        -DownloadRoot $DownloadRoot `
        -DownloadIfMissing:$DownloadIfMissing
}

function Copy-DirectoryContents {
    param(
        [string]$Source,
        [string]$Destination
    )

    New-Item -ItemType Directory -Force $Destination | Out-Null
    Copy-Item -Path (Join-Path $Source "*") -Destination $Destination -Recurse -Force
}

function Get-ChannelSlug {
    param(
        [string]$Channel
    )

    return $Channel.ToLowerInvariant()
}

function Get-ChannelEnvironmentValue {
    param(
        [string]$Channel,
        [string]$Name
    )

    $channelPrefix = if ([string]::Equals($Channel, "Store", [System.StringComparison]::Ordinal)) {
        "PASSPORT_WINDOWS_STORE_"
    }
    else {
        "PASSPORT_WINDOWS_SIDELOAD_"
    }

    $channelValue = [System.Environment]::GetEnvironmentVariable($channelPrefix + $Name)
    if (-not [string]::IsNullOrWhiteSpace($channelValue)) {
        return $channelValue
    }

    return [System.Environment]::GetEnvironmentVariable("PASSPORT_WINDOWS_MSIX_" + $Name)
}

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$appProject = Join-Path $repoRoot "src\ArchrealmsPassport.Windows\ArchrealmsPassport.Windows.csproj"
$packageManifestTemplate = Join-Path $repoRoot "src\ArchrealmsPassport.Windows.Package\Package.appxmanifest"
$assetsRoot = Join-Path $repoRoot "src\ArchrealmsPassport.Windows.Package\Assets"
$assetScript = Join-Path $repoRoot "tools\release\New-PassportWindowsMsixAssets.ps1"
$channelSlug = Get-ChannelSlug -Channel $Channel
$laneSlug = Get-PassportWindowsReleaseLaneSlug -Lane $Lane
if (-not $PackageIdentityName) {
    $PackageIdentityName = Get-PassportWindowsReleaseLaneEnvironmentValue -Lane $Lane -Name "PACKAGE_IDENTITY"
}
if (-not $PackageIdentityName) {
    $PackageIdentityName = Get-ChannelEnvironmentValue -Channel $Channel -Name "PACKAGE_IDENTITY"
}
if (-not $PackagePublisher) {
    $PackagePublisher = Get-ChannelEnvironmentValue -Channel $Channel -Name "PUBLISHER"
}
if (-not $PublisherDisplayName) {
    $PublisherDisplayName = Get-ChannelEnvironmentValue -Channel $Channel -Name "PUBLISHER_DISPLAY_NAME"
}
if (-not $PackageDisplayName) {
    $PackageDisplayName = Get-PassportWindowsReleaseLaneEnvironmentValue -Lane $Lane -Name "DISPLAY_NAME"
}
if (-not $PackageDisplayName) {
    $PackageDisplayName = Get-ChannelEnvironmentValue -Channel $Channel -Name "DISPLAY_NAME"
}
if (-not $PackageDescription) {
    $PackageDescription = Get-PassportWindowsReleaseLaneEnvironmentValue -Lane $Lane -Name "DESCRIPTION"
}
if (-not $PackageDescription) {
    $PackageDescription = Get-ChannelEnvironmentValue -Channel $Channel -Name "DESCRIPTION"
}

if (-not $PackageIdentityName) {
    $PackageIdentityName = Get-PassportWindowsDefaultMsixPackageIdentity -Channel $Channel -Lane $Lane
}
if (-not $PackagePublisher) {
    $PackagePublisher = "CN=The Archrealms"
}
if (-not $PublisherDisplayName) {
    $PublisherDisplayName = "The Archrealms"
}
if (-not $PackageDisplayName) {
    $PackageDisplayName = Get-PassportWindowsDefaultPackageDisplayName -Channel $Channel -Lane $Lane
}
if (-not $PackageDescription) {
    $PackageDescription = Get-PassportWindowsDefaultPackageDescription -Channel $Channel -Lane $Lane
}

$packageVersion = ConvertTo-AppxVersion -RawVersion $Version
$assemblyVersion = ConvertTo-AssemblyVersion -RawVersion $Version
$runtimeIdentifier = "win-" + $Platform
$dotnet = Resolve-DotnetPath -PreferredPath $DotnetPath

if (-not $OutputRoot) {
    $OutputRoot = Join-Path $repoRoot ("artifacts\release\passport-windows-msix-" + $channelSlug)
}
$OutputRoot = [System.IO.Path]::GetFullPath($OutputRoot)

if (-not $TimestampUrl -and $env:PASSPORT_WINDOWS_MSIX_TIMESTAMP_URL) {
    $TimestampUrl = $env:PASSPORT_WINDOWS_MSIX_TIMESTAMP_URL
}

if (-not $CertificatePfxBase64 -and $env:PASSPORT_WINDOWS_MSIX_PFX_BASE64) {
    $CertificatePfxBase64 = $env:PASSPORT_WINDOWS_MSIX_PFX_BASE64
}

if (-not $CertificatePassword -and $env:PASSPORT_WINDOWS_MSIX_PFX_PASSWORD) {
    $CertificatePassword = $env:PASSPORT_WINDOWS_MSIX_PFX_PASSWORD
}

& powershell -ExecutionPolicy Bypass -File $assetScript
if ($LASTEXITCODE -ne 0) {
    throw "Failed to generate MSIX branding assets."
}

$artifactRoot = Join-Path $OutputRoot $Platform
$publishRoot = Join-Path $artifactRoot "publish"
$layoutRoot = Join-Path $artifactRoot "layout"
$certificateRoot = Join-Path $artifactRoot "certificate"
if (-not $PackageFileName) {
    $PackageFileName = "passport-windows-" + $channelSlug + "-" + $laneSlug + "-" + $Platform + ".msix"
}
$packageOutput = Join-Path $artifactRoot $PackageFileName
$releaseManifestPath = Join-Path $artifactRoot "msix-package-manifest.json"
$layoutManifestPath = Join-Path $layoutRoot "AppxManifest.xml"
$appProjectXml = [xml](Get-Content -LiteralPath $appProject -Raw)
$applicationExecutable = $appProjectXml.Project.PropertyGroup.AssemblyName | Select-Object -First 1
if (-not $applicationExecutable) {
    $applicationExecutable = [System.IO.Path]::GetFileNameWithoutExtension($appProject)
}
$applicationExecutable += ".exe"

New-Item -ItemType Directory -Force $artifactRoot | Out-Null
New-Item -ItemType Directory -Force $certificateRoot | Out-Null

if (Test-Path -LiteralPath $publishRoot) {
    Remove-Item -Recurse -Force $publishRoot
}

if (Test-Path -LiteralPath $layoutRoot) {
    Remove-Item -Recurse -Force $layoutRoot
}

$certificateSource = if ($CertificatePfxPath) { "provided-path" } elseif ($CertificatePfxBase64) { "provided-base64" } else { "generated-test-certificate" }
$certificatePasswordValue = $CertificatePassword
$certificatePfx = Join-Path $certificateRoot "passport-windows-signing.pfx"
$certificateCer = Join-Path $artifactRoot "passport-windows-signing.cer"
$generatedCertificate = $null
$removeGeneratedCertificate = $false
$trustedPeopleImport = $null
$trustedRootImport = $null
$gitCommit = ""
try {
    $gitCommit = (git -C $repoRoot rev-parse HEAD).Trim()
}
catch {
}

if ([string]::Equals($laneSlug, "production-mvp", [System.StringComparison]::Ordinal)) {
    if ($SkipProductionMvpReadinessGate) {
        Write-Warning "Skipping ProductionMvp readiness gate. This package must not be treated as production-test ready until the readiness gate passes."
    }
    else {
        $readinessScript = Join-Path $repoRoot "tools\release\Test-PassportProductionMvpReadiness.ps1"
        $readinessReportPath = Join-Path $artifactRoot "production-mvp-readiness-report.json"
        $packageSigningConfigured = -not [string]::Equals($certificateSource, "generated-test-certificate", [System.StringComparison]::Ordinal)
        $timestampConfigured = -not [string]::IsNullOrWhiteSpace($TimestampUrl)
        $packageSigningConfiguredValue = if ($packageSigningConfigured) { "1" } else { "0" }
        $timestampConfiguredValue = if ($timestampConfigured) { "1" } else { "0" }
        & powershell -ExecutionPolicy Bypass -File $readinessScript `
            -OutputPath $readinessReportPath `
            -EnvironmentFile $EnvironmentFile `
            -PackageSigningConfigured $packageSigningConfiguredValue `
            -TimestampConfigured $timestampConfiguredValue `
            -EndpointTimeoutSeconds $ProductionMvpReadinessEndpointTimeoutSeconds
        if ($LASTEXITCODE -ne 0) {
            throw "ProductionMvp readiness gate failed. See $readinessReportPath."
        }
    }
}

$makeAppx = Resolve-WindowsSdkTool -PreferredPath $MakeAppxPath -ToolName "makeappx.exe"
$signTool = Resolve-WindowsSdkTool -PreferredPath $SignToolPath -ToolName "signtool.exe"

if ($CertificatePfxPath) {
    Copy-Item -LiteralPath $CertificatePfxPath -Destination $certificatePfx -Force
}
elseif ($CertificatePfxBase64) {
    [System.IO.File]::WriteAllBytes($certificatePfx, [System.Convert]::FromBase64String($CertificatePfxBase64))
}
else {
    $certificatePasswordValue = [Guid]::NewGuid().ToString("N") + "!"
    $securePassword = ConvertTo-SecureString -String $certificatePasswordValue -AsPlainText -Force
    $generatedCertificate = New-SelfSignedCertificate `
        -Type Custom `
        -Subject $PackagePublisher `
        -CertStoreLocation "Cert:\CurrentUser\My" `
        -KeyAlgorithm RSA `
        -KeyLength 4096 `
        -HashAlgorithm SHA256 `
        -KeyExportPolicy Exportable `
        -KeyUsage DigitalSignature `
        -TextExtension @("2.5.29.37={text}1.3.6.1.5.5.7.3.3") `
        -NotAfter (Get-Date).AddYears(3)
    $removeGeneratedCertificate = $true

    Export-PfxCertificate -Cert $generatedCertificate -FilePath $certificatePfx -Password $securePassword | Out-Null
    Export-Certificate -Cert $generatedCertificate -FilePath $certificateCer | Out-Null
}

$shouldExportCertificateCer = $CertificatePfxPath -or $CertificatePfxBase64 -or -not (Test-Path -LiteralPath $certificateCer)
if ($shouldExportCertificateCer) {
    $collection = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2Collection
    if ($certificatePasswordValue) {
        $collection.Import($certificatePfx, $certificatePasswordValue, [System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::Exportable)
    }
    else {
        $collection.Import($certificatePfx, $null, [System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::Exportable)
    }

    if ($collection.Count -lt 1) {
        throw "No certificate was found in the supplied PFX."
    }

    $exportCertificate = $null
    foreach ($candidate in $collection) {
        if ($candidate.HasPrivateKey) {
            $exportCertificate = $candidate
            break
        }
    }

    if (-not $exportCertificate) {
        $exportCertificate = $collection[0]
    }

    [System.IO.File]::WriteAllBytes($certificateCer, $exportCertificate.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Cert))
}

$signingCertificate = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 $certificateCer

try {
    $publishArgs = @(
        "publish", $appProject,
        "-c", $Configuration,
        "-r", $runtimeIdentifier,
        "-o", $publishRoot,
        "--self-contained", ($(if ($SelfContained) { "true" } else { "false" })),
        "-p:UseSharedCompilation=false"
    )

    if ($assemblyVersion) {
        $publishArgs += @("-p:Version=" + $assemblyVersion)
    }

    & $dotnet @publishArgs
    if ($LASTEXITCODE -ne 0) {
        throw "Application publish failed."
    }

    $bundledIpfsRuntime = Stage-BundledIpfsRuntime `
        -PublishDir $publishRoot `
        -PreferredPath $IpfsCliPath `
        -Platform $Platform `
        -RuntimeIdentifier $runtimeIdentifier `
        -KuboVersion $KuboVersion `
        -DownloadRoot (Join-Path $OutputRoot "kubo-cache") `
        -DownloadIfMissing:(!$SkipIpfsRuntimeBootstrap.IsPresent)

    $releaseLaneManifest = New-PassportWindowsReleaseLaneManifest `
        -Lane $Lane `
        -PackageChannel $Channel `
        -PackageIdentity $PackageIdentityName `
        -PackageDisplayName $PackageDisplayName `
        -GitCommit $gitCommit
    $releaseLaneManifestPath = Join-Path $publishRoot "passport-release-lane.json"
    $releaseLaneManifest | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $releaseLaneManifestPath -Encoding UTF8

    Copy-DirectoryContents -Source $publishRoot -Destination $layoutRoot
    Copy-DirectoryContents -Source $assetsRoot -Destination (Join-Path $layoutRoot "Assets")

    $manifestXml = [xml](Get-Content -LiteralPath $packageManifestTemplate -Raw)
    $namespaceManager = New-Object System.Xml.XmlNamespaceManager($manifestXml.NameTable)
    $namespaceManager.AddNamespace("appx", "http://schemas.microsoft.com/appx/manifest/foundation/windows10")
    $namespaceManager.AddNamespace("uap", "http://schemas.microsoft.com/appx/manifest/uap/windows10")
    $identityNode = $manifestXml.SelectSingleNode("/appx:Package/appx:Identity", $namespaceManager)
    if (-not $identityNode) {
        throw "Package manifest identity element was not found."
    }
    $applicationNode = $manifestXml.SelectSingleNode("/appx:Package/appx:Applications/appx:Application", $namespaceManager)
    if (-not $applicationNode) {
        throw "Package manifest application element was not found."
    }

    $identityNode.Name = $PackageIdentityName
    $identityNode.Publisher = $PackagePublisher
    $identityNode.Version = $packageVersion

    $propertiesNode = $manifestXml.SelectSingleNode("/appx:Package/appx:Properties", $namespaceManager)
    if ($propertiesNode) {
        $displayNameNode = $propertiesNode.SelectSingleNode("appx:DisplayName", $namespaceManager)
        if ($displayNameNode) {
            $displayNameNode.InnerText = $PackageDisplayName
        }

        $publisherDisplayNameNode = $propertiesNode.SelectSingleNode("appx:PublisherDisplayName", $namespaceManager)
        if ($publisherDisplayNameNode) {
            $publisherDisplayNameNode.InnerText = $PublisherDisplayName
        }

        $descriptionNode = $propertiesNode.SelectSingleNode("appx:Description", $namespaceManager)
        if ($descriptionNode) {
            $descriptionNode.InnerText = $PackageDescription
        }
    }

    $applicationNode.Executable = $applicationExecutable
    $visualElementsNode = $applicationNode.SelectSingleNode("uap:VisualElements", $namespaceManager)
    if ($visualElementsNode) {
        $visualElementsNode.DisplayName = $PackageDisplayName
        $visualElementsNode.Description = $PackageDescription
    }

    $manifestXml.Save($layoutManifestPath)

    if (Test-Path -LiteralPath $packageOutput) {
        Remove-Item -Force $packageOutput
    }

    & $makeAppx pack /d $layoutRoot /p $packageOutput /o
    if ($LASTEXITCODE -ne 0) {
        throw "MakeAppx packaging failed."
    }

    $signArgs = @("sign", "/fd", "SHA256", "/f", $certificatePfx)
    if ($certificatePasswordValue) {
        $signArgs += @("/p", $certificatePasswordValue)
    }
    if ($TimestampUrl) {
        $signArgs += @("/tr", $TimestampUrl, "/td", "SHA256")
    }
    $signArgs += $packageOutput

    & $signTool @signArgs
    if ($LASTEXITCODE -ne 0) {
        throw "MSIX signing failed."
    }

    if (-not $SkipSignatureVerification) {
        $trustedPeopleImport = Import-CertificateIntoCurrentUserStore -Certificate $signingCertificate -Path $certificateCer -StoreName "TrustedPeople"
        if ($signingCertificate.Subject -eq $signingCertificate.Issuer) {
            $trustedRootImport = Import-CertificateIntoCurrentUserStore -Certificate $signingCertificate -Path $certificateCer -StoreName "Root"
        }

        & $signTool verify /pa $packageOutput
        if ($LASTEXITCODE -ne 0) {
            throw "Signed MSIX verification failed."
        }
    }
}
finally {
    if ($trustedPeopleImport) {
        try {
            if (-not $trustedPeopleImport.PSObject.Properties["Added"] -or $trustedPeopleImport.Added) {
                Remove-Item -LiteralPath ($trustedPeopleImport.Store + "\" + $trustedPeopleImport.Thumbprint) -Force
            }
        }
        catch {
        }
    }

    if ($trustedRootImport) {
        try {
            if (-not $trustedRootImport.PSObject.Properties["Added"] -or $trustedRootImport.Added) {
                Remove-Item -LiteralPath ($trustedRootImport.Store + "\" + $trustedRootImport.Thumbprint) -Force
            }
        }
        catch {
        }
    }

    if ($removeGeneratedCertificate -and $generatedCertificate) {
        try {
            Remove-Item -LiteralPath ("Cert:\CurrentUser\My\" + $generatedCertificate.Thumbprint) -Force
        }
        catch {
        }
    }
}

$layoutFiles = Get-ChildItem -File -Recurse $layoutRoot | Sort-Object FullName | ForEach-Object {
    $hash = Get-FileHash -Algorithm SHA256 -LiteralPath $_.FullName
    [pscustomobject]@{
        path = $_.FullName.Substring($layoutRoot.Length).TrimStart('\').Replace('\', '/')
        size_bytes = $_.Length
        sha256 = $hash.Hash.ToLowerInvariant()
    }
}

$releaseManifest = [pscustomobject]@{
    created_utc = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
    lane = $laneSlug
    release_lane_manifest_path = $releaseLaneManifestPath
    ledger_namespace = $releaseLaneManifest.ledger_namespace
    telemetry_environment = $releaseLaneManifest.telemetry_environment
    issuer_key_scope = $releaseLaneManifest.issuer_key_scope
    channel = $Channel
    channel_slug = $channelSlug
    package_tag = $Version
    package_version = $packageVersion
    package_identity = $PackageIdentityName
    publisher = $PackagePublisher
    publisher_display_name = $PublisherDisplayName
    package_display_name = $PackageDisplayName
    package_description = $PackageDescription
    platform = $Platform
    runtime_identifier = $runtimeIdentifier
    configuration = $Configuration
    self_contained = $SelfContained
    dotnet = $dotnet
    publish_dir = $publishRoot
    layout_dir = $layoutRoot
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
    makeappx = $makeAppx
    signtool = $signTool
    package_path = $packageOutput
    package_sha256 = (Get-Sha256 -Path $packageOutput)
    certificate_source = $certificateSource
    certificate_path = $certificateCer
    certificate_sha256 = (Get-Sha256 -Path $certificateCer)
    signature_verification_skipped = $SkipSignatureVerification.IsPresent
    appx_manifest_path = $layoutManifestPath
    git_commit = $gitCommit
    file_count = @($layoutFiles).Count
    files = $layoutFiles
}

$releaseManifest | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $releaseManifestPath -Encoding UTF8
Get-Content -LiteralPath $releaseManifestPath
