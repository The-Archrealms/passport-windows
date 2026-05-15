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
- exporting a CID to a local CAR archive from inside Passport
- initializing and managing a local Kubo node for Passport participation

The repository is published under the [MIT License](LICENSE).

## Current Scope

This repo intentionally focuses on the Windows Passport client and its local tooling.

Included today:

- WPF desktop app under `src/ArchrealmsPassport.Windows`
- Windows packaging project under `src/ArchrealmsPassport.Windows.Package`
- Passport record schema notes under `docs/`
- local node MVP plan under `docs/archrealms-passport-local-node-mvp-plan-2026-04-19.md`
- app-level `LocalNodeService` abstraction for node initialization, daemon lifecycle control, registry submission publication, read-only IPFS access, standalone CAR export, diagnostics, and local health probing
- Passport metering and settlement roadmap under `docs/archrealms-passport-metering-and-settlement-roadmap-2026-04-26.md`
- Passport metering admission policy under `docs/archrealms-passport-metering-admission-policy-2026-04-27.md`
- Passport blockchain settlement interface under `docs/archrealms-passport-blockchain-settlement-interface-2026-04-30.md`
- Passport blockchain selection and contract criteria under `docs/archrealms-passport-blockchain-selection-and-contract-criteria-2026-04-30.md`
- Passport metering record schema notes under `docs/archrealms-passport-metering-record-schemas-2026-04-26.md`
- branding notes and emblem source under `docs/branding.md`
- JSON record templates under `registry/templates/`
- IPFS helper scripts under `tools/ipfs/`
- registry submission publish and verify scripts under `tools/passport/`
- a small verifier helper under `tools/registry-verifier/`
- a local metering verifier helper under `tools/metering-verifier/`
- a monetary ledger export verifier under `tools/ledger-verifier/`

Not included today:

- governance log management
- constitutional ratification tooling
- public registry servers
- Android or web clients
- mesh networking
- public token, wallet, redemption, trading, or marketplace systems

The current economy-facing path is proof and metering first. Public economy-facing release is gated on blockchain-based settlement finality. Until that layer exists, Passport may build proof, metering, admission, and settlement-handoff inputs, but it must not present local records as final settlement.

The first metering verifier is local and narrow. `Verify-ArchrealmsPassportMetering.ps1` reads a Passport workspace, verifies signed metering payloads and device signatures, and emits an authoritative-style metering report with accepted/rejected proof counts. It does not settle value.

The first monetary ledger verifier is also local and narrow. `Verify-ArchrealmsPassportMonetaryExport.ps1` verifies a Passport account export by checking event file hashes, account hash chains, Merkle inclusion proofs, the transparency root, replay-derived balances, and exported wallet key-history material. It does not provide public-chain anchoring or external settlement finality.

Metering reports can be packaged for registrar/admission review with `New-ArchrealmsPassportMeteringPackage.ps1` and verified with `Verify-ArchrealmsPassportMeteringPackage.ps1`. The package format preserves the authoritative metering report, referenced source records, signed payloads, detached signatures, and a manifest of document hashes.

Verified metering report packages can now be admitted with `New-ArchrealmsPassportMeteringAdmission.ps1` and checked with `Verify-ArchrealmsPassportMeteringAdmission.ps1`. Admission creates a signed `passport_metering_admission_record` for registrar-side review and keeps `settlement_status` at `not_settled`. Later handoff records are intended as inputs to blockchain settlement, not substitutes for it.

Admitted metering packages can now produce signed audit challenges with `New-ArchrealmsPassportMeteringAuditChallenge.ps1`. Signed review records can be checked with `Verify-ArchrealmsPassportSignedReviewRecord.ps1`.

Audit challenges can now produce signed dispute records with `New-ArchrealmsPassportMeteringDispute.ps1`. Disputes open review over admitted evidence while preserving `settlement_status` at `not_settled`.

