# Open-Weight Model Approval Request

- Approval ID: `<ARCHREALMS_PASSPORT_AI_MODEL_LICENSE_APPROVAL_ID>`
- Lane: `ProductionMvp`
- Model ID: `<ARCHREALMS_PASSPORT_AI_MODEL_ID>`
- Model artifact SHA-256: `<ARCHREALMS_PASSPORT_AI_MODEL_ARTIFACT_SHA256>`
- Runtime provider: `<ARCHREALMS_PASSPORT_AI_RUNTIME_PROVIDER>`
- Runtime image: `<ARCHREALMS_PASSPORT_AI_RUNTIME_IMAGE>`
- Inference base URL: `<ARCHREALMS_PASSPORT_AI_INFERENCE_BASE_URL>`

## Approval Requirements

- The model must be open weight and approved for hosted Crown-funded citizen use.
- The model license must permit the intended Passport AI guide use case.
- The exact model artifact or snapshot must have a SHA-256 hash recorded in `ARCHREALMS_PASSPORT_AI_MODEL_ARTIFACT_SHA256`.
- The runtime image must be pinned to an approved tag or digest before production.
- Passport clients must not call the model runtime directly; only the hosted AI gateway may call the private OpenAI-compatible `/v1/chat/completions` endpoint.
- The AI guide remains non-authoritative and cannot approve recovery, wallet changes, credit issuance, escrow release, burns, storage delivery, registry authority, or admin actions.

## Evidence

- License review: `<license-review-reference>`
- Model artifact source: `<artifact-source-reference>`
- Artifact hash command/output: `<hash-evidence-reference>`
- Safety/privacy review: `<safety-privacy-review-reference>`
- Runtime validation report: `artifacts/release/open-weight-ai-runtime-deployment-validation-report.json`
