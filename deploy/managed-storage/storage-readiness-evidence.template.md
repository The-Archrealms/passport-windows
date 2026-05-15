# Managed Storage Readiness Evidence

- Evidence ID: `<managed-storage-readiness-evidence-id>`
- Lane: `ProductionMvp`
- Created UTC: `<yyyy-mm-ddThh:mm:ssZ>`
- Provider: `<ARCHREALMS_PASSPORT_HOSTED_STORAGE_PROVIDER>`
- Hosted data root: `<ARCHREALMS_PASSPORT_HOSTED_DATA_ROOT>`

## Required Evidence

Attach the JSON report from:

```powershell
.\tools\release\Test-PassportProductionMvpReadiness.ps1 `
  -EnvironmentFile <production-env> `
  -OutputPath .\artifacts\release\production-mvp-readiness-report.json
```

The report must show:

- `managed_storage_backups` passed.
- `managed_storage_status` passed.
- `/ops/storage/status` authorized the configured operator key.
- `hosted_data_root_writable` or equivalent write/delete probe evidence is true.
- `records_root_writable` or equivalent records-root evidence is true.
- `append_log_root_writable` or equivalent append-log-root evidence is true.
- `backup_manifest_enumerable` is true.

Attach the signed backup manifest created through `POST /ops/backup/manifests`, including storage provider, backup policy URI, restore runbook URI, backup snapshot ID, manifest root SHA-256, file count, total bytes, and exclusion flags for private key material, raw AI prompts, and storage payload contents.
