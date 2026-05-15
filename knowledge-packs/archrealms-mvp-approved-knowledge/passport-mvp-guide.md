# Archrealms Passport MVP Guide Knowledge Pack

Knowledge pack ID: `archrealms-mvp-approved-knowledge`

Approval scope: Token-Ready Passport MVP guide answers for citizen onboarding, Passport identity, wallet-key separation, hosted AI boundaries, Service Credit redemption, storage contribution, registry browsing, and support-oriented troubleshooting.

## Passport Identity

Passport identity authenticates a citizen and authorized device. It is separate from wallet signing. Identity signatures can authorize authentication, registry submissions, device binding, and wallet binding or revocation records. Identity signatures must not move ARCH or Crown Credit.

## Wallet Key Separation

Passport uses a separate wallet key for asset and redemption operations. Wallet signatures can sign monetary ledger events, redemption requests, and wallet-key rotation or revocation flows. Wallet signatures must not change citizenship, office, constitutional authority, registry authority, or identity status.

## ARCH

ARCH is a fixed-genesis network reserve asset. It is generated once at genesis, highly divisible, and has no post-genesis minting path. Crown Credit issuance, emergency issuance, Crown reserve operations, storage auctions, AI usage, and treasury events cannot create ARCH. ARCH ownership grants no citizenship, office, vote, registry authority, constitutional authority, Crown authority, yield, guaranteed savings, or guaranteed buyback.

## Crown Credit

Crown Credit, abbreviated CC, is a Crown service-liability currency for listed Crown-administered services. It is not fiat, not legal tender, not a deposit, not equity, not token governance, not a fixed ARCH conversion promise, and not a guaranteed investment return. CC issuance must be constrained by conservative deliverable service capacity. CC issuance must not create ARCH or add ARCH to Crown reserves.

## Storage Contribution

Citizen contribution of storage, compute, labor, money, bandwidth, or attention is voluntary and revocable. Passport must not contribute storage until the user affirmatively enables it. The Windows Passport default suggested storage limit is 1 GB when contribution is enabled. Storage controls belong in the Storage tab. Storage contribution must expose disk limits, network behavior, unmetered-network enforcement, pause or stop controls, revocation behavior, and local data deletion expectations.

## Storage Redemption

CC storage redemption uses quote, escrow, delivery proof, burn, refund, re-credit, and service-extension records. CC should move to escrow when a storage redemption is accepted. Credits burn only as service epochs are verified. Failed epochs must trigger re-credit or service extension under published service terms. Proofs should include assignment, encrypted object or chunk manifest, possession challenge, retrieval challenge, metering, repair status, and signed evidence.

## Registry Browser

The Passport registry browser lets citizens inspect approved registry records and cached IPFS content. Registry browsing is read-only unless the citizen prepares and publishes a signed registration package. Read-only CID preview, fetch, and CAR export controls are inspection tools, not monetary or governance actions.

## Hosted AI

Hosted AI is a Crown-funded guide during MVP. Passport authenticates the citizen and device into the AI gateway using a signed Passport challenge and receives a short-lived AI session token. The session token is separate from wallet keys and cannot sign wallet operations, authorize recovery, issue credits, release escrow, mark storage delivered, burn credits, change registry authority, override identity status, or approve admin authority.

## AI Privacy

Prompts, support messages, diagnostics, storage telemetry, ledger exports, and private Passport state are not used for model training by default. Private diagnostics require explicit opt-in before upload. Raw prompts and responses should be retained only for limited abuse, safety, debugging, and service reliability windows. Immutable AI audit records should store metadata, hashes, source IDs, policy versions, model versions, and knowledge-pack IDs rather than secrets or full private transcripts.

## AI Safety Boundaries

The AI guide can answer questions from approved Archrealms docs and public registry records, explain Passport concepts, guide users through Passport controls, and summarize user-provided diagnostics only after explicit opt-in. The AI guide can be wrong and is not legal, financial, tax, accounting, securities, custody, or medical advice. Users should not paste wallet private keys, device private keys, seed material, recovery secrets, or auto-approved signing prompts into AI.

## Release Lanes

Passport release lanes separate development, internal verification, staging, canary MVP, and production MVP behavior. Staging and production must use separate endpoints, logs, model artifacts, vector stores, telemetry, token namespaces, and authority policies. Token-ready MVP behavior requires controlled production-intended rules, not fake balances or fake tokens.

## Open-Weight Model Serving

The Archrealms AI guide runs in Crown-controlled cloud infrastructure. Passport talks only to the Archrealms AI gateway. The gateway performs authorization, quota enforcement, retrieval, prompt construction, logging, and routing to an internal open-weight model runtime. The default runtime target is vLLM behind an OpenAI-compatible API, with Hugging Face Text Generation Inference as an approved fallback. Passport must not call vLLM, TGI, cloud model endpoints, or model hosts directly.
