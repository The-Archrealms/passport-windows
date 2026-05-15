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
| `POST /ai/session` | Authorize a Passport-signed AI session request | Verifies request hash, device signature evidence, token/key separation, expiry, and non-authority boundaries |
| `POST /ai/chat` | Authenticated AI guide response | Requires matching bearer session token; blocks private key, seed, and recovery-secret prompts; returns source-grounded gateway response shape |
| `POST /capacity/reports/cc` | Create conservative CC capacity reports | Enforces positive conservative capacity, no thin-market issuance, qualified independent volume, reserve exclusion, haircut range, and authority hash evidence |
| `POST /arch/genesis/manifests` | Create sealed ARCH genesis manifests | Enforces fixed supply, base-unit precision, unique allocation IDs, allocation total equals supply, no post-genesis minting, and authority hash evidence |
| `POST /admin/authority/validate` | Validate dual-control admin authority evidence | Checks action/scope/hash binding, distinct requester and approver devices, non-AI approval, and requester/approver signature record types |
| `POST /storage/delivery/requests` | Accept storage delivery requests | Verifies storage delivery request hash, positive storage/epoch terms, and returns proof requirements before burn |

## Storage

- The service uses `PassportHostedFileStore` by default.
- Set `ARCHREALMS_PASSPORT_HOSTED_DATA_ROOT` to control the hosted data root.
- AI session records are written without bearer tokens.
- Hosted records are written with SHA-256 sidecars and append-log entries under `append-log/*.jsonl`.

## Current Limits

- Production deployment still needs managed durable storage, backups, service signing-key custody, operator authentication, role membership lookup, telemetry, rate limits, incident logging, and release-lane configuration.
- The AI chat endpoint currently returns a gateway-contract response; production still needs the open-weight model runtime and vector store behind the gateway.
- The service does not make fiat, exchange, external wallet, staking, yield, governance, or public stable-value claims.

## Verification

- Hosted service build: `dotnet build .\src\ArchrealmsPassport.HostedServices\ArchrealmsPassport.HostedServices.csproj -c Release`
- Hosted service tests: `dotnet test .\tests\ArchrealmsPassport.HostedServices.Tests\ArchrealmsPassport.HostedServices.Tests.csproj -c Release`
- Windows Passport uses `/ai/session` for remote gateways and keeps the local preview path for `https://ai.archrealms.local`.
