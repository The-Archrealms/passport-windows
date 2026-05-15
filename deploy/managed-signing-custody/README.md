# Passport Managed Signing Custody Provisioning

This packet defines the operator inputs for the `managed_signing_key_custody` and `managed_signing_endpoint_probe` portions of the `ProductionMvp` readiness gate.

The ProductionMvp environment must set:

```text
ARCHREALMS_PASSPORT_HOSTED_SIGNING_KEY_PROVIDER
ARCHREALMS_PASSPORT_HOSTED_SIGNING_KEY_ID
ARCHREALMS_PASSPORT_HOSTED_SIGNING_KEY_CUSTODY
ARCHREALMS_PASSPORT_HOSTED_SIGNING_ENDPOINT
ARCHREALMS_PASSPORT_HOSTED_SIGNING_ENDPOINT_API_KEY
ARCHREALMS_PASSPORT_HOSTED_SIGNING_TIMEOUT_SECONDS
```

`ARCHREALMS_PASSPORT_HOSTED_SIGNING_KEY_CUSTODY` must be `managed`, `kms`, `hsm`, `managed-hsm`, or `cloud-kms`. Local hosted private-key paths and `local_validation_only=true` endpoint responses are not acceptable for ProductionMvp.

## Required Endpoint Behavior

The managed signing endpoint must accept `POST /sign` requests for `production_mvp_readiness_probe` and hosted record purposes. It must return:

- `signature_algorithm = RSA_PKCS1_SHA256`
- `signed_payload_sha256`
- `signature_base64`
- `public_key_spki_der_base64`
- `public_key_sha256`
- `signing_key_provider`
- `signing_key_id`
- `signing_key_custody`
- `local_validation_only = false`

The returned provider, key ID, and custody values must match the `ARCHREALMS_PASSPORT_HOSTED_SIGNING_*` environment values.

## Validation

Run the provisioning packet validator from the repo root:

```powershell
.\tools\release\Test-PassportManagedSigningCustodyProvisioning.ps1
```

For production, copy the templates into the controlled key-custody system, fill the bracketed values, approve them, validate the filled copies with `-RequireNoPlaceholders`, and load the approved values into the secure ProductionMvp readiness environment.

After the production endpoint is live, run `Test-PassportProductionMvpReadiness.ps1`. The readiness gate posts a non-mutating signing probe and verifies the returned RSA signature, public-key hash, custody metadata, and `local_validation_only=false`.
