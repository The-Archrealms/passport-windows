# Passport Store Signing Policy

- Document ID: `<controlled-document-id>`
- Owner: `<store-release-owner>`
- Approved by: `<approval-id>`
- Effective date: `<yyyy-mm-dd>`

## Scope

This policy applies to Microsoft Store package candidates created with:

```powershell
Publish-PassportWindowsMsix.ps1 -Lane ProductionMvp -Channel Store -EnvironmentFile <production-env>
```

## Partner Center Inputs

- Package identity name: `<partner-center-package-identity>`
- Publisher display name: `<publisher-display-name>`
- Publisher subject or ID: `<publisher-subject-or-id>`
- Store submission owner: `<submission-owner>`
- Store metadata approval ID: `<approval-id>`

## Store Candidate Rules

- Store-channel packages must use Partner Center identity values when available.
- Store artifacts must remain separate from public sideload release artifacts until approved.
- Store submission must use the same production release approval set as the sideload release when both channels are used for the same build.
- Store-specific rejection or metadata changes must be recorded before resubmission.

## Validation Evidence

- Store-channel MSIX artifact path and SHA-256
- package manifest validation report
- Partner Center identity record
- Store metadata approval record
- production readiness report hash
