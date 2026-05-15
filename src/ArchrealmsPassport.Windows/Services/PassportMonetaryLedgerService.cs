using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using ArchrealmsPassport.Core.Protocol;
using ArchrealmsPassport.Windows.Models;

namespace ArchrealmsPassport.Windows.Services
{
    public sealed class PassportMonetaryLedgerService
    {
        public const string AssetArch = PassportMonetaryProtocol.AssetArch;
        public const string AssetCrownCredit = PassportMonetaryProtocol.AssetCrownCredit;
        public const string EventArchGenesisAllocation = PassportMonetaryProtocol.EventArchGenesisAllocation;
        public const string EventArchTransferIn = PassportMonetaryProtocol.EventArchTransferIn;
        public const string EventArchTransferOut = PassportMonetaryProtocol.EventArchTransferOut;
        public const string EventCrownCreditIssue = PassportMonetaryProtocol.EventCrownCreditIssue;
        public const string EventCrownCreditEscrow = PassportMonetaryProtocol.EventCrownCreditEscrow;
        public const string EventCrownCreditBurn = PassportMonetaryProtocol.EventCrownCreditBurn;
        public const string EventCrownCreditRefund = PassportMonetaryProtocol.EventCrownCreditRefund;
        public const string EventCrownCreditRecredit = PassportMonetaryProtocol.EventCrownCreditRecredit;
        public const string EventCrownCreditTransferIn = PassportMonetaryProtocol.EventCrownCreditTransferIn;
        public const string EventCrownCreditTransferOut = PassportMonetaryProtocol.EventCrownCreditTransferOut;

        private static readonly JsonSerializerOptions JsonOptions = new JsonSerializerOptions
        {
            WriteIndented = true
        };

        private readonly PassportReleaseLane releaseLane;

        public PassportMonetaryLedgerService(PassportReleaseLane? releaseLane = null)
        {
            this.releaseLane = releaseLane ?? PassportEnvironment.GetReleaseLane();
        }

        public PassportMonetaryLedgerAppendResult AppendEvent(
            string workspaceRoot,
            string accountId,
            string identityId,
            string walletKeyId,
            string eventType,
            string assetCode,
            long amountBaseUnits,
            IDictionary<string, string>? evidenceReferences = null,
            string deviceSessionId = "",
            string walletKeyReferencePath = "",
            string walletPublicKeyPath = "")
        {
            try
            {
                var resolvedWorkspaceRoot = PassportEnvironment.ResolveWorkspaceRoot(workspaceRoot);
                var normalizedAccountId = NormalizeRequired(accountId, "account ID");
                var normalizedIdentityId = NormalizeRequired(identityId, "identity ID");
                var normalizedWalletKeyId = NormalizeRequired(walletKeyId, "wallet key ID");
                var normalizedEventType = NormalizeRequired(eventType, "event type").ToLowerInvariant();
                var normalizedAssetCode = NormalizeAssetCode(assetCode);

                if (amountBaseUnits <= 0)
                {
                    return FailedAppend("A monetary ledger event amount must be greater than zero.");
                }

                var replay = Replay(resolvedWorkspaceRoot);
                if (!replay.Succeeded)
                {
                    return FailedAppend("The monetary ledger must replay cleanly before appending a new event: " + string.Join("; ", replay.Failures));
                }

                var existingEvents = ReadEvents(resolvedWorkspaceRoot).ToArray();
                var accountEvents = existingEvents
                    .Where(item => string.Equals(item.Event.AccountId, normalizedAccountId, StringComparison.Ordinal))
                    .OrderBy(item => item.Event.AccountSequence)
                    .ThenBy(item => item.Event.CreatedUtc, StringComparer.Ordinal)
                    .ThenBy(item => item.Event.EventId, StringComparer.Ordinal)
                    .Select(item => item.Event)
                    .ToArray();

                var latestEvent = accountEvents.LastOrDefault();
                var createdUtc = DateTime.UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ");
                var eventId = DateTime.UtcNow.ToString("yyyyMMddTHHmmssZ") + "-" + Guid.NewGuid().ToString("N");
                var ledgerEvent = new PassportMonetaryLedgerEvent
                {
                    EventId = eventId,
                    EventType = normalizedEventType,
                    CreatedUtc = createdUtc,
                    ReleaseLane = releaseLane.Lane,
                    TelemetryEnvironment = releaseLane.TelemetryEnvironment,
                    LedgerNamespace = releaseLane.LedgerNamespace,
                    ProductionTokenRecord = releaseLane.ProductionLedger && releaseLane.AllowProductionTokenRecords,
                    StagingRecord = releaseLane.AllowStagingRecords,
                    AccountId = normalizedAccountId,
                    IdentityId = normalizedIdentityId,
                    WalletKeyId = normalizedWalletKeyId,
                    AssetCode = normalizedAssetCode,
                    AmountBaseUnits = amountBaseUnits,
                    GlobalSequence = existingEvents.Length == 0 ? 1 : existingEvents.Max(item => item.Event.GlobalSequence) + 1,
                    AccountSequence = latestEvent == null ? 1 : latestEvent.AccountSequence + 1,
                    PriorAccountEventHash = latestEvent?.EventHashSha256 ?? string.Empty,
                    ServerReceivedUtc = createdUtc,
                    AntiReplayNonce = Guid.NewGuid().ToString("N"),
                    DeviceSessionId = string.IsNullOrWhiteSpace(deviceSessionId) ? "local-passport-session" : deviceSessionId.Trim(),
                    PolicyVersion = releaseLane.PolicyVersion,
                    EvidenceReferences = NormalizeEvidence(evidenceReferences),
                    SignatureStatus = PassportMonetaryProtocol.SignatureUnsignedLocalFoundation
                };

                var adminAuthorityGate = ValidateAdminAuthorityGateIfPresent(resolvedWorkspaceRoot, ledgerEvent);
                if (!adminAuthorityGate.Succeeded)
                {
                    return FailedAppend(adminAuthorityGate.Message);
                }

                var recovery = new PassportRecoveryService(releaseLane);
                var hasAdminAuthority = IsAdminAuthorityStatus(ledgerEvent.SignatureStatus) || HasAdminAuthorityEvidence(ledgerEvent);
                if (recovery.IsWalletOperationsFrozen(resolvedWorkspaceRoot, normalizedIdentityId) && !hasAdminAuthority)
                {
                    return FailedAppend("Passport wallet operations are frozen for this identity.");
                }

                if (recovery.IsPendingEscrowFrozen(resolvedWorkspaceRoot, normalizedIdentityId)
                    && IsPendingEscrowMutation(ledgerEvent)
                    && !hasAdminAuthority)
                {
                    return FailedAppend("Passport pending escrow operations are frozen for this identity.");
                }

                if (releaseLane.ProductionLedger && string.IsNullOrWhiteSpace(walletKeyReferencePath) && !hasAdminAuthority)
                {
                    return FailedAppend("Production monetary ledger events require a wallet signature or valid dual-control admin authority evidence.");
                }

                if (!string.IsNullOrWhiteSpace(walletKeyReferencePath))
                {
                    var walletAuthority = new PassportWalletKeyService(releaseLane);
                    if (!walletAuthority.IsWalletKeyActive(resolvedWorkspaceRoot, normalizedIdentityId, normalizedWalletKeyId))
                    {
                        return FailedAppend("The wallet key is not active for this Passport identity.");
                    }

                    var resolvedWalletPublicKeyPath = ResolveWorkspaceRelativePath(resolvedWorkspaceRoot, NormalizeRequired(walletPublicKeyPath, "wallet public key path"));
                    if (!File.Exists(resolvedWalletPublicKeyPath))
                    {
                        return FailedAppend("The wallet public key path could not be found.");
                    }

                    var signedPayloadHash = ComputeUnsignedEventPayloadHash(ledgerEvent);
                    var signatureBytes = PassportDeviceKeyStore.SignData(walletKeyReferencePath, Encoding.UTF8.GetBytes(signedPayloadHash));
                    if (!VerifySignature(resolvedWalletPublicKeyPath, Encoding.UTF8.GetBytes(signedPayloadHash), signatureBytes))
                    {
                        return FailedAppend("The wallet signature could not be verified with the wallet public key.");
                    }

                    ledgerEvent.SignatureStatus = PassportMonetaryProtocol.SignatureWalletSigned;
                    ledgerEvent.WalletSignatureAlgorithm = "RSA_PKCS1_SHA256";
                    ledgerEvent.WalletSignatureBase64 = Convert.ToBase64String(signatureBytes);
                    ledgerEvent.SignedEventHashSha256 = signedPayloadHash;
                    ledgerEvent.WalletPublicKeyPath = ToWorkspaceRelativePath(resolvedWorkspaceRoot, resolvedWalletPublicKeyPath);
                }
                else if (hasAdminAuthority)
                {
                    ledgerEvent.SignatureStatus = PassportMonetaryProtocol.SignatureDualControlAdminAuthorized;
                    ledgerEvent.SignedEventHashSha256 = ComputeUnsignedEventPayloadHash(ledgerEvent);
                }

                if (releaseLane.ProductionLedger
                    && string.Equals(ledgerEvent.AssetCode, AssetCrownCredit, StringComparison.Ordinal)
                    && string.Equals(ledgerEvent.EventType, EventCrownCreditIssue, StringComparison.Ordinal))
                {
                    var issuanceGate = ValidateProductionCrownCreditIssuanceGate(resolvedWorkspaceRoot, ledgerEvent);
                    if (!issuanceGate.Succeeded)
                    {
                        return FailedAppend(issuanceGate.Message);
                    }
                }

                if (releaseLane.ProductionLedger
                    && string.Equals(ledgerEvent.AssetCode, AssetArch, StringComparison.Ordinal)
                    && string.Equals(ledgerEvent.EventType, EventArchGenesisAllocation, StringComparison.Ordinal))
                {
                    var genesisGate = ValidateProductionArchGenesisGate(resolvedWorkspaceRoot, ledgerEvent);
                    if (!genesisGate.Succeeded)
                    {
                        return FailedAppend(genesisGate.Message);
                    }
                }

                if (releaseLane.ProductionLedger
                    && string.Equals(ledgerEvent.AssetCode, AssetCrownCredit, StringComparison.Ordinal)
                    && string.Equals(ledgerEvent.EventType, EventCrownCreditRecredit, StringComparison.Ordinal)
                    && !hasAdminAuthority)
                {
                    return FailedAppend("Production CC re-credit events require valid dual-control admin authority evidence.");
                }

                var semanticBalances = replay.Balances.ToDictionary(
                    balance => balance.AccountId + "|" + balance.AssetCode,
                    balance => new PassportMonetaryBalance
                    {
                        AccountId = balance.AccountId,
                        AssetCode = balance.AssetCode,
                        AvailableBaseUnits = balance.AvailableBaseUnits,
                        EscrowedBaseUnits = balance.EscrowedBaseUnits,
                        BurnedBaseUnits = balance.BurnedBaseUnits
                    },
                    StringComparer.Ordinal);
                var semanticFailures = new List<string>();
                ApplyEventSemantics(semanticBalances, ledgerEvent, semanticFailures);
                if (semanticFailures.Count > 0)
                {
                    return FailedAppend(string.Join("; ", semanticFailures));
                }

                ledgerEvent.EventHashSha256 = ComputeEventHash(ledgerEvent);
                var eventPath = GetEventPath(resolvedWorkspaceRoot, ledgerEvent);
                Directory.CreateDirectory(Path.GetDirectoryName(eventPath) ?? string.Empty);
                File.WriteAllText(eventPath, JsonSerializer.Serialize(ledgerEvent, JsonOptions), Encoding.UTF8);

                return new PassportMonetaryLedgerAppendResult
                {
                    Succeeded = true,
                    Message = "Monetary ledger event appended.",
                    EventId = ledgerEvent.EventId,
                    EventPath = eventPath,
                    EventHashSha256 = ledgerEvent.EventHashSha256,
                    AccountSequence = ledgerEvent.AccountSequence
                };
            }
            catch (Exception ex)
            {
                return FailedAppend("Monetary ledger append failed: " + ex.Message);
            }
        }

