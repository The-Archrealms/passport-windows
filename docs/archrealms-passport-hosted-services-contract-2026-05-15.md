# Archrealms Passport Hosted Services Contract

- Date: 2026-05-15
- Status: implementation scaffold
- Project: `src/ArchrealmsPassport.HostedServices`

## Purpose

The hosted services project provides the production-facing API boundary that Windows Passport can target for the Token-Ready Passport MVP. The service is intentionally narrow: it validates Passport records, issues session or service records, and preserves the authority boundaries already enforced by the Windows client.

## Endpoints

| Endpoint | Purpose | Current implementation |
|---|---|---|
| `GET /health` | Liveness and contract version | Returns `passport-hosted-services-v1` |
| `GET /ai/status` | User-facing AI gateway status | Returns healthy/degraded state, endpoint names, runtime readiness flag, model ID, and non-authority boundaries without exposing secrets |
| `GET /ai/runtime/status` | Non-secret hosted open-weight AI readiness | Reports whether inference URL, approved model ID, model artifact hash, license approval, vector store, and knowledge approval root are configured |
| `GET /ai/runtime/probe` | Non-mutating hosted AI inference probe | Requires `X-Archrealms-Operator-Key`, sends a readiness prompt through the configured runtime, and verifies a non-empty answer |
| `GET /ops/runtime/status` | Non-secret hosted operations readiness | Reports managed data root, storage/backup/restore policy, managed signing-key custody, telemetry, and incident-response configuration without exposing secrets |
| `GET /ops/operator/status` | Non-mutating operator authentication probe | Requires `X-Archrealms-Operator-Key` and returns authorization status for production readiness checks |
| `GET /ops/storage/status` | Non-mutating managed-storage readiness probe | Requires `X-Archrealms-Operator-Key`, verifies hosted data-root write/delete probes and backup-manifest enumeration |
| `POST /ai/challenge` | Create a Passport-signable AI challenge | Issues a short-lived nonce, gateway audience, requested scopes, and non-authority boundaries; saves a signed hosted challenge record |
| `POST /ai/session` | Authorize a Passport-signed AI session request | Verifies request hash, device signature evidence, token/key separation, expiry, and non-authority boundaries |
| `GET /ai/quota` | Read AI session quota | Requires matching bearer session token and `session_id`; returns message/token limits, usage, remaining quota, and reset time |
| `POST /ai/chat` | Authenticated AI guide response | Requires matching bearer session token; blocks private key, seed, and recovery-secret prompts; retrieves approved knowledge-pack chunks; calls an OpenAI-compatible open-weight runtime when configured; otherwise returns the deterministic gateway-contract fallback |
| `POST /ai/feedback` | Capture optional AI feedback | Requires matching bearer session token; stores metadata and feedback hash only; does not mutate ledger, wallet, identity, storage, registry, recovery, or admin state |
| `POST /capacity/reports/cc` | Create conservative CC capacity reports | Enforces positive conservative capacity, no thin-market issuance, qualified independent volume, reserve exclusion, haircut range, and authority hash evidence |
| `POST /arch/genesis/manifests` | Create sealed ARCH genesis manifests | Enforces fixed supply, base-unit precision, unique allocation IDs, allocation total equals supply, no post-genesis minting, and authority hash evidence |
| `POST /admin/authority/validate` | Validate dual-control admin authority evidence | Checks action/scope/hash binding, distinct requester and approver devices, non-AI approval, and requester/approver signature record types |
| `POST /telemetry/access` | Authorize redacted hosted telemetry access | Requires operator authentication, strict `telemetry_access` dual-control authority, request-payload hash binding, metadata-only access, and bounded time windows |
| `POST /recovery/controls/validate` | Validate Passport recovery controls | Verifies self-service recovery signatures against hosted device public keys and support-mediated recovery overrides against strict dual-control admin authority; successful validations are signed and saved as hosted recovery-control validation records |
| `POST /storage/delivery/requests` | Accept storage delivery requests | Verifies storage delivery request hash, positive storage/epoch terms, and returns proof requirements before burn |
| `POST /ops/backup/manifests` | Create signed hosted backup manifests | Requires operator authentication, hashes managed `records/` and `append-log/` files, excludes key material and raw payloads, and records backup/restore policy evidence |
| `POST /ops/incidents` | Create signed hosted incident reports | Requires operator authentication and metadata-only incident records with severity, type, runbook, owner, telemetry-retention policy, and related record hashes |

## Storage

- The service uses `PassportHostedFileStore` by default.
- Set `ARCHREALMS_PASSPORT_HOSTED_DATA_ROOT` to control the hosted data root.
- Production readiness calls `/ops/storage/status` to verify the hosted data root, records root, and append-log root are writable and that backup-manifest enumeration can run.
- AI session records are written without bearer tokens.
- Hosted records are written with SHA-256 sidecars and append-log entries under `append-log/*.jsonl`.
- Approved AI knowledge-pack chunks can be stored under `records/ai/knowledge-packs/{knowledge_pack_id}/chunks.jsonl` with source IDs, hashes, approval status, and chunk text.
- Backup manifests enumerate only managed `records/` and `append-log/` files; they exclude `keys/`, private key material, raw AI prompts, and storage payload details.
- AI challenge and feedback records are hosted records with append-log entries. Feedback records store a hash of feedback text, not the raw feedback text.

## Operator And Signing Controls

