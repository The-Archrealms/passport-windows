param(
    [string]$Version,
    [ValidateSet("x64", "x86", "arm64")]
    [string]$Platform = "x64",
    [string]$Configuration = "Release",
    [string]$OutputRoot,
    [string]$DotnetPath,
    [string]$MakeAppxPath,
    [string]$SignToolPath,
    [string]$TimestampUrl,
    [string]$CertificatePfxPath,
    [string]$CertificatePassword,
    [string]$CertificatePfxBase64,
    [bool]$SelfContained = $true
)

$ErrorActionPreference = "Stop"

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

function Copy-DirectoryContents {
    param(
        [string]$Source,
        [string]$Destination
    )

    New-Item -ItemType Directory -Force $Destination | Out-Null
    Copy-Item -Path (Join-Path $Source "*") -Destination $Destination -Recurse -Force
}

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$appProject = Join-Path $repoRoot "src\ArchrealmsPassport.Windows\ArchrealmsPassport.Windows.csproj"
$packageManifestTemplate = Join-Path $repoRoot "src\ArchrealmsPassport.Windows.Package\Package.appxmanifest"
$assetsRoot = Join-Path $repoRoot "src\ArchrealmsPassport.Windows.Package\Assets"
$assetScript = Join-Path $repoRoot "tools\release\New-PassportWindowsMsixAssets.ps1"
$packagePublisher = "CN=The Archrealms"
$packageIdentityName = "TheArchrealms.PassportWindows"
$packageVersion = ConvertTo-AppxVersion -RawVersion $Version
$assemblyVersion = ConvertTo-AssemblyVersion -RawVersion $Version
$runtimeIdentifier = "win-" + $Platform
$dotnet = Resolve-DotnetPath -PreferredPath $DotnetPath
$makeAppx = Resolve-WindowsSdkTool -PreferredPath $MakeAppxPath -ToolName "makeappx.exe"
$signTool = Resolve-WindowsSdkTool -PreferredPath $SignToolPath -ToolName "signtool.exe"

if (-not $OutputRoot) {
    $OutputRoot = Join-Path $repoRoot "artifacts\release\passport-windows-msix"
}

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
$packageOutput = Join-Path $artifactRoot ("passport-windows-" + $Platform + ".msix")
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
        -Subject $packagePublisher `
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

if (-not (Test-Path -LiteralPath $certificateCer)) {
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

    [System.IO.File]::WriteAllBytes($certificateCer, $collection[0].Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Cert))
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

    $identityNode.Version = $packageVersion
    $applicationNode.Executable = $applicationExecutable
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

    $trustedPeopleImport = Import-Certificate -FilePath $certificateCer -CertStoreLocation "Cert:\CurrentUser\TrustedPeople"
    if ($signingCertificate.Subject -eq $signingCertificate.Issuer) {
        $trustedRootImport = Import-Certificate -FilePath $certificateCer -CertStoreLocation "Cert:\CurrentUser\Root"
    }

    & $signTool verify /pa $packageOutput
    if ($LASTEXITCODE -ne 0) {
        throw "Signed MSIX verification failed."
    }
}
finally {
    if ($trustedPeopleImport) {
        try {
            Remove-Item -LiteralPath ("Cert:\CurrentUser\TrustedPeople\" + $trustedPeopleImport.Thumbprint) -Force
        }
        catch {
        }
    }

    if ($trustedRootImport) {
        try {
            Remove-Item -LiteralPath ("Cert:\CurrentUser\Root\" + $trustedRootImport.Thumbprint) -Force
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

$gitCommit = ""
try {
    $gitCommit = (git -C $repoRoot rev-parse HEAD).Trim()
}
catch {
}

$releaseManifest = [pscustomobject]@{
    created_utc = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
    package_tag = $Version
    package_version = $packageVersion
    package_identity = $packageIdentityName
    publisher = $packagePublisher
    platform = $Platform
    runtime_identifier = $runtimeIdentifier
    configuration = $Configuration
    self_contained = $SelfContained
    dotnet = $dotnet
    makeappx = $makeAppx
    signtool = $signTool
    package_path = $packageOutput
    package_sha256 = (Get-Sha256 -Path $packageOutput)
    certificate_source = $certificateSource
    certificate_path = $certificateCer
    certificate_sha256 = (Get-Sha256 -Path $certificateCer)
    appx_manifest_path = $layoutManifestPath
    git_commit = $gitCommit
}

$releaseManifest | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $releaseManifestPath -Encoding UTF8
Get-Content -LiteralPath $releaseManifestPath