        public PassportMonetaryLedgerReplayResult Replay(string workspaceRoot)
        {
            var result = new PassportMonetaryLedgerReplayResult();

            try
            {
                var resolvedWorkspaceRoot = PassportEnvironment.ResolveWorkspaceRoot(workspaceRoot);
                var readEvents = ReadEvents(resolvedWorkspaceRoot).ToArray();
                foreach (var item in readEvents)
                {
                    var ledgerEvent = item.Event;
                    ValidateEventEnvelope(resolvedWorkspaceRoot, ledgerEvent, item.Path, result.Failures);
                }

                var coreReplay = PassportMonetaryLedgerReplayVerifier.Verify(
                    readEvents.Select(item => ToCoreReplayEvent(item.Event)),
                    new PassportMonetaryLedgerReplayOptions
                    {
                        ExpectedReleaseLane = releaseLane.Lane,
                        ExpectedLedgerNamespace = releaseLane.LedgerNamespace,
                        ProductionLedger = releaseLane.ProductionLedger,
                        AllowProductionTokenRecords = releaseLane.AllowProductionTokenRecords,
                        AllowStagingRecords = releaseLane.AllowStagingRecords,
                        EnforceUniqueArchGenesisAllocationIds = releaseLane.ProductionLedger
                    });
                result.Failures.AddRange(coreReplay.Failures);

                result.EventCount = coreReplay.EventCount;
                result.Balances.AddRange(coreReplay.Balances.Select(balance => new PassportMonetaryBalance
                {
                    AccountId = balance.AccountId,
                    AssetCode = balance.AssetCode,
                    AvailableBaseUnits = balance.AvailableBaseUnits,
                    EscrowedBaseUnits = balance.EscrowedBaseUnits,
                    BurnedBaseUnits = balance.BurnedBaseUnits
                }));
                result.Message = result.Succeeded
                    ? "Monetary ledger replay succeeded."
                    : "Monetary ledger replay failed.";
            }
            catch (Exception ex)
            {
                result.Failures.Add("Monetary ledger replay failed: " + ex.Message);
                result.Message = "Monetary ledger replay failed.";
            }

            return result;
        }

        public PassportMonetaryTransparencyRootResult CreateTransparencyRoot(string workspaceRoot)
        {
            try
            {
                var resolvedWorkspaceRoot = PassportEnvironment.ResolveWorkspaceRoot(workspaceRoot);
                var replay = Replay(resolvedWorkspaceRoot);
                if (!replay.Succeeded)
                {
                    return FailedTransparencyRoot("The monetary ledger must replay cleanly before creating a transparency root: " + string.Join("; ", replay.Failures));
                }

                var readEvents = ReadEvents(resolvedWorkspaceRoot)
                    .OrderBy(item => item.Event.GlobalSequence)
                    .ThenBy(item => item.Event.CreatedUtc, StringComparer.Ordinal)
                    .ThenBy(item => item.Event.EventId, StringComparer.Ordinal)
                    .ToArray();
                var transparencySnapshot = BuildTransparencySnapshot(readEvents);
                var timestamp = DateTime.UtcNow.ToString("yyyyMMddTHHmmssZ");
                var createdUtc = DateTime.UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ");
                var rootsRoot = Path.Combine(resolvedWorkspaceRoot, "records", "passport", "monetary", "transparency-roots");
                Directory.CreateDirectory(rootsRoot);
                var recordPath = Path.Combine(rootsRoot, timestamp + "-" + releaseLane.Lane + "-" + transparencySnapshot.EpochRootSha256[..12] + ".json");
                var record = new Dictionary<string, object?>
                {
                    ["schema_version"] = 1,
                    ["record_type"] = "passport_monetary_transparency_root",
                    ["record_id"] = timestamp + "-" + transparencySnapshot.EpochRootSha256[..12],
                    ["created_utc"] = createdUtc,
                    ["release_lane"] = releaseLane.Lane,
                    ["ledger_namespace"] = releaseLane.LedgerNamespace,
                    ["policy_version"] = releaseLane.PolicyVersion,
                    ["root_algorithm"] = "merkle_sha256_v1",
                    ["event_count"] = readEvents.Length,
                    ["first_global_sequence"] = readEvents.Length == 0 ? 0 : readEvents.First().Event.GlobalSequence,
                    ["last_global_sequence"] = readEvents.Length == 0 ? 0 : readEvents.Last().Event.GlobalSequence,
                    ["event_hashes"] = transparencySnapshot.EventHashes,
                    ["event_leaves"] = transparencySnapshot.EventLeaves,
                    ["epoch_root_sha256"] = transparencySnapshot.EpochRootSha256,
                    ["public_chain_anchor_status"] = "not_anchored_external_launch_gate",
                    ["summary"] = "Transparency root for replayable Passport ARCH/CC monetary ledger events."
                };

                File.WriteAllText(recordPath, JsonSerializer.Serialize(record, JsonOptions), Encoding.UTF8);

                return new PassportMonetaryTransparencyRootResult
                {
                    Succeeded = true,
                    Message = "Monetary ledger transparency root created.",
                    RecordPath = recordPath,
                    EpochRootSha256 = transparencySnapshot.EpochRootSha256,
                    EventCount = readEvents.Length
                };
            }
            catch (Exception ex)
            {
                return FailedTransparencyRoot("Monetary ledger transparency root creation failed: " + ex.Message);
            }
        }

