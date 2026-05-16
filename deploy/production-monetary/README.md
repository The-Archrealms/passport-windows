# Passport Production Monetary Provisioning

This folder contains templates for the ProductionMvp monetary identifiers behind:

- `ARCHREALMS_PASSPORT_CC_ISSUER_AUTHORITY_ID`
- `ARCHREALMS_PASSPORT_CAPACITY_REPORT_ISSUER_ID`
- `ARCHREALMS_PASSPORT_ARCH_GENESIS_MANIFEST_ID`
- `ARCHREALMS_PASSPORT_PRODUCTION_LEDGER_NAMESPACE`

The templates are operator inputs for the hosted API endpoints:

- `POST /arch/genesis/manifests`
- `POST /capacity/reports/cc`

The ARCH genesis request must include the approved allocation policy,
vesting/lock policy, treasury policy, and genesis ledger hash evidence. The CC
capacity request must include the conservative issuance methodology, issuance
authority, issuance record schema, and no-ARCH-creation validation evidence.

Validate the template package:

```powershell
.\tools\release\Test-PassportProductionMonetaryProvisioning.ps1
```

Validate filled production copies:

```powershell
.\tools\release\Test-PassportProductionMonetaryProvisioning.ps1 `
  -ProductionMonetaryPath C:\secure\archrealms-passport-production-monetary `
  -RequireNoPlaceholders
```

After approvals and production hosted API deployment, create the hosted genesis/capacity records explicitly:

```powershell
.\tools\release\Test-PassportProductionMonetaryProvisioning.ps1 `
  -ProductionMonetaryPath C:\secure\archrealms-passport-production-monetary `
  -RequireNoPlaceholders `
  -CreateHostedRecords `
  -HostedApiBaseUrl https://passport.archrealms.example `
  -OperatorKey <operator-key>
```

`-CreateHostedRecords` mutates the hosted API by creating signed production records. Use it only after the production release approvals and monetary authority signoff are recorded.