Disputes can now produce signed correction records with `New-ArchrealmsPassportMeteringCorrection.ps1`. Corrections supersede admitted review totals by reference and preserve original evidence records unchanged.

Corrected review packages can now produce signed settlement handoff records with `New-ArchrealmsPassportMeteringSettlementHandoff.ps1`. Handoffs mark evidence as eligible, held, or rejected for future blockchain settlement review; they are not settlement.

Settlement handoff records can now be consumed by `New-ArchrealmsPassportMockBlockchainSettlement.ps1` to create simulated `blockchain_settlement_batch_record` and read-only `blockchain_settlement_status_record` outputs for Passport read-path testing. This is mock finality only and is not real chain settlement.

Candidate settlement chains can now be recorded with `New-ArchrealmsPassportBlockchainSettlementChainEvaluation.ps1` and checked with `Verify-ArchrealmsPassportBlockchainSettlementChainEvaluation.ps1`. These evaluation records compute whether the release gate is satisfied; they do not select or approve a real chain by themselves.

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

Passport can also prefer a bundled local IPFS runtime when one is shipped with the release. Release packaging now defaults to a pinned official Kubo download, verifies the archive hash, and stages `ipfs.exe` plus Kubo license files under `tools/ipfs/runtime/`. The app resolves the IPFS CLI in this order:

1. configured runtime override in Passport settings
2. `ARCHREALMS_IPFS_CLI`
3. bundled runtime under `tools/ipfs/runtime/`
4. `ipfs.exe` on `PATH`
5. IPFS Desktop Kubo locations

The desktop UI now routes local-node actions through `LocalNodeService` instead of binding button handlers directly to individual script paths. The service currently covers node initialization, daemon start/stop/restart, registry-submission publication, read-only IPFS preview/fetch, diagnostics, and health status. Health status checks runtime detection, repo/node-record presence, and local API reachability when the daemon is running.

During onboarding, Passport can initialize and start the local node automatically after a new identity is created or a join approval is imported. That bootstrap is controlled by the `Initialize and start local node during onboarding` setting and is non-blocking for identity activation: if no IPFS runtime is available, Passport records the recovery message and the user can retry from the local-node buttons after runtime setup.

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
- `records/ipfs-car-exports/`
- `records/passport/ipfs-node.local.json`
- `records/passport/node-activity/`
- `records/passport/metering/proofs/`
- `records/passport/metering/submissions/`
- `records/passport/metering/status/`
- `records/passport/metering/admissions/`
- `records/passport/settlement/chain-evaluations/`
- `records/passport/settlement/mock-chain/`
- `records/passport/settlement/read-only/`

The metering and settlement workspace paths are reserved for proof records and read-only status. They are not final blockchain settlement, wallet, redemption, trading, or public token records.

The app includes first metering actions:

- `Record Node Capacity Snapshot` writes a signed local `node_capacity_snapshot_record`.
- `Acknowledge Storage Assignment` writes a signed local `storage_assignment_acknowledgment_record`.
- `Create Storage Epoch Proof` writes a signed local `storage_epoch_proof_record` from deterministic segment hashes of a user-selected proof source file.
- `Create Local Metering Status` writes a local read-only `metering_status_record` summarizing submitted proof claims without accepting or settling them.
- `Verify Local Metering Records` writes a local verification report checking signed payload hashes and device signatures for local metering records.

These are metering input records only; they do not create payouts, wallet balances, tokens, or settlement claims. The storage epoch proof is submitted local evidence; later network metering still decides whether it is accepted, rejected, audited, or settled.

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

Build the registry verifier helper:

```powershell
dotnet build .\tools\registry-verifier\Archrealms.RegistryVerifier.csproj
```

Build the monetary ledger verifier helper:

```powershell
dotnet build .\tools\ledger-verifier\Archrealms.LedgerVerifier.csproj /m:1 /nr:false /p:UseSharedCompilation=false
```