        public PassportMonetaryLedgerExportResult CreateAccountExport(string workspaceRoot, string accountId)
        {
            try
            {
                var resolvedWorkspaceRoot = PassportEnvironment.ResolveWorkspaceRoot(workspaceRoot);
                var normalizedAccountId = NormalizeRequired(accountId, "account ID");
                var replay = Replay(resolvedWorkspaceRoot);
                if (!replay.Succeeded)
                {
                    return FailedExport("The monetary ledger must replay cleanly before exporting account history: " + string.Join("; ", replay.Failures));
                }

                var orderedEvents = ReadEvents(resolvedWorkspaceRoot)
                    .OrderBy(item => item.Event.GlobalSequence)
                    .ThenBy(item => item.Event.CreatedUtc, StringComparer.Ordinal)
                    .ThenBy(item => item.Event.EventId, StringComparer.Ordinal)
                    .ToArray();
                var transparencySnapshot = BuildTransparencySnapshot(orderedEvents);
                var accountEvents = orderedEvents
                    .Where(item => string.Equals(item.Event.AccountId, normalizedAccountId, StringComparison.Ordinal))
                    .OrderBy(item => item.Event.AccountSequence)
                    .ThenBy(item => item.Event.CreatedUtc, StringComparer.Ordinal)
                    .ThenBy(item => item.Event.EventId, StringComparer.Ordinal)
                    .ToArray();
                if (accountEvents.Length == 0)
                {
                    return FailedExport("No monetary ledger events were found for account " + normalizedAccountId + ".");
                }

                var transparencyRoot = CreateTransparencyRoot(resolvedWorkspaceRoot);
                if (!transparencyRoot.Succeeded)
                {
                    return FailedExport(transparencyRoot.Message);
                }

                var timestamp = DateTime.UtcNow.ToString("yyyyMMddTHHmmssZ");
                var createdUtc = DateTime.UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ");
                var exportRoot = Path.Combine(
                    resolvedWorkspaceRoot,
                    "records",
                    "passport",
                    "monetary",
                    "exports",
                    SanitizePathSegment(normalizedAccountId),
                    timestamp);
                Directory.CreateDirectory(exportRoot);

                var eventManifestRows = new List<Dictionary<string, object?>>();
                foreach (var item in accountEvents)
                {
                    var relativePath = ToWorkspaceRelativePath(resolvedWorkspaceRoot, item.Path);
                    var exportPath = Path.Combine(exportRoot, relativePath.Replace('/', Path.DirectorySeparatorChar));
                    CopyFile(item.Path, exportPath);
                    var leaf = FindLeaf(transparencySnapshot, item.Event.EventId, item.Event.EventHashSha256);
                    eventManifestRows.Add(new Dictionary<string, object?>
                    {
                        ["event_id"] = item.Event.EventId,
                        ["event_type"] = item.Event.EventType,
                        ["asset_code"] = item.Event.AssetCode,
                        ["global_sequence"] = item.Event.GlobalSequence,
                        ["account_sequence"] = item.Event.AccountSequence,
                        ["prior_account_event_hash"] = item.Event.PriorAccountEventHash,
                        ["event_hash_sha256"] = item.Event.EventHashSha256,
                        ["event_file_sha256"] = ComputeSha256(File.ReadAllBytes(exportPath)),
                        ["export_path"] = relativePath,
                        ["inclusion_proof"] = BuildInclusionProof(transparencySnapshot, leaf)
                    });
                }

                var exportedTransparencyRootPath = Path.Combine(exportRoot, "transparency-root.json");
                CopyFile(transparencyRoot.RecordPath, exportedTransparencyRootPath);
                var keyHistoryRows = CopyWalletKeyHistory(resolvedWorkspaceRoot, exportRoot, accountEvents.Select(item => item.Event).ToArray());

                var accountBalances = replay.Balances
                    .Where(balance => string.Equals(balance.AccountId, normalizedAccountId, StringComparison.Ordinal))
                    .OrderBy(balance => balance.AssetCode, StringComparer.Ordinal)
                    .ToArray();
                var manifestPath = Path.Combine(exportRoot, "manifest.json");
                var manifest = new Dictionary<string, object?>
                {
                    ["schema_version"] = 1,
                    ["record_type"] = "passport_monetary_account_export",
                    ["record_id"] = timestamp + "-" + SanitizePathSegment(normalizedAccountId),
                    ["created_utc"] = createdUtc,
                    ["release_lane"] = releaseLane.Lane,
                    ["ledger_namespace"] = releaseLane.LedgerNamespace,
                    ["policy_version"] = releaseLane.PolicyVersion,
                    ["account_id"] = normalizedAccountId,
                    ["event_count"] = accountEvents.Length,
                    ["events"] = eventManifestRows,
                    ["balances"] = accountBalances,
                    ["account_hash_chain"] = BuildAccountHashChain(accountEvents.Select(item => item.Event).ToArray()),
                    ["key_history"] = keyHistoryRows,
                    ["transparency_root_sha256"] = transparencyRoot.EpochRootSha256,
                    ["transparency_root_export_path"] = "transparency-root.json",
                    ["verifier_replay_root"] = "records/passport/monetary/events",
                    ["verifier"] = new Dictionary<string, object?>
                    {
                        ["tool_name"] = "Archrealms.LedgerVerifier",
                        ["tool_project"] = "tools/ledger-verifier/Archrealms.LedgerVerifier.csproj",
                        ["checks"] = new[]
                        {
                            "event_hashes",
                            "account_hash_chain",
                            "transparency_root",
                            "inclusion_proofs",
                            "replay_balances",
                            "key_history_hashes"
                        }
                    },
                    ["summary"] = "Replayable Passport ARCH/CC monetary account export. Balances are derived from exported events."
                };
                File.WriteAllText(manifestPath, JsonSerializer.Serialize(manifest, JsonOptions), Encoding.UTF8);
                var exportHash = ComputeDirectoryHash(exportRoot);

                return new PassportMonetaryLedgerExportResult
                {
                    Succeeded = true,
                    Message = "Monetary ledger account export created.",
                    ExportRoot = exportRoot,
                    ManifestPath = manifestPath,
                    TransparencyRootPath = exportedTransparencyRootPath,
                    ExportRootSha256 = exportHash,
                    EventCount = accountEvents.Length
                };
            }
            catch (Exception ex)
            {
                return FailedExport("Monetary ledger account export failed: " + ex.Message);
            }
        }

        public PassportMonetaryLedgerExportVerificationResult VerifyAccountExport(string exportRoot)
        {
            var result = new PassportMonetaryLedgerExportVerificationResult();

            try
            {
                var resolvedExportRoot = Path.GetFullPath(NormalizeRequired(exportRoot, "export root"));
                var manifestPath = Path.Combine(resolvedExportRoot, "manifest.json");
                if (!File.Exists(manifestPath))
                {
                    result.Failures.Add("Missing account export manifest.");
                    result.Message = "Monetary ledger account export verification failed.";
                    return result;
                }

                var coreVerification = PassportMonetaryLedgerExportVerifier.Verify(
                    resolvedExportRoot,
                    new PassportMonetaryLedgerReplayOptions
                    {
                        ExpectedReleaseLane = releaseLane.Lane,
                        ExpectedLedgerNamespace = releaseLane.LedgerNamespace,
                        ProductionLedger = releaseLane.ProductionLedger,
                        AllowProductionTokenRecords = releaseLane.AllowProductionTokenRecords,
                        AllowStagingRecords = releaseLane.AllowStagingRecords,
                        EnforceUniqueArchGenesisAllocationIds = releaseLane.ProductionLedger
                    });
                result.Failures.AddRange(coreVerification.Failures);

                var replay = Replay(resolvedExportRoot);
                if (!replay.Succeeded)
                {
                    result.Failures.AddRange(replay.Failures.Select(failure => "Replay failed: " + failure));
                }

                result.EventCount = coreVerification.EventCount;
                result.ExportRootSha256 = coreVerification.ExportRootSha256;
                result.Succeeded = result.Failures.Count == 0;
                result.Message = result.Succeeded
                    ? "Monetary ledger account export verification succeeded."
                    : "Monetary ledger account export verification failed.";
            }
            catch (Exception ex)
            {
                result.Failures.Add("Monetary ledger account export verification failed: " + ex.Message);
                result.Message = "Monetary ledger account export verification failed.";
            }

            return result;
        }

        public static string ComputeEventHash(PassportMonetaryLedgerEvent ledgerEvent)
        {
            return PassportMonetaryLedgerExportVerifier.ComputeEventHash(ToCoreLedgerRecord(ledgerEvent));
        }

        public static string ComputeCrownCreditIssueIntentHash(
            PassportReleaseLane releaseLane,
            string accountId,
            string identityId,
            string walletKeyId,
            long amountBaseUnits,
            IDictionary<string, string> evidenceReferences)
        {
            var capacityReportSha256 = evidenceReferences.TryGetValue("capacity_report_sha256", out var hash)
                ? hash.Trim().ToLowerInvariant()
                : string.Empty;
            var intent = new SortedDictionary<string, object?>(StringComparer.Ordinal)
            {
                ["release_lane"] = releaseLane.Lane,
                ["ledger_namespace"] = releaseLane.LedgerNamespace,
                ["event_type"] = EventCrownCreditIssue,
                ["asset_code"] = AssetCrownCredit,
                ["account_id"] = (accountId ?? string.Empty).Trim(),
                ["archrealms_identity_id"] = (identityId ?? string.Empty).Trim(),
                ["wallet_key_id"] = (walletKeyId ?? string.Empty).Trim(),
                ["amount_base_units"] = amountBaseUnits,
                ["capacity_report_sha256"] = capacityReportSha256
            };
            return ComputeSha256(Encoding.UTF8.GetBytes(JsonSerializer.Serialize(intent, JsonOptions)));
        }

        public static string ComputeUnsignedEventPayloadHash(PassportMonetaryLedgerEvent ledgerEvent)
        {
            var originalEventHash = ledgerEvent.EventHashSha256;
            var originalSignatureStatus = ledgerEvent.SignatureStatus;
            var originalAlgorithm = ledgerEvent.WalletSignatureAlgorithm;
            var originalSignature = ledgerEvent.WalletSignatureBase64;
            var originalSignedEventHash = ledgerEvent.SignedEventHashSha256;
            var originalWalletPublicKeyPath = ledgerEvent.WalletPublicKeyPath;

            ledgerEvent.EventHashSha256 = string.Empty;
            ledgerEvent.SignatureStatus = string.Empty;
            ledgerEvent.WalletSignatureAlgorithm = string.Empty;
            ledgerEvent.WalletSignatureBase64 = string.Empty;
            ledgerEvent.SignedEventHashSha256 = string.Empty;
            ledgerEvent.WalletPublicKeyPath = string.Empty;

            try
            {
                var payload = JsonSerializer.Serialize(ledgerEvent, JsonOptions);
                return ComputeSha256(Encoding.UTF8.GetBytes(payload));
            }
            finally
            {
                ledgerEvent.EventHashSha256 = originalEventHash;
                ledgerEvent.SignatureStatus = originalSignatureStatus;
                ledgerEvent.WalletSignatureAlgorithm = originalAlgorithm;
                ledgerEvent.WalletSignatureBase64 = originalSignature;
                ledgerEvent.SignedEventHashSha256 = originalSignedEventHash;
                ledgerEvent.WalletPublicKeyPath = originalWalletPublicKeyPath;
            }
        }

