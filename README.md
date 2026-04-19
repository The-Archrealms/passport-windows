# passport-windows

`passport-windows` is the standalone Windows Passport client for the Archrealms.

It is a public-facing desktop app and tooling bundle for:

- creating a new Passport identity or requesting authorization under an existing identity
- generating persisted Windows device credentials
- signing Passport challenges
- preparing portable registry submission packages
- publishing registry submission packages to IPFS
- initializing and managing a local Kubo node for Passport participation

## Current Scope

This repo intentionally focuses on the Windows Passport client and its local tooling.

Included today:

- WPF desktop app under `src/ArchrealmsPassport.Windows`
- Passport record schema notes under `docs/`
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

These are reference files, not exported private keys. New Passport device credentials are created as persisted Windows CNG keys with provider preference in this order:

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

Build the app:

```powershell
dotnet build .\src\ArchrealmsPassport.Windows\ArchrealmsPassport.Windows.csproj /p:UseSharedCompilation=false
```

Build the verifier helper:

```powershell
dotnet build .\tools\registry-verifier\Archrealms.RegistryVerifier.csproj
```

The project file copies the local `tools/` and `registry/templates/` folders into the app output so the desktop client can use the bundled scripts.

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

## Repository Layout

```text
passport-windows/
  docs/
  registry/templates/
  src/ArchrealmsPassport.Windows/
  tools/ipfs/
  tools/passport/
  tools/registry-verifier/
```
