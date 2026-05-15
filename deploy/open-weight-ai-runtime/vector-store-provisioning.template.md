# AI Vector Store And Knowledge Approval Provisioning

- Provisioning ID: `<ai-vector-store-provisioning-id>`
- Lane: `ProductionMvp`
- Vector store provider: `<ARCHREALMS_PASSPORT_AI_VECTOR_STORE_PROVIDER>`
- Vector store ID: `<ARCHREALMS_PASSPORT_AI_VECTOR_STORE_ID>`
- Knowledge approval root: `<ARCHREALMS_PASSPORT_AI_KNOWLEDGE_APPROVAL_ROOT>`

## Scope

The vector store may contain only approved Archrealms knowledge-pack content, retrieval metadata, embeddings, and non-secret document references required by the hosted AI gateway.

## Requirements

- Knowledge-pack source documents must be approved before ingestion.
- `ARCHREALMS_PASSPORT_AI_KNOWLEDGE_APPROVAL_ROOT` must identify the approved knowledge-pack root, hash, or controlled document set.
- Raw AI prompts must not be used for training by default.
- Private wallet keys, recovery secrets, PII beyond approved support metadata, and storage payload contents must not be ingested.
- Retrieval logs must follow the approved telemetry-retention policy.
- The hosted AI gateway must enforce quota and non-authority policy before invoking retrieval or inference.

## Evidence

- Knowledge approval root/hash: `<knowledge-approval-root-evidence>`
- Vector store creation record: `<vector-store-record>`
- Ingestion manifest: `<ingestion-manifest-reference>`
- Redaction/privacy review: `<privacy-review-reference>`
- `/ai/runtime/status` showed vector store provider, vector store ID, and knowledge approval root configured.