        private void ValidateEventEnvelope(string workspaceRoot, PassportMonetaryLedgerEvent ledgerEvent, string path, List<string> failures)
        {
            if (!string.Equals(ledgerEvent.RecordType, "passport_monetary_ledger_event", StringComparison.Ordinal))
            {
                failures.Add("Invalid monetary ledger record type in " + path + ".");
            }

            if (string.IsNullOrWhiteSpace(ledgerEvent.EventId))
            {
                failures.Add("Missing monetary ledger event ID in " + path + ".");
            }

            if (ledgerEvent.AmountBaseUnits <= 0)
            {
                failures.Add("Monetary ledger event amount must be greater than zero for " + ledgerEvent.EventId + ".");
            }

            if (ledgerEvent.AccountSequence <= 0)
            {
                failures.Add("Monetary ledger account sequence must be greater than zero for " + ledgerEvent.EventId + ".");
            }

            if (ledgerEvent.GlobalSequence <= 0)
            {
                failures.Add("Monetary ledger global sequence must be greater than zero for " + ledgerEvent.EventId + ".");
            }

            if (string.IsNullOrWhiteSpace(ledgerEvent.ServerReceivedUtc))
            {
                failures.Add("Missing monetary ledger server-received timestamp for " + ledgerEvent.EventId + ".");
            }

            if (string.IsNullOrWhiteSpace(ledgerEvent.AntiReplayNonce))
            {
                failures.Add("Missing monetary ledger anti-replay nonce for " + ledgerEvent.EventId + ".");
            }

            if (string.IsNullOrWhiteSpace(ledgerEvent.DeviceSessionId))
            {
                failures.Add("Missing monetary ledger device/session reference for " + ledgerEvent.EventId + ".");
            }

            if (string.IsNullOrWhiteSpace(ledgerEvent.EventHashSha256))
            {
                failures.Add("Missing monetary ledger event hash for " + ledgerEvent.EventId + ".");
            }
            else
            {
                var actualHash = ComputeEventHash(ledgerEvent);
                if (!string.Equals(actualHash, ledgerEvent.EventHashSha256, StringComparison.OrdinalIgnoreCase))
                {
                    failures.Add("Invalid monetary ledger event hash for " + ledgerEvent.EventId + ".");
                }
            }

            ValidateEventSignature(workspaceRoot, ledgerEvent, failures);

            if (releaseLane.ProductionLedger
                && string.Equals(ledgerEvent.AssetCode, AssetCrownCredit, StringComparison.Ordinal)
                && string.Equals(ledgerEvent.EventType, EventCrownCreditIssue, StringComparison.Ordinal))
            {
                var issuanceGate = ValidateProductionCrownCreditIssuanceGate(workspaceRoot, ledgerEvent);
                if (!issuanceGate.Succeeded)
                {
                    failures.Add("CC issuance authority validation failed for event " + ledgerEvent.EventId + ": " + issuanceGate.Message);
                }
            }

            if (releaseLane.ProductionLedger
                && string.Equals(ledgerEvent.AssetCode, AssetArch, StringComparison.Ordinal)
                && string.Equals(ledgerEvent.EventType, EventArchGenesisAllocation, StringComparison.Ordinal))
            {
                var genesisGate = ValidateProductionArchGenesisGate(workspaceRoot, ledgerEvent);
                if (!genesisGate.Succeeded)
                {
                    failures.Add("ARCH genesis validation failed for event " + ledgerEvent.EventId + ": " + genesisGate.Message);
                }
            }
        }

        private PassportMonetaryLedgerAppendResult ValidateProductionCrownCreditIssuanceGate(
            string workspaceRoot,
            PassportMonetaryLedgerEvent ledgerEvent)
        {
            var capacityValidation = new PassportCrownCreditCapacityService(releaseLane)
                .ValidateIssuance(workspaceRoot, ledgerEvent.AmountBaseUnits, ledgerEvent.EvidenceReferences);
            if (!capacityValidation.Succeeded)
            {
                return FailedAppend(capacityValidation.Message);
            }

            if (!ledgerEvent.EvidenceReferences.TryGetValue("capacity_report_sha256", out var capacityReportSha256)
                || string.IsNullOrWhiteSpace(capacityReportSha256))
            {
                return FailedAppend("Production CC issuance requires capacity_report_sha256 evidence.");
            }

            var intentHash = ComputeCrownCreditIssueIntentHash(
                releaseLane,
                ledgerEvent.AccountId,
                ledgerEvent.IdentityId,
                ledgerEvent.WalletKeyId,
                ledgerEvent.AmountBaseUnits,
                ledgerEvent.EvidenceReferences);
            var issuerValidation = new PassportAdminAuthorityService(releaseLane)
                .ValidateDualControlActionEvidence(
                    workspaceRoot,
                    ledgerEvent.EvidenceReferences,
                    EventCrownCreditIssue,
                    capacityReportSha256,
                    intentHash);
            if (!issuerValidation.Succeeded)
            {
                return FailedAppend(issuerValidation.Message);
            }

            return new PassportMonetaryLedgerAppendResult
            {
                Succeeded = true,
                Message = "Production CC issuance authority is valid."
            };
        }

        private PassportMonetaryLedgerAppendResult ValidateProductionArchGenesisGate(
            string workspaceRoot,
            PassportMonetaryLedgerEvent ledgerEvent)
        {
            var genesisValidation = new PassportArchGenesisService(releaseLane)
                .ValidateAllocation(
                    workspaceRoot,
                    ledgerEvent.AccountId,
                    ledgerEvent.IdentityId,
                    ledgerEvent.WalletKeyId,
                    ledgerEvent.AmountBaseUnits,
                    ledgerEvent.EvidenceReferences);
            if (!genesisValidation.Succeeded)
            {
                return FailedAppend(genesisValidation.Message);
            }

            return new PassportMonetaryLedgerAppendResult
            {
                Succeeded = true,
                Message = "Production ARCH genesis allocation is valid."
            };
        }

        private PassportMonetaryLedgerAppendResult ValidateAdminAuthorityGateIfPresent(
            string workspaceRoot,
            PassportMonetaryLedgerEvent ledgerEvent)
        {
            if (!HasAdminAuthorityEvidence(ledgerEvent))
            {
                return new PassportMonetaryLedgerAppendResult
                {
                    Succeeded = true,
                    Message = "No admin authority evidence present."
                };
            }

            var expectedActionType = ReadEvidence(ledgerEvent, "admin_authority_action_type");
            var expectedTargetRecordSha256 = ReadEvidence(ledgerEvent, "admin_authority_target_record_sha256");
            var expectedRequestedPayloadSha256 = ReadEvidence(ledgerEvent, "admin_authority_requested_payload_sha256");
            if (string.IsNullOrWhiteSpace(expectedActionType)
                || string.IsNullOrWhiteSpace(expectedTargetRecordSha256)
                || string.IsNullOrWhiteSpace(expectedRequestedPayloadSha256))
            {
                return FailedAppend("Admin-authorized ledger events require admin_authority_action_type, admin_authority_target_record_sha256, and admin_authority_requested_payload_sha256 evidence.");
            }

            if (!IsAdminActionAllowedForLedgerEvent(expectedActionType, ledgerEvent.EventType, ledgerEvent.AssetCode))
            {
                return FailedAppend("Admin action " + expectedActionType + " is not allowed for ledger event " + ledgerEvent.EventType + ".");
            }

            var validation = new PassportAdminAuthorityService(releaseLane).ValidateDualControlActionEvidence(
                workspaceRoot,
                ledgerEvent.EvidenceReferences,
                expectedActionType,
                expectedTargetRecordSha256,
                expectedRequestedPayloadSha256);
            if (!validation.Succeeded)
            {
                return FailedAppend(validation.Message);
            }

            return new PassportMonetaryLedgerAppendResult
            {
                Succeeded = true,
                Message = "Admin-authorized ledger event authority is valid."
            };
        }

        private static bool HasAdminAuthorityEvidence(PassportMonetaryLedgerEvent ledgerEvent)
        {
            return ledgerEvent.EvidenceReferences.ContainsKey("admin_authority_action_type");
        }

        private static bool IsAdminAuthorityStatus(string signatureStatus)
        {
            return string.Equals(signatureStatus, PassportMonetaryProtocol.SignatureDualControlAdminAuthorized, StringComparison.Ordinal);
        }

        private static bool IsPendingEscrowMutation(PassportMonetaryLedgerEvent ledgerEvent)
        {
            return string.Equals(ledgerEvent.AssetCode, AssetCrownCredit, StringComparison.Ordinal)
                && (string.Equals(ledgerEvent.EventType, EventCrownCreditBurn, StringComparison.Ordinal)
                    || string.Equals(ledgerEvent.EventType, EventCrownCreditRefund, StringComparison.Ordinal));
        }

        private static bool IsAdminActionAllowedForLedgerEvent(string actionType, string eventType, string assetCode)
        {
            var normalized = (actionType ?? string.Empty).Trim().ToLowerInvariant();
            if (!string.Equals(assetCode, AssetCrownCredit, StringComparison.Ordinal))
            {
                return false;
            }

            return (normalized == "escrow_release" && eventType == EventCrownCreditRefund)
                || (normalized == "burn_override" && eventType == EventCrownCreditBurn)
                || (normalized == "storage_recredit" && eventType == EventCrownCreditRecredit)
                || (normalized == "recovery_override" && eventType == EventCrownCreditRecredit);
        }

