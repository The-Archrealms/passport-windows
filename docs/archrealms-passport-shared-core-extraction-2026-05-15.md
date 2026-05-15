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
- Monetary ledger replay semantics:
  - ARCH genesis, transfer-in, and transfer-out balance rules;
  - CC issue, escrow, burn, refund, re-credit, transfer-in, and transfer-out balance rules;
  - deterministic overspend failure reporting while preserving replay state transitions.
- Registry record inspection and envelope validation:
  - shared summary extraction for record type, record ID, created time, status, CID, signatures, wallet signatures, relative path, and SHA-256;
  - common envelope diagnostics for schema version, record type, identifier, created timestamp, signature object shape, and wallet-signature object shape;
  - BOM-tolerant UTF-8 parsing while preserving original-byte hash calculation;
  - shared filter semantics for registry browser records and validation failures.
- AI non-authority policy:
  - fields AI must not be allowed to set;
  - reusable non-authority boundary record creation;
  - JSON validation that all forbidden authority fields are false;
  - private key, seed phrase, and recovery-secret prompt detection.

## Consumers

- Windows Passport references `ArchrealmsPassport.Core` for AI gateway defaults, record types, monetary asset/event constants, wallet authority scopes, monetary balance semantics, registry record inspection/filtering, AI authority boundary validation, and secret-material prompt blocking.
- `ArchrealmsPassport.HostedServices` references the same core package for hosted AI session/chat validation, hosted record-type creation, admin authority record types, and telemetry access record types.

## Remaining Extraction

- Continue moving wallet-key binding validation into Core while leaving OS key storage platform-specific.
- Move ledger replay/export verifier logic into Core.
- Continue expanding registry record schema validation beyond the common envelope as record families stabilize.
- Keep WPF, Windows tray behavior, MSIX packaging, DPAPI/Windows Hello, and Windows background process management outside Core.