The project file copies the local `tools/` and `registry/templates/` folders into the app output so the desktop client can use the bundled scripts.

## Automated Tests

Run the C# unit and service integration suite:

```powershell
dotnet test .\tests\ArchrealmsPassport.Windows.Tests\ArchrealmsPassport.Windows.Tests.csproj -c Release /m:1 /nr:false /p:UseSharedCompilation=false
```

The suite uses isolated temporary workspaces and covers command dispatching, IPFS runtime resolution, challenge signing, registry submission packaging, local storage metering records, tamper detection, and metering admission/review/handoff records.

Run the WPF UI smoke check against a local executable:

```powershell
.\tools\release\Invoke-PassportWindowsUiSmokeTest.ps1 `
  -ExecutablePath .\src\ArchrealmsPassport.Windows\bin\Release\net8.0-windows10.0.19041.0\ArchrealmsPassport.Windows.exe `
  -StopExisting `
  -ExerciseTrayMinimize
```

The UI smoke check launches Passport, verifies the main window and key controls through Windows UI Automation, optionally exercises minimize-to-tray, and fails if new Passport runtime crash events appear.

## Smoke Test

Run the end-to-end local smoke test:

```powershell
.\tools\passport\Invoke-ArchrealmsPassportSmokeTest.ps1
```

That script exercises:

- creation of a new identity
- delegated join request and approval
- anchored and unanchored verification of the resulting submission package
- local metering record creation for node capacity, assignment acknowledgment, storage epoch proof, local metering status, and local metering integrity verification
- authoritative local metering verification for submitted proof records
- metering report package creation and verification
- metering admission, audit challenge, dispute, correction, and settlement handoff creation and verification
- mock blockchain settlement batch and read-only status creation and verification
- dev-only blockchain settlement chain evaluation creation and verification

It writes a JSON report to a temporary directory by default, or to a custom path if `-OutputPath` is supplied.

## Release Packaging

Create a packaged Windows release bundle:

```powershell
.\tools\release\Publish-PassportWindows.ps1 -RuntimeIdentifier win-x64
```

Release packaging is lane-aware. The default lane is `Staging`, which writes `passport-release-lane.json` into the artifact, uses the `archrealms-passport-staging` ledger namespace, and keeps runtime settings and keys under a staging-specific app data root. Supported lanes are `Dev`, `InternalVerification`, `Staging`, `CanaryMvp`, and `ProductionMvp`.

```powershell
.\tools\release\Publish-PassportWindows.ps1 `
  -RuntimeIdentifier win-x64 `
  -Lane Staging
```

To force inclusion of a specific local `ipfs.exe` in the published Passport bundle:

```powershell
.\tools\release\Publish-PassportWindows.ps1 `
  -RuntimeIdentifier win-x64 `
  -IpfsCliPath "C:\path\to\ipfs.exe"
```

If `-IpfsCliPath` and `ARCHREALMS_IPFS_CLI` are not set, the release script downloads pinned Kubo for the target Windows platform from `dist.ipfs.tech`, verifies SHA-512 from the official distribution metadata, and bundles it under `tools/ipfs/runtime/`. Use `-SkipIpfsRuntimeBootstrap` only when intentionally producing an artifact that depends on an external IPFS runtime.

That produces:

- a published application directory under `artifacts/release/passport-windows-win-x64/publish`
- a lane-specific zipped bundle, such as `artifacts/release/passport-windows-win-x64/passport-windows-win-x64-staging.zip`
- a release manifest with file hashes under `artifacts/release/passport-windows-win-x64/release-manifest.json`
- a runtime lane manifest under `artifacts/release/passport-windows-win-x64/publish/passport-release-lane.json`

Validate the zip artifact before handing it to testers:

```powershell
.\tools\release\Test-PassportWindowsReleaseArtifact.ps1 `
  -ManifestPath .\artifacts\release\passport-windows-win-x64\release-manifest.json `
  -RequireBundledIpfs