        private static string ReadEvidence(PassportMonetaryLedgerEvent ledgerEvent, string key)
        {
            return ledgerEvent.EvidenceReferences.TryGetValue(key, out var value) ? value.Trim() : string.Empty;
        }

        private static PassportMonetaryLedgerReplayEvent ToCoreReplayEvent(PassportMonetaryLedgerEvent ledgerEvent)
        {
            return new PassportMonetaryLedgerReplayEvent
            {
                EventId = ledgerEvent.EventId,
                EventType = ledgerEvent.EventType,
                CreatedUtc = ledgerEvent.CreatedUtc,
                ReleaseLane = ledgerEvent.ReleaseLane,
                LedgerNamespace = ledgerEvent.LedgerNamespace,
                ProductionTokenRecord = ledgerEvent.ProductionTokenRecord,
                StagingRecord = ledgerEvent.StagingRecord,
                AccountId = ledgerEvent.AccountId,
                AssetCode = ledgerEvent.AssetCode,
                AmountBaseUnits = ledgerEvent.AmountBaseUnits,
                GlobalSequence = ledgerEvent.GlobalSequence,
                AccountSequence = ledgerEvent.AccountSequence,
                PriorAccountEventHash = ledgerEvent.PriorAccountEventHash,
                EventHashSha256 = ledgerEvent.EventHashSha256,
                AntiReplayNonce = ledgerEvent.AntiReplayNonce,
                ArchGenesisAllocationId = ReadEvidence(ledgerEvent, "arch_genesis_allocation_id")
            };
        }

        private static PassportMonetaryLedgerRecord ToCoreLedgerRecord(PassportMonetaryLedgerEvent ledgerEvent)
        {
            return new PassportMonetaryLedgerRecord
            {
                SchemaVersion = ledgerEvent.SchemaVersion,
                RecordType = ledgerEvent.RecordType,
                EventId = ledgerEvent.EventId,
                EventType = ledgerEvent.EventType,
                CreatedUtc = ledgerEvent.CreatedUtc,
                ReleaseLane = ledgerEvent.ReleaseLane,
                TelemetryEnvironment = ledgerEvent.TelemetryEnvironment,
                LedgerNamespace = ledgerEvent.LedgerNamespace,
                ProductionTokenRecord = ledgerEvent.ProductionTokenRecord,
                StagingRecord = ledgerEvent.StagingRecord,
                AccountId = ledgerEvent.AccountId,
                IdentityId = ledgerEvent.IdentityId,
                WalletKeyId = ledgerEvent.WalletKeyId,
                AssetCode = ledgerEvent.AssetCode,
                AmountBaseUnits = ledgerEvent.AmountBaseUnits,
                GlobalSequence = ledgerEvent.GlobalSequence,
                AccountSequence = ledgerEvent.AccountSequence,
                PriorAccountEventHash = ledgerEvent.PriorAccountEventHash,
                ServerReceivedUtc = ledgerEvent.ServerReceivedUtc,
                AntiReplayNonce = ledgerEvent.AntiReplayNonce,
                DeviceSessionId = ledgerEvent.DeviceSessionId,
                PolicyVersion = ledgerEvent.PolicyVersion,
                EvidenceReferences = new Dictionary<string, string>(ledgerEvent.EvidenceReferences, StringComparer.Ordinal),
                SignatureStatus = ledgerEvent.SignatureStatus,
                WalletSignatureAlgorithm = ledgerEvent.WalletSignatureAlgorithm,
                WalletSignatureBase64 = ledgerEvent.WalletSignatureBase64,
                SignedEventHashSha256 = ledgerEvent.SignedEventHashSha256,
                WalletPublicKeyPath = ledgerEvent.WalletPublicKeyPath,
                EventHashSha256 = ledgerEvent.EventHashSha256
            };
        }

        private void ValidateEventSignature(string workspaceRoot, PassportMonetaryLedgerEvent ledgerEvent, List<string> failures)
        {
            if (releaseLane.ProductionLedger
                && !string.Equals(ledgerEvent.SignatureStatus, PassportMonetaryProtocol.SignatureWalletSigned, StringComparison.Ordinal)
                && !IsAdminAuthorityStatus(ledgerEvent.SignatureStatus))
            {
                failures.Add("Production monetary ledger event " + ledgerEvent.EventId + " is not wallet-signed.");
            }

            if (IsAdminAuthorityStatus(ledgerEvent.SignatureStatus))
            {
                var adminGate = ValidateAdminAuthorityGateIfPresent(workspaceRoot, ledgerEvent);
                if (!adminGate.Succeeded)
                {
                    failures.Add("Admin-authorized ledger event " + ledgerEvent.EventId + " failed authority validation: " + adminGate.Message);
                }

                return;
            }

            if (!string.Equals(ledgerEvent.SignatureStatus, PassportMonetaryProtocol.SignatureWalletSigned, StringComparison.Ordinal))
            {
                return;
            }

            if (!string.Equals(ledgerEvent.WalletSignatureAlgorithm, "RSA_PKCS1_SHA256", StringComparison.Ordinal))
            {
                failures.Add("Unsupported wallet signature algorithm for event " + ledgerEvent.EventId + ".");
            }

            if (string.IsNullOrWhiteSpace(ledgerEvent.WalletSignatureBase64))
            {
                failures.Add("Missing wallet signature for event " + ledgerEvent.EventId + ".");
                return;
            }

            if (string.IsNullOrWhiteSpace(ledgerEvent.WalletPublicKeyPath))
            {
                failures.Add("Missing wallet public key path for event " + ledgerEvent.EventId + ".");
                return;
            }

            var expectedSignedHash = ComputeUnsignedEventPayloadHash(ledgerEvent);
            if (!string.Equals(expectedSignedHash, ledgerEvent.SignedEventHashSha256, StringComparison.OrdinalIgnoreCase))
            {
                failures.Add("Wallet signature payload hash does not match event payload for event " + ledgerEvent.EventId + ".");
                return;
            }

            try
            {
                var publicKeyPath = ResolveWorkspaceRelativePath(workspaceRoot, ledgerEvent.WalletPublicKeyPath);
                if (!File.Exists(publicKeyPath))
                {
                    failures.Add("Wallet public key file is missing for event " + ledgerEvent.EventId + ".");
                    return;
                }

                var signatureBytes = Convert.FromBase64String(ledgerEvent.WalletSignatureBase64);
                if (!VerifySignature(publicKeyPath, Encoding.UTF8.GetBytes(ledgerEvent.SignedEventHashSha256), signatureBytes))
                {
                    failures.Add("Wallet signature verification failed for event " + ledgerEvent.EventId + ".");
                }

                var walletAuthority = new PassportWalletKeyService(releaseLane);
                if (!walletAuthority.IsWalletKeyAuthorizedAt(workspaceRoot, ledgerEvent.IdentityId, ledgerEvent.WalletKeyId, ledgerEvent.CreatedUtc))
                {
                    failures.Add("Wallet key " + ledgerEvent.WalletKeyId + " was not authorized for event " + ledgerEvent.EventId + ".");
                }
            }
            catch (Exception ex)
            {
                failures.Add("Wallet signature validation failed for event " + ledgerEvent.EventId + ": " + ex.Message);
            }
        }

        private void ValidateReleaseLane(PassportMonetaryLedgerEvent ledgerEvent, List<string> failures)
        {
            if (!string.Equals(ledgerEvent.ReleaseLane, releaseLane.Lane, StringComparison.Ordinal))
            {
                failures.Add("Event " + ledgerEvent.EventId + " belongs to release lane " + ledgerEvent.ReleaseLane + " but this ledger is " + releaseLane.Lane + ".");
            }

            if (!string.Equals(ledgerEvent.LedgerNamespace, releaseLane.LedgerNamespace, StringComparison.Ordinal))
            {
                failures.Add("Event " + ledgerEvent.EventId + " belongs to ledger namespace " + ledgerEvent.LedgerNamespace + " but this ledger is " + releaseLane.LedgerNamespace + ".");
            }

            if (releaseLane.ProductionLedger && !ledgerEvent.ProductionTokenRecord)
            {
                failures.Add("Production ledger event " + ledgerEvent.EventId + " is missing production token record status.");
            }

            if (!releaseLane.AllowProductionTokenRecords && ledgerEvent.ProductionTokenRecord)
            {
                failures.Add("Non-production ledger event " + ledgerEvent.EventId + " cannot carry production token record status.");
            }

            if (ledgerEvent.StagingRecord && !releaseLane.AllowStagingRecords)
            {
                failures.Add("Event " + ledgerEvent.EventId + " is marked as staging but this release lane does not allow staging records.");
            }
        }

        private void ApplyEventSemantics(
            Dictionary<string, PassportMonetaryBalance> balances,
            PassportMonetaryLedgerEvent ledgerEvent,
            List<string> failures)
        {
            ValidateReleaseLane(ledgerEvent, failures);

            if (string.Equals(ledgerEvent.AssetCode, AssetArch, StringComparison.Ordinal))
            {
                ApplyArchEvent(balances, ledgerEvent, failures);
                return;
            }

            if (string.Equals(ledgerEvent.AssetCode, AssetCrownCredit, StringComparison.Ordinal))
            {
                ApplyCrownCreditEvent(balances, ledgerEvent, failures);
                return;
            }

            failures.Add("Unsupported monetary asset code " + ledgerEvent.AssetCode + " for event " + ledgerEvent.EventId + ".");
        }

