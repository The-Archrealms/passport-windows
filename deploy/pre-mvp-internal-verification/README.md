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

After the staff/steward pilot is complete, generate the pilot report from explicit operator confirmations. Use at least three evidence files from the controlled pilot session record, participant signoff, and issue/blocker review; do not use placeholders:

```powershell
.\tools\release\New-PassportPreMvpStaffStewardPilotReport.ps1 `
  -OutputPath .\artifacts\release\pre-mvp-staff-steward-pilot-report.json `
  -PilotId <pre-mvp-staff-steward-pilot-id> `
  -PilotOwner <pilot-owner> `
  -ParticipantCount 1 `
  -EvidenceFilePath @(
    "C:\secure\passport-pilot\pilot-session-record.json",
    "C:\secure\passport-pilot\participant-signoff.json",
    "C:\secure\passport-pilot\pilot-issue-review.json"
  ) `
  -ConfirmCompleted `
  -ConfirmStaffOrStewardParticipants `
  -ConfirmCrownOwnedDevices `
  -ConfirmNoCitizenProductionTokens `
  -ConfirmRecoveryRevocationValidated `
  -ConfirmStorageContributionValidated `
  -ConfirmLedgerExportValidated `
  -ConfirmHostedAiPrivacyValidated `
  -ConfirmProductionReadinessBlockersReviewed `
  -ConfirmPilotSignoffSigned `
  -ConfirmNoProductionRecordsCreated
```

The template remains available for controlled document-system review. The generated report includes hashed `evidence_files`; `Test-PassportPreMvpInternalVerification.ps1` verifies those files exist and match their recorded SHA-256 values. Pass both evidence report paths and SHA-256 hashes to the verifier:

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
