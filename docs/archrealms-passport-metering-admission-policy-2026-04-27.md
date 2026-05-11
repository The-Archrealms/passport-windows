# Archrealms Passport Metering Admission Policy

- Date: 2026-04-27
- Status: draft registrar policy baseline
- Scope: admitted Passport metering packages, audit challenge, dispute handling, correction records, and settlement handoff gates

## Purpose

Define the policy layer after a Passport metering report package has been verified and admitted.

This policy governs records and review gates only. It does not create settlement, payout, wallet balance, public token, redemption, trading, or marketplace functionality.

The external economy-facing Passport release is gated on blockchain settlement finality. These review records exist so that only reviewed metering inputs are submitted to the future blockchain settlement layer.

## Boundary

Admission means:

- a metering package was present;
- the package manifest hashes verified;
- the packaged authoritative metering report was present;
- the admission record was signed by an authorized Passport/device credential; and
- the package is eligible for registrar review.

Admission does not mean:

- final blockchain settlement approval;
- payout approval;
- escrow or settlement-contract release;
- token issuance;
- external transfer eligibility;
- governance power;
- citizenship, office, or registry authority.

## Record Classes

The registrar review path uses these records:

- `passport_metering_admission_record`
- `passport_metering_audit_challenge_record`
- `passport_metering_dispute_record`
- `passport_metering_correction_record`
- `passport_metering_settlement_handoff_record`

All records must preserve `settlement_status` unless and until a blockchain settlement system creates a valid final settlement record, transaction, or state commitment.

## Admission Review States

An admitted package may move through these review states:

- `admitted`: package verification passed and an admission record exists.
- `audit_pending`: registrar selected the package or proof subset for audit.
- `audit_passed`: requested audit evidence satisfied the review rule.
- `audit_failed`: requested audit evidence did not satisfy the review rule.
- `disputed`: a participant or registrar opened a dispute.
- `corrected`: a correction record supersedes all or part of the admitted totals.
- `eligible_for_settlement_handoff`: review gates are complete and the record may be referenced by the later blockchain settlement system.
- `rejected_for_settlement_handoff`: review gates failed or remain unresolved.

These are metering review states, not payment states.

## Audit Challenge Rule

A registrar may issue an audit challenge when:

- a package is newly admitted;
- a package exceeds policy thresholds;
- a participant's recent reliability falls below threshold;
- duplicate or conflicting proof evidence appears;
- a random sample selects the package;
- a dispute names the package; or
- a later governance rule requires challenge.

The first audit cadence is conservative:

- sample at least one accepted proof from every admitted package until production policy changes;
- sample additional proofs when accepted proof count, verified byte-seconds, or service class risk exceeds published thresholds;
- require deterministic challenge inputs to be recorded;
- require challenge deadline and evidence expectations to be recorded;
- preserve a challenge record even when the challenge is waived.

Current implementation note:

- signed `passport_metering_audit_challenge_record` creation is implemented for admitted metering packages;
- audit challenge verification checks signed payload hash and device signature;
- the record remains `not_settled` and does not submit or finalize blockchain settlement.

Current dispute implementation note:

- signed `passport_metering_dispute_record` creation is implemented for admitted packages and audit challenges;
- dispute verification checks signed payload hash and device signature;
- the record remains `not_settled` and does not create correction, handoff, payout, wallet, token, redemption, transfer, or blockchain settlement.

Current correction implementation note:

- signed `passport_metering_correction_record` creation is implemented for admitted packages, audit challenges, and disputes;
- correction verification checks signed payload hash and device signature;
- corrections supersede metering totals by reference and preserve original records unchanged;
- the record remains `not_settled` and does not create handoff, payout, wallet, token, redemption, transfer, or blockchain settlement.

Current settlement handoff implementation note:

- signed `passport_metering_settlement_handoff_record` creation is implemented for admitted packages and optional audit, dispute, and correction records;
- handoff verification checks signed payload hash and device signature;
- handoff uses corrected totals where a correction exists, otherwise admitted totals;
- the record remains `not_settled` and is only an input for future blockchain settlement review.

## Dispute Rule

A dispute record may be opened by:

- registrar review;
- the submitting participant;
- an affected content steward;
- a treasury or escrow reviewer after settlement systems exist; or
- a delegated metering authority.

Dispute records must identify:

- the admitted package;
- the challenged proof, report, or total;
- the requested remedy;
- evidence paths or references;
- opening party role;
- response deadline; and
- current disposition.

Dispute disposition values:

- `opened`
- `awaiting_response`
- `evidence_received`
- `accepted`
- `rejected`
- `withdrawn`
- `superseded_by_correction`

## Correction Rule

A correction record may adjust admitted metering totals only by explicit reference to:

- the original admission record;
- the package id;
- affected source report or proof records;
- prior accepted and rejected counts;
- corrected accepted and rejected counts;
- prior and corrected verified service units;
- reason for correction; and
- reviewer identity or registrar authority.

Corrections must not mutate original records. They supersede by reference.

Correction reason values:

- `audit_failure`
- `duplicate_proof`
- `invalid_signature`
- `hash_mismatch`
- `assignment_mismatch`
- `service_class_mismatch`
- `measurement_error`
- `dispute_resolution`
- `registrar_policy_update`

## Blockchain Settlement Handoff Gate

A settlement handoff record may be created only when:

- admission exists and verifies;
- required audit challenge records are complete or explicitly waived by policy;
- open disputes are resolved or excluded;
- corrections have been applied by reference;
- final metering totals are stated;
- settlement status remains `not_settled`;
- the handoff record says it is an input to a later blockchain settlement system, not settlement itself.

The handoff record should expose:

- admission record id;
- package id;
- final accepted proof count;
- final rejected proof count;
- final verified service units;
- unresolved exclusions, if any;
- registrar review status;
- policy version;
- handoff status.
- target chain or settlement layer, if known.
- intended settlement contract or ledger interface, if known.

Valid handoff statuses:

- `eligible_for_settlement_review`
- `held_for_dispute`
- `held_for_audit`
- `rejected_for_settlement_review`

## Passport UI Rule

Passport may display review status in read-only form:

- admitted;
- audit pending;
- dispute open;
- corrected;
- eligible for settlement review;
- held;
- rejected.

Passport must not label these states as paid, payable, redeemable, tokenized, withdrawable, or tradeable.

## Templates

Templates:

- `registry/templates/metering-admission-record.template.json`
- `registry/templates/metering-audit-challenge-record.template.json`
- `registry/templates/metering-dispute-record.template.json`
- `registry/templates/metering-correction-record.template.json`
- `registry/templates/metering-settlement-handoff-record.template.json`

## Bottom Line

Metering admission creates reviewable evidence.

Audit, dispute, correction, and settlement handoff policies decide whether that evidence can become an input to a later blockchain settlement system.

No record in this policy creates money, cryptocurrency, external redemption, or public market functionality.
