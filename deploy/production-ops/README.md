# Passport Production Ops Documents

This folder contains reviewable templates for the production documents referenced by the `ProductionMvp` readiness environment. These templates do not make production ready by themselves. Operators must copy them into the controlled production document system, fill the bracketed fields, approve them, and use the resulting document IDs or URIs in the readiness environment.

Required readiness variables:

- `ARCHREALMS_PASSPORT_HOSTED_STORAGE_BACKUP_POLICY_URI`
- `ARCHREALMS_PASSPORT_HOSTED_STORAGE_RESTORE_RUNBOOK_URI`
- `ARCHREALMS_PASSPORT_TELEMETRY_RETENTION_POLICY_URI`
- `ARCHREALMS_PASSPORT_INCIDENT_RESPONSE_RUNBOOK_URI`
- `ARCHREALMS_PASSPORT_INCIDENT_RESPONSE_OWNER`
- `ARCHREALMS_PASSPORT_PRODUCTION_RELEASE_APPROVAL_ID`
- `ARCHREALMS_PASSPORT_ENGINEERING_SIGNOFF_ID`
- `ARCHREALMS_PASSPORT_SECURITY_PRIVACY_SIGNOFF_ID`
- `ARCHREALMS_PASSPORT_CROWN_MONETARY_AUTHORITY_SIGNOFF_ID`

Validate the template package:

```powershell
.\tools\release\Test-PassportProductionOpsDocuments.ps1
```

Validate copied and completed production documents by pointing the validator at their directory and requiring placeholders to be removed:

```powershell
.\tools\release\Test-PassportProductionOpsDocuments.ps1 `
  -ProductionOpsPath C:\secure\archrealms-passport-production-ops `
  -RequireNoPlaceholders
```

The validator writes `artifacts/release/production-ops-documents-validation-report.json` by default.
