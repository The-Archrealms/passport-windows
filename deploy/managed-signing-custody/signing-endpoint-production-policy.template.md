# Managed Signing Endpoint Production Policy

- Policy ID: `<managed-signing-endpoint-policy-id>`
- Lane: `ProductionMvp`
- Endpoint: `<ARCHREALMS_PASSPORT_HOSTED_SIGNING_ENDPOINT>`
- API key policy: `<api-key-policy-id>`
- Timeout seconds: `<ARCHREALMS_PASSPORT_HOSTED_SIGNING_TIMEOUT_SECONDS>`

## Transport And Authentication

- Production endpoint URL must use HTTPS.
- Loopback HTTP is allowed only for local validation.
- If `ARCHREALMS_PASSPORT_HOSTED_SIGNING_ENDPOINT_API_KEY` is configured, the hosted service must send it as `X-Archrealms-Managed-Signing-Key`.
- The managed signing endpoint should store only an API-key hash, not the raw API key.

## Response Contract

The endpoint must return a verifiable `RSA_PKCS1_SHA256` signature, SPKI public-key evidence, matching provider/key/custody metadata, and `local_validation_only=false`.

The endpoint must reject requests whose key ID, provider, custody mode, payload SHA-256, or signing purpose is not approved for ProductionMvp.

## Operational Controls

- Signing failures open an incident under `ARCHREALMS_PASSPORT_INCIDENT_RESPONSE_RUNBOOK_URI`.
- Key rotation must preserve auditability of prior signatures.
- Endpoint logs must not contain raw private key material or full unsigned payloads unless approved by the telemetry-retention policy.
