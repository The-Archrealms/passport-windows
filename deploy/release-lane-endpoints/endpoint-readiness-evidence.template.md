# Endpoint Readiness Evidence

- Evidence ID: `<endpoint-readiness-evidence-id>`
- Lane: `ProductionMvp`
- Created UTC: `<yyyy-mm-ddThh:mm:ssZ>`
- API URL: `<PASSPORT_WINDOWS_PRODUCTION_MVP_API_BASE_URL>`
- AI gateway URL: `<PASSPORT_WINDOWS_PRODUCTION_MVP_AI_GATEWAY_URL>`
- Operator key hash: `<ARCHREALMS_PASSPORT_HOSTED_OPERATOR_API_KEY_SHA256>`

## Required Evidence

Attach the JSON report from:

```powershell
.\tools\release\Test-PassportProductionMvpReadiness.ps1 `
  -EnvironmentFile <production-env> `
  -OutputPath .\artifacts\release\production-mvp-readiness-report.json
```

The report must show:

- `release_lane_endpoints` passed.
- `hosted_runtime_status` passed.
- `hosted_operator_status` passed.
- `managed_storage_status` passed.
- `hosted_ai_runtime_probe` passed.
- API and AI gateway URLs use HTTPS unless they are loopback validation URLs.
- `/ops/operator/status` authorized the configured operator key.
- `/ai/runtime/probe` returned `ready=true` and `runtime_answer_received=true`.

## Promotion Rule

Citizen-facing production testing may not start from this endpoint packet alone. The full ProductionMvp readiness gate must return `ready=true` after package signing, managed storage/backups, managed signing custody, issuer/capacity/genesis identifiers, open-weight AI runtime, telemetry/incident response, and release approvals are also configured.
