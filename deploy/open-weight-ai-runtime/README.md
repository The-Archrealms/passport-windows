# Passport Open-Weight AI Runtime Deployment

This folder contains deployment templates for the private open-weight model runtime used by the Passport hosted AI gateway.

Passport clients never call this runtime directly. Windows Passport authenticates to the hosted AI gateway, and the gateway calls an OpenAI-compatible `/v1/chat/completions` endpoint configured by `ARCHREALMS_PASSPORT_AI_INFERENCE_BASE_URL`.

## Runtime Choices

Two container templates are provided:

- `docker-compose.vllm.yml`: preferred default for vLLM OpenAI-compatible serving.
- `docker-compose.tgi.yml`: fallback for Hugging Face Text Generation Inference when the selected model or deployment target is better supported there.

Both templates bind the model runtime to `127.0.0.1` for local validation. Production deployments should put the runtime on a private network behind TLS and expose only the hosted AI gateway to Passport clients.

## Environment

Create a secure env file from the template:

```powershell
Copy-Item .\deploy\open-weight-ai-runtime\open-weight-ai-runtime.env.template `
  .\artifacts\release\open-weight-ai-runtime.env
```

Populate the values in a secure deployment environment. Do not commit populated env files.

Required production readiness values:

- `ARCHREALMS_PASSPORT_AI_INFERENCE_BASE_URL`
- `ARCHREALMS_PASSPORT_AI_MODEL_ID`
- `ARCHREALMS_PASSPORT_AI_MODEL_ARTIFACT_SHA256`
- `ARCHREALMS_PASSPORT_AI_MODEL_LICENSE_APPROVAL_ID`
- `ARCHREALMS_PASSPORT_AI_VECTOR_STORE_PROVIDER`
- `ARCHREALMS_PASSPORT_AI_VECTOR_STORE_ID`
- `ARCHREALMS_PASSPORT_AI_KNOWLEDGE_APPROVAL_ROOT`

The hosted gateway reads the same values for `/ai/runtime/status` and `/ai/runtime/probe`.

## Production Approval Packet

Before loading production AI values into the readiness environment, fill and approve:

- `model-approval-request.template.md`
- `vector-store-provisioning.template.md`
- `ai-runtime-readiness-evidence.template.md`

These templates record the approved model artifact SHA-256, license approval ID, private inference endpoint, vector store provider and ID, knowledge approval root, and the readiness evidence proving `/ai/runtime/status` and `/ai/runtime/probe` pass through the hosted gateway.

## Local Validation

Validate the deployment files without starting the model runtime:

```powershell
.\tools\release\Test-PassportOpenWeightAiRuntimeDeployment.ps1
```

If a local or private runtime is already running, run the non-mutating probe:

```powershell
.\tools\release\Test-PassportOpenWeightAiRuntimeDeployment.ps1 `
  -ProbeRuntime `
  -RuntimeBaseUrl http://127.0.0.1:8000/v1 `
  -ModelId Qwen/Qwen3-8B
```

The production readiness gate still requires the hosted AI gateway `/ai/runtime/status` and `/ai/runtime/probe` endpoints to pass with the approved runtime, model artifact hash, license approval, vector store, and knowledge approval root configured.

## vLLM

```powershell
docker compose `
  --env-file .\artifacts\release\open-weight-ai-runtime.env `
  -f .\deploy\open-weight-ai-runtime\docker-compose.vllm.yml `
  up -d
```

The runtime should answer OpenAI-compatible chat requests at `/v1/chat/completions`.

## TGI

```powershell
docker compose `
  --env-file .\artifacts\release\open-weight-ai-runtime.env `
  -f .\deploy\open-weight-ai-runtime\docker-compose.tgi.yml `
  up -d
```

Use TGI only after verifying the selected model exposes an OpenAI-compatible chat route that matches the gateway contract.
