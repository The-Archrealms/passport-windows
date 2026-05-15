# Backup Manifest Schedule

- Schedule ID: `<backup-manifest-schedule-id>`
- Lane: `ProductionMvp`
- Backup policy URI: `<ARCHREALMS_PASSPORT_HOSTED_STORAGE_BACKUP_POLICY_URI>`
- Restore runbook URI: `<ARCHREALMS_PASSPORT_HOSTED_STORAGE_RESTORE_RUNBOOK_URI>`
- Storage provider: `<ARCHREALMS_PASSPORT_HOSTED_STORAGE_PROVIDER>`

## Schedule

- Backup frequency: `<frequency>`
- Backup retention: `<retention-period>`
- Manifest creation cadence: `<manifest-cadence>`
- Restore validation cadence: `<restore-validation-cadence>`

## Manifest Rules

Operators must create signed hosted backup manifests through:

```text
POST /ops/backup/manifests
```

Every retained backup selected for recovery must have a signed manifest that hashes `records/` and `append-log/`, records the backup snapshot ID, and excludes private key material, raw AI prompts, and storage payload contents.

## Failure Handling

Failed backup-manifest creation, backup snapshot failure, restore-validation failure, or `/ops/storage/status` failure must open an incident under `ARCHREALMS_PASSPORT_INCIDENT_RESPONSE_RUNBOOK_URI`.
