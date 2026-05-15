# Passport Production Release Approval Record

- Document ID: `<controlled-document-id>`
- Release lane: `ProductionMvp`
- Candidate app commit: `<git-commit>`
- Pre-MVP verification report SHA-256: `<sha256>`
- Production readiness report SHA-256: `<sha256>`

## Required Approval IDs

- Product approval: `ARCHREALMS_PASSPORT_PRODUCTION_RELEASE_APPROVAL_ID=<approval-id>`
- Engineering signoff: `ARCHREALMS_PASSPORT_ENGINEERING_SIGNOFF_ID=<approval-id>`
- Security/privacy signoff: `ARCHREALMS_PASSPORT_SECURITY_PRIVACY_SIGNOFF_ID=<approval-id>`
- Crown monetary authority signoff: `ARCHREALMS_PASSPORT_CROWN_MONETARY_AUTHORITY_SIGNOFF_ID=<approval-id>`

## Approval Checklist

- Pre-MVP internal verification passed and hash is recorded.
- Production package signing certificate report passed.
- Hosted API and AI gateway readiness endpoints returned `ready=true`.
- Managed storage and backup/restore documents are approved.
- Managed signing endpoint returned `local_validation_only=false`.
- ARCH genesis, CC issuer, capacity-report issuer, and ledger namespace IDs are configured.
- Open-weight AI runtime, model artifact hash, license approval, vector store, and knowledge approval root are configured.
- Telemetry retention and incident response documents are approved.
- Production readiness gate returned `ready=true`.
