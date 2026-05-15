# Passport Sideload Trust Policy

- Document ID: `<controlled-document-id>`
- Owner: `<release-owner>`
- Approved by: `<approval-id>`
- Effective date: `<yyyy-mm-dd>`

## Scope

This policy applies to controlled sideload distribution of Passport MSIX packages outside Microsoft Store submission.

## Trust Rules

- Sideload clients must trust the certificate chain that signs the package.
- If the signer is self-signed, testers must explicitly install the `.cer` into the appropriate trusted certificate store before installation.
- Self-signed sideload certificates are acceptable only for controlled testing, not broad public distribution unless separately approved.
- Production sideload upgrades must use a stable signer so package identity and update continuity are preserved.
- Certificate rotation must include an upgrade test and a rollback plan.

## User/Tester Instructions

- Publish the package `.msix`, public `.cer`, package manifest, and signing certificate report together.
- Record the certificate thumbprint and SHA-256 in the release notes.
- Do not ask testers to trust an unsigned or unknown package source.

## Validation Evidence

- `production-signing-certificate-report.json`
- `msix-package-manifest.json`
- signed package path and SHA-256
- certificate thumbprint
- trust-installation instructions for controlled sideload testers
