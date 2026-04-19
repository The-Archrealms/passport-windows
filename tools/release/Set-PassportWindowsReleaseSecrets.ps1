param(
    [string]$Repo = "The-Archrealms/passport-windows",
    [string]$CertificatePfxPath,
    [string]$CertificatePassword,
    [string]$SecretPrefix = "PASSPORT_WINDOWS_MSIX"
)

$ErrorActionPreference = "Stop"

if (-not $CertificatePfxPath) {
    throw "CertificatePfxPath is required."
}

if (-not $CertificatePassword) {
    throw "CertificatePassword is required."
}

$resolvedPfxPath = (Resolve-Path -LiteralPath $CertificatePfxPath).Path
$gh = Get-Command gh -ErrorAction Stop
$pfxBase64 = [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($resolvedPfxPath))

& $gh.Source secret set ($SecretPrefix + "_PFX_BASE64") -R $Repo -b $pfxBase64
if ($LASTEXITCODE -ne 0) {
    throw "Failed to set $($SecretPrefix)_PFX_BASE64."
}

& $gh.Source secret set ($SecretPrefix + "_PFX_PASSWORD") -R $Repo -b $CertificatePassword
if ($LASTEXITCODE -ne 0) {
    throw "Failed to set $($SecretPrefix)_PFX_PASSWORD."
}

$result = [pscustomobject]@{
    repo = $Repo
    secret_prefix = $SecretPrefix
    pfx_path = $resolvedPfxPath
    updated_utc = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
    secrets = @(
        $SecretPrefix + "_PFX_BASE64",
        $SecretPrefix + "_PFX_PASSWORD"
    )
}

$result | ConvertTo-Json -Depth 4