```

Validate the installed artifact behavior before handoff:

```powershell
.\tools\release\Invoke-PassportWindowsInstalledArtifactValidation.ps1 `
  -ManifestPath .\artifacts\release\passport-windows-win-x64\release-manifest.json `
  -OutputPath .\artifacts\release\passport-windows-win-x64\installed-validation-report.json
```

Create a sideload `MSIX` installer package:

```powershell
.\tools\release\Publish-PassportWindowsMsix.ps1 -Channel Sideload -Version v0.1.0 -Platform x64
```

To bundle a specific local `ipfs.exe` into the sideload `MSIX` package:

```powershell
.\tools\release\Publish-PassportWindowsMsix.ps1 `
  -Channel Sideload `
  -Version v0.1.0 `
  -Platform x64 `
  -IpfsCliPath "C:\path\to\ipfs.exe"
```

If no explicit IPFS CLI path is supplied, the `MSIX` path uses the same pinned Kubo download and hash verification as the zip release path.

That produces:

- a signed lane-specific sideload `MSIX` package under `artifacts/release/passport-windows-msix-sideload/x64`, such as `passport-windows-sideload-staging-x64.msix`
- a public signing certificate under `artifacts/release/passport-windows-msix-sideload/x64/passport-windows-signing.cer`
- an `MSIX` package manifest with hashes under `artifacts/release/passport-windows-msix-sideload/x64/msix-package-manifest.json`

Validate the `MSIX` layout and manifest before handoff:

```powershell
.\tools\release\Test-PassportWindowsReleaseArtifact.ps1 `
  -ManifestPath .\artifacts\release\passport-windows-msix-sideload\x64\msix-package-manifest.json `
  -RequireBundledIpfs
```

Validate the installed `MSIX` artifact behavior before handoff:

```powershell
.\tools\release\Invoke-PassportWindowsInstalledArtifactValidation.ps1 `
  -ManifestPath .\artifacts\release\passport-windows-msix-sideload\x64\msix-package-manifest.json `
  -OutputPath .\artifacts\release\passport-windows-msix-sideload\x64\installed-validation-report.json
```

Validate that the sideload `MSIX` can be trusted and installed by Windows:

```powershell
.\tools\release\Invoke-PassportWindowsMsixInstallValidation.ps1 `
  -ManifestPath .\artifacts\release\passport-windows-msix-sideload\x64\msix-package-manifest.json `
  -OutputPath .\artifacts\release\passport-windows-msix-sideload\x64\msix-install-validation-report.json `
  -SkipLaunch
```

The script publishes the app, assembles a package layout, builds the package with `MakeAppx.exe`, and signs it with `signtool.exe`, so it requires the Windows SDK packaging tools on the machine that runs it. Post-sign verification can be skipped with `-SkipSignatureVerification`, which is the mode used in CI for self-signed preview packages.

The `MSIX` script supports separate channels:

- `Sideload`: defaults to a lane-scoped package identity, for example `TheArchrealms.PassportWindows.Staging.Sideload`, and output root `artifacts/release/passport-windows-msix-sideload`
- `Store`: defaults to a lane-scoped package identity, for example `TheArchrealms.PassportWindows.Staging`, and output root `artifacts/release/passport-windows-msix-store`

Use `-Lane ProductionMvp` only for an approved production MVP build. `ProductionMvp` uses the production app data root and package identity defaults. `Staging`, `InternalVerification`, and `Dev` are non-production lanes and release validation fails if their lane manifest allows production token records.

For a Microsoft Store package candidate, use Partner Center values when they are available:

```powershell
.\tools\release\Publish-PassportWindowsMsix.ps1 `
  -Channel Store `
  -Version v0.1.0 `
  -Platform x64 `
  -PackageIdentityName "<Partner Center package identity>" `
  -PackagePublisher "<Partner Center publisher>"
