# Staging Readiness Evidence

This folder contains the evidence templates required by `tools/release/Test-PassportStagingReadiness.ps1` before a Staging lane build can be promoted to canary or production MVP review.

Staging is not the MVP. It is a production-candidate lane with isolated staging endpoints, staging ledger namespace, staging telemetry, staging rollback evidence, and signed promotion approvals.

## Required Evidence

Generate a controlled staging evidence packet, fill every placeholder, approve the records, then load the paths and SHA-256 hashes into `artifacts/release/staging.env` or the staging secret store:

- `staging-rollback-drill-report.template.json`
- `staging-operational-drill-report.template.json`
- `staging-promotion-approval-record.template.json`

```powershell
.\tools\release\New-PassportStagingReadinessEvidencePacket.ps1 `
  -OutputDirectory C:\secure\passport-staging `
  -OperationalDrillId <staging-operational-drill-id> `
  -RollbackDrillId <staging-rollback-drill-id> `
  -PromotionApprovalId <staging-promotion-approval-id>
```

Validate the filled packet before running the staging readiness gate:

```powershell
.\tools\release\Test-PassportStagingReadinessEvidencePacket.ps1 `
  -PacketRoot C:\secure\passport-staging `
  -RequireNoPlaceholders
```

The readiness gate validates:

- operational drill schema, lane, matching operational drill ID, endpoint/ledger/telemetry values, package version, policy version, operator, incident owner, evidence references, upgrade validation, endpoint failover, signing verification, ledger export replay, recovery/revocation, storage proof, storage redemption dry-run, conversion disclosure dry-run, telemetry/privacy, incident response, support access controls, AI gateway auth/privacy, and prohibited monetary claim blocking;
- rollback report schema, lane, matching rollback drill ID, completion status, operation routing, ledger preservation, no mutation/backdating, pending escrow handling, export preservation, production-record isolation, approvers, affected services/assets, reason code, package version, policy version, and user-facing status;
- promotion approval schema, lane, matching signoff IDs, matching pre-MVP/staging artifact/operational-drill/rollback hashes, and signed product, engineering, security/privacy, and Crown monetary authority approvals.

Synthetic staging readiness reports are valid only for validator self-tests. ProductionMvp readiness rejects synthetic staging reports.
