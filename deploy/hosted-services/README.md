# Passport Hosted Services Deployment

This folder contains the cloud-neutral container baseline for the Passport hosted API and AI gateway. It packages `src/ArchrealmsPassport.HostedServices` only; the open-weight model runtime, vector store, managed signing endpoint, managed storage provider, telemetry destination, and release approvals remain external production infrastructure.

The container exposes the gateway on port `8080` and stores hosted records under:

```text
/var/lib/archrealms/passport-hosted
```

The mounted data root is expected to be backed by managed durable storage in staging and production. Local container volumes are acceptable only for development and staging smoke checks.

## Build

From the repo root:

```powershell
docker build `
  -f .\deploy\hosted-services\Dockerfile `
  -t archrealms/passport-hosted-services:staging .
```

## Staging Compose

Create the local staging env file from the template:

```powershell
Copy-Item `
  .\deploy\hosted-services\hosted-services-staging-env.template `
  .\deploy\hosted-services\hosted-services.staging.env
```

Fill the copied file with staging values from the staging secret store, then run:

```powershell
docker compose `
  -f .\deploy\hosted-services\docker-compose.staging.yml `
  up --build
```

Smoke-check the public status endpoints:

```powershell
Invoke-RestMethod http://localhost:8080/health
Invoke-RestMethod http://localhost:8080/ai/runtime/status
Invoke-RestMethod http://localhost:8080/ops/runtime/status
```

Operator-protected endpoints such as `/ops/operator/status`, `/ops/storage/status`, and `/ai/runtime/probe` require the raw operator key in `X-Archrealms-Operator-Key`. The hosted service should only receive `ARCHREALMS_PASSPORT_HOSTED_OPERATOR_API_KEY_SHA256`.

## Validation

Run the deployment validator from the repo root:

```powershell
.\tools\release\Test-PassportHostedServicesDeployment.ps1
```

The validator checks the deployment files, publishes the hosted service in Release mode, and writes:

```text
artifacts/release/hosted-services-deployment-validation-report.json
```

To also build the Docker image when Docker is available:

```powershell
.\tools\release\Test-PassportHostedServicesDeployment.ps1 -BuildDockerImage
```

## Production Boundary

This deployment harness does not by itself make the ProductionMvp lane ready. Production testing still requires `Test-PassportProductionMvpReadiness.ps1` to pass with real production values for package signing, HTTPS hosted endpoints, operator secret validation, managed storage/backups, managed signing custody, issuer/genesis IDs, open-weight model runtime, vector store, telemetry/incident response, and formal approvals.