- Authority-bearing endpoints require `X-Archrealms-Operator-Key` when `ARCHREALMS_PASSPORT_HOSTED_OPERATOR_API_KEY_SHA256` is configured.
- Production readiness also requires `ARCHREALMS_PASSPORT_HOSTED_OPERATOR_API_KEY`; the gate verifies it hashes to `ARCHREALMS_PASSPORT_HOSTED_OPERATOR_API_KEY_SHA256` and authenticates against `/ops/operator/status`.
- Missing operator-key configuration is allowed only in local/development mode.
- Hosted records returned by capacity, genesis, and storage-delivery endpoints are signed with the hosted service signing key.
- Local development can use `ARCHREALMS_PASSPORT_HOSTED_SIGNING_KEY_PATH` to control the service signing-key location.
- Production MVP managed custody must use `ARCHREALMS_PASSPORT_HOSTED_SIGNING_ENDPOINT` with `ARCHREALMS_PASSPORT_HOSTED_SIGNING_KEY_PROVIDER`, `ARCHREALMS_PASSPORT_HOSTED_SIGNING_KEY_ID`, and `ARCHREALMS_PASSPORT_HOSTED_SIGNING_KEY_CUSTODY`. The hosted service posts unsigned record payloads to that endpoint and records the returned signature/public-key evidence; local private-key paths are rejected by the production readiness gate. The readiness gate also posts a non-mutating `production_mvp_readiness_probe` payload and verifies the returned RSA signature and public-key hash.
- Hosted endpoints apply in-process per-scope rate limits and return `429` with `Retry-After` when exceeded.
- The admin authority endpoint validates signed admin action payloads against requester/approver public keys stored in the hosted registry.
- The admin authority endpoint requires active hosted role-membership records for both requester and approver devices.
- Hosted role-membership records are verified with issuer signatures and hosted registry public keys.
- The telemetry access endpoint returns redacted append-log metadata only; it blocks personal data, raw AI prompts, and storage payload details.
- The recovery controls endpoint rejects AI-approved recovery controls, validates signed device deauthorization/security-freeze records, validates support-mediated recovery override records against hosted admin authority, and appends signed validation records for auditability.
- The backup manifest and incident endpoints return hosted service signatures and append-log entries like other hosted authority records.
- The incident endpoint creates metadata-only incident reports; operational teams must keep sensitive evidence in the approved incident system referenced by the runbook.

## Hosted AI Runtime

- Set `ARCHREALMS_PASSPORT_AI_INFERENCE_BASE_URL` to a private vLLM/TGI OpenAI-compatible `/v1` endpoint.
- Set `ARCHREALMS_PASSPORT_AI_MODEL_ID` to the approved model ID for the release lane.
- Set `ARCHREALMS_PASSPORT_AI_INFERENCE_API_KEY` when the runtime endpoint requires bearer authentication.
- Optional controls: `ARCHREALMS_PASSPORT_AI_SYSTEM_PROMPT`, `ARCHREALMS_PASSPORT_AI_MAX_OUTPUT_TOKENS`, and `ARCHREALMS_PASSPORT_AI_TEMPERATURE`.
- Set `ARCHREALMS_PASSPORT_AI_MODEL_ARTIFACT_SHA256`, `ARCHREALMS_PASSPORT_AI_MODEL_LICENSE_APPROVAL_ID`, `ARCHREALMS_PASSPORT_AI_VECTOR_STORE_PROVIDER`, `ARCHREALMS_PASSPORT_AI_VECTOR_STORE_ID`, and `ARCHREALMS_PASSPORT_AI_KNOWLEDGE_APPROVAL_ROOT` so `/ai/runtime/status` can prove the production AI lane is configured before clients rely on it.
- Production readiness calls `/ai/runtime/probe` with the operator key to prove the configured hosted AI gateway can obtain a non-mutating answer from the approved model runtime.
- Passport clients call only the hosted gateway. They do not receive model runtime credentials and do not call vLLM/TGI directly.
- `/ai/status`, `/ai/challenge`, `/ai/session`, `/ai/quota`, `/ai/chat`, and `/ai/feedback` make up the citizen-facing hosted AI gateway surface. The runtime status/probe endpoints remain release-readiness and operations controls.

## Release-Lane Configuration

- `passport-release-lane.json` supports `ai_gateway_url`.
- Release scripts populate `ai_gateway_url` from `PASSPORT_WINDOWS_<LANE>_AI_GATEWAY_URL`, `PASSPORT_WINDOWS_RELEASE_LANE_AI_GATEWAY_URL`, or `api_base_url`.
- Windows Passport uses the lane AI gateway for staging, canary MVP, and production MVP unless the user explicitly configured a non-local gateway.

## Current Limits

- Production MVP package publishing is guarded by `tools/release/Test-PassportProductionMvpReadiness.ps1`; the MSIX publisher runs it automatically for `-Lane ProductionMvp` unless explicitly skipped.
- When production API and AI gateway URLs are configured, the readiness gate calls `/ops/runtime/status`, `/ops/operator/status`, `/ops/storage/status`, `/ai/runtime/status`, and `/ai/runtime/probe` and requires those endpoints to return the expected ready/authorized results.
- Production deployment still needs managed durable storage provider configuration, backup/restore runbook URIs, managed signing-key custody, telemetry destination/retention configuration, incident-response owner/runbook configuration, and managed release-lane deployment configuration.
- Production still needs final model endpoint selection, model artifact/license approval, managed vector store deployment, and production knowledge-pack approval workflow.
- The service does not make fiat, exchange, external wallet, staking, yield, governance, or public stable-value claims.

## Verification

- Hosted service build: `dotnet build .\src\ArchrealmsPassport.HostedServices\ArchrealmsPassport.HostedServices.csproj -c Release`
- Hosted service tests: `dotnet test .\tests\ArchrealmsPassport.HostedServices.Tests\ArchrealmsPassport.HostedServices.Tests.csproj -c Release` currently covers the hosted AI challenge, session, quota, chat, feedback, status, runtime status, and runtime probe policies.
- Windows Passport uses `/ai/session` for remote gateways and keeps the local preview path for `https://ai.archrealms.local`.
