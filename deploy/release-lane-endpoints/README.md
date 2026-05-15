# Passport Release-Lane Endpoint Provisioning

This packet defines the operator inputs for the `release_lane_endpoints`, `hosted_runtime_status`, `hosted_operator_status`, `managed_storage_status`, `hosted_ai_runtime_probe`, and public hosted AI gateway portions of the `ProductionMvp` readiness gate.

The ProductionMvp environment must set:

```text
PASSPORT_WINDOWS_PRODUCTION_MVP_API_BASE_URL
PASSPORT_WINDOWS_PRODUCTION_MVP_AI_GATEWAY_URL
ARCHREALMS_PASSPORT_HOSTED_OPERATOR_API_KEY_SHA256
ARCHREALMS_PASSPORT_HOSTED_OPERATOR_API_KEY
```

The API and AI gateway URLs may point to the same HTTPS origin when the reverse proxy routes all required paths to the hosted service. Production URLs must use HTTPS; loopback HTTP is only for local validation.

## Required Hosted Routes

The production API URL must route:

- `GET /health`
- `GET /ops/runtime/status`
- `GET /ops/operator/status`
- `GET /ops/storage/status`
- `POST /ops/backup/manifests`
- `POST /ops/incidents`
- `POST /arch/genesis/manifests`
- `POST /capacity/reports/cc`
- `POST /storage/delivery`

The production AI gateway URL must route:

- `GET /ai/status`
- `POST /ai/challenge`
- `POST /ai/session`
- `GET /ai/quota`
- `POST /ai/chat`
- `POST /ai/feedback`
- `GET /ai/runtime/status`
- `POST /ai/runtime/probe`

Operator-protected routes must require `X-Archrealms-Operator-Key` and must validate that the raw key hashes to `ARCHREALMS_PASSPORT_HOSTED_OPERATOR_API_KEY_SHA256`.

## Validation

Run the packet validator from the repo root:

```powershell
.\tools\release\Test-PassportReleaseLaneEndpointProvisioning.ps1
```

For production, copy the templates into the controlled deployment system, fill the bracketed values, approve them, validate the filled copies with `-RequireNoPlaceholders`, and then load the approved URLs and operator-key values into the secure ProductionMvp readiness environment.

After production endpoints are live, run:

```powershell
.\tools\release\Test-PassportProductionMvpReadiness.ps1 `
  -EnvironmentFile .\artifacts\release\production-mvp.env
```

The gate must verify HTTPS endpoint URLs, runtime readiness, operator authentication, managed storage status, and a non-mutating AI runtime probe before citizen-facing production testing.
