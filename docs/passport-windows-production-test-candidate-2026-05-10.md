# Passport Windows Production-Test Candidate

- Status: ready for production testing
- Validated UTC: 2026-05-11T03:35Z
- Scope: Windows Passport local-node MVP, zip, sideload MSIX, and Store-channel MSIX candidate artifacts

## Candidate Artifacts

- Zip: `artifacts/release/passport-windows-win-x64/passport-windows-win-x64.zip`
- Zip SHA-256: `E7C48BA1098D484F791F697E3EC6DF50CEC651D83C5E3A9E69A98D3DE080F280`
- Sideload MSIX: `artifacts/release/passport-windows-msix-sideload/x64/passport-windows-sideload-x64.msix`
- Sideload MSIX SHA-256: `5239859A4B8BA503E4BBF81EEB3A841F55AFACF3B121A087A0440F926A66D96D`
- Store-channel MSIX candidate: `artifacts/release/passport-windows-msix-store/x64/passport-windows-store-x64.msix`
- Store-channel MSIX candidate SHA-256: `29A8F155E90E9D9A4429C8BCFE2E55E4E7BC85CAEDF3C06EAC1A7882BEA8EC88`

## Automated Validation Passed

- `dotnet build src/ArchrealmsPassport.Windows/ArchrealmsPassport.Windows.csproj -c Release`
- `powershell -NoProfile -ExecutionPolicy Bypass -File tools/passport/Invoke-ArchrealmsPassportSmokeTest.ps1`
- `dotnet build tools/registry-verifier/Archrealms.RegistryVerifier.csproj -c Release`
- `powershell -NoProfile -ExecutionPolicy Bypass -File tools/release/Test-PassportWindowsReleaseArtifact.ps1 -ManifestPath artifacts/release/passport-windows-win-x64/release-manifest.json -RequireBundledIpfs`
- `powershell -NoProfile -ExecutionPolicy Bypass -File tools/release/Invoke-PassportWindowsInstalledArtifactValidation.ps1 -ManifestPath artifacts/release/passport-windows-win-x64/release-manifest.json -OutputPath artifacts/release/passport-windows-win-x64/installed-validation-report.json`
- `powershell -NoProfile -ExecutionPolicy Bypass -File tools/release/Test-PassportWindowsReleaseArtifact.ps1 -ManifestPath artifacts/release/passport-windows-msix-sideload/x64/msix-package-manifest.json -RequireBundledIpfs`
- `powershell -NoProfile -ExecutionPolicy Bypass -File tools/release/Invoke-PassportWindowsInstalledArtifactValidation.ps1 -ManifestPath artifacts/release/passport-windows-msix-sideload/x64/msix-package-manifest.json -OutputPath artifacts/release/passport-windows-msix-sideload/x64/installed-validation-report.json`
- `powershell -NoProfile -ExecutionPolicy Bypass -File tools/release/Test-PassportWindowsReleaseArtifact.ps1 -ManifestPath artifacts/release/passport-windows-msix-store/x64/msix-package-manifest.json -RequireBundledIpfs`
- `powershell -NoProfile -ExecutionPolicy Bypass -File tools/release/Invoke-PassportWindowsInstalledArtifactValidation.ps1 -ManifestPath artifacts/release/passport-windows-msix-store/x64/msix-package-manifest.json -OutputPath artifacts/release/passport-windows-msix-store/x64/installed-validation-report.json`
- UI startup probe after binding/tray fixes: release executable stayed running without new `.NET Runtime`, `Application Error`, or `Windows Error Reporting` events.
- Storage provisioning crash fixed: command completion now raises WPF command-state changes on the UI dispatcher instead of a background thread.
- First-run identity mode simplified: the visible Identity Mode picker was removed and new Passport identities now default to normal named mode.
- Tray behavior added: minimizing the Passport window hides it from the taskbar, keeps it running in the system tray, restores on tray-icon double-click or `Open Archrealms Passport`, and exits from the tray `Exit` menu.

## Installed-Artifact Evidence

All installed-artifact reports passed with:

- bundled Kubo: `ipfs version 0.41.0`
- storage max: `5GB`
- storage GC watermark: `80`
- provide strategy: `pinned`
- participation mode: `Public archive contributor`
- cache policy: `Balanced pinned archive`
- daemon stopped cleanly: `true`

## Production Test Entry

Begin production testing with a clean Windows machine or VM. The first pass should install one artifact at a time, complete first-run Passport onboarding, confirm local node initialization/startup, publish a registry submission package, preview/fetch a public CID, export a CAR, and record a node capacity snapshot with each participation/cache profile.

Use the sideload MSIX for external sideload testing. The Store-channel MSIX candidate is structurally validated but should be rebuilt with final Partner Center package identity and publisher values before submission.
