# Archrealms Passport Blockchain Selection and Contract Criteria

- Date: 2026-04-30
- Status: draft release-gate criteria
- Scope: chain selection, settlement contract requirements, custody boundary, and Passport read-only verification requirements

## Purpose

Define the criteria for choosing a blockchain settlement layer and the minimum settlement contract semantics required before public economy-facing Passport release.

This document does not select a chain. It defines the bar a candidate chain or settlement network must clear.

## Decision Boundary

The settlement layer must provide finality for metered service settlement.

It must not:

- sell citizenship, office, registry authority, or governance power;
- make token ownership constitutional authority;
- require Passport to custody user assets for the release-gate version;
- present unfinalized transactions as settled;
- allow local metering records to substitute for on-chain settlement finality.

## Candidate Chain Criteria

Candidate chains or settlement networks should be evaluated against:

- finality model and reorganization risk;
- transaction cost predictability;
- settlement throughput for epoch batches;
- contract maturity and auditability;
- long-term availability of public RPC or indexer access;
- ability to verify transactions from Passport without requiring custody;
- multisig or threshold signing support for registrar and treasury authorities;
- ecosystem support for stable development tooling;
- regulatory and tax posture for intended settlement units;
- operational continuity if a provider, indexer, bridge, or RPC endpoint fails;
- ability to keep detailed proof evidence off-chain while committing evidence roots on-chain;
- migration or emergency pause capability under published rules.

## Required Contract Semantics

The settlement contract or ledger interface must support:

- registering a settlement batch id;
- committing an evidence root hash;
- linking one or more settlement handoff record ids;
- recording the settlement epoch;
- recording the policy version and split rule id;
- recording participant outputs;
- recording the settlement unit or asset identifier;
- exposing transaction or state commitment status;
- emitting events that Passport can read through a public RPC or indexer;
- preventing duplicate settlement of the same handoff record id;
- supporting correction batches after finality without mutating historical settlement.

## Minimum Contract Methods

Equivalent methods or ledger operations should exist:

- `submitSettlementBatch`
- `getSettlementBatch`
- `isHandoffSettled`
- `getParticipantSettlement`
- `getBatchFinalityStatus`
- `submitCorrectionBatch`
- `pauseSettlement`
- `unpauseSettlement`

Names may vary by chain. Semantics matter more than exact method names.

## Required Events or Indexable Records

Equivalent emitted events or indexable records should exist:

- `SettlementBatchSubmitted`
- `SettlementBatchIncluded`
- `SettlementBatchFinalized`
- `ParticipantSettlementRecorded`
- `SettlementBatchCorrected`
- `SettlementPaused`
- `SettlementUnpaused`

Passport should be able to show read-only settlement state from these records.

## Finality Policy

Every candidate chain must document:

- finality type;
- confirmation or checkpoint threshold;
- expected time to finality;
- behavior during reorg, fork, outage, bridge failure, or contract pause;
- whether Passport may call a transaction final before a registrar indexer has confirmed it;
- how a later correction is linked to a final historical settlement.

Passport must only display `final` after the selected finality rule is satisfied.

## Custody and Signing Policy

The release-gate version should keep Passport read-only for settlement.

Settlement submission keys should be controlled by registrar, treasury, or settlement-service infrastructure, not ordinary Passport clients.

Required controls:

- multisig or threshold signing for settlement batch submission;
- separation between registrar review authority and treasury authority where practical;
- key rotation procedure;
- emergency pause procedure;
- documented authority for resubmission after failed transaction;
- audit log for every settlement batch submission.

## Off-Chain Evidence Policy

The settlement contract should not store full proof packages.

It should commit:

- evidence root hash;
- handoff record ids;
- package ids;
- correction and exclusion references;
- participant output summary.

Full evidence remains in Passport/registrar package storage and is verified by hash.

## Passport Read-Only Verification

Passport must be able to verify:

- the settlement batch references the expected handoff record id;
- the evidence root matches the off-chain package or manifest;
- the participant output includes the active identity or node;
- the finality status is `final` before showing final settlement;
- the settlement record has not been superseded by a visible correction.

Passport should expose status labels such as:

- `Not submitted`
- `Submitted`
- `Included`
- `Final`
- `Failed`
- `Superseded`

Passport should not expose transfer, redemption, or trading controls in this phase.

## Evaluation Template

Candidate chain evaluations should use:

- `registry/templates/blockchain-settlement-chain-evaluation.template.json`

## Current Dev Implementation

`New-ArchrealmsPassportBlockchainSettlementChainEvaluation.ps1` can create candidate-chain evaluation records.

`Verify-ArchrealmsPassportBlockchainSettlementChainEvaluation.ps1` recomputes release-gate status from the record fields and reports whether the evaluation is well formed and whether the release gate is satisfied.

The smoke path currently records a `dev_only` mock-chain evaluation. That verifies the evaluation shape but deliberately leaves `release_gate_satisfied` false.

## Open Decisions

The following remain undecided:

- settlement chain or network;
- settlement unit or asset;
- whether settlement uses a token, internal credit, or contract accounting unit;
- registrar/treasury signing authority;
- contract upgradeability policy;
- public RPC or indexer provider;
- legal and tax release posture.

## Bottom Line

The blockchain layer is not a brand feature. It is the finality mechanism that makes public economy-facing Passport release possible.

Passport should stay read-only until the chain, contract, custody, finality, and legal posture are selected and approved.
