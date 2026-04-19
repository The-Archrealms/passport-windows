# passport-windows

`passport-windows` is the standalone Windows Passport client for the Archrealms.

It is a public-facing desktop app and tooling bundle for:

- creating a new Passport identity or requesting authorization under an existing identity
- generating persisted Windows device credentials
- signing Passport challenges
- preparing portable registry submission packages
- publishing registry submission packages to IPFS
- previewing canonical public files from IPFS in read-only mode
- fetching read-only local copies of public IPFS files into the Passport workspace
- initializing and managing a local Kubo node for Passport participation

The repository is published under the [MIT License](LICENSE).

## Current Scope

This repo intentionally focuses on the Windows Passport client and its local tooling.

Included today:

- WPF desktop app under `src/ArchrealmsPassport.Windows`
- Windows packaging project under `src/ArchrealmsPassport.Windows.Package`
- Passport record schema notes under `docs/`
- branding notes and emblem source under `docs/branding.md`
- JSON record templates under `registry/templates/`
- IPFS helper scripts under `tools/ipfs/`
- registry submission publish and verify scripts under `tools/passport/`
- a small verifier helper under `tools/registry-verifier/`

Not included today:

- governance log management
- constitutional ratification tooling
- public registry servers
- Android or web clients
- mesh networking
- token or marketplace systems

## Runtime Model

The app does not write runtime records into the source tree.

By default it uses local app data:

- settings: `%LOCALAPPDATA%\\Archrealms\\PassportWindows\\passport-settings.json`
- workspace: `%LOCALAPPDATA%\\Archrealms\\PassportWindows\\workspace`
- protected device keys: `%LOCALAPPDATA%\\Archrealms\\PassportWindows\\keys`
- default IPFS repo: `%LOCALAPPDATA%\\Archrealms\\PassportWindows\\ipfs\\kubo`

Device key references live under:

- `%LOCALAPPDATA%\\Archrealms\\PassportWindows\\keys`

These are reference files, not exported private keys.

The client now has an explicit Windows Hello path for new device credentials. When the user enables `Use Windows Hello for new device credentials when available`, Passport tries Windows Hello first and falls back to persisted Windows CNG storage if Hello enrollment or signing is unavailable.

Fallback provider preference is:

1. `Microsoft Passport Key Storage Provider`
2. `Microsoft Platform Crypto Provider`
3. `Microsoft Software Key Storage Provider`

If Windows Hello or TPM-backed creation is unavailable, the client falls back to the software KSP while keeping the private key outside the source tree and outside exportable PKCS#8 files.

The workspace contains local Passport records such as:

- `records/registry/identities/`
- `records/registry/device-credentials/`
- `records/registry/join-requests/`
- `records/registry/join-approvals/`
- `records/registry/device-authorizations/`
- `records/registry/signatures/`
- `records/registry/submissions/`
- `records/ipfs-readonly/`
- `records/passport/ipfs-node.local.json`

## Trust Model

Adding a device to an existing Passport identity is a signed ceremony, not a local self-assertion.

- the new device creates a signed join request with its own key
- an already active device for that identity signs a device-authorization package
- the new device imports that approval package and activates only after the authorization record verifies

Registry submission verification now distinguishes:

- `integrity_verified`: the package hashes and manifest signature are internally correct
- `authorization_integrity_verified`: the delegated authorization materials are internally consistent
- `authorization_anchored`: the approving device is present in a trusted Passport workspace or mirrored registry root

Delegated devices should only be treated as fully verified when the package is checked against a trusted workspace anchor.

## Build

This repo is pinned to `.NET 8` via [global.json](global.json). Install a .NET 8 SDK before building.

Build the app:

```powershell
dotnet build .\src\ArchrealmsPassport.Windows\ArchrealmsPassport.Windows.csproj /p:UseSharedCompilation=false
```

Build the verifier helper:

```powershell
dotnet build .\tools\registry-verifier\Archrealms.RegistryVerifier.csproj
```

The project file copies the local `tools/` and `registry/templates/` folders into the app output so the desktop client can use the bundled scripts.

## Smoke Test

Run the end-to-end local smoke test:

```powershell
.\tools\passport\Invoke-ArchrealmsPassportSmokeTest.ps1
```

That script exercises:

- creation of a new identity
- delegated join request and approval
- anchored and unanchored verification of the resulting submission package

It writes a JSON report to a temporary directory by default, or to a custom path if `-OutputPath` is supplied.

## Release Packaging

Create a packaged Windows release bundle:

```powershell
.\tools\release\Publish-PassportWindows.ps1 -RuntimeIdentifier win-x64
```

That produces:

