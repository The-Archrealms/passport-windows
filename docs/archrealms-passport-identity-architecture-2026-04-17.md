# Archrealms Passport Identity Architecture

- Date: 2026-04-17
- Status: working architecture note for passport and registry development
- Scope: citizen identity, device authorization, authentication, registry publication, and the role of IPFS

## Purpose
Define the first deliberate identity model for the Archrealms Passport system so that a Passport identity is stable across many devices, device loss does not destroy control of that identity, and archival publication remains distinct from authentication.

## Governing principles
- Passport identity is identity-bound, not device-bound
- one Passport identity may act through many authorized devices without fragmenting that identity across many machines
- device credentials may be granted, rotated, or revoked without destroying the Passport identity
- the Archrealms should not attempt to operate as a central civil-identity authority
- uniqueness of natural persons should not be compelled by a central mechanism
- one natural person may maintain multiple Passport identities if they so choose
- citizenship or standing within the Archrealms may attach to a Passport identity without constituting state-style civil identification
- no record is authenticated merely because it is present in the public registry or published through IPFS
- IPFS and other content-addressed systems are publication, retrieval, and continuity layers, not the source of citizen authentication
- lawful standing, authentication, and evidentiary weight depend on signatures, attestations, authorization records, and other proper proofs

## Identity layers
The Passport identity system should be understood in distinct layers:

- `passport identity layer`: the durable Archrealms identity or persona through which a person acts
- `credential layer`: the keys, devices, recovery methods, and authorization records by which that Passport identity may act
- `registry layer`: the public identity, attestation, and device-authorization records preserved in the Archrealms registry
- `publication layer`: IPFS, IPNS, local archives, mirrors, and other systems through which the signed records are distributed

No later layer should be confused with the earlier one. Publication does not create identity, and storage does not create authority.

## Core records
The system should distinguish at minimum:

- `passport identity record`: a stable Archrealms identity record, including identity identifier, display style or name, any declared role or standing, and references to current credential authority
- `device credential record`: a record naming a particular device key as authorized to act for a Passport identity
- `device revocation record`: a record withdrawing authority from a device key
- `recovery authority record`: a record defining the authority by which a Passport identity may recover or reconstitute control after device loss or compromise
- `attestation record`: a signed declaration concerning identity, standing, office, lineage, or other relevant fact

## Passport identity model
The system should support durable Archrealms identities that persist across phones, desktops, laptops, and later passport clients.

No one machine should be equated with the identity it serves. Instead, any given Passport identity should be anchored by an identity authority capable of authorizing devices and recovering that identity when necessary. In implementation terms, this authority may be one key, a threshold of keys, a recovery instrument, or another lawful method established by later rule.

The Passport identity record should therefore be treated as the stable anchor for that identity, while devices remain subordinate credentials beneath it.

This architecture should not assume that one natural person can or must possess only one Passport identity throughout the entire Archrealms. The system may preserve multiple identities where anonymity, pseudonymity, ceremony, art, privacy, separate projects, or deliberate plurality have given rise to them.

## Civil identity out of scope
The Archrealms should not create one central bureau charged with conclusively validating the real-world civil identity of all persons.

Civil identity authentication is ordinarily handled by the sovereign states and legal systems in which people already live. Within the Archrealms, a Passport identity should therefore be understood as an internal identity or persona, not as a universal claim of legal personhood accepted everywhere.

Where a person wishes to link a Passport identity to external legal or civil identity evidence, that should occur only by optional attestation, covenant, or supporting record, not by mandatory central validation.

## Pseudonymous and plural identities
The Passport system should tolerate anonymous, pseudonymous, and plural identities without pretending that software alone should collapse them into one canonical human record.

Where multiple Passport identities appear to be related, the system may preserve optional relation or attestation records, but no global merge should be treated as mandatory merely for the convenience of the software.

## Device authorization model
Each participating device should have its own keypair and its own device identifier.

A device becomes authorized only when a lawful authorization record links that device key to a Passport identity. That record should preserve at minimum:

