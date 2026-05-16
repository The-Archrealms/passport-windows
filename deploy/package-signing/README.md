# Passport Package Signing Provisioning

This folder contains reviewable templates for the `ProductionMvp` package-signing gate. It supports both controlled sideload distribution and Microsoft Store packaging.

The readiness gate is still enforced by:

```powershell
.\tools\release\Test-PassportWindowsSigningCertificate.ps1
.\tools\release\Test-PassportProductionMvpReadiness.ps1
```

These templates define the operator decisions and evidence that should exist before `PASSPORT_WINDOWS_MSIX_PFX_BASE64` or `PASSPORT_WINDOWS_MSIX_PFX_PATH` is loaded into a production environment.

Validate the template package:

```powershell
.\tools\release\Test-PassportPackageSigningProvisioning.ps1
```

Validate completed production copies:

```powershell
.\tools\release\Test-PassportPackageSigningProvisioning.ps1 `
  -PackageSigningPath C:\secure\archrealms-passport-package-signing `
  -RequireNoPlaceholders
```

Required production readiness variables:

- `PASSPORT_WINDOWS_MSIX_PFX_BASE64` or `PASSPORT_WINDOWS_MSIX_PFX_PATH`
- `PASSPORT_WINDOWS_MSIX_PFX_PASSWORD`
- `PASSPORT_WINDOWS_MSIX_PUBLISHER`
- `PASSPORT_WINDOWS_MSIX_TIMESTAMP_URL`

Prefer local secret files for operator validation so PFX passwords are not placed in command history or committed environment files:

```powershell
.\tools\release\Test-PassportWindowsSigningCertificate.ps1 `
  -PfxPath C:\secure\archrealms-passport\passport-windows-signing.pfx `
  -PasswordFile C:\secure\archrealms-passport\passport-windows-signing.password.txt `
  -ExpectedPublisher "CN=The Archrealms" `
  -TimestampUrl https://timestamp.example.invalid `
  -OutputPath .\artifacts\release\production-signing-certificate-report.json
```

Controlled sideload test certificates can be generated locally when approved:

```powershell
.\tools\release\New-PassportWindowsReleaseCertificate.ps1 `
  -OutputDirectory C:\secure\archrealms-passport\sideload-signing `
  -Subject "CN=The Archrealms"
```

The generated metadata records the `.pfx`, `.cer`, and password-file paths. It does not include the password unless `-IncludePasswordInMetadata` is explicitly supplied.

When loading GitHub Actions secrets for the release workflow, prefer the password-file form:

```powershell
.\tools\release\Set-PassportWindowsReleaseSecrets.ps1 `
  -CertificatePfxPath C:\secure\archrealms-passport\passport-windows-signing.pfx `
  -CertificatePasswordFile C:\secure\archrealms-passport\passport-windows-signing.password.txt
```

Controlled sideload testing may use a self-signed certificate only when the release approval explicitly accepts client trust installation. Production public sideload distribution should use a stable organization-controlled signing certificate or another approved signing authority so upgrades remain consistent.
