# Passport Production Monetary Provisioning Record

- Document ID: `<controlled-document-id>`
- Owner: `<crown-monetary-authority-owner>`
- Approved by: `<approval-id>`
- Effective date: `<yyyy-mm-dd>`

## Readiness Variables

- `ARCHREALMS_PASSPORT_CC_ISSUER_AUTHORITY_ID=<cc-issuer-authority-id>`
- `ARCHREALMS_PASSPORT_CAPACITY_REPORT_ISSUER_ID=<capacity-report-issuer-id>`
- `ARCHREALMS_PASSPORT_ARCH_GENESIS_MANIFEST_ID=<hosted-arch-genesis-manifest-record-id>`
- `ARCHREALMS_PASSPORT_PRODUCTION_LEDGER_NAMESPACE=archrealms-passport-production-mvp`

## Required Hosted Records

- ARCH genesis manifest created through `POST /arch/genesis/manifests`
- Conservative CC capacity report created through `POST /capacity/reports/cc`

## Monetary Invariants

- ARCH is fixed at genesis.
- No post-genesis ARCH mint path exists.
- CC issuance cannot create ARCH.
- Emergency issuance cannot create ARCH.
- Crown reserve operations cannot create ARCH.
- Crown ARCH reserve can increase only by receiving pre-existing ARCH.
- CC issuance must be constrained by conservative deliverable service capacity.
- Continuity reserve and operational reserve are excluded from CC issuance capacity.
- Thin-market or unqualified capacity authorizes zero CC issuance.

## Approval Evidence

- Genesis authority record SHA-256: `<64-hex-genesis-authority-record-sha256>`
- Allocation policy SHA-256: `<64-hex-allocation-policy-sha256>`
- Vesting or lock policy SHA-256: `<64-hex-vesting-lock-policy-sha256>`
- Treasury policy SHA-256: `<64-hex-treasury-policy-sha256>`
- Genesis ledger hash SHA-256: `<64-hex-genesis-ledger-hash-sha256>`
- Capacity report authority record SHA-256: `<64-hex-capacity-authority-record-sha256>`
- Conservative methodology SHA-256: `<64-hex-conservative-methodology-sha256>`
- Issuance authority record SHA-256: `<64-hex-issuance-authority-record-sha256>`
- Issuance record schema SHA-256: `<64-hex-issuance-record-schema-sha256>`
- No-ARCH-creation validation SHA-256: `<64-hex-no-arch-creation-validation-sha256>`
- Crown monetary authority signoff ID: `<signoff-id>`
- Production release approval ID: `<release-approval-id>`
