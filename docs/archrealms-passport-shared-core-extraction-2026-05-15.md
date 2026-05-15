# Archrealms Passport Shared Core Extraction

- Date: 2026-05-15
- Status: registry and monetary extraction slices implemented
- Project: `src/ArchrealmsPassport.Core`

## Purpose

`ArchrealmsPassport.Core` is the platform-neutral package for Passport protocol constants and validation rules that must stay identical across Windows, hosted services, and future Mac, iOS, and Android clients.

## Current Shared Surface

- AI gateway defaults:
  - local preview gateway URL;
  - approved MVP knowledge-pack ID;
  - AI session/chat endpoint paths;
  - AI gateway challenge audience.
- Record type constants used across Windows and hosted services.
- Monetary protocol constants and validation:
  - ARCH and CC asset-code normalization;
  - supported ARCH and CC ledger event types;
  - shared monetary signature-status labels;
  - wallet-authorized and wallet-prohibited scope semantics.
- Wallet-key binding validation:
  - required monetary signing scopes;
  - prohibited identity, citizenship, office, registry-authority, constitutional-status, and Crown-authority scopes;
  - wallet-key separation from identity and device identifiers;
  - production-strength RSA wallet-key parameter checks;
  - registry-inspector diagnostics for wallet-binding policy violations.
- Monetary ledger replay semantics:
  - ARCH genesis, transfer-in, and transfer-out balance rules;
  - CC issue, escrow, burn, refund, re-credit, transfer-in, and transfer-out balance rules;
  - deterministic overspend failure reporting while preserving replay state transitions.
- Monetary ledger replay verification:
  - duplicate event ID and anti-replay nonce detection;
  - ARCH genesis allocation uniqueness for production replay;
  - global-sequence monotonicity;
  - account-sequence and prior-account-event-hash validation;
  - release-lane, ledger-namespace, production-token, and staging-record isolation checks;
  - replay-derived balances for portable clients and verifier tools.
- Monetary account export verification:
  - account-export manifest record checks;
  - exported event file hash and event-hash verification;
  - transparency root recomputation;
  - inclusion proof verification;
  - account hash-chain verification;
  - exported key-history material hash checks and private-key exclusion;
  - manifest balance verification through the Core replay verifier.
- Monetary hash and Merkle helpers:
  - shared ledger event hash calculation;
  - shared transparency leaf hash calculation;
  - shared empty-root, parent-node, and Merkle-root calculation.
- Registry record inspection and envelope validation:
  - shared summary extraction for record type, record ID, created time, status, CID, signatures, wallet signatures, relative path, and SHA-256;
  - common envelope diagnostics for schema version, record type, identifier, created timestamp, signature object shape, and wallet-signature object shape;
  - placeholder-aware template inspection and shared top-level required-field diagnostics for packaged registry record families;
  - generated storage redemption quote, accepted, epoch-burn, and refund record-family diagnostics;
  - BOM-tolerant UTF-8 parsing while preserving original-byte hash calculation;
  - shared filter semantics for registry browser records and validation failures.
- AI non-authority policy:
  - fields AI must not be allowed to set;
  - reusable non-authority boundary record creation;
  - JSON validation that all forbidden authority fields are false;
  - private key, seed phrase, and recovery-secret prompt detection.

## Consumers

- Windows Passport references `ArchrealmsPassport.Core` for AI gateway defaults, record types, monetary asset/event constants, wallet authority scopes, monetary balance semantics, monetary replay/export verification, registry record inspection/filtering, AI authority boundary validation, and secret-material prompt blocking.
- `ArchrealmsPassport.HostedServices` references the same core package for hosted AI session/chat validation, hosted record-type creation, admin authority, telemetry access, backup manifest, and incident report record types.
- `tools/ledger-verifier` now targets platform-neutral `net8.0` and references Core directly instead of the Windows/WPF project.

## Remaining Extraction

- Continue expanding nested registry semantics beyond top-level record-family fields as schemas stabilize.
- Keep WPF, Windows tray behavior, MSIX packaging, DPAPI/Windows Hello, and Windows background process management outside Core.
