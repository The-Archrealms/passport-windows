# Archrealms Passport Metering and Settlement Roadmap

- Date: 2026-04-26
- Status: draft implementation roadmap
- Repo: `passport-windows`
- Scope: Passport-facing sequence for proof records, metering visibility, blockchain settlement readiness, and deferred public wallet/token functions

## Decision

Passport should not treat public token issuance, external redemption, or marketplace trading as part of the current MVP.

External release of the economy-facing Passport product is gated on a blockchain-based settlement layer. Until that layer exists, Passport may build and test identity, local node, proof, metering, package admission, and settlement-handoff inputs, but it must not present local records as final economic settlement.

The Passport app should first become credible as:

- an identity client;
- a device trust client;
- a local node manager;
- a registry submission client;
- a proof and metering record client; and
- later, a read-only participant account viewer for blockchain-backed settlement records.

## Product Boundary

The current Passport product may eventually show service activity and blockchain-backed settlement status, but it should not yet become:

- a public crypto wallet;
- a public token sale client;
- a trading interface;
- a redemption interface;
- a governance-token interface; or
- a way to buy citizenship, office, registry authority, or constitutional power.

## Ledger Split

Passport should reflect the architecture split already adopted for the Archrealms economy.

### Metering Records

Metering records answer:

- what node participated;
- what service class was performed;
- what content or assignment was involved;
- what epoch was measured;
- what proof, retrieval, or repair evidence was submitted;
- whether the evidence verified; and
- what service units were credited.

Metering records are not money.

### Blockchain Settlement Records

Blockchain settlement records answer:

- what funded escrow, treasury source, or settlement contract paid;
- what epoch was settled;
- which metered records were included;
- what split rule applied;
- what on-chain transaction, batch, or state commitment finalized the settlement;
- what internal or contract balances moved; and
- what correction or dispute entries were resolved before finalization.

Blockchain settlement records are value accounting and finality records, not constitutional authority.

## Passport Responsibilities

Passport should eventually support the following participant-facing functions.

### 1. Local Service Activity

Show local node activity such as:

- archive participation enabled or disabled;
- storage contribution limit;
- node health;
- pinned or cached public records;
- recent publication actions;
- recent retrievals through the local node.

This is ordinary local-node product scope.

### 2. Proof Record Preparation

Prepare and sign proof-related records when the node participates in a measured service program.

Possible record classes:

- `storage_assignment_acknowledgment`
- `storage_epoch_proof`
- `retrieval_observation`
- `repair_participation_record`
- `node_capacity_snapshot`

These records should be written into the Passport workspace before any settlement feature exists.

### 3. Metering Status View

Display verified service status from trusted metering outputs.

The first view should be read-only and conservative:

- submitted proofs;
- accepted proofs;
- rejected proofs;
- verified replicated byte-seconds;
- verified retrieval bytes;
- verified repair bytes;
- current node reliability indicators.

Passport should not calculate authoritative payouts locally unless the governing metering rules assign that role to the client.

### 4. Blockchain Settlement View

After blockchain settlement records exist, Passport may show participant settlement status.

The first version should be read-only:

- pending settlement batches;
- settled on-chain batches or commitments;
- transaction hashes or settlement commitment identifiers;
- operator share;
- steward treasury share where applicable;
- reserve share where applicable;
- corrections and disputes.

### 5. Later Wallet or Token Functions

Public wallet, redemption, external transfer, or public token functions are later-scope only. Blockchain settlement rails are not optional for external economy release; they are the required finality layer before Passport presents economic settlement as final.

They require:

- lawful instrument approval;
- legal and tax review;
- treasury policy;
- user risk disclosures;
- abuse and fraud controls;
- accounting and reporting design;
- jurisdictional review where needed.

## MVP Sequence

The recommended Passport sequence is:

1. finish identity, device trust, and join approval;
2. finish bundled local node management;
3. add local service activity records;
4. add proof record templates and signing;
5. add read-only metering status;
6. define blockchain settlement contract or ledger interface;
7. add read-only blockchain settlement status after settlement records exist;
8. only later consider public wallet, token, redemption, or marketplace features.

## Release Gate

No public economy-facing Passport release should present settlement as final until:

- a blockchain settlement layer is selected and documented;
- settlement contract or ledger semantics are defined;
- metering handoff inputs are mapped to on-chain settlement batches or commitments;
- transaction finality, reversal limits, and correction policy are documented;
- wallet custody, key custody, and user risk boundaries are approved;
- legal, tax, treasury, and governance review approves the release posture.

