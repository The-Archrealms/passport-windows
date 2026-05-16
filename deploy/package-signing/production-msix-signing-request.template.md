# Passport Production MSIX Signing Request

- Document ID: `<controlled-document-id>`
- Owner: `<release-engineering-owner>`
- Approved by: `<approval-id>`
- Effective date: `<yyyy-mm-dd>`

## Package Identity

- Release lane: `ProductionMvp`
- Channel: `Sideload` and/or `Store`
- Package publisher: `PASSPORT_WINDOWS_MSIX_PUBLISHER=CN=The Archrealms`
- Package identity: `<production-package-identity>`
- Expected artifact command: `Publish-PassportWindowsMsix.ps1 -Lane ProductionMvp -EnvironmentFile <production-env>`

## Certificate Requirements

- Private key available to secure signing environment: required
- Enhanced key usage: Code Signing (`1.3.6.1.5.5.7.3.3`)
- Key algorithm: RSA or approved equivalent
- Minimum key size: `<key-size>`
- Hash algorithm: SHA-256 or stronger
- Minimum remaining validity at release: at least 30 days
- Timestamp URL: `PASSPORT_WINDOWS_MSIX_TIMESTAMP_URL=<timestamp-url>`
- Publisher-subject match: certificate subject must match `PASSPORT_WINDOWS_MSIX_PUBLISHER`

## Source And Custody

- Signing path: `<public-ca | enterprise-root-sideload | store-submission | other-approved-path>`
- Certificate provider or authority: `<provider-or-authority>`
- Organization validation evidence: `<controlled-document-id-or-uri>`
- PFX storage location: `<secret-store-reference>`
- PFX password storage location: `<secret-store-reference>`
- Export policy: `<export-policy>`
- Renewal owner: `<renewal-owner>`

## Required Validation

Before ProductionMvp packaging:

```powershell
.\tools\release\Test-PassportWindowsSigningCertificate.ps1 `
  -PfxPath <approved-msix-signing-pfx-path> `
  -PasswordFile <approved-msix-signing-password-file> `
  -ExpectedPublisher "CN=The Archrealms" `
  -TimestampUrl <timestamp-url> `
  -OutputPath .\artifacts\release\production-signing-certificate-report.json
```

The report must return `passed=true`. If `self_signed=true`, release approval must explicitly limit use to controlled sideload testing and require client trust installation.

If the release lane uses an environment file, the same values must also be present as `PASSPORT_WINDOWS_MSIX_PFX_PATH` or `PASSPORT_WINDOWS_MSIX_PFX_BASE64`, `PASSPORT_WINDOWS_MSIX_PFX_PASSWORD`, `PASSPORT_WINDOWS_MSIX_PUBLISHER`, and `PASSPORT_WINDOWS_MSIX_TIMESTAMP_URL` before the `ProductionMvp` readiness gate or MSIX publishing run is executed.
