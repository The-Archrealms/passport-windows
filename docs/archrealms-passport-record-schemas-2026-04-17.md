# Archrealms Passport Record Schemas

- Date: 2026-04-17
- Status: working schema note for Passport and registry development
- Scope: Passport identity records, device credential records, revocation records, and attestation records

## Purpose
Define the first concrete record shapes for the Passport system so that the Windows Passport app and later clients can emit consistent records for hashing, signing, registry publication, and IPFS packaging.

## General rule
These schemas define Archrealms-internal identity records. They do not attempt to function as public-law civil identification, state registration, or universal legal identity proof.

The schemas are designed for:

- pseudonymous or named Passport identities
- multiple Passport identities held by one person where desired
- many devices authorized beneath one Passport identity
- optional attestations and relation records
- later publication in the public registry and canonical archive

## Common fields
Every Passport record should preserve these fields unless the specific schema states otherwise:

- `schema_version`: the record schema version
- `record_type`: the specific record class
- `record_id`: the stable identifier of the record itself
- `created_utc`: record creation time in UTC
- `effective_utc`: time at which the record is intended to take effect
- `status`: `active`, `revoked`, `superseded`, `disputed`, or other lawful status
- `archrealms_identity_id`: the Passport identity to which the record belongs where applicable
- `summary`: short human-readable description

Record packages should also preserve hashes, signatures, manifests, and publication notices according to the archive instruments already in force or in draft.

## Record 1: Passport identity record
The Passport identity record is the anchor record for one Archrealms identity or persona.

Required fields:

- `schema_version`
- `record_type` = `passport_identity_record`
- `record_id`
- `created_utc`
- `effective_utc`
- `status`
- `archrealms_identity_id`
- `display_name`
- `identity_mode`
- `summary`

Recommended fields:

- `citizenship_class`: such as `citizen`, `member`, `officer`, `steward`, or another later class
- `public_biography`: optional short description
- `declared_scope`: optional statement of the identity's intended use, such as `personal`, `artistic`, `house`, `office`, or `project`
- `recovery_authority`: reference to the active recovery authority record or method
- `attestation_refs`: optional list of supporting attestation record identifiers
- `supersedes_record_id`: optional link if the identity record replaces an earlier version

Notes:

- `identity_mode` may preserve advanced registry semantics such as `named`, `pseudonymous`, `anonymous`, or `ceremonial`, but the Windows Passport app should default normal first-run identities to `named` and not ask ordinary users to choose among these modes
- the Passport identity record does not prove civil identity merely by existing
- the same person may hold many Passport identity records

## Record 2: Device credential record
The device credential record authorizes one device key to act for one Passport identity.

Required fields:

- `schema_version`
- `record_type` = `device_credential_record`
- `record_id`
- `created_utc`
- `effective_utc`
- `status`
- `archrealms_identity_id`
- `device_id`
- `device_label`
- `public_key_algorithm`
- `public_key_format`
- `public_key_path`
- `public_key_sha256`
- `authorized_scopes`
- `summary`

Recommended fields:

- `device_class`: such as `desktop`, `laptop`, `phone`, `tablet`, `server`, `hardware-key`, or `node`
- `client_platform`: such as `windows`, `android`, or another later client family
- `credential_origin`: such as `passport-windows`, `passport-android`, `manual-import`, or another lawful source
- `expires_utc`: optional expiration time
- `revocation_record_id`: filled if later revoked
- `attestation_refs`: optional list of supporting attestations

Notes:

- one Passport identity may have many active device credential records
- `authorized_scopes` should be explicit, for example `authenticate`, `submit_registry_record`, `publish_archive`, `storage_contributor`, or `office_use`
- the public key may be embedded in a package, but the record should still preserve a stable path or reference used by the package manifest

## Record 3: Device revocation record
The device revocation record withdraws authority from a previously authorized device credential.

Required fields:

- `schema_version`
- `record_type` = `device_revocation_record`
- `record_id`
- `created_utc`
- `effective_utc`
- `status`
- `archrealms_identity_id`
- `revoked_device_record_id`
- `device_id`
- `revocation_reason`
- `summary`

Recommended fields:

- `supersedes_credential_status`: such as `active`
- `replacement_device_record_id`: optional replacement credential
- `incident_reference`: optional local incident or continuity reference

Notes:

- revocation should preserve history rather than deleting the old device record
- common `revocation_reason` values may include `lost`, `compromised`, `retired`, `replaced`, `destroyed`, or `withdrawn_by_identity`

## Record 4: Attestation record
The attestation record is an optional supporting record declaring that a fact, relation, or identity claim has been witnessed or affirmed.

Required fields:

- `schema_version`
- `record_type` = `attestation_record`
- `record_id`
- `created_utc`
- `effective_utc`
- `status`
- `attestation_type`
- `subject_record_ids`
- `attestor_label`
- `attestation_statement`
- `summary`

Recommended fields:

- `attestor_identity_id`: optional Passport identity of the attestor
- `attestor_external_reference`: optional external or legal reference where the attestor wishes to provide one
- `evidence_refs`: optional list of attached or linked evidence references
- `scope_note`: optional note describing the intended scope or limits of the attestation

Notes:

- attestations are optional support records, not mandatory central validation
- an attestation may concern a named identity, a pseudonymous identity, a device relation, a lineage claim, or another lawful fact

## Packaging rule
When these records are published, they should ordinarily be packaged with:

- the record JSON file
- any linked public key material needed for verification
- detached signatures or signature records
- a manifest listing the governed files and their hashes
- a publication notice if the package is published through IPFS or another content-addressed system

## Template files
The first template files for these schemas are provided under:

- `records/registry/templates/passport-identity-record.template.json`
- `records/registry/templates/device-credential-record.template.json`
- `records/registry/templates/device-revocation-record.template.json`
- `records/registry/templates/attestation-record.template.json`

## Limits
- these schemas are working development schemas, not yet binding decree text
- they define record shape, not final governance thresholds for admission or attestation
- they do not require any Passport identity to be linked to external legal identity
