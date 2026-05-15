# Passport Managed Storage Provisioning

This packet defines the operator inputs for the `managed_storage_backups` and `managed_storage_status` portions of the `ProductionMvp` readiness gate.

The ProductionMvp environment must set:

```text
ARCHREALMS_PASSPORT_HOSTED_DATA_ROOT
ARCHREALMS_PASSPORT_HOSTED_STORAGE_PROVIDER
ARCHREALMS_PASSPORT_HOSTED_STORAGE_BACKUP_POLICY_URI
ARCHREALMS_PASSPORT_HOSTED_STORAGE_RESTORE_RUNBOOK_URI
```

The hosted data root must be durable managed storage for hosted records, append logs, recovery validation records, capacity reports, ARCH genesis records, storage delivery records, AI metadata, telemetry metadata, backup manifests, and incident records.

## Storage Layout

The hosted service expects the data root to support:

- `records/`
- `append-log/`
- backup manifest enumeration through `/ops/storage/status`
- signed backup-manifest creation through `POST /ops/backup/manifests`

Private key material, raw AI prompts, and storage payload contents must not be included in backup manifests.

## Validation

Run the provisioning packet validator from the repo root:

```powershell
.\tools\release\Test-PassportManagedStorageProvisioning.ps1
```

For production, copy the templates into the controlled deployment system, fill the bracketed values, approve them, validate the filled copies with `-RequireNoPlaceholders`, and load the approved storage values into the secure ProductionMvp readiness environment.

After production hosted storage is configured, the readiness gate must authenticate to `/ops/storage/status` with `X-Archrealms-Operator-Key` and verify data-root write/delete probes, `records/`, `append-log/`, and backup-manifest enumeration.