- a published application directory under `artifacts/release/passport-windows-win-x64/publish`
- a zipped bundle under `artifacts/release/passport-windows-win-x64/passport-windows-win-x64.zip`
- a release manifest with file hashes under `artifacts/release/passport-windows-win-x64/release-manifest.json`

Create an `MSIX` installer package:

```powershell
.\tools\release\Publish-PassportWindowsMsix.ps1 -Version v0.1.0 -Platform x64
```

That produces:

- a signed `MSIX` package under `artifacts/release/passport-windows-msix/x64/passport-windows-x64.msix`
- a public signing certificate under `artifacts/release/passport-windows-msix/x64/passport-windows-signing.cer`
- an `MSIX` package manifest with hashes under `artifacts/release/passport-windows-msix/x64/msix-package-manifest.json`

The script publishes the app, assembles a package layout, builds the package with `MakeAppx.exe`, and signs it with `signtool.exe`, so it requires the Windows SDK packaging tools on the machine that runs it. Post-sign verification can be skipped with `-SkipSignatureVerification`, which is the mode used in CI for self-signed preview packages.

The packaging script accepts a stable signing certificate through either:

- `PASSPORT_WINDOWS_MSIX_PFX_BASE64`
- `PASSPORT_WINDOWS_MSIX_PFX_PASSWORD`

If those are not provided, the script falls back to a generated self-signed test certificate. That fallback is suitable for preview and sideload testing, but a stable certificate should be configured before treating `MSIX` upgrades as production-grade.

Create and install a stable release-signing certificate:

```powershell
.\tools\release\New-PassportWindowsReleaseCertificate.ps1
.\tools\release\Set-PassportWindowsReleaseSecrets.ps1 `
  -CertificatePfxPath "$env:LOCALAPPDATA\Archrealms\PassportWindows\release-signing\passport-windows-signing.pfx" `
  -CertificatePassword "<password-returned-by-the-certificate-script>"
```

That stores the persistent signing `PFX` outside the repo, pushes it into the `passport-windows` GitHub repository secrets, and lets all future tagged releases reuse the same signer. If you keep using a self-signed certificate, users will still need the attached `.cer` for sideload trust, but upgrades will remain consistent because the signer stays stable.

GitHub Actions includes:

- `ci.yml` for build plus smoke test on pushes and pull requests
- `release.yml` for packaging a `win-x64` zip bundle, packaging a signed `MSIX`, and creating a GitHub Release on tag push or manual dispatch with a tag input

## IPFS Tooling

Initialize a local Passport IPFS node:

```powershell
.\tools\ipfs\Initialize-ArchrealmsIpfsNode.ps1 -WorkspaceRoot "$env:LOCALAPPDATA\Archrealms\PassportWindows\workspace"
```

Publish a prepared registry submission package:

```powershell
.\tools\passport\Publish-ArchrealmsRegistrySubmissionToIpfs.ps1 `
  -WorkspaceRoot "$env:LOCALAPPDATA\Archrealms\PassportWindows\workspace" `
  -SubmissionPath "<path-to-submission.json>"
```

Preview a public text file directly from IPFS:

```powershell
.\tools\passport\Read-ArchrealmsIpfsText.ps1 `
  -Cid "<bundle-root-cid>" `
  -RelativePath "canonical-manifest.md"
```

Fetch a read-only local copy of a public IPFS file:

```powershell
.\tools\passport\Save-ArchrealmsIpfsFileReadOnly.ps1 `
  -Cid "<bundle-root-cid>" `
  -RelativePath "canonical-manifest.md" `
  -WorkspaceRoot "$env:LOCALAPPDATA\Archrealms\PassportWindows\workspace"
```

Verify a received registry submission package:

```powershell
.\tools\passport\Verify-ArchrealmsRegistrySubmission.ps1 -SubmissionPath "<path-to-submission.json>"
```

Verify a delegated submission package against a trusted workspace root:

```powershell
.\tools\passport\Verify-ArchrealmsRegistrySubmission.ps1 `
  -SubmissionPath "<path-to-submission.json>" `
  -TrustedWorkspaceRoot "$env:LOCALAPPDATA\Archrealms\PassportWindows\workspace"
```

If your machine has multiple `dotnet` installations and the default `dotnet` on `PATH` is not .NET 8, pass an explicit SDK path or set an environment override:

```powershell
$env:ARCHREALMS_DOTNET = "C:\path\to\dotnet.exe"
.\tools\passport\Verify-ArchrealmsRegistrySubmission.ps1 -SubmissionPath "<path-to-submission.json>"
```

## Repository Layout

```text
passport-windows/
  docs/
  registry/templates/
  src/ArchrealmsPassport.Windows/
  src/ArchrealmsPassport.Windows.Package/
  tools/ipfs/
  tools/passport/
  tools/registry-verifier/
```
