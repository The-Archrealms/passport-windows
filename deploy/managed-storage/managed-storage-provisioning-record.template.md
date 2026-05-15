# Managed Storage Provisioning Record

- Provisioning ID: `<managed-storage-provisioning-id>`
- Lane: `ProductionMvp`
- Storage owner: `<owner>`
- Provider: `<ARCHREALMS_PASSPORT_HOSTED_STORAGE_PROVIDER>`
- Hosted data root: `<ARCHREALMS_PASSPORT_HOSTED_DATA_ROOT>`
- Backup policy URI: `<ARCHREALMS_PASSPORT_HOSTED_STORAGE_BACKUP_POLICY_URI>`
- Restore runbook URI: `<ARCHREALMS_PASSPORT_HOSTED_STORAGE_RESTORE_RUNBOOK_URI>`

## Scope

This storage root holds hosted `records/`, hosted `append-log/`, recovery validation records, CC capacity reports, ARCH genesis manifests, storage delivery records, AI metadata, telemetry metadata, backup manifests, incident records, and non-secret readiness records.

## Requirements

- Managed storage must be durable and production backed, not a local container volume.
- The hosted service identity must have least-privilege read/write/list access to `records/` and `append-log/`.
- Backup manifest enumeration must be available to `/ops/storage/status`.
- Backup snapshots must be restorable under `ARCHREALMS_PASSPORT_HOSTED_STORAGE_RESTORE_RUNBOOK_URI`.
- Backup manifests must exclude private key material, raw AI prompts, and storage payload contents.
- Provider retention and deletion behavior must match `ARCHREALMS_PASSPORT_HOSTED_STORAGE_BACKUP_POLICY_URI`.

## Acceptance Evidence

- `/ops/storage/status` passed with the production operator key.
- `POST /ops/backup/manifests` created a signed backup manifest.
- Restore validation completed against the approved restore runbook.
- The full `Test-PassportProductionMvpReadiness.ps1` report shows `managed_storage_backups` and `managed_storage_status` passed.
