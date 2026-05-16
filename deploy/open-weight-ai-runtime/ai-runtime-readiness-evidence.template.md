# AI Runtime Readiness Evidence

- Evidence ID: `<ai-runtime-readiness-evidence-id>`
- Lane: `ProductionMvp`
- Created UTC: `<yyyy-mm-ddThh:mm:ssZ>`
- Inference base URL: `<ARCHREALMS_PASSPORT_AI_INFERENCE_BASE_URL>`
- Model ID: `<ARCHREALMS_PASSPORT_AI_MODEL_ID>`
- Model artifact SHA-256: `<ARCHREALMS_PASSPORT_AI_MODEL_ARTIFACT_SHA256>`
- License approval ID: `<ARCHREALMS_PASSPORT_AI_MODEL_LICENSE_APPROVAL_ID>`
- Vector store provider: `<ARCHREALMS_PASSPORT_AI_VECTOR_STORE_PROVIDER>`
- Vector store ID: `<ARCHREALMS_PASSPORT_AI_VECTOR_STORE_ID>`
- Knowledge approval root: `<ARCHREALMS_PASSPORT_AI_KNOWLEDGE_APPROVAL_ROOT>`

## Required Evidence

Attach the JSON report from:

```powershell
.\tools\release\Test-PassportProductionMvpReadiness.ps1 `
  -EnvironmentFile <production-env> `
  -OutputPath .\artifacts\release\production-mvp-readiness-report.json
```

The report must show:

- `open_weight_ai_runtime` passed.
- `hosted_ai_runtime_probe` passed.
- `/ai/runtime/status` returned `ready=true`.
- `/ai/runtime/status` matched the approved production model ID, model artifact SHA-256, license approval ID, vector store provider, vector store ID, and knowledge approval root.
- `/ai/runtime/probe` returned `ready=true`.
- `/ai/runtime/probe` returned `runtime_answer_received=true`.
- `/ai/runtime/probe` returned the approved production model ID.
- The hosted gateway, not Passport clients, called the private OpenAI-compatible runtime.

Attach the model approval request, vector store provisioning record, and any runtime probe evidence from `Test-PassportOpenWeightAiRuntimeDeployment.ps1 -ProbeRuntime`.
