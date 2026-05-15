# Managed Signing Key Custody Request

- Request ID: `<managed-signing-custody-request-id>`
- Lane: `ProductionMvp`
- Request owner: `<owner>`
- Provider: `<ARCHREALMS_PASSPORT_HOSTED_SIGNING_KEY_PROVIDER>`
- Key ID: `<ARCHREALMS_PASSPORT_HOSTED_SIGNING_KEY_ID>`
- Custody mode: `<ARCHREALMS_PASSPORT_HOSTED_SIGNING_KEY_CUSTODY>`
- Signing endpoint: `<ARCHREALMS_PASSPORT_HOSTED_SIGNING_ENDPOINT>`

## Key Requirements

- Custody mode must be `managed`, `kms`, `hsm`, `managed-hsm`, or `cloud-kms`.
- Private key material must not be exportable into hosted service configuration.
- Hosted services must call the managed signing endpoint rather than loading a local signing key.
- The endpoint must return `local_validation_only=false`.
- The endpoint must return `signing_key_provider`, `signing_key_id`, and `signing_key_custody` matching the ProductionMvp environment.
- Allowed signing purposes must include `production_mvp_readiness_probe`, `hosted_record`, `cc_capacity_report`, `arch_genesis_manifest`, `storage_delivery_acceptance`, `hosted_storage_backup_manifest`, `hosted_incident_report`, `recovery_control_validation`, `telemetry_access`, and `ai_feedback`.

## Approval Evidence

- Key creation or import approval reference: `<approval-id>`
- Custody provider attestation reference: `<attestation-id>`
- Rotation policy reference: `<rotation-policy-id>`
- Break-glass policy reference: `<break-glass-policy-id>`
- Managed signing endpoint deployment validation report: `artifacts/release/managed-signing-deployment-validation-report.json`
