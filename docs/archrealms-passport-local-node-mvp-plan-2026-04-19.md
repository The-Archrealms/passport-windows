# Archrealms Passport Local Node MVP Plan

- Date: 2026-04-19
- Status: draft implementation plan
- Repo: `passport-windows`
- Scope: Windows desktop Passport bundled with a managed local IPFS node

## Goal

Deliver a Windows Passport release in which the citizen installs only one application, `Archrealms Passport`, while still receiving:

- a local managed IPFS-capable archival node;
- identity and device-credential workflows;
- read-only public archive access;
- submission packaging and publication;
- storage-contribution controls; and
- a clean separation between citizen functions and privileged registrar authority.

## Product Rule

For the citizen:

- one installer;
- one onboarding flow;
- one UI;
- one settings surface.

Under the hood:

- Passport UI and identity layer;
- local node service/runtime;
- local control scripts or service interface;
- future registrar tooling as a separate privileged application.

## Current Baseline

The repo already has:

- a WPF Passport app;
- local Passport identity and device-key workflows;
- submission packaging and verification;
- read-only IPFS file preview and fetch;
- local node initialization scripts;
- registry publication scripts; and
- Windows packaging and release workflows.

What is still missing for the one-app local-node experience:

- manual clean-machine UI onboarding validation on a fresh Windows tester machine as the first production-test pass.

Current implementation note:

- the Windows app now has a `LocalNodeService` abstraction for node initialization, registry submission publication, read-only IPFS preview/fetch, and local node health/status probing;
- the status surface can distinguish runtime detection, repo/node-record presence, and whether the local API daemon is reachable; and
- start, stop, restart, repair/config reapply, standalone CAR export, and diagnostics are now routed through the same service boundary.
- onboarding now has a default-on setting to initialize and start the local node after new identity creation or join approval import, with a non-blocking recovery message if no IPFS runtime is available.
- release packaging now bundles a pinned official Kubo runtime into both zip and MSIX artifacts and validates required Passport files, bundled Kubo, executable version checks, and manifest hashes.
- installed-artifact validation now proves zip and MSIX layouts can initialize an isolated repo, add content, export a CAR, start/probe/stop bundled Kubo, and write validation reports using only packaged files.
- the storage participation surface now exposes explicit participation modes and cache policies, and the selected profile is written into settings, Kubo initialization records, diagnostics, status snapshots, and signed capacity snapshots.
- fresh zip and MSIX production-test candidate artifacts were rebuilt and passed static plus installed-artifact validation with bundled Kubo `0.41.0`.
- MSIX packaging now has separate sideload and Store channels; the sideload channel uses a distinct package identity, and the Store channel can be rebuilt with Partner Center identity and publisher values.

## Architectural Decision

The MVP should package the local node with Passport, but not fuse them into one code path.

The clean boundary is:

- `Passport UI`: identity, citizen settings, browsing, submission, read-only archive access
- `Node Runtime`: Kubo or equivalent local IPFS runtime
- `Node Control Layer`: local-only start, stop, health, config, and publish operations

Passport should call the node through a narrow local control interface. It should not assume that archival networking logic belongs inside the UI layer.

## MVP Phases

## Phase 1. Bundle the Local Node Runtime

Objective:

- make the shipped Passport installer include the node runtime automatically

Required work:

- choose the packaged Kubo delivery path for Windows;
- place the runtime under an app-controlled install or data directory;
- detect whether a usable node runtime already exists;
- expose the resolved node binary path through app configuration;
- ensure upgrades do not orphan the node runtime.

Acceptance criteria:

- fresh Passport install gives the machine a usable local node runtime without a second manual install;
- Passport can locate the runtime deterministically after installation.

Current implementation note:

