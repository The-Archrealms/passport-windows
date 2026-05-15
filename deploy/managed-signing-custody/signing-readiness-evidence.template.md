# Managed Signing Readiness Evidence

- Evidence ID: `<managed-signing-readiness-evidence-id>`
- Lane: `ProductionMvp`
- Created UTC: `<yyyy-mm-ddThh:mm:ssZ>`
- Provider: `<ARCHREALMS_PASSPORT_HOSTED_SIGNING_KEY_PROVIDER>`
- Key ID: `<ARCHREALMS_PASSPORT_HOSTED_SIGNING_KEY_ID>`
- Custody mode: `<ARCHREALMS_PASSPORT_HOSTED_SIGNING_KEY_CUSTODY>`
- Endpoint: `<ARCHREALMS_PASSPORT_HOSTED_SIGNING_ENDPOINT>`

## Required Evidence

Attach the JSON report from:

```powershell
.\tools\release\Test-PassportProductionMvpReadiness.ps1 `
  -EnvironmentFile <production-env> `
  -OutputPath .\artifacts\release\production-mvp-readiness-report.json
```

The report must show:

- `managed_signing_key_custody` passed.
- `managed_signing_endpoint_probe` passed.
- The managed signing endpoint returned `signature_algorithm = RSA_PKCS1_SHA256`.
- The managed signing endpoint returned `public_key_sha256`.
- The managed signing endpoint returned matching `signing_key_provider`, `signing_key_id`, and `signing_key_custody`.
- The managed signing endpoint returned `local_validation_only=false`.

Attach the managed-signing deployment validation report and the custody approval/attestation references from the key-custody request.
