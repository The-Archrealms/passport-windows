# Passport Production Backup Policy

- Document ID: `<controlled-document-id>`
- Owner: `<operations-owner>`
- Approved by: `<approval-id>`
- Effective date: `<yyyy-mm-dd>`
- Readiness URI variable: `ARCHREALMS_PASSPORT_HOSTED_STORAGE_BACKUP_POLICY_URI`

## Scope

This policy covers the managed hosted data root configured by `ARCHREALMS_PASSPORT_HOSTED_DATA_ROOT`, including hosted `records/`, hosted `append-log/`, AI knowledge-pack metadata, recovery validation records, capacity reports, storage delivery records, backup manifests, incident reports, and non-secret readiness records.

The policy excludes private signing keys, wallet private keys, raw user secrets, raw AI prompts unless separately approved for an incident, and any model-runtime provider secrets.

## Storage Provider

- Provider: `<managed-storage-provider>`
- Region or failure domain: `<region-or-domain>`
- Encryption at rest: `<provider-kms-key-or-policy>`
- Access control group: `<operator-access-group>`
- Break-glass approver: `<break-glass-approver>`

## Cadence And Objectives

- Backup cadence: `<for example hourly snapshots plus daily retained manifests>`
- Recovery point objective: `<RPO>`
- Recovery time objective: `<RTO>`
- Retention window: `<retention-window>`
- Restore validation cadence: `<for example weekly staging restore drill>`

## Backup Manifest

Operators must create signed hosted backup manifests through `POST /ops/backup/manifests` after every production backup cycle selected for retention. The manifest must hash managed `records/` and `append-log/` files and must exclude key material and raw payloads.

## Monitoring And Exceptions

Backup failure, manifest-generation failure, restore-drill failure, or unexplained append-log mismatch must open an incident using the production incident response runbook URI configured in `ARCHREALMS_PASSPORT_INCIDENT_RESPONSE_RUNBOOK_URI`.
