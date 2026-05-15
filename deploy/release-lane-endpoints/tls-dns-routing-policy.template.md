# TLS, DNS, And Routing Policy

- Policy ID: `<tls-dns-routing-policy-id>`
- Lane: `ProductionMvp`
- API hostname: `<api-hostname>`
- AI gateway hostname: `<ai-gateway-hostname>`
- Approved ingress provider: `<provider>`
- TLS certificate reference: `<certificate-reference>`

## DNS

- DNS records must be controlled by the Archrealms production DNS owner.
- DNS records must point only to the approved production ingress or load balancer.
- DNS changes require release approval and rollback instructions.

## TLS

- Production endpoint URLs must use HTTPS.
- TLS certificates must cover `PASSPORT_WINDOWS_PRODUCTION_MVP_API_BASE_URL` and `PASSPORT_WINDOWS_PRODUCTION_MVP_AI_GATEWAY_URL`.
- TLS private keys must be stored in managed certificate custody or the approved ingress provider.
- Loopback HTTP is allowed only for local validation and must not be used for citizen-facing ProductionMvp.

## Routing

- The API and AI gateway URLs may share one origin only when every required route is explicitly forwarded to the hosted service.
- Operator routes must not be cached by the reverse proxy.
- Public AI routes may be rate-limited at the ingress, but quota enforcement remains in the hosted service.
- Request bodies for `/ai/chat`, `/ai/feedback`, `/ops/incidents`, and storage/monetary record endpoints must not be logged by the ingress unless the approved telemetry-retention policy permits it.

## Readiness Evidence

The release packet must include successful `Test-PassportProductionMvpReadiness.ps1` output showing `release_lane_endpoints`, `hosted_runtime_status`, `hosted_operator_status`, `managed_storage_status`, and `hosted_ai_runtime_probe` passed.
