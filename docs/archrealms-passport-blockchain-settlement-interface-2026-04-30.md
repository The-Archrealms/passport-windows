# Archrealms Passport Blockchain Settlement Interface

- Date: 2026-04-30
- Status: draft release-gate interface
- Scope: chain-neutral settlement interface for Passport metering handoff, on-chain commitment, and read-only settlement status

## Purpose

Define the boundary between Passport metering records and the blockchain settlement layer required before public economy-facing release.

This document does not select a chain, issue a token, define redemption, or approve public wallet functionality. It defines the minimum interface Passport and registrar tooling need so reviewed metering evidence can become final on-chain settlement.

## Release Gate

Public economy-facing Passport release remains blocked until:

- a settlement chain or settlement network is selected;
- settlement contract or ledger semantics are documented;
- finality rules are documented;
- custody and signing responsibilities are approved;
- legal, tax, treasury, and governance review approves the release posture;
- Passport can read settlement status without treating local metering records as final settlement.

Chain-selection and settlement-contract criteria are defined in `docs/archrealms-passport-blockchain-selection-and-contract-criteria-2026-04-30.md`.

## Settlement Split

### Off-Chain Evidence

The following should remain off-chain, content-addressed, and hash-committed:

- source proof records;
- detached signed payloads;
- metering package manifests;
- admission records;
- audit challenge records;
- dispute records;
- correction records;
- settlement handoff records.

Off-chain evidence preserves explainability and audit detail without forcing every proof artifact onto the settlement chain.

### On-Chain Commitment

The blockchain settlement layer should commit:

- settlement batch id;
- policy version;
- registrar or settlement authority id;
- metering handoff record ids;
- evidence root hash;
- participant settlement outputs;
- split rule id;
- token, credit, or unit identifier if one exists;
- settlement epoch;
- finality rule;
- correction or dispute exclusion references;
- transaction hash or state commitment.

The on-chain commitment is the final settlement surface. The off-chain package explains it.

## Required Interface

A settlement implementation must expose these concepts to Passport:

- `chain_id`
- `settlement_contract`
- `settlement_method`
- `settlement_batch_id`
- `settlement_epoch_id`
- `settlement_tx_hash`
- `settlement_block_height`
- `settlement_finality_status`
- `finality_confirmations_required`
- `finality_confirmations_observed`
- `evidence_root_sha256`
- `handoff_record_ids`
- `participant_outputs`
- `settlement_status`

Passport must treat any settlement record as non-final until `settlement_finality_status` is `final`.

## Finality States

Settlement finality states:

- `not_submitted`: no blockchain settlement transaction or commitment exists.
- `submitted`: transaction or commitment was submitted but not yet included.
- `included`: transaction or commitment appears on chain but finality threshold is not met.
- `final`: finality rule is satisfied.
- `failed`: submission failed or reverted.
- `superseded`: a later correction or settlement record supersedes the visible status.

Only `final` may be shown as final settlement.

## Participant Outputs

Participant output entries should include:

- `archrealms_identity_id`
- `node_id`
- `settlement_role`
- `service_class`
- `metering_units`
- `settlement_units`
- `asset_or_credit_id`
- `destination_account`
- `settlement_status`

The interface allows a future token, internal credit, or contract accounting unit without requiring Passport to implement a public wallet in the pre-release phase.

## Custody Boundary

For the release-gate version, Passport should be read-only for settlement status.

Passport should not:

- custody settlement contract administrator keys;
- submit settlement transactions automatically;
- expose public token transfer controls;
- expose redemption controls;
- imply cash-out;
- let settlement units buy citizenship, office, registry authority, or governance power.

Settlement submission should be a registrar, treasury, or settlement-service responsibility until a later wallet/custody design is separately approved.

## Correction After Finality

Blockchain settlement finality means the transaction or commitment is final. It does not mean the underlying policy can never recognize an error.

If an error is discovered after finality:

- the original on-chain settlement remains historically final;
- the correction must be represented by a new correction record;
- any economic adjustment must be represented by a later settlement batch;
- Passport must display the original settlement and the superseding adjustment as distinct records.

No local record may rewrite a finalized blockchain settlement.

## Templates

Templates:

- `registry/templates/blockchain-settlement-batch-record.template.json`
- `registry/templates/blockchain-settlement-status-record.template.json`
- `registry/templates/blockchain-settlement-chain-evaluation.template.json`

## Current Dev Implementation

`New-ArchrealmsPassportMockBlockchainSettlement.ps1` can consume a signed settlement handoff record and produce simulated blockchain settlement batch and read-only status records for Passport read-path testing.

This adapter is not a real settlement rail. Its finality is marked simulated only and does not satisfy the public economy-facing release gate.

## Bottom Line

Passport can build proof and metering infrastructure before release.

Public economy-facing release requires blockchain settlement finality, and Passport must read finality from the settlement layer rather than infer it from local records.