        private static void ApplyArchEvent(
            Dictionary<string, PassportMonetaryBalance> balances,
            PassportMonetaryLedgerEvent ledgerEvent,
            List<string> failures)
        {
            var balance = GetBalance(balances, ledgerEvent.AccountId, AssetArch);
            ApplyCoreBalanceSemantics(balance, ledgerEvent, failures);
        }

        private static void ApplyCrownCreditEvent(
            Dictionary<string, PassportMonetaryBalance> balances,
            PassportMonetaryLedgerEvent ledgerEvent,
            List<string> failures)
        {
            var balance = GetBalance(balances, ledgerEvent.AccountId, AssetCrownCredit);
            ApplyCoreBalanceSemantics(balance, ledgerEvent, failures);
        }

        private static void ApplyCoreBalanceSemantics(
            PassportMonetaryBalance balance,
            PassportMonetaryLedgerEvent ledgerEvent,
            List<string> failures)
        {
            var result = PassportMonetaryLedgerSemantics.ApplyEvent(
                new PassportMonetaryBalanceState
                {
                    AccountId = balance.AccountId,
                    AssetCode = balance.AssetCode,
                    AvailableBaseUnits = balance.AvailableBaseUnits,
                    EscrowedBaseUnits = balance.EscrowedBaseUnits,
                    BurnedBaseUnits = balance.BurnedBaseUnits
                },
                new PassportMonetaryLedgerEventState
                {
                    EventId = ledgerEvent.EventId,
                    AccountId = ledgerEvent.AccountId,
                    AssetCode = ledgerEvent.AssetCode,
                    EventType = ledgerEvent.EventType,
                    AmountBaseUnits = ledgerEvent.AmountBaseUnits
                });

            foreach (var failure in result.Failures)
            {
                failures.Add(failure);
            }

            balance.AvailableBaseUnits = result.Balance.AvailableBaseUnits;
            balance.EscrowedBaseUnits = result.Balance.EscrowedBaseUnits;
            balance.BurnedBaseUnits = result.Balance.BurnedBaseUnits;
        }

        private static PassportMonetaryBalance GetBalance(
            Dictionary<string, PassportMonetaryBalance> balances,
            string accountId,
            string assetCode)
        {
            var key = accountId + "|" + assetCode;
            if (!balances.TryGetValue(key, out var balance))
            {
                balance = new PassportMonetaryBalance
                {
                    AccountId = accountId,
                    AssetCode = assetCode
                };
                balances[key] = balance;
            }

            return balance;
        }

        private TransparencySnapshot BuildTransparencySnapshot(IReadOnlyList<(string Path, PassportMonetaryLedgerEvent Event)> orderedEvents)
        {
            var leaves = orderedEvents
                .Select((item, index) =>
                {
                    var leafHash = ComputeTransparencyLeafHash(item.Event);
                    return new TransparencyLeaf
                    {
                        Index = index,
                        EventId = item.Event.EventId,
                        GlobalSequence = item.Event.GlobalSequence,
                        AccountId = item.Event.AccountId,
                        AssetCode = item.Event.AssetCode,
                        EventHashSha256 = item.Event.EventHashSha256,
                        LeafHashSha256 = leafHash
                    };
                })
                .ToArray();

            var leafHashes = leaves.Select(leaf => leaf.LeafHashSha256).ToArray();
            return new TransparencySnapshot
            {
                EventHashes = orderedEvents.Select(item => item.Event.EventHashSha256).ToArray(),
                EventLeaves = leaves
                    .Select(leaf => new Dictionary<string, object?>
                    {
                        ["event_id"] = leaf.EventId,
                        ["global_sequence"] = leaf.GlobalSequence,
                        ["account_id"] = leaf.AccountId,
                        ["asset_code"] = leaf.AssetCode,
                        ["event_hash_sha256"] = leaf.EventHashSha256,
                        ["leaf_hash_sha256"] = leaf.LeafHashSha256
                    })
                    .ToArray(),
                Leaves = leaves,
                LeafHashes = leafHashes,
                EpochRootSha256 = ComputeMerkleRoot(leafHashes)
            };
        }

        private static string ComputeTransparencyLeafHash(PassportMonetaryLedgerEvent ledgerEvent)
        {
            return PassportMonetaryLedgerExportVerifier.ComputeTransparencyLeafHash(ToCoreLedgerRecord(ledgerEvent));
        }

        private static string ComputeMerkleRoot(IReadOnlyList<string> leafHashes)
        {
            return PassportMonetaryLedgerExportVerifier.ComputeMerkleRoot(leafHashes);
        }

        private static string ComputeMerkleParent(string leftHash, string rightHash)
        {
            return PassportMonetaryLedgerExportVerifier.ComputeMerkleParent(leftHash, rightHash);
        }

        private static Dictionary<string, object?> BuildInclusionProof(TransparencySnapshot snapshot, TransparencyLeaf leaf)
        {
            var siblings = BuildMerkleProof(snapshot.LeafHashes, leaf.Index);
            return new Dictionary<string, object?>
            {
                ["proof_version"] = 1,
                ["root_algorithm"] = "merkle_sha256_v1",
                ["event_id"] = leaf.EventId,
                ["global_sequence"] = leaf.GlobalSequence,
                ["leaf_index"] = leaf.Index,
                ["leaf_hash_sha256"] = leaf.LeafHashSha256,
                ["epoch_root_sha256"] = snapshot.EpochRootSha256,
                ["siblings"] = siblings
            };
        }

        private static List<Dictionary<string, object?>> BuildMerkleProof(IReadOnlyList<string> leafHashes, int leafIndex)
        {
            if (leafIndex < 0 || leafIndex >= leafHashes.Count)
            {
                throw new InvalidOperationException("Transparency inclusion proof leaf index is out of range.");
            }

            var proof = new List<Dictionary<string, object?>>();
            var index = leafIndex;
            var level = leafHashes.Select(NormalizeHash).ToList();
            while (level.Count > 1)
            {
                var isRight = index % 2 == 1;
                var siblingIndex = isRight ? index - 1 : index + 1;
                var siblingHash = siblingIndex < level.Count ? level[siblingIndex] : level[index];
                proof.Add(new Dictionary<string, object?>
                {
                    ["position"] = isRight ? "left" : "right",
                    ["hash_sha256"] = siblingHash
                });

                var next = new List<string>();
                for (var i = 0; i < level.Count; i += 2)
                {
                    var left = level[i];
                    var right = i + 1 < level.Count ? level[i + 1] : left;
                    next.Add(ComputeMerkleParent(left, right));
                }

                index /= 2;
                level = next;
            }

            return proof;
        }

        private static bool VerifyMerkleProof(JsonElement proof, string expectedRootSha256, List<string> failures)
        {
            var eventId = ReadString(proof, "event_id");
            var computed = ReadString(proof, "leaf_hash_sha256");
            if (string.IsNullOrWhiteSpace(computed))
            {
                failures.Add("Inclusion proof is missing a leaf hash for event " + eventId + ".");
                return false;
            }

            if (proof.TryGetProperty("siblings", out var siblings) && siblings.ValueKind == JsonValueKind.Array)
            {
                foreach (var sibling in siblings.EnumerateArray())
                {
                    var siblingHash = ReadString(sibling, "hash_sha256");
                    var position = ReadString(sibling, "position");
                    if (string.Equals(position, "left", StringComparison.Ordinal))
                    {
                        computed = ComputeMerkleParent(siblingHash, computed);
                    }
                    else if (string.Equals(position, "right", StringComparison.Ordinal))
                    {
                        computed = ComputeMerkleParent(computed, siblingHash);
                    }
                    else
                    {
                        failures.Add("Inclusion proof has an invalid sibling position for event " + eventId + ".");
                        return false;
                    }
                }
            }

            var expected = NormalizeHash(expectedRootSha256);
            var proofRoot = NormalizeHash(ReadString(proof, "epoch_root_sha256"));
            if (!string.Equals(proofRoot, expected, StringComparison.Ordinal))
            {
                failures.Add("Inclusion proof root does not match export transparency root for event " + eventId + ".");
                return false;
            }

            if (!string.Equals(NormalizeHash(computed), expected, StringComparison.Ordinal))
            {
                failures.Add("Inclusion proof does not resolve to the transparency root for event " + eventId + ".");
                return false;
            }

            return true;
        }

        private static TransparencyLeaf FindLeaf(TransparencySnapshot snapshot, string eventId, string eventHashSha256)
        {
            var leaf = snapshot.Leaves.FirstOrDefault(item =>
                string.Equals(item.EventId, eventId, StringComparison.Ordinal)
                && string.Equals(item.EventHashSha256, eventHashSha256, StringComparison.OrdinalIgnoreCase));
            if (leaf == null)
            {
                throw new InvalidOperationException("Unable to find transparency leaf for event " + eventId + ".");
            }

            return leaf;
        }

        private static List<Dictionary<string, object?>> BuildAccountHashChain(IReadOnlyList<PassportMonetaryLedgerEvent> accountEvents)
        {
            return accountEvents
                .OrderBy(item => item.AccountSequence)
                .ThenBy(item => item.CreatedUtc, StringComparer.Ordinal)
                .ThenBy(item => item.EventId, StringComparer.Ordinal)
                .Select(item => new Dictionary<string, object?>
                {
                    ["account_sequence"] = item.AccountSequence,
                    ["event_id"] = item.EventId,
                    ["prior_account_event_hash"] = item.PriorAccountEventHash,
                    ["event_hash_sha256"] = item.EventHashSha256
                })
                .ToList();
        }

