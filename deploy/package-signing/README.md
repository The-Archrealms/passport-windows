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

Controlled sideload testing may use a self-signed certificate only when the release approval explicitly accepts client trust installation. Production public sideload distribution should use a stable organization-controlled signing certificate or another approved signing authority so upgrades remain consistent.
