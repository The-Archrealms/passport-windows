param(
    [string]$ManifestPath,
    [string]$PackagePath,
    [string]$CertificatePath,
    [string]$PackageName,
    [string]$AppId = "App",
    [string]$OutputPath,
    [switch]$SkipLaunch,
    [switch]$StopExisting,
    [switch]$UninstallAfter,
    [switch]$RemoveImportedCertificates
)

$ErrorActionPreference = "Stop"

function Add-Failure {
    param(
        [System.Collections.Generic.List[string]]$Failures,
        [string]$Message
    )

    $Failures.Add($Message) | Out-Null
}

function Resolve-PathFromManifestDirectory {
    param(
        [string]$Path,
        [string]$ManifestDirectory
    )

    if (-not $Path) {
        return ""
    }

    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        return (Resolve-Path -LiteralPath $Path).Path
    }

    $candidate = Join-Path $ManifestDirectory (Split-Path -Leaf $Path)
    if (Test-Path -LiteralPath $candidate -PathType Leaf) {
        return (Resolve-Path -LiteralPath $candidate).Path
    }

    return [System.IO.Path]::GetFullPath($Path)
}

function Import-PackageCertificate {
    param([string]$Path)

    $imports = @()
    if (-not $Path) {
        return $imports
    }

    $certificate = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new($Path)
    $imports += Import-CertificateIntoCurrentUserStore -Certificate $certificate -Path $Path -StoreName "TrustedPeople"

    if ($certificate.Subject -eq $certificate.Issuer) {
        $imports += Import-CertificateIntoCurrentUserStore -Certificate $certificate -Path $Path -StoreName "Root"
    }

    return $imports
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
        store = "Cert:\CurrentUser\$StoreName"
        thumbprint = $Certificate.Thumbprint
        added = $added
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

function Remove-ImportedCertificates {
    param([object[]]$Imports)

    foreach ($import in @($Imports)) {
        try {
            $wasAdded = $true
            if ($import.PSObject.Properties["added"]) {
                $wasAdded = [bool]$import.added
            }

            if ($wasAdded -and $import.store -and $import.thumbprint) {
                Remove-Item -LiteralPath ($import.store + "\" + $import.thumbprint) -Force
            }
        }
        catch {
        }
    }
}

$failures = [System.Collections.Generic.List[string]]::new()
$manifest = $null
$manifestDirectory = ""
$resolvedPackagePath = $PackagePath
$resolvedCertificatePath = $CertificatePath
$resolvedPackageName = $PackageName
$certificateImports = @()
$installedPackage = $null
$preexistingPackage = $null
$uiSmokeReportPath = ""

try {
    if ($ManifestPath) {
        $resolvedManifestPath = (Resolve-Path -LiteralPath $ManifestPath).Path
        $manifestDirectory = Split-Path -Parent $resolvedManifestPath
        $manifest = Get-Content -LiteralPath $resolvedManifestPath -Raw | ConvertFrom-Json

        if (-not $resolvedPackagePath -and $manifest.PSObject.Properties["package_path"]) {
            $resolvedPackagePath = [string]$manifest.package_path
        }

        if (-not $resolvedCertificatePath -and $manifest.PSObject.Properties["certificate_path"]) {
            $resolvedCertificatePath = [string]$manifest.certificate_path
        }

        if (-not $resolvedPackageName -and $manifest.PSObject.Properties["package_identity"]) {
            $resolvedPackageName = [string]$manifest.package_identity
        }
    }

    if (-not $resolvedPackagePath) {
        throw "PackagePath or a manifest with package_path is required."
    }

    if ($manifestDirectory) {
        $resolvedPackagePath = Resolve-PathFromManifestDirectory -Path $resolvedPackagePath -ManifestDirectory $manifestDirectory
        $resolvedCertificatePath = Resolve-PathFromManifestDirectory -Path $resolvedCertificatePath -ManifestDirectory $manifestDirectory
    }
    else {
        $resolvedPackagePath = (Resolve-Path -LiteralPath $resolvedPackagePath).Path
        if ($resolvedCertificatePath) {
            $resolvedCertificatePath = (Resolve-Path -LiteralPath $resolvedCertificatePath).Path
        }
    }

    if (-not (Test-Path -LiteralPath $resolvedPackagePath -PathType Leaf)) {
        throw "MSIX package was not found: $resolvedPackagePath"
    }

    if ($resolvedCertificatePath -and -not (Test-Path -LiteralPath $resolvedCertificatePath -PathType Leaf)) {
        throw "MSIX signing certificate was not found: $resolvedCertificatePath"
    }

    if ($resolvedPackageName) {
        $preexistingPackage = Get-AppxPackage -Name $resolvedPackageName -ErrorAction SilentlyContinue
    }

    if ($resolvedCertificatePath) {
        $certificateImports = Import-PackageCertificate -Path $resolvedCertificatePath
    }

    Add-AppxPackage -Path $resolvedPackagePath -ForceUpdateFromAnyVersion

    if ($resolvedPackageName) {
        $installedPackage = Get-AppxPackage -Name $resolvedPackageName -ErrorAction SilentlyContinue
    }
    else {
        $installedPackage = Get-AppxPackage | Where-Object {
            $_.InstallLocation -and
            (Test-Path -LiteralPath (Join-Path $_.InstallLocation "ArchrealmsPassport.Windows.exe") -PathType Leaf)
        } | Sort-Object InstallDate -Descending | Select-Object -First 1
    }

    if (-not $installedPackage) {
        Add-Failure -Failures $failures -Message "The MSIX package was not found after installation."
    }

    if ($installedPackage -and -not $SkipLaunch) {
        $uiSmokeScript = Join-Path $PSScriptRoot "Invoke-PassportWindowsUiSmokeTest.ps1"
        if (-not (Test-Path -LiteralPath $uiSmokeScript -PathType Leaf)) {
            Add-Failure -Failures $failures -Message "UI smoke script was not found."
        }
        else {
            $uiSmokeReportPath = if ($OutputPath) {
                Join-Path (Split-Path -Parent ([System.IO.Path]::GetFullPath($OutputPath))) "msix-ui-smoke-report.json"
            }
            else {
                Join-Path ([System.IO.Path]::GetTempPath()) ("passport-msix-ui-smoke-" + [Guid]::NewGuid().ToString("N") + ".json")
            }

            $uiSmokeArguments = @(
                "-NoProfile",
                "-ExecutionPolicy", "Bypass",
                "-File", $uiSmokeScript,
                "-PackageFamilyName", $installedPackage.PackageFamilyName,
                "-AppId", $AppId,
                "-OutputPath", $uiSmokeReportPath
            )
            if ($StopExisting) {
                $uiSmokeArguments += "-StopExisting"
            }

            & powershell @uiSmokeArguments | Out-Null

            if ($LASTEXITCODE -ne 0) {
                Add-Failure -Failures $failures -Message "The installed MSIX UI smoke test failed."
            }
        }
    }
}
catch {
    Add-Failure -Failures $failures -Message $_.Exception.Message
}
finally {
    if ($UninstallAfter -and $installedPackage -and -not $preexistingPackage) {
        try {
            Remove-AppxPackage -Package $installedPackage.PackageFullName
        }
        catch {
            Add-Failure -Failures $failures -Message ("MSIX cleanup uninstall failed: " + $_.Exception.Message)
        }
    }

    if ($RemoveImportedCertificates) {
        Remove-ImportedCertificates -Imports $certificateImports
    }
}

$report = [pscustomobject]@{
    verified_utc = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
    passed = ($failures.Count -eq 0)
    failures = @($failures)
    manifest_path = if ($ManifestPath) { (Resolve-Path -LiteralPath $ManifestPath).Path } else { "" }
    package_path = $resolvedPackagePath
    certificate_path = $resolvedCertificatePath
    package_name = $resolvedPackageName
    package_preexisted = ($null -ne $preexistingPackage)
    installed_package_full_name = if ($installedPackage) { $installedPackage.PackageFullName } else { "" }
    installed_package_family_name = if ($installedPackage) { $installedPackage.PackageFamilyName } else { "" }
    installed_version = if ($installedPackage) { [string]$installedPackage.Version } else { "" }
    install_location = if ($installedPackage) { $installedPackage.InstallLocation } else { "" }
    launch_validation_skipped = $SkipLaunch.IsPresent
    ui_smoke_report_path = $uiSmokeReportPath
    uninstall_after_requested = $UninstallAfter.IsPresent
    uninstalled_after_validation = ($UninstallAfter.IsPresent -and $installedPackage -and -not $preexistingPackage)
    certificate_imports = $certificateImports
}

if ($OutputPath) {
    $outputDirectory = Split-Path -Parent ([System.IO.Path]::GetFullPath($OutputPath))
    if ($outputDirectory) {
        New-Item -ItemType Directory -Force -Path $outputDirectory | Out-Null
    }

    $report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $OutputPath -Encoding UTF8
}

$report | ConvertTo-Json -Depth 8

if ($failures.Count -gt 0) {
    throw "Passport Windows MSIX install validation failed."
}
