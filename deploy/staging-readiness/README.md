# Staging Readiness Evidence

This folder contains the evidence templates required by `tools/release/Test-PassportStagingReadiness.ps1` before a Staging lane build can be promoted to canary or production MVP review.

Staging is not the MVP. It is a production-candidate lane with isolated staging endpoints, staging ledger namespace, staging telemetry, staging rollback evidence, and signed promotion approvals.

## Required Evidence

Copy these templates into the controlled staging document system, fill every placeholder, approve them, then load the paths and SHA-256 hashes into `artifacts/release/staging.env` or the staging secret store:

- `staging-rollback-drill-report.template.json`
- `staging-promotion-approval-record.template.json`

The readiness gate validates:

- rollback report schema, lane, matching rollback drill ID, completion status, operation routing, ledger preservation, no mutation/backdating, pending escrow handling, export preservation, production-record isolation, approvers, affected services/assets, reason code, package version, policy version, and user-facing status;
- promotion approval schema, lane, matching signoff IDs, matching pre-MVP/staging artifact/rollback hashes, and signed product, engineering, security/privacy, and Crown monetary authority approvals.

Synthetic staging readiness reports are valid only for validator self-tests. ProductionMvp readiness rejects synthetic staging reports.