- the identity identifier
- the device identifier
- the device public key
- the scope of authority granted to the device
- the time of authorization
- the signature or signatures required to prove that authorization

Different devices may be granted different scopes. For example:

- one device may authenticate ordinary Passport sessions
- one device may submit public registry records
- one device may contribute storage or bandwidth as an archival node
- one device may hold elevated authority for recovery or office use

## Authentication model
Passport authentication should occur by challenge-response signing, not by mere possession of a public record.

The ordinary authentication flow should be:

1. the Passport client requests or generates a challenge
2. an authorized device signs that challenge with its local device key
3. the verifier confirms that the device key is currently authorized for the Passport identity
4. the verifier accepts the act only within the scope granted to that device credential

This model allows one Passport identity to authenticate from many devices while preserving revocation and auditability.

## Recovery and replacement
Because devices may be lost, replaced, sold, broken, or compromised, the Passport identity must survive beyond any one device.

The identity model should therefore support:

- addition of new devices without replacing the Passport identity
- revocation of lost or compromised devices
- recovery by identity authority or other lawful recovery method
- historical preservation of prior device-authority records and revocations for audit and proof

Recovery should restore the identity's authority to authorize new devices, not merely recreate a local app profile.

## Registry role
The public registry should preserve the public-facing records necessary to understand identity and standing within the Archrealms, including:

- Passport identity records
- authorized device records suitable for publication
- revocation notices
- identity-related attestations

Admission to the public registry means that the record is received, classified, preserved, and published. It does not by itself mean that the Crown guarantees the truth of the record or that the record authenticates any later act without signature verification and other proper evidence.

## Role of IPFS and IPNS
IPFS and related content-addressed systems should be used to publish and replicate signed identity materials, not to serve as the source of authentication.

Their proper role is:

- preserve and distribute signed identity and device records
- provide content-addressed retrieval of canonical identity packages
- support independent verification of the exact published package
- provide resilient publication paths independent of any one commercial host

IPNS or another signed naming layer may be used as a mutable pointer to the current identity package or current device-authorization package. Even then, the operative proof remains the signature chain and authorization records, not the mere existence of the pointer.

## Privacy and publicity rule
Where the Archrealms chooses to treat identity and standing records as public registry material, those records may be published as public record. Where narrower custody is needed, such materials should be preserved under the appropriate non-public archive class rather than silently treated as public merely because a software client generated them.

Nothing in this architecture implies that every local device detail, telemetry artifact, or recovery material must be made public merely because a citizen uses the Passport.

## Windows Passport MVP direction
The Windows Passport should evolve toward this architecture in stages.

### Stage 1
- local Passport identity profile
- local device key generation or import
- local display of device identifier and public key fingerprint
- local signing of challenges and registry submissions

### Stage 2
- generation and preservation of device authorization packages
- publication of signed identity and device records into the Archrealms registry
- publication of optional attestation records into the Archrealms registry
- revocation workflow for lost or compromised devices

### Stage 3
- multi-device management under one Passport identity
- management of multiple Passport identities by one user where desired
- recovery workflows
- contribution accounting for storage, compute, or bandwidth rolled up to one Passport identity

## Android and later clients
Android and later Passport clients should use the same identity model:

- many authorized devices
- signature-based authentication
- registry-backed authorization, revocation, and optional attestation

Platform differences should affect only credential storage and user experience, not the constitutional or registry meaning of identity.

## Limits
- this architecture note does not by itself constitute a decree, instrument, or authoritative registry rule
- no client application may claim to authenticate a Passport identity merely by reading public registry data without verifying the relevant signatures and authorization chain
- no IPFS publication, CID, IPNS name, or PeerID shall be treated as synonymous with a Passport identity without the lawful records that connect it to that identity

## Linked schema note
The first concrete record shapes for this architecture are defined in `docs/archrealms-passport-record-schemas-2026-04-17.md` and the template JSON records under `records/registry/templates/`.
