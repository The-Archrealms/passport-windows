# Archrealms Passport Shared Core Extraction

- Date: 2026-05-15
- Status: first extraction slice implemented
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
- AI non-authority policy:
  - fields AI must not be allowed to set;
  - reusable non-authority boundary record creation;
  - JSON validation that all forbidden authority fields are false;
  - private key, seed phrase, and recovery-secret prompt detection.

## Consumers

- Windows Passport references `ArchrealmsPassport.Core` for AI gateway defaults, record types, AI authority boundary validation, and secret-material prompt blocking.
- `ArchrealmsPassport.HostedServices` references the same core package for hosted AI session/chat validation and hosted record-type creation.

## Remaining Extraction

- Move monetary record constants and validation into Core.
- Move wallet-key binding semantics into Core while leaving OS key storage platform-specific.
- Move ledger replay/export verifier logic into Core.
- Move registry record schemas and validation into Core.
- Keep WPF, Windows tray behavior, MSIX packaging, DPAPI/Windows Hello, and Windows background process management outside Core.
