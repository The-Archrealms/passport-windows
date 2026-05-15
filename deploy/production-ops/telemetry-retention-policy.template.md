# Passport Production Telemetry Retention Policy

- Document ID: `<controlled-document-id>`
- Owner: `<security-privacy-owner>`
- Approved by: `<approval-id>`
- Effective date: `<yyyy-mm-dd>`
- Readiness URI variable: `ARCHREALMS_PASSPORT_TELEMETRY_RETENTION_POLICY_URI`

## Data Categories

Allowed production telemetry is metadata-first and service-operability focused:

- request timestamps, route names, status codes, latency buckets, and correlation IDs;
- signed record IDs, hashes, policy versions, release lane, and readiness status;
- AI session token hashes, quota counters, model ID, knowledge-pack ID, and source IDs;
- storage proof status, metering summaries, backup manifest IDs, and incident IDs.

Do not collect wallet private keys, seed material, signing prompts, raw AI prompts by default, raw AI responses by default, storage payload contents, file names, government IDs, biometric data, or unredacted support secrets.

## Retention

- Operational telemetry: `<retention-window>`
- Security events: `<retention-window>`
- Incident evidence: `<retention-window-or-case-policy>`
- Raw AI prompts and responses: `not retained by default`
- Immutable audit hashes: retained as required by ledger and incident policy

## Access

Telemetry access requires operator authentication and dual-control `telemetry_access` authority evidence. Exports must be metadata-only unless a security/privacy incident explicitly authorizes narrower evidence collection.

## AI No-Training Default

Prompts, support messages, diagnostics, storage telemetry, ledger exports, and private Passport state must not be used to train or fine-tune models unless a separate user opt-in and approved policy exists.

## Review

Review this policy before production testing, after any material data-flow change, and after every severity-1 or severity-2 incident.
