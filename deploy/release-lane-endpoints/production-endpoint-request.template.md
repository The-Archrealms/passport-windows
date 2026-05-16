# Production Endpoint Request

- Request ID: `<release-lane-endpoint-request-id>`
- Lane: `ProductionMvp`
- Request owner: `<owner>`
- Requested date: `<yyyy-mm-dd>`
- Hosted service image or artifact: `<image-or-artifact-reference>`
- Hosted service deployment validation report: `artifacts/release/hosted-services-deployment-validation-report.json`

## Required Environment Values

| Variable | Value |
|---|---|
| `PASSPORT_WINDOWS_PRODUCTION_MVP_API_BASE_URL` | `<https-api-base-url>` |
| `PASSPORT_WINDOWS_PRODUCTION_MVP_AI_GATEWAY_URL` | `<https-ai-gateway-url>` |
| `ARCHREALMS_PASSPORT_HOSTED_OPERATOR_API_KEY_SHA256` | `<sha256-of-operator-key>` |
| `ARCHREALMS_PASSPORT_HOSTED_OPERATOR_API_KEY` | Stored only in the secure readiness secret store |

## Routing Contract

The API endpoint must expose `GET /health`, `GET /ops/runtime/status`, `GET /ops/operator/status`, `GET /ops/storage/status`, `POST /ops/backup/manifests`, `POST /ops/incidents`, `POST /arch/genesis/manifests`, `POST /capacity/reports/cc`, and `POST /storage/delivery/requests`.

The AI gateway endpoint must expose `GET /ai/status`, `POST /ai/challenge`, `POST /ai/session`, `GET /ai/quota`, `POST /ai/chat`, `POST /ai/feedback`, `GET /ai/runtime/status`, and `GET /ai/runtime/probe`.

Operator-protected routes must require `X-Archrealms-Operator-Key`. The hosted service must store only `ARCHREALMS_PASSPORT_HOSTED_OPERATOR_API_KEY_SHA256`, not the raw operator key.

## Acceptance Evidence

- DNS record points to the approved production ingress.
- TLS certificate covers both production hostnames.
- Non-loopback production endpoints use HTTPS.
- `Test-PassportProductionMvpReadiness.ps1` returns ready runtime and AI probe results for these URLs.
- Production API and AI gateway URLs are recorded in the secure ProductionMvp environment file or secret store.
