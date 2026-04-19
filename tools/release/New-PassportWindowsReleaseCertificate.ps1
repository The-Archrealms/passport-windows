param(
    [string]$Subject = "CN=The Archrealms",
    [string]$FriendlyName = "Passport Windows Release Signing",
    [int]$YearsValid = 5,
    [string]$OutputDirectory,
    [string]$Password,
    [switch]$Force
)

$ErrorActionPreference = "Stop"

if (-not $OutputDirectory) {
    $OutputDirectory = Join-Path $env:LOCALAPPDATA "Archrealms\PassportWindows\release-signing"
}

$resolvedOutputDirectory = [System.IO.Path]::GetFullPath($OutputDirectory)
New-Item -ItemType Directory -Force -Path $resolvedOutputDirectory | Out-Null

$pfxPath = Join-Path $resolvedOutputDirectory "passport-windows-signing.pfx"
$cerPath = Join-Path $resolvedOutputDirectory "passport-windows-signing.cer"
$metadataPath = Join-Path $resolvedOutputDirectory "passport-windows-signing.json"

if (-not $Force) {
    foreach ($path in @($pfxPath, $cerPath, $metadataPath)) {
        if (Test-Path -LiteralPath $path) {
            throw "Signing artifact already exists: $path. Use -Force to overwrite."
        }
    }
}

if (-not $Password) {
    $Password = [Guid]::NewGuid().ToString("N") + "!" + [Guid]::NewGuid().ToString("N").Substring(0, 8)
}

$securePassword = ConvertTo-SecureString -String $Password -AsPlainText -Force

$certificate = New-SelfSignedCertificate `
    -Type Custom `
    -Subject $Subject `
    -FriendlyName $FriendlyName `
    -CertStoreLocation "Cert:\CurrentUser\My" `
    -KeyAlgorithm RSA `
    -KeyLength 4096 `
    -HashAlgorithm SHA256 `
    -KeyExportPolicy Exportable `
    -KeyUsage DigitalSignature `
    -TextExtension @("2.5.29.37={text}1.3.6.1.5.5.7.3.3") `
    -NotAfter (Get-Date).AddYears($YearsValid)

Export-PfxCertificate -Cert $certificate -FilePath $pfxPath -Password $securePassword | Out-Null
Export-Certificate -Cert $certificate -FilePath $cerPath | Out-Null

$metadata = [pscustomobject]@{
    created_utc = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
    subject = $certificate.Subject
    friendly_name = $FriendlyName
    thumbprint = $certificate.Thumbprint
    not_after_utc = $certificate.NotAfter.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    pfx_path = $pfxPath
    cer_path = $cerPath
    output_directory = $resolvedOutputDirectory
    password = $Password
}

$metadata | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $metadataPath -Encoding UTF8
Get-Content -LiteralPath $metadataPath
