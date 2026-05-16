param(
    [string]$Repo = "The-Archrealms/passport-windows",
    [string]$CertificatePfxPath,
    [string]$CertificatePassword,
    [string]$CertificatePasswordFile,
    [string]$SecretPrefix = "PASSPORT_WINDOWS_MSIX"
)

$ErrorActionPreference = "Stop"

if (-not $CertificatePfxPath) {
    throw "CertificatePfxPath is required."
}

if (-not $CertificatePassword -and $CertificatePasswordFile) {
    $resolvedPasswordPath = (Resolve-Path -LiteralPath $CertificatePasswordFile).Path
    $CertificatePassword = (Get-Content -LiteralPath $resolvedPasswordPath -Raw).Trim()
    if ([string]::IsNullOrWhiteSpace($CertificatePassword)) {
        throw "CertificatePasswordFile is empty: $resolvedPasswordPath"
    }
}

if (-not $CertificatePassword) {
    throw "CertificatePassword or CertificatePasswordFile is required."
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
    password_source = if ($CertificatePasswordFile) { "file" } else { "argument" }
    updated_utc = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
    secrets = @(
        $SecretPrefix + "_PFX_BASE64",
        $SecretPrefix + "_PFX_PASSWORD"
    )
}

$result | ConvertTo-Json -Depth 4
