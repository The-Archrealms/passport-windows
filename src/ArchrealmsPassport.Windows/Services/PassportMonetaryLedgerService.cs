using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using ArchrealmsPassport.Windows.Models;

namespace ArchrealmsPassport.Windows.Services
{
    public sealed class PassportMonetaryLedgerService
    {
        public const string AssetArch = "ARCH";
        public const string AssetCrownCredit = "CC";
        public const string EventArchGenesisAllocation = "arch_genesis_allocation";
        public const string EventArchTransferIn = "arch_transfer_in";
        public const string EventArchTransferOut = "arch_transfer_out";
        public const string EventCrownCreditIssue = "cc_issue";
        public const string EventCrownCreditEscrow = "cc_escrow";
        public const string EventCrownCreditBurn = "cc_burn";
        public const string EventCrownCreditRefund = "cc_refund";
        public const string EventCrownCreditRecredit = "cc_recredit";

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
                    SignatureStatus = "unsigned-local-ledger-foundation"
                };

                if (releaseLane.ProductionLedger && string.IsNullOrWhiteSpace(walletKeyReferencePath))
                {
                    return FailedAppend("Production monetary ledger events require a wallet signature.");
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

                    ledgerEvent.SignatureStatus = "wallet_signed";
                    ledgerEvent.WalletSignatureAlgorithm = "RSA_PKCS1_SHA256";
                    ledgerEvent.WalletSignatureBase64 = Convert.ToBase64String(signatureBytes);
                    ledgerEvent.SignedEventHashSha256 = signedPayloadHash;
                    ledgerEvent.WalletPublicKeyPath = ToWorkspaceRelativePath(resolvedWorkspaceRoot, resolvedWalletPublicKeyPath);
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
                var duplicateEventIds = new HashSet<string>(StringComparer.Ordinal);
                var duplicateNonces = new HashSet<string>(StringComparer.Ordinal);
                foreach (var item in readEvents)
                {
                    var ledgerEvent = item.Event;
                    if (!duplicateEventIds.Add(ledgerEvent.EventId))
                    {
                        result.Failures.Add("Duplicate monetary ledger event ID: " + ledgerEvent.EventId);
                    }

                    if (!string.IsNullOrWhiteSpace(ledgerEvent.AntiReplayNonce)
                        && !duplicateNonces.Add(ledgerEvent.AntiReplayNonce))
                    {
                        result.Failures.Add("Duplicate monetary ledger anti-replay nonce: " + ledgerEvent.AntiReplayNonce);
                    }

                    ValidateEventEnvelope(resolvedWorkspaceRoot, ledgerEvent, item.Path, result.Failures);
                }

                var priorGlobalSequence = 0L;
                foreach (var item in readEvents
                    .OrderBy(item => item.Event.GlobalSequence)
                    .ThenBy(item => item.Event.CreatedUtc, StringComparer.Ordinal)
                    .ThenBy(item => item.Event.EventId, StringComparer.Ordinal))
                {
                    if (item.Event.GlobalSequence <= priorGlobalSequence)
                    {
                        result.Failures.Add("Monetary ledger global sequence is not strictly increasing at event " + item.Event.EventId + ".");
                    }

                    priorGlobalSequence = item.Event.GlobalSequence;
                }

                var balances = new Dictionary<string, PassportMonetaryBalance>(StringComparer.Ordinal);
                foreach (var accountGroup in readEvents
                    .OrderBy(item => item.Event.AccountId, StringComparer.Ordinal)
                    .ThenBy(item => item.Event.AccountSequence)
                    .ThenBy(item => item.Event.CreatedUtc, StringComparer.Ordinal)
                    .ThenBy(item => item.Event.EventId, StringComparer.Ordinal)
                    .GroupBy(item => item.Event.AccountId, StringComparer.Ordinal))
                {
                    var expectedSequence = 1L;
                    var priorHash = string.Empty;
                    var sequenceIds = new HashSet<long>();

                    foreach (var item in accountGroup)
                    {
                        var ledgerEvent = item.Event;
                        if (!sequenceIds.Add(ledgerEvent.AccountSequence))
                        {
                            result.Failures.Add("Duplicate account sequence " + ledgerEvent.AccountSequence + " for " + ledgerEvent.AccountId + ".");
                        }

                        if (ledgerEvent.AccountSequence != expectedSequence)
                        {
                            result.Failures.Add("Expected account sequence " + expectedSequence + " for " + ledgerEvent.AccountId + " but found " + ledgerEvent.AccountSequence + ".");
                        }

                        if (!string.Equals(ledgerEvent.PriorAccountEventHash, priorHash, StringComparison.OrdinalIgnoreCase))
                        {
                            result.Failures.Add("Invalid prior account event hash at sequence " + ledgerEvent.AccountSequence + " for " + ledgerEvent.AccountId + ".");
                        }

                        ApplyEventSemantics(balances, ledgerEvent, result.Failures);
                        priorHash = ledgerEvent.EventHashSha256;
                        expectedSequence++;
                    }
                }

                result.EventCount = readEvents.Length;
                result.Balances.AddRange(balances.Values
                    .OrderBy(balance => balance.AccountId, StringComparer.Ordinal)
                    .ThenBy(balance => balance.AssetCode, StringComparer.Ordinal));
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
                var eventHashes = readEvents.Select(item => item.Event.EventHashSha256).ToArray();
                var rootMaterial = string.Join(
                    "\n",
                    new[]
                    {
                        releaseLane.Lane,
                        releaseLane.LedgerNamespace,
                        releaseLane.PolicyVersion,
                        readEvents.Length.ToString()
                    }.Concat(eventHashes));
                var epochRoot = ComputeSha256(Encoding.UTF8.GetBytes(rootMaterial));
                var timestamp = DateTime.UtcNow.ToString("yyyyMMddTHHmmssZ");
                var createdUtc = DateTime.UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ");
                var rootsRoot = Path.Combine(resolvedWorkspaceRoot, "records", "passport", "monetary", "transparency-roots");
                Directory.CreateDirectory(rootsRoot);
                var recordPath = Path.Combine(rootsRoot, timestamp + "-" + releaseLane.Lane + "-" + epochRoot[..12] + ".json");
                var record = new Dictionary<string, object?>
                {
                    ["schema_version"] = 1,
                    ["record_type"] = "passport_monetary_transparency_root",
                    ["record_id"] = timestamp + "-" + epochRoot[..12],
                    ["created_utc"] = createdUtc,
                    ["release_lane"] = releaseLane.Lane,
                    ["ledger_namespace"] = releaseLane.LedgerNamespace,
                    ["policy_version"] = releaseLane.PolicyVersion,
                    ["event_count"] = readEvents.Length,
                    ["first_global_sequence"] = readEvents.Length == 0 ? 0 : readEvents.First().Event.GlobalSequence,
                    ["last_global_sequence"] = readEvents.Length == 0 ? 0 : readEvents.Last().Event.GlobalSequence,
                    ["event_hashes"] = eventHashes,
                    ["epoch_root_sha256"] = epochRoot,
                    ["summary"] = "Transparency root for replayable Passport ARCH/CC monetary ledger events."
                };

                File.WriteAllText(recordPath, JsonSerializer.Serialize(record, JsonOptions), Encoding.UTF8);

                return new PassportMonetaryTransparencyRootResult
                {
                    Succeeded = true,
                    Message = "Monetary ledger transparency root created.",
                    RecordPath = recordPath,
                    EpochRootSha256 = epochRoot,
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

                var accountEvents = ReadEvents(resolvedWorkspaceRoot)
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
                    eventManifestRows.Add(new Dictionary<string, object?>
                    {
                        ["event_id"] = item.Event.EventId,
                        ["event_type"] = item.Event.EventType,
                        ["asset_code"] = item.Event.AssetCode,
                        ["global_sequence"] = item.Event.GlobalSequence,
                        ["account_sequence"] = item.Event.AccountSequence,
                        ["event_hash_sha256"] = item.Event.EventHashSha256,
                        ["export_path"] = relativePath
                    });
                }

                var exportedTransparencyRootPath = Path.Combine(exportRoot, "transparency-root.json");
                CopyFile(transparencyRoot.RecordPath, exportedTransparencyRootPath);

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
                    ["transparency_root_sha256"] = transparencyRoot.EpochRootSha256,
                    ["transparency_root_export_path"] = "transparency-root.json",
                    ["verifier_replay_root"] = "records/passport/monetary/events",
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

        public static string ComputeEventHash(PassportMonetaryLedgerEvent ledgerEvent)
        {
            var originalHash = ledgerEvent.EventHashSha256;
            ledgerEvent.EventHashSha256 = string.Empty;

            try
            {
                var payload = JsonSerializer.Serialize(ledgerEvent, JsonOptions);
                return ComputeSha256(Encoding.UTF8.GetBytes(payload));
            }
            finally
            {
                ledgerEvent.EventHashSha256 = originalHash;
            }
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
        }

        private void ValidateEventSignature(string workspaceRoot, PassportMonetaryLedgerEvent ledgerEvent, List<string> failures)
        {
            if (releaseLane.ProductionLedger
                && !string.Equals(ledgerEvent.SignatureStatus, "wallet_signed", StringComparison.Ordinal))
            {
                failures.Add("Production monetary ledger event " + ledgerEvent.EventId + " is not wallet-signed.");
            }

            if (!string.Equals(ledgerEvent.SignatureStatus, "wallet_signed", StringComparison.Ordinal))
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

            switch (ledgerEvent.EventType)
            {
                case EventArchGenesisAllocation:
                    if (balance.AvailableBaseUnits > 0)
                    {
                        failures.Add("ARCH genesis allocation can appear only once for account " + ledgerEvent.AccountId + ".");
                    }

                    balance.AvailableBaseUnits += ledgerEvent.AmountBaseUnits;
                    break;

                case EventArchTransferIn:
                    balance.AvailableBaseUnits += ledgerEvent.AmountBaseUnits;
                    break;

                case EventArchTransferOut:
                    if (balance.AvailableBaseUnits < ledgerEvent.AmountBaseUnits)
                    {
                        failures.Add("ARCH transfer out exceeds available balance for account " + ledgerEvent.AccountId + ".");
                    }

                    balance.AvailableBaseUnits -= ledgerEvent.AmountBaseUnits;
                    break;

                default:
                    failures.Add("Unsupported ARCH event type " + ledgerEvent.EventType + ". ARCH can be allocated from genesis or transferred; it cannot be minted after genesis.");
                    break;
            }
        }

        private static void ApplyCrownCreditEvent(
            Dictionary<string, PassportMonetaryBalance> balances,
            PassportMonetaryLedgerEvent ledgerEvent,
            List<string> failures)
        {
            var balance = GetBalance(balances, ledgerEvent.AccountId, AssetCrownCredit);

            switch (ledgerEvent.EventType)
            {
                case EventCrownCreditIssue:
                    balance.AvailableBaseUnits += ledgerEvent.AmountBaseUnits;
                    break;

                case EventCrownCreditEscrow:
                    if (balance.AvailableBaseUnits < ledgerEvent.AmountBaseUnits)
                    {
                        failures.Add("CC escrow exceeds available balance for account " + ledgerEvent.AccountId + ".");
                    }

                    balance.AvailableBaseUnits -= ledgerEvent.AmountBaseUnits;
                    balance.EscrowedBaseUnits += ledgerEvent.AmountBaseUnits;
                    break;

                case EventCrownCreditBurn:
                    if (balance.EscrowedBaseUnits < ledgerEvent.AmountBaseUnits)
                    {
                        failures.Add("CC burn exceeds escrowed balance for account " + ledgerEvent.AccountId + ".");
                    }

                    balance.EscrowedBaseUnits -= ledgerEvent.AmountBaseUnits;
                    balance.BurnedBaseUnits += ledgerEvent.AmountBaseUnits;
                    break;

                case EventCrownCreditRefund:
                    if (balance.EscrowedBaseUnits < ledgerEvent.AmountBaseUnits)
                    {
                        failures.Add("CC refund exceeds escrowed balance for account " + ledgerEvent.AccountId + ".");
                    }

                    balance.EscrowedBaseUnits -= ledgerEvent.AmountBaseUnits;
                    balance.AvailableBaseUnits += ledgerEvent.AmountBaseUnits;
                    break;

                case EventCrownCreditRecredit:
                    balance.AvailableBaseUnits += ledgerEvent.AmountBaseUnits;
                    break;

                default:
                    failures.Add("Unsupported CC event type " + ledgerEvent.EventType + ". MVP CC events are issue, escrow, burn, refund, and re-credit only.");
                    break;
            }
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
            var normalized = NormalizeRequired(assetCode, "asset code").ToUpperInvariant();
            if (string.Equals(normalized, "CROWN_CREDIT", StringComparison.Ordinal)
                || string.Equals(normalized, "CROWN-CREDIT", StringComparison.Ordinal))
            {
                return AssetCrownCredit;
            }

            return normalized;
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
