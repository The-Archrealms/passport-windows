param(
    [string]$Version,
    [ValidateSet("x64", "x86", "ARM64")]
    [string]$Platform = "x64",
    [string]$Configuration = "Release",
    [string]$OutputRoot,
    [string]$MsBuildPath,
    [string]$CertificatePfxPath,
    [string]$CertificatePassword,
    [string]$CertificatePfxBase64,
    [switch]$UseTestCertificate
)

$ErrorActionPreference = "Stop"

function Resolve-MsBuildPath {
    param(
        [string]$PreferredPath
    )

    if ($PreferredPath) {
        return (Resolve-Path -LiteralPath $PreferredPath).Path
    }

    $vswherePath = "C:\Program Files (x86)\Microsoft Visual Studio\Installer\vswhere.exe"
    if (Test-Path -LiteralPath $vswherePath) {
        $resolved = & $vswherePath -latest -products * -requires Microsoft.Component.MSBuild -find "MSBuild\**\Bin\MSBuild.exe" | Select-Object -First 1
        if ($resolved) {
            return $resolved.Trim()
        }
    }

    throw "MSBuild.exe was not found. Use -MsBuildPath or build on a Windows runner with Visual Studio build tools."
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

function Get-Sha256 {
    param(
        [string]$Path
    )

    return (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant()
}

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$packageProject = Join-Path $repoRoot "src\ArchrealmsPassport.Windows.Package\ArchrealmsPassport.Windows.Package.wapproj"
$packageManifest = Join-Path $repoRoot "src\ArchrealmsPassport.Windows.Package\Package.appxmanifest"
$assetScript = Join-Path $repoRoot "tools\release\New-PassportWindowsMsixAssets.ps1"
$packagePublisher = "CN=The Archrealms"
$packageIdentityName = "TheArchrealms.PassportWindows"
$packageVersion = ConvertTo-AppxVersion -RawVersion $Version
$msbuild = Resolve-MsBuildPath -PreferredPath $MsBuildPath

if (-not $OutputRoot) {
    $OutputRoot = Join-Path $repoRoot "artifacts\release\passport-windows-msix"
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

$artifactRoot = Join-Path $OutputRoot $Platform.ToLowerInvariant()
$stagingRoot = Join-Path $artifactRoot "staging"
$certificateRoot = Join-Path $artifactRoot "certificate"
$packageOutput = Join-Path $artifactRoot ("passport-windows-" + $Platform.ToLowerInvariant() + ".msix")
$releaseManifestPath = Join-Path $artifactRoot "msix-package-manifest.json"

New-Item -ItemType Directory -Force $artifactRoot | Out-Null
New-Item -ItemType Directory -Force $stagingRoot | Out-Null
New-Item -ItemType Directory -Force $certificateRoot | Out-Null

$certificateSource = if ($CertificatePfxPath) { "provided-path" } elseif ($CertificatePfxBase64) { "provided-base64" } else { "generated-test-certificate" }
$certificatePasswordValue = $CertificatePassword
$certificatePfx = Join-Path $certificateRoot "passport-windows-signing.pfx"
$certificateCer = Join-Path $artifactRoot "passport-windows-signing.cer"
$generatedCertificate = $null
$removeGeneratedCertificate = $false

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

$manifestXml = [xml](Get-Content -LiteralPath $packageManifest -Raw)
$namespaceManager = New-Object System.Xml.XmlNamespaceManager($manifestXml.NameTable)
$namespaceManager.AddNamespace("appx", "http://schemas.microsoft.com/appx/manifest/foundation/windows10")
$identityNode = $manifestXml.SelectSingleNode("/appx:Package/appx:Identity", $namespaceManager)
if (-not $identityNode) {
    throw "Package manifest identity element was not found."
}

$originalVersion = $identityNode.Version

try {
    $identityNode.Version = $packageVersion
    $manifestXml.Save($packageManifest)

    if (Test-Path -LiteralPath $packageOutput) {
        Remove-Item -Force $packageOutput
    }

    $msbuildArgs = @(
        $packageProject,
        "/restore",
        "/p:Configuration=$Configuration",
        "/p:Platform=$Platform",
        "/p:UapAppxPackageBuildMode=SideloadOnly",
        "/p:AppxBundle=Never",
        "/p:GenerateAppInstallerFile=false",
        "/p:AppxPackageOutput=$packageOutput",
        "/p:AppxPackageSigningEnabled=true",
        "/p:PackageCertificateKeyFile=$certificatePfx",
        "/p:PackageCertificatePassword=$certificatePasswordValue"
    )

    & $msbuild @msbuildArgs
    if ($LASTEXITCODE -ne 0) {
        throw "MSIX packaging failed."
    }
}
finally {
    $identityNode.Version = $originalVersion
    $manifestXml.Save($packageManifest)

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
    configuration = $Configuration
    msbuild = $msbuild
    package_path = $packageOutput
    package_sha256 = (Get-Sha256 -Path $packageOutput)
    certificate_source = $certificateSource
    certificate_path = $certificateCer
    certificate_sha256 = (Get-Sha256 -Path $certificateCer)
    git_commit = $gitCommit
}

$releaseManifest | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $releaseManifestPath -Encoding UTF8
Get-Content -LiteralPath $releaseManifestPath