        private static List<Dictionary<string, object?>> CopyWalletKeyHistory(
            string workspaceRoot,
            string exportRoot,
            IReadOnlyList<PassportMonetaryLedgerEvent> accountEvents)
        {
            var walletKeyIds = accountEvents
                .Select(item => item.WalletKeyId)
                .Where(item => !string.IsNullOrWhiteSpace(item))
                .Distinct(StringComparer.Ordinal)
                .ToArray();
            var identityIds = accountEvents
                .Select(item => item.IdentityId)
                .Where(item => !string.IsNullOrWhiteSpace(item))
                .Distinct(StringComparer.Ordinal)
                .ToArray();
            var sourceRoots = new[]
            {
                Path.Combine(workspaceRoot, "records", "passport", "wallet", "bindings"),
                Path.Combine(workspaceRoot, "records", "passport", "wallet", "revocations")
            };
            var copied = new List<Dictionary<string, object?>>();
            var copiedPaths = new HashSet<string>(StringComparer.OrdinalIgnoreCase);

            foreach (var sourceRoot in sourceRoots.Where(Directory.Exists))
            {
                foreach (var file in Directory.GetFiles(sourceRoot, "*.json").OrderBy(Path.GetFileName, StringComparer.OrdinalIgnoreCase))
                {
                    using var document = JsonDocument.Parse(File.ReadAllText(file));
                    var root = document.RootElement;
                    var walletKeyId = ReadString(root, "wallet_key_id");
                    var identityId = ReadString(root, "archrealms_identity_id");
                    if (!walletKeyIds.Contains(walletKeyId, StringComparer.Ordinal)
                        || !identityIds.Contains(identityId, StringComparer.Ordinal))
                    {
                        continue;
                    }

                    CopyExportMaterial(workspaceRoot, exportRoot, file, copied, copiedPaths, "wallet_key_history");

                    if (root.TryGetProperty("wallet_public_key_path", out var publicKeyPathElement))
                    {
                        var publicKeyPath = ResolveWorkspaceRelativePath(workspaceRoot, publicKeyPathElement.GetString() ?? string.Empty);
                        if (File.Exists(publicKeyPath))
                        {
                            CopyExportMaterial(workspaceRoot, exportRoot, publicKeyPath, copied, copiedPaths, "wallet_public_key");
                        }
                    }
                }
            }

            return copied;
        }

        private static void CopyExportMaterial(
            string workspaceRoot,
            string exportRoot,
            string sourcePath,
            List<Dictionary<string, object?>> copied,
            HashSet<string> copiedPaths,
            string materialType)
        {
            var relativePath = ToWorkspaceRelativePath(workspaceRoot, sourcePath);
            if (relativePath.StartsWith("records/passport/wallet/keys/", StringComparison.OrdinalIgnoreCase))
            {
                return;
            }

            if (!copiedPaths.Add(relativePath))
            {
                return;
            }

            var exportPath = Path.Combine(exportRoot, relativePath.Replace('/', Path.DirectorySeparatorChar));
            CopyFile(sourcePath, exportPath);
            copied.Add(new Dictionary<string, object?>
            {
                ["material_type"] = materialType,
                ["source_path"] = relativePath,
                ["export_path"] = ToWorkspaceRelativePath(exportRoot, exportPath),
                ["sha256"] = ComputeSha256(File.ReadAllBytes(exportPath))
            });
        }

        private void VerifyExportedEvent(string exportRoot, JsonElement manifest, JsonElement eventRow, List<string> failures)
        {
            var eventId = ReadString(eventRow, "event_id");
            var relativePath = ReadString(eventRow, "export_path");
            var eventPath = ResolveWorkspaceRelativePath(exportRoot, relativePath);
            if (!File.Exists(eventPath))
            {
                failures.Add("Missing exported event file for event " + eventId + ".");
                return;
            }

            var expectedFileHash = ReadString(eventRow, "event_file_sha256");
            if (!string.IsNullOrWhiteSpace(expectedFileHash))
            {
                var actualFileHash = ComputeSha256(File.ReadAllBytes(eventPath));
                if (!string.Equals(actualFileHash, expectedFileHash, StringComparison.OrdinalIgnoreCase))
                {
                    failures.Add("Exported event file hash mismatch for event " + eventId + ".");
                }
            }

            var ledgerEvent = JsonSerializer.Deserialize<PassportMonetaryLedgerEvent>(File.ReadAllText(eventPath));
            if (ledgerEvent == null)
            {
                failures.Add("Unable to parse exported event " + eventId + ".");
                return;
            }

            if (!string.Equals(ledgerEvent.EventId, eventId, StringComparison.Ordinal))
            {
                failures.Add("Exported event ID mismatch for " + eventId + ".");
            }

            if (!string.Equals(ledgerEvent.EventHashSha256, ReadString(eventRow, "event_hash_sha256"), StringComparison.OrdinalIgnoreCase))
            {
                failures.Add("Export manifest event hash mismatch for " + eventId + ".");
            }

            var computedEventHash = ComputeEventHash(ledgerEvent);
            if (!string.Equals(computedEventHash, ledgerEvent.EventHashSha256, StringComparison.OrdinalIgnoreCase))
            {
                failures.Add("Exported event hash is invalid for event " + eventId + ".");
            }

            if (eventRow.TryGetProperty("inclusion_proof", out var proof))
            {
                var leafHash = ComputeTransparencyLeafHash(ledgerEvent);
                if (!string.Equals(leafHash, ReadString(proof, "leaf_hash_sha256"), StringComparison.OrdinalIgnoreCase))
                {
                    failures.Add("Inclusion proof leaf hash does not match event " + eventId + ".");
                }

                VerifyMerkleProof(proof, ReadString(manifest, "transparency_root_sha256"), failures);
            }
            else
            {
                failures.Add("Exported event is missing an inclusion proof: " + eventId + ".");
            }
        }

        private static void VerifyTransparencyRoot(string transparencyRootPath, string expectedRootSha256, List<string> failures)
        {
            using var document = JsonDocument.Parse(File.ReadAllText(transparencyRootPath));
            var root = document.RootElement;
            if (!Matches(root, "record_type", "passport_monetary_transparency_root"))
            {
                failures.Add("Invalid transparency root record type.");
                return;
            }

            if (!Matches(root, "root_algorithm", "merkle_sha256_v1"))
            {
                failures.Add("Unsupported transparency root algorithm.");
                return;
            }

            if (!string.Equals(ReadString(root, "epoch_root_sha256"), expectedRootSha256, StringComparison.OrdinalIgnoreCase))
            {
                failures.Add("Transparency root hash does not match manifest.");
            }

            if (!root.TryGetProperty("event_leaves", out var eventLeaves) || eventLeaves.ValueKind != JsonValueKind.Array)
            {
                failures.Add("Transparency root is missing event leaves.");
                return;
            }

            var leafHashes = eventLeaves
                .EnumerateArray()
                .Select(item => ReadString(item, "leaf_hash_sha256"))
                .ToArray();
            var computedRoot = ComputeMerkleRoot(leafHashes);
            if (!string.Equals(computedRoot, expectedRootSha256, StringComparison.OrdinalIgnoreCase))
            {
                failures.Add("Transparency root cannot be recomputed from event leaves.");
            }
        }

        private static void VerifyKeyHistory(string exportRoot, JsonElement keyHistory, List<string> failures)
        {
            foreach (var item in keyHistory.EnumerateArray())
            {
                var exportPath = ResolveWorkspaceRelativePath(exportRoot, ReadString(item, "export_path"));
                if (!File.Exists(exportPath))
                {
                    failures.Add("Missing key-history export material: " + ReadString(item, "export_path") + ".");
                    continue;
                }

                var expectedHash = ReadString(item, "sha256");
                var actualHash = ComputeSha256(File.ReadAllBytes(exportPath));
                if (!string.Equals(actualHash, expectedHash, StringComparison.OrdinalIgnoreCase))
                {
                    failures.Add("Key-history export material hash mismatch: " + ReadString(item, "export_path") + ".");
                }

                if (ReadString(item, "export_path").Contains("records/passport/wallet/keys/", StringComparison.OrdinalIgnoreCase))
                {
                    failures.Add("Account export must not include protected wallet private key material.");
                }
            }
        }

        private static void VerifyManifestBalances(JsonElement manifest, PassportMonetaryLedgerReplayResult replay, List<string> failures)
        {
            if (!manifest.TryGetProperty("balances", out var balances) || balances.ValueKind != JsonValueKind.Array)
            {
                failures.Add("Manifest does not contain replay balances.");
                return;
            }

            foreach (var manifestBalance in balances.EnumerateArray())
            {
                var accountId = ReadString(manifestBalance, "account_id");
                var assetCode = ReadString(manifestBalance, "asset_code");
                var replayBalance = replay.Balances.FirstOrDefault(balance =>
                    string.Equals(balance.AccountId, accountId, StringComparison.Ordinal)
                    && string.Equals(balance.AssetCode, assetCode, StringComparison.Ordinal));
                if (replayBalance == null)
                {
                    failures.Add("Replay does not contain manifest balance for " + accountId + " " + assetCode + ".");
                    continue;
                }

                if (replayBalance.AvailableBaseUnits != ReadInt64(manifestBalance, "available_base_units")
                    || replayBalance.EscrowedBaseUnits != ReadInt64(manifestBalance, "escrowed_base_units")
                    || replayBalance.BurnedBaseUnits != ReadInt64(manifestBalance, "burned_base_units"))
                {
                    failures.Add("Replay balance does not match manifest for " + accountId + " " + assetCode + ".");
                }
            }
        }

