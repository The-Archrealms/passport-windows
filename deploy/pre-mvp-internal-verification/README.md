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

Create a staff/steward pilot handoff before the controlled pilot. The handoff writes the evidence packet, operator runbook, manifest, template validation report, and a `-RequireNoPlaceholders` preview that must fail until real pilot evidence is filled:

```powershell
.\tools\release\New-PassportPreMvpStaffStewardPilotHandoff.ps1 `
  -OutputDirectory C:\secure\passport-pilot-handoff `
  -PilotId <pre-mvp-staff-steward-pilot-id> `
  -PilotOwner <pilot-owner> `
  -ParticipantCount 1

.\tools\release\Test-PassportPreMvpStaffStewardPilotHandoff.ps1 `
  -HandoffRoot C:\secure\passport-pilot-handoff
```

Optionally generate supporting dry-run evidence for the controlled pilot packet. This does not replace staff/steward participation, observations, or signoff:

```powershell
.\tools\release\New-PassportPreMvpStaffStewardPilotDryRunEvidence.ps1 `
  -OutputDirectory C:\secure\passport-pilot-handoff\pilot-dry-run `
  -HandoffRoot C:\secure\passport-pilot-handoff `
  -PilotId <pre-mvp-staff-steward-pilot-id> `
  -PilotOwner <pilot-owner> `
  -Force

.\tools\release\Test-PassportPreMvpStaffStewardPilotDryRunEvidence.ps1 `
  -ReportPath C:\secure\passport-pilot-handoff\pilot-dry-run\staff-steward-pilot-dry-run-evidence.json
```

If the controlled evidence system needs the packet only, create a staff/steward pilot evidence packet before the controlled pilot, then fill the generated JSON records after the pilot is complete:

```powershell
.\tools\release\New-PassportPreMvpStaffStewardPilotEvidencePacket.ps1 `
  -OutputDirectory C:\secure\passport-pilot `
  -PilotId <pre-mvp-staff-steward-pilot-id> `
  -PilotOwner <pilot-owner> `
  -ParticipantCount 1
```

The packet contains:

- `pilot-session-record.json`;
- `participant-signoff.json`;
- `pilot-issue-review.json`.

Validate the filled packet before generating the pilot report:

```powershell
.\tools\release\Test-PassportPreMvpStaffStewardPilotEvidencePacket.ps1 `
  -PacketRoot C:\secure\passport-pilot `
  -RequireNoPlaceholders
```

After the staff/steward pilot is complete, generate the pilot report from explicit operator confirmations. Use the validated evidence packet; do not use placeholders:

```powershell
.\tools\release\New-PassportPreMvpStaffStewardPilotReport.ps1 `
  -OutputPath .\artifacts\release\pre-mvp-staff-steward-pilot-report.json `
  -PilotId <pre-mvp-staff-steward-pilot-id> `
  -PilotOwner <pilot-owner> `
  -ParticipantCount 1 `
  -EvidencePacketPath C:\secure\passport-pilot `
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

Validate the generated pilot report and record its SHA-256 before using it to close the umbrella gate:

```powershell
$staffPilotHash = (Get-FileHash -Algorithm SHA256 .\artifacts\release\pre-mvp-staff-steward-pilot-report.json).Hash.ToLowerInvariant()

.\tools\release\Test-PassportPreMvpStaffStewardPilotReport.ps1 `
  -ReportPath .\artifacts\release\pre-mvp-staff-steward-pilot-report.json `
  -ReportSha256 $staffPilotHash
```

Alternatively, once the handoff packet has been filled with real controlled pilot evidence, run the fail-closed closeout command. It validates the handoff, validates the filled packet with `-RequireNoPlaceholders`, generates the pilot report, validates the report hash, and reruns the umbrella pre-MVP gate:

```powershell
.\tools\release\Complete-PassportPreMvpStaffStewardPilotHandoff.ps1 `
  -HandoffRoot C:\secure\passport-pilot-handoff `
  -OutputDirectory .\artifacts\release\pre-mvp-staff-steward-pilot-closeout `
  -PilotReportPath .\artifacts\release\pre-mvp-staff-steward-pilot-report.json `
  -PreMvpReportPath .\artifacts\release\pre-mvp-internal-verification-report.json `
  -SimulationRunReportPath .\artifacts\release\pre-mvp-simulation-run-report.json `
  -SimulationRunReportSha256 $simulationHash
```

The templates remain available for controlled document-system review. The generated report includes hashed `evidence_files`; `Test-PassportPreMvpStaffStewardPilotReport.ps1` and `Test-PassportPreMvpInternalVerification.ps1` verify those files exist, match their recorded SHA-256 values, and pass the staff/steward pilot evidence packet schema validation. Pass both evidence report paths and SHA-256 hashes to the verifier:

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

The reports must use the `internal-verification` lane, include real non-placeholder evidence references and evidence files, and prove that no production ARCH, production CC, Crown reserve balance, citizen production account history, or production service-liability record was created.

`Test-PassportPreMvpInternalVerification.ps1` also validates the handoff generator through `staff_steward_pilot_handoff_validation`, the supporting dry-run helper through `staff_steward_pilot_dry_run_validation`, the final report validator through `staff_steward_pilot_report_validation`, and the closeout path through `staff_steward_pilot_closeout_validation`. Those automated checks do not close the external pilot gate; they only prove the operator path is available, scenario evidence references are structured, filled-evidence closeout is repeatable, and final acceptance still fails closed until real pilot evidence exists.

The umbrella invokes the generated closeout fixture with its final pre-MVP rerun skipped to avoid recursive verification. To independently prove the full generated closeout path, including final pre-MVP rerun, use:

```powershell
.\tools\release\Complete-PassportPreMvpStaffStewardPilotHandoff.ps1 `
  -UseGeneratedFixture `
  -RunPreMvpRerunForGeneratedFixture
```

That standalone fixture remains tool validation only. It does not satisfy the external staff/steward pilot requirement, and its generated report must not be used as staging, canary, or production readiness evidence.
