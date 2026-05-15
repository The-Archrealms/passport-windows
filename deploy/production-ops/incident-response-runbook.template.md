# Passport Production Incident Response Runbook

- Document ID: `<controlled-document-id>`
- Owner: `<incident-response-owner>`
- Approved by: `<approval-id>`
- Effective date: `<yyyy-mm-dd>`
- Readiness URI variable: `ARCHREALMS_PASSPORT_INCIDENT_RESPONSE_RUNBOOK_URI`
- Owner variable: `ARCHREALMS_PASSPORT_INCIDENT_RESPONSE_OWNER`

## Severity

- Severity 1: active key compromise, ledger corruption, destructive hosted storage event, unauthorized credit issuance, production data exposure, or AI privacy breach with sensitive data.
- Severity 2: failed storage delivery at scale, repeated backup or restore failure, signing endpoint outage, quota abuse affecting service availability, or production readiness drift.
- Severity 3: contained operational defect with no balance, privacy, custody, or service-delivery impact.

## First Hour

1. Assign incident owner and severity.
2. Preserve logs and signed records without expanding access.
3. Freeze affected authority paths when needed.
4. Rotate exposed operator or endpoint credentials.
5. Verify `/ops/runtime/status`, `/ops/storage/status`, `/ai/runtime/status`, and managed signing status.
6. Open a signed hosted incident report through `POST /ops/incidents`.

## Playbooks

### Key Compromise

Freeze affected signing or wallet authority, rotate keys, preserve old public-key evidence, and use signed correction or recovery records only under dual control.

### Hosted Storage Failure

Activate the restore runbook, validate manifests, verify append-log continuity, and use refund, re-credit, or service-extension records for failed service epochs.

### Ledger Or Issuance Error

Do not mutate historical events. Correct by appending signed correction events with reason codes and dual-control authority evidence.

### AI Privacy Or Abuse Incident

Disable affected AI sessions, preserve metadata hashes, do not expose raw prompts by default, and apply no-training and retention rules from the telemetry retention policy.

## Closure

Closure requires root-cause summary, affected-record list, correction or remediation records, user-impact assessment, release-lane impact, approval IDs, and follow-up owners.