        private static void VerifyManifestAccountHashChain(JsonElement manifest, List<string> failures)
        {
            if (!manifest.TryGetProperty("events", out var events) || events.ValueKind != JsonValueKind.Array)
            {
                return;
            }

            if (!manifest.TryGetProperty("account_hash_chain", out var chain) || chain.ValueKind != JsonValueKind.Array)
            {
                failures.Add("Manifest does not contain an account hash chain.");
                return;
            }

            var eventRows = events
                .EnumerateArray()
                .ToDictionary(
                    item => ReadString(item, "event_id"),
                    item => item.Clone(),
                    StringComparer.Ordinal);
            var expectedSequence = 1L;
            var expectedPriorHash = string.Empty;
            foreach (var chainItem in chain.EnumerateArray().OrderBy(item => ReadInt64(item, "account_sequence")))
            {
                var eventId = ReadString(chainItem, "event_id");
                if (!eventRows.TryGetValue(eventId, out var eventRow))
                {
                    failures.Add("Account hash chain references an event missing from the export manifest: " + eventId + ".");
                    continue;
                }

                var sequence = ReadInt64(chainItem, "account_sequence");
                if (sequence != expectedSequence)
                {
                    failures.Add("Account hash chain expected sequence " + expectedSequence + " but found " + sequence + ".");
                }

                if (!string.Equals(ReadString(chainItem, "prior_account_event_hash"), expectedPriorHash, StringComparison.OrdinalIgnoreCase))
                {
                    failures.Add("Account hash chain prior hash mismatch at sequence " + sequence + ".");
                }

                if (!string.Equals(ReadString(chainItem, "event_hash_sha256"), ReadString(eventRow, "event_hash_sha256"), StringComparison.OrdinalIgnoreCase))
                {
                    failures.Add("Account hash chain event hash mismatch for event " + eventId + ".");
                }

                expectedPriorHash = ReadString(chainItem, "event_hash_sha256");
                expectedSequence++;
            }

            if (chain.GetArrayLength() != eventRows.Count)
            {
                failures.Add("Account hash chain length does not match exported event count.");
            }
        }

        private IEnumerable<(string Path, PassportMonetaryLedgerEvent Event)> ReadEvents(string workspaceRoot)
        {
            var eventsRoot = GetEventsRoot(workspaceRoot);
            if (!Directory.Exists(eventsRoot))
            {
                return Array.Empty<(string Path, PassportMonetaryLedgerEvent Event)>();
            }

            return Directory
                .EnumerateFiles(eventsRoot, "*.json", SearchOption.AllDirectories)
                .OrderBy(path => path, StringComparer.OrdinalIgnoreCase)
                .Select(path =>
                {
                    var ledgerEvent = JsonSerializer.Deserialize<PassportMonetaryLedgerEvent>(File.ReadAllText(path));
                    if (ledgerEvent == null)
                    {
                        throw new InvalidOperationException("Unable to parse monetary ledger event: " + path);
                    }

                    return (Path: path, Event: ledgerEvent);
                })
                .ToArray();
        }

        private static string GetEventPath(string workspaceRoot, PassportMonetaryLedgerEvent ledgerEvent)
        {
            return Path.Combine(
                GetEventsRoot(workspaceRoot),
                ledgerEvent.AssetCode.ToLowerInvariant(),
                SanitizePathSegment(ledgerEvent.AccountId),
                ledgerEvent.AccountSequence.ToString("D12") + "-" + SanitizePathSegment(ledgerEvent.EventId) + ".json");
        }

        private static string GetEventsRoot(string workspaceRoot)
        {
            return Path.Combine(workspaceRoot, "records", "passport", "monetary", "events");
        }

        private static Dictionary<string, string> NormalizeEvidence(IDictionary<string, string>? evidenceReferences)
        {
            var normalized = new Dictionary<string, string>(StringComparer.Ordinal);
            if (evidenceReferences == null)
            {
                return normalized;
            }

            foreach (var item in evidenceReferences.OrderBy(item => item.Key, StringComparer.Ordinal))
            {
                if (!string.IsNullOrWhiteSpace(item.Key) && !string.IsNullOrWhiteSpace(item.Value))
                {
                    normalized[item.Key.Trim()] = item.Value.Trim();
                }
            }

            return normalized;
        }

        private static string NormalizeAssetCode(string assetCode)
        {
            return PassportMonetaryProtocol.NormalizeAssetCode(NormalizeRequired(assetCode, "asset code"));
        }

        private static string NormalizeRequired(string value, string label)
        {
            var normalized = (value ?? string.Empty).Trim();
            if (string.IsNullOrWhiteSpace(normalized))
            {
                throw new InvalidOperationException("A " + label + " is required.");
            }

            return normalized;
        }

        private static string SanitizePathSegment(string value)
        {
            var builder = new StringBuilder(value.Length);
            foreach (var c in value)
            {
                builder.Append(char.IsLetterOrDigit(c) || c == '-' || c == '_' || c == '.' ? c : '-');
            }

            return builder.ToString();
        }

        private static string ToWorkspaceRelativePath(string workspaceRoot, string path)
        {
            var normalizedRoot = Path.GetFullPath(workspaceRoot).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
            var normalizedPath = Path.GetFullPath(path);
            if (!normalizedPath.StartsWith(normalizedRoot, StringComparison.OrdinalIgnoreCase))
            {
                return path.Replace(Path.DirectorySeparatorChar, '/');
            }

            var relative = normalizedPath.Substring(normalizedRoot.Length).TrimStart(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
            return relative.Replace(Path.DirectorySeparatorChar, '/');
        }

        private static string ResolveWorkspaceRelativePath(string workspaceRoot, string path)
        {
            var normalized = path.Replace('/', Path.DirectorySeparatorChar);
            return Path.IsPathRooted(normalized)
                ? Path.GetFullPath(normalized)
                : Path.GetFullPath(Path.Combine(workspaceRoot, normalized));
        }

        private static bool Matches(JsonElement root, string propertyName, string expectedValue)
        {
            return string.Equals(ReadString(root, propertyName), expectedValue, StringComparison.Ordinal);
        }

        private static string ReadString(JsonElement root, string propertyName)
        {
            return root.TryGetProperty(propertyName, out var value) ? value.GetString() ?? string.Empty : string.Empty;
        }

        private static long ReadInt64(JsonElement root, string propertyName)
        {
            if (!root.TryGetProperty(propertyName, out var value))
            {
                return 0;
            }

            if (value.ValueKind == JsonValueKind.Number && value.TryGetInt64(out var number))
            {
                return number;
            }

            return value.ValueKind == JsonValueKind.String && long.TryParse(value.GetString(), out var parsed) ? parsed : 0;
        }

        private static string NormalizeHash(string hash)
        {
            return (hash ?? string.Empty).Trim().ToLowerInvariant();
        }

        private static bool VerifySignature(string publicKeyPath, byte[] data, byte[] signatureBytes)
        {
            using var rsa = RSA.Create();
            rsa.ImportSubjectPublicKeyInfo(File.ReadAllBytes(publicKeyPath), out _);
            return rsa.VerifyData(data, signatureBytes, HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1);
        }

        private static string CopyFile(string sourcePath, string destinationPath)
        {
            Directory.CreateDirectory(Path.GetDirectoryName(destinationPath) ?? string.Empty);
            File.Copy(sourcePath, destinationPath, true);
            return destinationPath;
        }

        private static string ComputeDirectoryHash(string root)
        {
            var builder = new StringBuilder();
            foreach (var file in Directory.EnumerateFiles(root, "*", SearchOption.AllDirectories).OrderBy(path => path, StringComparer.OrdinalIgnoreCase))
            {
                var relativePath = ToWorkspaceRelativePath(root, file);
                builder.Append(relativePath).Append('\n');
                builder.Append(ComputeSha256(File.ReadAllBytes(file))).Append('\n');
            }

            return ComputeSha256(Encoding.UTF8.GetBytes(builder.ToString()));
        }

        private static string ComputeSha256(byte[] value)
        {
            return Convert.ToHexString(SHA256.HashData(value)).ToLowerInvariant();
        }

        private sealed class TransparencySnapshot
        {
            public string[] EventHashes { get; set; } = Array.Empty<string>();

            public Dictionary<string, object?>[] EventLeaves { get; set; } = Array.Empty<Dictionary<string, object?>>();

            public TransparencyLeaf[] Leaves { get; set; } = Array.Empty<TransparencyLeaf>();

            public string[] LeafHashes { get; set; } = Array.Empty<string>();

            public string EpochRootSha256 { get; set; } = string.Empty;
        }

        private sealed class TransparencyLeaf
        {
            public int Index { get; set; }

            public string EventId { get; set; } = string.Empty;

            public long GlobalSequence { get; set; }

            public string AccountId { get; set; } = string.Empty;

            public string AssetCode { get; set; } = string.Empty;

            public string EventHashSha256 { get; set; } = string.Empty;

            public string LeafHashSha256 { get; set; } = string.Empty;
        }

        private static PassportMonetaryLedgerAppendResult FailedAppend(string message)
        {
            return new PassportMonetaryLedgerAppendResult
            {
                Succeeded = false,
                Message = message
            };
        }

        private static PassportMonetaryTransparencyRootResult FailedTransparencyRoot(string message)
        {
            return new PassportMonetaryTransparencyRootResult
            {
                Succeeded = false,
                Message = message
            };
        }

        private static PassportMonetaryLedgerExportResult FailedExport(string message)
        {
            return new PassportMonetaryLedgerExportResult
            {
                Succeeded = false,
                Message = message
            };
        }
    }
}
