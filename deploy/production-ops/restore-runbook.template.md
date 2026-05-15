# Passport Production Restore Runbook

- Document ID: `<controlled-document-id>`
- Owner: `<operations-owner>`
- Approved by: `<approval-id>`
- Effective date: `<yyyy-mm-dd>`
- Readiness URI variable: `ARCHREALMS_PASSPORT_HOSTED_STORAGE_RESTORE_RUNBOOK_URI`

## Activation Criteria

Use this runbook for hosted data-root loss, managed storage corruption, append-log inconsistency, failed deployment rollback, ransomware or destructive access event, or recovery drill.

## Preconditions

- Confirm incident owner and severity.
- Freeze non-essential hosted writes when doing so reduces risk.
- Preserve the current `records/` and `append-log/` roots for forensic review.
- Confirm managed signing endpoint status before generating post-restore records.

## Restore Steps

1. Select the approved backup snapshot and signed backup manifest.
2. Restore `records/` and `append-log/` into an isolated restore root.
3. Verify manifest hashes against restored files.
4. Start the hosted service against the restored root in a non-public validation environment.
5. Call `/ops/storage/status` with the operator key and confirm readiness.
6. Call `/ops/runtime/status` and confirm storage, signing, telemetry, and incident-response configuration.
7. Run ledger replay and export verification against representative accounts.
8. Promote the restored root only after engineering and security/privacy approval.
9. Create a new signed backup manifest after promotion.

## Rollback

If restore validation fails, keep the previous production root sealed, do not delete failed restore evidence, and resolve balances or escrow only through signed correction, refund, re-credit, or service-extension records.

## Evidence

Record snapshot ID, backup manifest ID, restore operator, approver IDs, validation timestamps, failed checks, and final disposition in the incident record.