- zip and MSIX release packaging now default to downloading pinned official Kubo for Windows from `dist.ipfs.tech`;
- the downloaded archive is verified against official SHA-512 distribution metadata before staging;
- `ipfs.exe` and Kubo license files are staged under `tools/ipfs/runtime/`; and
- release validation fails if bundled Kubo, required Passport scripts, registry templates, executable, or manifest hashes are missing.
- installed-artifact validation exercises the bundled Kubo runtime from extracted zip/MSIX layouts with an isolated workspace and repo.

## Phase 2. First-Run Node Bootstrap

Objective:

- initialize the local node during Passport onboarding

Required work:

- add first-run checks for node presence and repo initialization;
- prompt for storage contribution and basic participation choices;
- initialize the local node repo automatically;
- write the node record into the Passport workspace;
- confirm local API and gateway health before onboarding completes.

Acceptance criteria:

- a first-time user can complete onboarding without opening PowerShell;
- node initialization succeeds from inside the app or produces a clear recovery message.

Current implementation note:

- after a new identity is created or a join approval is imported, Passport can initialize and start the local node automatically;
- the bootstrap is controlled by the `Initialize and start local node during onboarding` setting; and
- identity activation remains complete if runtime setup is missing, with recovery routed to the local-node action buttons.

## Phase 3. Local Node Control Layer

Objective:

- stop relying on loosely coupled shell usage as the primary runtime contract

Required work:

- define a `LocalNodeService` abstraction in the app;
- wrap:
  - initialize repo;
  - start node;
  - stop node;
  - health check;
  - publish path;
  - read path;
  - CAR export;
  - node diagnostics;
- keep the underlying scripts where useful, but make the app depend on a stable service API.

Acceptance criteria:

- UI actions for node control go through a coherent app service rather than scattered shell calls;
- node errors are surfaced as structured app status instead of raw shell text only.

Current implementation note:

- the first service boundary is in place for initialize, publish, read, fetch, and health status;
- start, stop, restart, repair/config reapply, standalone CAR export, and diagnostics are now in place behind the service boundary; and
- direct UI-to-script path knowledge has been removed from existing node/IPFS actions.

## Phase 4. Storage Allocation UX

Objective:

- give the citizen a simple but real storage contribution control

Required work:

- expose storage allocation in Passport settings;
- write the selected storage policy to the node configuration path;
- support at least:
  - storage max;
  - read-only mode vs participation mode;
  - local archive cache on/off;
  - conservative default resource settings.

Acceptance criteria:

- a citizen can choose how much storage to allocate without editing config files;
- the setting is persisted and reflected in node configuration.

Current implementation note:

- the storage allocation slider is persisted in Passport settings;
- the citizen can now choose a participation mode: `Read-only cache`, `Public archive contributor`, or `Steward reserve`;
- the citizen can now choose a cache policy: `Conservative cache`, `Balanced pinned archive`, or `Archive-first reserve`;
- `Apply Node Settings` now reapplies storage max, GC watermark, provide strategy, participation mode, and cache policy through `LocalNodeService`; and
- refreshed node status, diagnostics, node records, and capacity snapshots include the applied node profile.

## Phase 5. Read-Only Public Archive Access

Objective:

- make Passport read public records through the local node by default

Required work:

- prefer local node reads where available;
- fall back to gateway reads only when needed;
- preserve the existing read-only local copy behavior;
- support local CAR export for the current CID;
- add CID/path history and basic usability improvements for public archive browsing.

Acceptance criteria:

- Passport can read a known public record bundle from the local node after onboarding;
- the citizen can save a read-only local copy or CAR archive from inside the app.

## Phase 6. Submission Publication Through the Local Node

Objective:

- keep Passport submission publication self-contained inside the one-app install

Required work:

- route submission publication through the local node service;
- store publication records in the Passport workspace;
- expose resulting CIDs in the UI;
- keep publication distinct from official registry admission.

Acceptance criteria:

- a citizen can publish a submission package to IPFS without installing extra tools;
- the resulting CID and publication record are visible in the app.

## Phase 7. Node Health and Recovery

Objective:

