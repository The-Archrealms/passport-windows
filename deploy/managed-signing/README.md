# Passport Managed-Signing Endpoint Deployment

This folder contains a deployment baseline for the HTTPS endpoint used by Passport hosted services for service-record signatures.

The production readiness gate calls `ARCHREALMS_PASSPORT_HOSTED_SIGNING_ENDPOINT` with a non-mutating `production_mvp_readiness_probe` payload. The endpoint must return a verifiable RSA PKCS#1 SHA-256 signature and key-custody metadata.

## Endpoints

- `GET /health`: non-secret process health.
- `GET /signing/status`: readiness metadata for provider, key ID, custody, mode, local-validation status, and allowed purposes.
- `POST /sign`: managed signing endpoint used by hosted services and readiness probes.

`POST /sign` accepts:

```json
{
  "key_id": "<configured key id>",
  "provider": "<configured provider>",
  "custody": "<managed|kms|hsm|managed-hsm|cloud-kms>",
  "purpose": "production_mvp_readiness_probe",
  "payload_sha256": "<sha256>",
  "payload_base64": "<base64>"
}
```

It returns:

```json
{
  "signature_algorithm": "RSA_PKCS1_SHA256",
  "signed_payload_sha256": "<same payload sha256>",
  "signature_base64": "<signature>",
  "public_key_spki_der_base64": "<SPKI DER public key>",
  "public_key_sha256": "<sha256 of SPKI DER public key>",
  "signing_key_provider": "<configured provider>",
  "signing_key_id": "<configured key id>",
  "signing_key_custody": "<configured custody>",
  "local_validation_only": false
}
```

The `X-Archrealms-Managed-Signing-Key` header is required when `ARCHREALMS_MANAGED_SIGNING_API_KEY_SHA256` is configured.

## Modes

`local-pkcs8-validation` signs with `ARCHREALMS_MANAGED_SIGNING_LOCAL_PKCS8_PATH` and returns `local_validation_only=true`. This is only for local endpoint contract testing. `ProductionMvp` readiness rejects this mode.

`external-command` runs `ARCHREALMS_MANAGED_SIGNING_COMMAND_PATH`, sends the signing request JSON to stdin, and expects the response JSON on stdout. Use this mode to place the endpoint in front of KMS, HSM, managed-HSM, or cloud-KMS custody.

## Local Validation

Create a local env file from the template:

```powershell
Copy-Item .\deploy\managed-signing\managed-signing-env.template `
  .\deploy\managed-signing\managed-signing.local-validation.env
```

Start the endpoint:

```powershell
docker compose `
  -f .\deploy\managed-signing\docker-compose.local-validation.yml `
  up -d
```

Validate the deployment files and Release publish output:

```powershell
.\tools\release\Test-PassportManagedSigningDeployment.ps1
```

After a local or private endpoint is running, validate the signing contract:

```powershell
.\tools\release\Test-PassportManagedSigningDeployment.ps1 `
  -ProbeEndpoint `
  -SigningEndpoint http://127.0.0.1:8081/sign `
  -KeyProvider local-validation `
  -KeyId passport-managed-signing-local-validation `
  -KeyCustody local-validation `
  -AllowLocalValidationResponse
```

For production, the endpoint must use HTTPS and must return `local_validation_only=false` with managed custody evidence matching the `ARCHREALMS_PASSPORT_HOSTED_SIGNING_*` values used by hosted services.