```

GitHub Actions can receive the same Store values through repository variables:

- `PASSPORT_WINDOWS_STORE_PACKAGE_IDENTITY`
- `PASSPORT_WINDOWS_STORE_PUBLISHER`
- `PASSPORT_WINDOWS_STORE_PUBLISHER_DISPLAY_NAME`

The Store channel is for Partner Center submission and internal validation. The GitHub Release uploads the sideload `MSIX` and zip bundle; Store packages are uploaded as workflow artifacts instead of public release files.

The packaging script accepts a stable signing certificate through either:

- `PASSPORT_WINDOWS_MSIX_PFX_BASE64`
- `PASSPORT_WINDOWS_MSIX_PFX_PASSWORD`

If those are not provided, the script falls back to a generated self-signed test certificate. That fallback is suitable for preview and sideload testing, but a stable certificate should be configured before treating public sideload `MSIX` upgrades as production-grade.

Production MVP packages are gated by `tools\release\Test-PassportProductionMvpReadiness.ps1`. `Publish-PassportWindowsMsix.ps1 -Lane ProductionMvp` runs this gate automatically unless `-SkipProductionMvpReadinessGate` is supplied. The gate emits `production-mvp-readiness-report.json` and fails until package signing, production endpoints, hosted operator controls, managed storage/backups, managed key custody, issuer/capacity/genesis authority IDs, open-weight AI runtime/vector store, telemetry/incident response, and release approvals are configured. When production API and AI gateway URLs are present, the gate also calls `/ops/runtime/status` and `/ai/runtime/status` and requires both to return `ready=true`.

Run the gate directly:

```powershell
.\tools\release\Test-PassportProductionMvpReadiness.ps1 `
  -EnvironmentFile .\artifacts\release\production-mvp.env `
  -PackageSigningConfigured 1 `
  -TimestampConfigured 1 `
  -EndpointTimeoutSeconds 10 `
  -OutputPath .\artifacts\release\production-mvp-readiness-report.json
```

Generate a production MVP environment template before wiring secrets or deployment variables:

```powershell
.\tools\release\New-PassportProductionMvpEnvironmentTemplate.ps1 `
  -Format Env `
  -OutputPath .\artifacts\release\production-mvp.env.template
```

The template lists each readiness-gate variable, whether it is secret, and the gate it satisfies. Populate values only in a secure shell, CI secret store, or deployment environment; populated `.env` files are ignored by git and can be passed to the readiness gate or production package publisher with `-EnvironmentFile`.

Package with the same production environment file after the gate is ready:

```powershell
.\tools\release\Publish-PassportWindowsMsix.ps1 `
  -Lane ProductionMvp `
  -EnvironmentFile .\artifacts\release\production-mvp.env
```

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
- `release.yml` for packaging a `win-x64` zip bundle, packaging sideload and Store-channel `MSIX` candidates, and creating a GitHub Release on tag push or manual dispatch with a tag input

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

Export a public CID to a local CAR archive:

```powershell
.\tools\ipfs\Export-ArchrealmsIpfsCar.ps1 `
  -Cid "<bundle-root-cid>" `
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

Verify submitted Passport metering records:

```powershell
.\tools\passport\Verify-ArchrealmsPassportMetering.ps1 `
  -WorkspaceRoot "$env:LOCALAPPDATA\Archrealms\PassportWindows\workspace"
```

Package and verify an authoritative metering report:

```powershell
.\tools\passport\New-ArchrealmsPassportMeteringPackage.ps1 `
  -WorkspaceRoot "$env:LOCALAPPDATA\Archrealms\PassportWindows\workspace"

.\tools\passport\Verify-ArchrealmsPassportMeteringPackage.ps1 `
  -PackageRoot "$env:LOCALAPPDATA\Archrealms\PassportWindows\workspace\records\passport\metering\packages\<package-id>"
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