Before that release gate is satisfied, Passport builds remain proof, metering, registrar-review, and settlement-readiness builds.

The chain-neutral settlement interface baseline is defined in `docs/archrealms-passport-blockchain-settlement-interface-2026-04-30.md`.

Chain selection and settlement contract criteria are defined in `docs/archrealms-passport-blockchain-selection-and-contract-criteria-2026-04-30.md`.

## Record Storage

Passport should store local proof and metering-related records under the workspace, for example:

- `records/passport/node-activity/`
- `records/passport/metering/proofs/`
- `records/passport/metering/submissions/`
- `records/passport/metering/status/`
- `records/passport/metering/admissions/`
- `records/passport/settlement/read-only/`

These are suggested app workspace paths, not canonical registry paths.

Canonical admission remains governed by registrar or governance systems outside ordinary Passport authority. The current Windows tooling can create a signed local admission record for a verified metering package, but that record is an admission artifact only and does not settle value.

Registrar review policy is defined in `docs/archrealms-passport-metering-admission-policy-2026-04-27.md`. It covers audit challenge, dispute, correction, and settlement handoff records while preserving the rule that handoff is not settlement.

Settlement handoff records are intended to become inputs to a blockchain settlement layer. They are not final because blockchain settlement finality has not occurred yet.

Blockchain settlement batch and read-only status records should use:

- `registry/templates/blockchain-settlement-batch-record.template.json`
- `registry/templates/blockchain-settlement-status-record.template.json`

The current dev implementation includes a mock blockchain settlement adapter that creates simulated batch and read-only status records from signed handoff records for Passport read-path testing. Mock finality does not satisfy the release gate.

Candidate chain evaluations should use:

- `registry/templates/blockchain-settlement-chain-evaluation.template.json`

The current tooling can create and verify candidate-chain evaluation records and compute whether the blockchain release gate is satisfied. Dev-only mock-chain evaluations remain non-release records.

## UI Rule

The app should avoid crypto-native labels in the MVP.

Prefer:

- `Service Activity`
- `Proofs`
- `Metering`
- `Internal Credits`
- `Settlement Status`

Avoid for now:

- `Wallet`
- `Token`
- `Coin`
- `Trade`
- `Exchange`
- `Cash Out`

This keeps the product aligned with the current architecture and avoids implying external financial functionality that does not exist.

## Non-Goals

The current pre-chain Passport roadmap does not include:

- public token issuance;
- speculative trading;
- governance voting by token ownership;
- external redemption;
- payment processing;
- tax reporting automation;
- investment-style yield claims;
- guaranteed payouts for nominal storage allocation.

It also does not include a public economy release before blockchain settlement finality is implemented.

## Acceptance for First Metering Milestone

The first Passport metering milestone is complete when:

- the app can display local node service activity;
- the workspace has stable folders for proof and metering records;
- at least one proof record template is defined;
- the app can prepare or preserve a signed proof-related record;
- no money, wallet, token, redemption, or marketplace function is implied by the UI.

Current implementation note:

- `node_capacity_snapshot_record` creation is implemented.
- `storage_assignment_acknowledgment_record` creation is implemented.
- `storage_epoch_proof_record` creation is implemented as a local deterministic segment-hash proof against a user-selected proof source file.
- `metering_status_record` creation is implemented as a local read-only summary of submitted proof claims.
- local payload-hash and device-signature verification for metering records is implemented.
- signed `passport_metering_admission_record` creation is implemented for verified metering report packages.
- registrar review policy templates are defined for admission, audit challenge, dispute, correction, and settlement handoff.
- signed `passport_metering_audit_challenge_record` creation and verification are implemented for admitted packages.
- signed `passport_metering_dispute_record` creation and verification are implemented for admitted packages and audit challenges.
- signed `passport_metering_correction_record` creation and verification are implemented for admitted packages, audit challenges, and disputes.
- signed `passport_metering_settlement_handoff_record` creation and verification are implemented for admitted packages and review records.
- blockchain settlement interface templates are defined for settlement batch commitment and read-only finality status.
- mock blockchain settlement batch/status creation and verification are implemented for settlement handoff read-path testing.
- blockchain settlement chain evaluation record creation and verification are implemented, including release-gate assessment.
- Network acceptance, audit, payout, and settlement remain deferred until metering authority, verification rules, and blockchain settlement finality are finalized.

## Bottom Line

Passport should earn the right to show economic information by first recording real service.

The correct order is:

- identity;
- node;
- service activity;
- proof;
- metering;
- blockchain settlement visibility;
- later legal-reviewed public token or wallet features, if still desired.