- make the bundled node supportable for nontechnical users

Required work:

- add status indicators for:
  - node installed;
  - repo initialized;
  - daemon reachable;
  - last publish result;
  - storage usage;
- add repair actions such as:
  - restart node;
  - export CAR;
  - open workspace/log location.

Acceptance criteria:

- common failure states can be diagnosed and retried from inside Passport.

Current implementation note:

- restart, repair/config reapply, and diagnostics reports are now available from inside Passport;
- repair/config reapply is non-destructive and reuses the idempotent node initializer; and
- standalone CAR export and richer diagnostics reports are now in place; direct workspace/log navigation remains later polish.

## Phase 8. Packaging and Release

Objective:

- treat the node as part of the deliverable product

Required work:

- update the packaging pipeline so the release bundle and MSIX include the local node runtime or bootstrap it as part of installation;
- verify pathing for installed builds, not only dev builds;
- ensure upgrades preserve the Passport workspace and node repo.

Acceptance criteria:

- the release artifact installs a working Passport-plus-node environment on a clean Windows machine.

Current implementation note:

- the zip release path has been locally packaged and validated with bundled Kubo `0.41.0`;
- the MSIX release path has been locally packaged, signed with a generated test certificate, and validated with bundled Kubo `0.41.0`;
- both zip and MSIX artifacts now pass installed-layout node validation using packaged files only;
- installed-layout validation asserts node profile persistence for storage max, GC watermark, provide strategy, participation mode, and cache policy; and
- the current artifacts are ready for clean-machine production testing.
- sideload and Store-channel MSIX candidates are built separately to avoid package identity conflicts between public sideload testing and Microsoft Store distribution.

## Phase 9. Test Coverage

Objective:

- make the one-app local-node path repeatable

Required work:

- add smoke coverage for:
  - first-run node bootstrap;
  - read-only archive access;
  - submission publication;
  - node status and restart;
- keep deterministic tests separate from Windows Hello-interactive flows where necessary.

Acceptance criteria:

- CI covers the noninteractive portions of the local-node MVP;
- manual test instructions exist for Hello-backed and installer-backed paths.
- release CI runs static artifact validation and installed-layout node validation for zip and MSIX artifacts.

## Explicit Non-Goals for This MVP

The following should remain out of scope for the first bundled-node Passport release:

- registrar authority inside ordinary citizen mode;
- constitutional decree approval from Passport;
- mesh networking;
- token economics;
- wallet, redemption, trading, or public cryptocurrency functions;
- mobile full-node parity;
- secret or proprietary verification logic.

Metering and internal settlement visibility are later Passport layers. The local-node MVP should only produce a reliable identity, node, archive, and submission foundation for that work.

## Security Boundaries

The local node does not confer official authority.

The citizen Passport app may:

- read public records;
- create and publish submissions;
- pin public materials locally.

It may not, merely by having a node, admit records into the canonical registry.

Authority continues to come from:

- device or role keys;
- signed admission records;
- signed canonical indices; and
- governance rules outside ordinary citizen mode.

## Recommended Implementation Order

1. bundle node runtime in release artifacts
2. wire first-run node bootstrap into Passport onboarding
3. add a `LocalNodeService` in the app
4. expose storage allocation and node health in settings
5. move read-only archive access to prefer the local node
6. move submission publication fully behind the local node service
7. add packaging and smoke-test coverage

## Definition of MVP Done

The local-node MVP is done when:

- a citizen installs only `Archrealms Passport`;
- Passport installs or provides the local node runtime automatically;
- Passport initializes and manages the node on first run;
- the citizen can choose storage contribution limits;
- the citizen can read public records through the node;
- the citizen can publish submissions through the node;
- no second app is required for ordinary citizen participation.

Current implementation note:

- the release artifacts now include the node runtime by default, pass installed-layout node validation, preserve explicit node participation/cache profiles, and are ready for manual clean-machine production testing.
