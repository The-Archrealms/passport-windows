# Pre-MVP Internal Verification Evidence

Pre-MVP verification is required before citizen-facing token release, but it is not the MVP.

`Test-PassportPreMvpInternalVerification.ps1` requires controlled evidence for the PRD/ARD items that cannot be proven by unit tests alone:

- simulation runs;
- staff/steward pilots.

Generate the simulation-run report from the local test harness, then record the output path and SHA-256 in the controlled verification evidence system:

```powershell
.\tools\release\New-PassportPreMvpSimulationRunReport.ps1 `
  -OutputPath .\artifacts\release\pre-mvp-simulation-run-report.json `
  -EvidenceRoot .\artifacts\release\pre-mvp-simulation-run-evidence

$simulationHash = (Get-FileHash -Algorithm SHA256 .\artifacts\release\pre-mvp-simulation-run-report.json).Hash.ToLowerInvariant()
```

Copy the staff/steward pilot template in this folder into the controlled verification evidence system, fill every placeholder, approve or sign it under the internal verification policy, then pass both evidence file paths and SHA-256 hashes to the verifier:

```powershell
.\tools\release\Test-PassportPreMvpInternalVerification.ps1 `
  -SimulationRunReportPath <controlled-simulation-run-report.json> `
  -SimulationRunReportSha256 <sha256> `
  -StaffStewardPilotReportPath <controlled-staff-steward-pilot-report.json> `
  -StaffStewardPilotReportSha256 <sha256> `
  -OutputPath .\artifacts\release\pre-mvp-internal-verification-report.json
```

The same values can be supplied through environment variables:

```text
ARCHREALMS_PASSPORT_PRE_MVP_SIMULATION_RUN_REPORT_PATH
ARCHREALMS_PASSPORT_PRE_MVP_SIMULATION_RUN_REPORT_SHA256
ARCHREALMS_PASSPORT_PRE_MVP_STAFF_STEWARD_PILOT_REPORT_PATH
ARCHREALMS_PASSPORT_PRE_MVP_STAFF_STEWARD_PILOT_REPORT_SHA256
```

The reports must use the `internal-verification` lane, include real non-placeholder evidence references, and prove that no production ARCH, production CC, Crown reserve balance, citizen production account history, or production service-liability record was created.
