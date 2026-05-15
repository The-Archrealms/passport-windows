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

Synthetic canary readiness reports are valid only for validator self-tests. ProductionMvp readiness rejects synthetic canary reports.

