# Canary MVP Readiness Evidence

This folder contains the evidence templates required by `tools/release/Test-PassportCanaryMvpReadiness.ps1` before a Canary MVP lane can be promoted to the broader Production MVP lane.

Canary MVP is the first citizen-facing real-token lane. It uses real fixed-genesis ARCH and real Crown Credit under canary policy limits, production-intended controls, allowlisted citizens, and production-ledger semantics. It is not a substitute for the broader Production MVP readiness gate.

The canary readiness gate validates:

- passing non-synthetic staging readiness;
- a validated `CanaryMvp` package artifact;
- approved canary policy limits;
- canary incident review;
- ARCH, CC, escrow, burn, refund, re-credit, and Crown reserve balance reconciliation;
- storage/service delivery reconciliation;
- support and recovery readiness;
- signed product, engineering, security/privacy, and Crown monetary authority approval for Production MVP promotion.

Generate a controlled canary evidence packet, fill every placeholder, approve the records, then load the paths and SHA-256 hashes into `artifacts/release/canary-mvp.env` or the canary secret store:

```powershell
.\tools\release\New-PassportCanaryMvpReadinessEvidencePacket.ps1 `
  -OutputDirectory .\artifacts\release\canary-mvp-readiness-evidence `
  -StagingReadinessReportSha256 "<staging-readiness-report-sha256>" `
  -CanaryArtifactValidationReportSha256 "<canary-artifact-validation-report-sha256>"
```

Validate the filled packet before running the canary readiness gate:

```powershell
.\tools\release\Test-PassportCanaryMvpReadinessEvidencePacket.ps1 `
  -PacketRoot .\artifacts\release\canary-mvp-readiness-evidence `
  -RequireNoPlaceholders
```

The packet validator checks that canary policy limits prohibit non-MVP token behavior, incident review is complete, ARCH/CC/escrow/burn/refund/re-credit balances reconcile, service delivery reconciles to storage proofs and verified burn epochs, support and recovery coverage is ready, and production-promotion approval hashes match the filled canary evidence files.

Synthetic canary readiness reports are valid only for validator self-tests. ProductionMvp readiness rejects synthetic canary reports.
