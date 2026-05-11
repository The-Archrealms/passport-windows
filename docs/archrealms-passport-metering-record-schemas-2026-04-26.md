# Archrealms Passport Metering Record Schemas

- Date: 2026-04-26
- Status: working schema note for Passport metering development
- Scope: local node activity, proof-related records, and read-only metering status records

## Purpose

Define the first concrete metering-adjacent record shapes for Passport so the Windows client can prepare stable proof records before blockchain settlement, wallet, token, redemption, or marketplace functionality exists.

These schemas support the sequence adopted in `archrealms-passport-metering-and-settlement-roadmap-2026-04-26.md`:

1. local service activity;
2. proof record preparation;
3. read-only metering status;
4. later read-only blockchain settlement visibility.

## Boundary

These records are not money.

They do not create:

- cryptocurrency;
- public token balances;
- external redemption rights;
- governance voting power;
- citizenship;
- registry admission authority;
- guaranteed payout rights.

They only describe node capacity, assignments, proof claims, retrieval observations, repair participation, and metering status.

## Workspace Layout

Passport should reserve these workspace paths for the first metering milestone:

- `records/passport/node-activity/`
- `records/passport/metering/proofs/`
- `records/passport/metering/submissions/`
- `records/passport/metering/status/`
- `records/passport/metering/admissions/`
- `records/passport/settlement/read-only/`

The `settlement/read-only` path is reserved for later blockchain settlement display. The first milestone should not write wallet, redemption, transfer, or trading records.

## Common Fields

Metering-related Passport records should preserve:

- `schema_version`
- `record_type`
- `record_id`
- `created_utc`
- `effective_utc`
- `status`
- `archrealms_identity_id`
- `device_id`
- `node_id`
- `summary`

Proof-bearing records should also preserve a `signature` object that identifies:

- signature algorithm;
- signing device record;
- relative signed payload path;
- relative signature path;
- hash of the signed payload.

## Record 1: Node Capacity Snapshot

`node_capacity_snapshot_record` describes the local node's declared participation mode and observed capacity for an epoch.

Primary use:

- service activity display;
- storage contribution reporting;
- later eligibility or assignment decisions.

It should not be treated as proof that service was delivered.

Template:

- `registry/templates/node-capacity-snapshot-record.template.json`

## Record 2: Storage Assignment Acknowledgment

`storage_assignment_acknowledgment_record` records that a node accepted or declined a storage assignment for a content object, manifest, or replica.

Primary use:

- establish assigned responsibility before storage proofs are expected;
- avoid paying for unassigned self-report.

Template:

- `registry/templates/storage-assignment-acknowledgment-record.template.json`

## Record 3: Storage Epoch Proof

`storage_epoch_proof_record` records a node's submitted response to an epoch challenge for assigned content.

Primary use:

- claim proof-backed storage participation;
- produce a record that a metering authority can later accept, reject, or audit.

This record may claim service units, but the authoritative accepted value belongs in later metering status or settlement records.

Template:

- `registry/templates/storage-epoch-proof-record.template.json`

## Record 4: Retrieval Observation

`retrieval_observation_record` records observed retrieval service.

Primary use:

- preserve evidence that a request was served;
- claim retrieval bytes for later verification.

Template:

- `registry/templates/retrieval-observation-record.template.json`

## Record 5: Repair Participation

`repair_participation_record` records node participation in restoring or improving an under-replicated object.

Primary use:

- preserve repair evidence;
- claim repair bytes for later verification.

Template:

- `registry/templates/repair-participation-record.template.json`

## Record 6: Metering Status

`metering_status_record` records verified service totals reported from a trusted metering output.

Primary use:

- read-only Passport display;
- show submitted, accepted, and rejected proofs;
- show verified service units;
- link to later settlement records when those exist.

Template:

- `registry/templates/metering-status-record.template.json`

## Record 7: Metering Admission and Review

`passport_metering_admission_record` records that a verified metering report package has been admitted for registrar review.

Related registrar review records are:

- `passport_metering_audit_challenge_record`
- `passport_metering_dispute_record`
- `passport_metering_correction_record`
- `passport_metering_settlement_handoff_record`

Primary use:

- preserve package admission;
- issue audit challenges;
- record disputes;
- supersede admitted totals by correction;
- mark reviewed metering evidence as eligible or held for later blockchain settlement review.

These records are not settlement records.

Templates:

- `registry/templates/metering-admission-record.template.json`
- `registry/templates/metering-audit-challenge-record.template.json`
- `registry/templates/metering-dispute-record.template.json`
- `registry/templates/metering-correction-record.template.json`
- `registry/templates/metering-settlement-handoff-record.template.json`

## Record 8: Blockchain Settlement Batch and Status

`blockchain_settlement_batch_record` records the chain-neutral settlement batch interface after registrar review has produced one or more settlement handoff records.

`blockchain_settlement_status_record` records read-only Passport settlement visibility for a participant, node, or batch.

Primary use:

- commit reviewed metering handoffs to a future blockchain settlement layer;
- preserve transaction hash, block height, finality status, and evidence root;
- allow Passport to display settlement status without custody or transfer controls.

Templates:

- `registry/templates/blockchain-settlement-batch-record.template.json`
- `registry/templates/blockchain-settlement-status-record.template.json`
- `registry/templates/blockchain-settlement-chain-evaluation.template.json`

## First Implementation Rule

The first Passport implementation should create folders and preserve signed proof-related records.

It should not:

- show payout promises;
- call the feature a wallet;
- imply cash-out;
- imply external transfer;
- calculate authoritative settlement locally;
- treat unverified proof claims as earned money.

External economy-facing release is blocked until blockchain settlement finality is implemented and approved.

Local integrity verification may check:

- whether the signed payload file exists;
- whether the signed payload hash still matches;
- whether the detached signature verifies against the active device public key.

That verification is not network metering acceptance.

## Template Files

The first metering templates are:

- `registry/templates/node-capacity-snapshot-record.template.json`
- `registry/templates/storage-assignment-acknowledgment-record.template.json`
- `registry/templates/storage-epoch-proof-record.template.json`
- `registry/templates/retrieval-observation-record.template.json`
- `registry/templates/repair-participation-record.template.json`
- `registry/templates/metering-status-record.template.json`
- `registry/templates/metering-admission-record.template.json`
- `registry/templates/metering-audit-challenge-record.template.json`
- `registry/templates/metering-dispute-record.template.json`
- `registry/templates/metering-correction-record.template.json`
- `registry/templates/metering-settlement-handoff-record.template.json`
- `registry/templates/blockchain-settlement-batch-record.template.json`
- `registry/templates/blockchain-settlement-status-record.template.json`
- `registry/templates/blockchain-settlement-chain-evaluation.template.json`

## Bottom Line

Passport metering begins with records, not money.

The first useful milestone is a stable local workspace, proof-capable templates, and conservative read-only metering status.
