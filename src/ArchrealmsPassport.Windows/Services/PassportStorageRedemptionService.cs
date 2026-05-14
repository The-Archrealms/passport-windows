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
    public sealed class PassportStorageRedemptionService
    {
        private static readonly JsonSerializerOptions JsonOptions = new JsonSerializerOptions
        {
            WriteIndented = true
        };

        private readonly PassportReleaseLane releaseLane;

        public PassportStorageRedemptionService(PassportReleaseLane? releaseLane = null)
        {
            this.releaseLane = releaseLane ?? PassportEnvironment.GetReleaseLane();
        }

        public PassportStorageRedemptionResult CreateQuote(
            string workspaceRoot,
            string accountId,
            string identityId,
            string walletKeyId,
            long storageGb,
            int serviceEpochCount,
            long ccPerGbEpochBaseUnits,
            DateTime expiresUtc,
            string serviceClass,
            string quoteSource)
        {
            try
            {
                var resolvedWorkspaceRoot = PassportEnvironment.ResolveWorkspaceRoot(workspaceRoot);
                if (storageGb <= 0 || serviceEpochCount <= 0 || ccPerGbEpochBaseUnits <= 0)
                {
                    return Failed("Storage quote requires positive storage, epoch count, and CC rate.");
                }

                if (expiresUtc.ToUniversalTime() <= DateTime.UtcNow)
                {
                    return Failed("Storage quote expiration must be in the future.");
                }

                var quoteId = DateTime.UtcNow.ToString("yyyyMMddTHHmmssZ") + "-storage-quote-" + Guid.NewGuid().ToString("N")[..10];
                var root = Path.Combine(resolvedWorkspaceRoot, "records", "passport", "monetary", "storage-redemptions", "quotes");
                Directory.CreateDirectory(root);
                var path = Path.Combine(root, quoteId + ".json");
                var total = checked(storageGb * serviceEpochCount * ccPerGbEpochBaseUnits);
                var record = new Dictionary<string, object?>
                {
                    ["schema_version"] = 1,
                    ["record_type"] = "passport_storage_redemption_quote",
                    ["record_id"] = quoteId,
                    ["quote_id"] = quoteId,
                    ["created_utc"] = DateTime.UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ"),
                    ["expires_utc"] = expiresUtc.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ"),
                    ["release_lane"] = releaseLane.Lane,
                    ["ledger_namespace"] = releaseLane.LedgerNamespace,
                    ["policy_version"] = releaseLane.PolicyVersion,
                    ["account_id"] = NormalizeRequired(accountId, "account ID"),
                    ["archrealms_identity_id"] = NormalizeRequired(identityId, "identity ID"),
                    ["wallet_key_id"] = NormalizeRequired(walletKeyId, "wallet key ID"),
                    ["service_class"] = NormalizeRequired(serviceClass, "service class"),
                    ["storage_gb"] = storageGb,
                    ["service_epoch_count"] = serviceEpochCount,
                    ["cc_per_gb_epoch_base_units"] = ccPerGbEpochBaseUnits,
                    ["total_cc_base_units"] = total,
                    ["quote_source"] = NormalizeRequired(quoteSource, "quote source"),
                    ["capacity_or_liquidity_limited"] = true,
                    ["execution_status"] = "quote_only_not_accepted",
                    ["summary"] = "CC storage redemption quote. CC is escrowed on acceptance and burned only as verified service epochs complete."
                };
                File.WriteAllText(path, JsonSerializer.Serialize(record, JsonOptions), Encoding.UTF8);
                return Success("Storage redemption quote created.", quoteId, path, string.Empty, string.Empty);
            }
            catch (Exception ex)
            {
                return Failed("Storage redemption quote failed: " + ex.Message);
            }
        }

        public PassportStorageRedemptionResult AcceptQuote(
            string workspaceRoot,
            string quotePath,
            string quoteSha256,
            string walletKeyReferencePath,
            string walletPublicKeyPath)
        {
            try
            {
                var resolvedWorkspaceRoot = PassportEnvironment.ResolveWorkspaceRoot(workspaceRoot);
                var quote = ReadAndValidateQuote(resolvedWorkspaceRoot, quotePath, quoteSha256);
                if (!quote.Succeeded)
                {
                    return quote;
                }

                using var document = JsonDocument.Parse(File.ReadAllText(quote.RecordPath));
                var root = document.RootElement;
                var redemptionId = DateTime.UtcNow.ToString("yyyyMMddTHHmmssZ") + "-storage-redemption-" + Guid.NewGuid().ToString("N")[..10];
                var evidence = new Dictionary<string, string>
                {
                    ["storage_quote_id"] = ReadString(root, "quote_id"),
                    ["storage_quote_path"] = quote.RecordPath,
                    ["storage_quote_sha256"] = quote.RecordSha256,
                    ["storage_redemption_id"] = redemptionId
                };
                var ledger = new PassportMonetaryLedgerService(releaseLane);
                var escrow = ledger.AppendEvent(
                    resolvedWorkspaceRoot,
                    ReadString(root, "account_id"),
                    ReadString(root, "archrealms_identity_id"),
                    ReadString(root, "wallet_key_id"),
                    PassportMonetaryLedgerService.EventCrownCreditEscrow,
                    PassportMonetaryLedgerService.AssetCrownCredit,
                    ReadInt64(root, "total_cc_base_units"),
                    evidence,
                    walletKeyReferencePath: walletKeyReferencePath,
                    walletPublicKeyPath: walletPublicKeyPath);
                if (!escrow.Succeeded)
                {
                    return Failed("Storage redemption escrow failed: " + escrow.Message);
                }

                var recordPath = WriteSignedRecord(
                    resolvedWorkspaceRoot,
                    "accepted",
                    redemptionId,
                    root,
                    quote,
                    escrow,
                    walletKeyReferencePath,
                    walletPublicKeyPath,
                    new Dictionary<string, object?>
                    {
                        ["accepted_utc"] = DateTime.UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ"),
                        ["escrow_cc_base_units"] = ReadInt64(root, "total_cc_base_units")
                    });
                return Success("Storage redemption accepted and escrowed.", redemptionId, recordPath, escrow.EventPath, escrow.EventHashSha256);
            }
            catch (Exception ex)
            {
                return Failed("Storage redemption acceptance failed: " + ex.Message);
            }
        }

        public PassportStorageRedemptionResult BurnVerifiedEpoch(
            string workspaceRoot,
            string acceptedRedemptionPath,
            long burnCcBaseUnits,
            long verifiedGbDays,
            string proofRecordPath,
            string proofRecordSha256,
            string walletKeyReferencePath,
            string walletPublicKeyPath)
        {
            try
            {
                var resolvedWorkspaceRoot = PassportEnvironment.ResolveWorkspaceRoot(workspaceRoot);
                if (burnCcBaseUnits <= 0 || verifiedGbDays <= 0)
                {
                    return Failed("Storage epoch burn requires positive CC burn and verified GB-days.");
                }

                var acceptedPath = ResolveWorkspaceRelativePath(resolvedWorkspaceRoot, acceptedRedemptionPath);
                if (!File.Exists(acceptedPath))
                {
                    return Failed("Accepted storage redemption record could not be found.");
                }

                using var document = JsonDocument.Parse(File.ReadAllText(acceptedPath));
                var accepted = document.RootElement;
                if (!Matches(accepted, "record_type", "passport_storage_redemption_accepted"))
                {
                    return Failed("Storage burn requires an accepted redemption record.");
                }

                var proofPath = ResolveWorkspaceRelativePath(resolvedWorkspaceRoot, proofRecordPath);
                if (!File.Exists(proofPath))
                {
                    return Failed("Storage proof record could not be found.");
                }

                var actualProofHash = ComputeSha256(File.ReadAllBytes(proofPath));
                if (!string.Equals(actualProofHash, proofRecordSha256, StringComparison.OrdinalIgnoreCase))
                {
                    return Failed("Storage proof hash does not match burn evidence.");
                }

                var burnedSoFar = SumRecords(resolvedWorkspaceRoot, ReadString(accepted, "redemption_id"), "passport_storage_redemption_epoch_burn", "burn_cc_base_units");
                var refundedSoFar = SumRecords(resolvedWorkspaceRoot, ReadString(accepted, "redemption_id"), "passport_storage_redemption_refund", "refund_cc_base_units");
                var escrowTotal = ReadInt64(accepted, "escrow_cc_base_units");
                if (burnedSoFar + refundedSoFar + burnCcBaseUnits > escrowTotal)
                {
                    return Failed("Storage burn exceeds remaining escrow.");
                }

                var burnId = DateTime.UtcNow.ToString("yyyyMMddTHHmmssZ") + "-storage-burn-" + Guid.NewGuid().ToString("N")[..10];
                var evidence = new Dictionary<string, string>
                {
                    ["storage_redemption_id"] = ReadString(accepted, "redemption_id"),
                    ["storage_accepted_redemption_path"] = acceptedPath,
                    ["storage_proof_record_path"] = proofPath,
                    ["storage_proof_record_sha256"] = actualProofHash,
                    ["storage_burn_id"] = burnId
                };
                var burn = new PassportMonetaryLedgerService(releaseLane).AppendEvent(
                    resolvedWorkspaceRoot,
                    ReadString(accepted, "account_id"),
                    ReadString(accepted, "archrealms_identity_id"),
                    ReadString(accepted, "wallet_key_id"),
                    PassportMonetaryLedgerService.EventCrownCreditBurn,
                    PassportMonetaryLedgerService.AssetCrownCredit,
                    burnCcBaseUnits,
                    evidence,
                    walletKeyReferencePath: walletKeyReferencePath,
                    walletPublicKeyPath: walletPublicKeyPath);
                if (!burn.Succeeded)
                {
                    return Failed("Storage burn ledger event failed: " + burn.Message);
                }

                var recordPath = WriteSignedRecord(
                    resolvedWorkspaceRoot,
                    "epoch-burn",
                    burnId,
                    accepted,
                    null,
                    burn,
                    walletKeyReferencePath,
                    walletPublicKeyPath,
                    new Dictionary<string, object?>
                    {
                        ["burn_cc_base_units"] = burnCcBaseUnits,
                        ["verified_gb_days"] = verifiedGbDays,
                        ["proof_record_path"] = ToWorkspaceRelativePath(resolvedWorkspaceRoot, proofPath),
                        ["proof_record_sha256"] = actualProofHash
                    });
                return Success("Storage epoch burn recorded.", burnId, recordPath, burn.EventPath, burn.EventHashSha256);
            }
            catch (Exception ex)
            {
                return Failed("Storage epoch burn failed: " + ex.Message);
            }
        }

        public PassportStorageRedemptionResult RefundRemaining(
            string workspaceRoot,
            string acceptedRedemptionPath,
            long refundCcBaseUnits,
            string reasonCode,
            string walletKeyReferencePath,
            string walletPublicKeyPath)
        {
            try
            {
                var resolvedWorkspaceRoot = PassportEnvironment.ResolveWorkspaceRoot(workspaceRoot);
                if (refundCcBaseUnits <= 0)
                {
                    return Failed("Storage refund requires a positive CC amount.");
                }

                var acceptedPath = ResolveWorkspaceRelativePath(resolvedWorkspaceRoot, acceptedRedemptionPath);
                if (!File.Exists(acceptedPath))
                {
                    return Failed("Accepted storage redemption record could not be found.");
                }

                using var document = JsonDocument.Parse(File.ReadAllText(acceptedPath));
                var accepted = document.RootElement;
                var redemptionId = ReadString(accepted, "redemption_id");
                var burnedSoFar = SumRecords(resolvedWorkspaceRoot, redemptionId, "passport_storage_redemption_epoch_burn", "burn_cc_base_units");
                var refundedSoFar = SumRecords(resolvedWorkspaceRoot, redemptionId, "passport_storage_redemption_refund", "refund_cc_base_units");
                var escrowTotal = ReadInt64(accepted, "escrow_cc_base_units");
                if (burnedSoFar + refundedSoFar + refundCcBaseUnits > escrowTotal)
                {
                    return Failed("Storage refund exceeds remaining escrow.");
                }

                var refundId = DateTime.UtcNow.ToString("yyyyMMddTHHmmssZ") + "-storage-refund-" + Guid.NewGuid().ToString("N")[..10];
                var evidence = new Dictionary<string, string>
                {
                    ["storage_redemption_id"] = redemptionId,
                    ["storage_accepted_redemption_path"] = acceptedPath,
                    ["storage_refund_id"] = refundId,
                    ["storage_refund_reason_code"] = NormalizeReasonCode(reasonCode)
                };
                var refund = new PassportMonetaryLedgerService(releaseLane).AppendEvent(
                    resolvedWorkspaceRoot,
                    ReadString(accepted, "account_id"),
                    ReadString(accepted, "archrealms_identity_id"),
                    ReadString(accepted, "wallet_key_id"),
                    PassportMonetaryLedgerService.EventCrownCreditRefund,
                    PassportMonetaryLedgerService.AssetCrownCredit,
                    refundCcBaseUnits,
                    evidence,
                    walletKeyReferencePath: walletKeyReferencePath,
                    walletPublicKeyPath: walletPublicKeyPath);
                if (!refund.Succeeded)
                {
                    return Failed("Storage refund ledger event failed: " + refund.Message);
                }

                var recordPath = WriteSignedRecord(
                    resolvedWorkspaceRoot,
                    "refund",
                    refundId,
                    accepted,
                    null,
                    refund,
                    walletKeyReferencePath,
                    walletPublicKeyPath,
                    new Dictionary<string, object?>
                    {
                        ["refund_cc_base_units"] = refundCcBaseUnits,
                        ["reason_code"] = NormalizeReasonCode(reasonCode)
                    });
                return Success("Storage redemption refund recorded.", refundId, recordPath, refund.EventPath, refund.EventHashSha256);
            }
            catch (Exception ex)
            {
                return Failed("Storage redemption refund failed: " + ex.Message);
            }
        }

        private string WriteSignedRecord(
            string workspaceRoot,
            string kind,
            string recordId,
            JsonElement sourceRecord,
            PassportStorageRedemptionResult? quote,
            PassportMonetaryLedgerAppendResult ledgerEvent,
            string walletKeyReferencePath,
            string walletPublicKeyPath,
            Dictionary<string, object?> extra)
        {
            var recordType = kind switch
            {
                "accepted" => "passport_storage_redemption_accepted",
                "epoch-burn" => "passport_storage_redemption_epoch_burn",
                "refund" => "passport_storage_redemption_refund",
                _ => "passport_storage_redemption_record"
            };
            var root = Path.Combine(workspaceRoot, "records", "passport", "monetary", "storage-redemptions", kind);
            Directory.CreateDirectory(root);
            var path = Path.Combine(root, recordId + ".json");
            var record = new Dictionary<string, object?>
            {
                ["schema_version"] = 1,
                ["record_type"] = recordType,
                ["record_id"] = recordId,
                ["redemption_id"] = kind == "accepted" ? recordId : ReadString(sourceRecord, "redemption_id"),
                ["created_utc"] = DateTime.UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ"),
                ["release_lane"] = releaseLane.Lane,
                ["ledger_namespace"] = releaseLane.LedgerNamespace,
                ["policy_version"] = releaseLane.PolicyVersion,
                ["account_id"] = ReadString(sourceRecord, "account_id"),
                ["archrealms_identity_id"] = ReadString(sourceRecord, "archrealms_identity_id"),
                ["wallet_key_id"] = ReadString(sourceRecord, "wallet_key_id"),
                ["quote_id"] = kind == "accepted" ? ReadString(sourceRecord, "quote_id") : ReadString(sourceRecord, "quote_id"),
                ["quote_path"] = kind == "accepted" && quote != null ? ToWorkspaceRelativePath(workspaceRoot, quote.RecordPath) : ReadString(sourceRecord, "quote_path"),
                ["quote_sha256"] = kind == "accepted" && quote != null ? quote.RecordSha256 : ReadString(sourceRecord, "quote_sha256"),
                ["ledger_event_id"] = ledgerEvent.EventId,
                ["ledger_event_path"] = ToWorkspaceRelativePath(workspaceRoot, ledgerEvent.EventPath),
                ["ledger_event_hash_sha256"] = ledgerEvent.EventHashSha256,
                ["burn_timing"] = "escrow_on_acceptance_burn_per_verified_epoch",
                ["summary"] = "Storage redemption record linked to CC escrow, proof-backed epoch burn, refund, or re-credit behavior."
            };
            foreach (var item in extra)
            {
                record[item.Key] = item.Value;
            }

            var unsignedPayload = JsonSerializer.Serialize(record, JsonOptions);
            var signature = new PassportWalletKeyService(releaseLane).SignWalletPayload(
                walletKeyReferencePath,
                walletPublicKeyPath,
                Encoding.UTF8.GetBytes(unsignedPayload));
            if (!signature.Succeeded)
            {
                throw new InvalidOperationException(signature.Message);
            }

            record["wallet_signature"] = new Dictionary<string, object?>
            {
                ["signature_algorithm"] = "RSA_PKCS1_SHA256",
                ["signature_base64"] = signature.SignatureBase64,
                ["signed_payload_sha256"] = signature.PayloadSha256,
                ["wallet_public_key_path"] = ToWorkspaceRelativePath(workspaceRoot, walletPublicKeyPath),
                ["verified_with_wallet_key"] = signature.VerifiedWithWalletKey
            };
            File.WriteAllText(path, JsonSerializer.Serialize(record, JsonOptions), Encoding.UTF8);
            return path;
        }

        private PassportStorageRedemptionResult ReadAndValidateQuote(string workspaceRoot, string quotePath, string expectedSha256)
        {
            var path = ResolveWorkspaceRelativePath(workspaceRoot, quotePath);
            if (!File.Exists(path))
            {
                return Failed("Storage redemption quote could not be found.");
            }

            var hash = ComputeSha256(File.ReadAllBytes(path));
            if (!string.IsNullOrWhiteSpace(expectedSha256) && !string.Equals(hash, expectedSha256, StringComparison.OrdinalIgnoreCase))
            {
                return Failed("Storage redemption quote hash does not match evidence.");
            }

            using var document = JsonDocument.Parse(File.ReadAllText(path));
            var root = document.RootElement;
            if (!Matches(root, "record_type", "passport_storage_redemption_quote"))
            {
                return Failed("Storage redemption evidence is not a quote record.");
            }

            if (!Matches(root, "release_lane", releaseLane.Lane) || !Matches(root, "ledger_namespace", releaseLane.LedgerNamespace))
            {
                return Failed("Storage redemption quote belongs to another release lane or ledger namespace.");
            }

            if (!DateTime.TryParse(ReadString(root, "expires_utc"), out var expiresUtc) || expiresUtc.ToUniversalTime() <= DateTime.UtcNow)
            {
                return Failed("Storage redemption quote is expired.");
            }

            return Success("Storage quote is valid.", ReadString(root, "quote_id"), path, string.Empty, string.Empty, hash);
        }

        private static long SumRecords(string workspaceRoot, string redemptionId, string recordType, string amountProperty)
        {
            var root = Path.Combine(workspaceRoot, "records", "passport", "monetary", "storage-redemptions");
            if (!Directory.Exists(root))
            {
                return 0;
            }

            return Directory.GetFiles(root, "*.json", SearchOption.AllDirectories)
                .Select(path =>
                {
                    using var document = JsonDocument.Parse(File.ReadAllText(path));
                    var element = document.RootElement.Clone();
                    return element;
                })
                .Where(record => Matches(record, "record_type", recordType) && Matches(record, "redemption_id", redemptionId))
                .Sum(record => ReadInt64(record, amountProperty));
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

        private static string NormalizeReasonCode(string reasonCode)
        {
            var normalized = NormalizeRequired(reasonCode, "reason code").Trim().ToLowerInvariant().Replace(" ", "_").Replace("-", "_");
            return normalized.Length > 64 ? normalized[..64] : normalized;
        }

        private static bool Matches(JsonElement root, string propertyName, string expected)
        {
            return root.TryGetProperty(propertyName, out var property)
                && property.ValueKind == JsonValueKind.String
                && string.Equals(property.GetString() ?? string.Empty, expected, StringComparison.Ordinal);
        }

        private static string ReadString(JsonElement root, string propertyName)
        {
            return root.TryGetProperty(propertyName, out var property) && property.ValueKind == JsonValueKind.String
                ? property.GetString() ?? string.Empty
                : string.Empty;
        }

        private static long ReadInt64(JsonElement root, string propertyName)
        {
            return root.TryGetProperty(propertyName, out var property) && property.TryGetInt64(out var value) ? value : 0;
        }

        private static string ResolveWorkspaceRelativePath(string workspaceRoot, string path)
        {
            var normalized = path.Replace('/', Path.DirectorySeparatorChar);
            return Path.IsPathRooted(normalized)
                ? Path.GetFullPath(normalized)
                : Path.GetFullPath(Path.Combine(workspaceRoot, normalized));
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

        private static string ComputeSha256(byte[] value)
        {
            return Convert.ToHexString(SHA256.HashData(value)).ToLowerInvariant();
        }

        private static PassportStorageRedemptionResult Success(
            string message,
            string recordId,
            string recordPath,
            string ledgerEventPath,
            string ledgerEventHash,
            string recordHash = "")
        {
            return new PassportStorageRedemptionResult
            {
                Succeeded = true,
                Message = message,
                RecordId = recordId,
                RecordPath = recordPath,
                RecordSha256 = string.IsNullOrWhiteSpace(recordHash) && File.Exists(recordPath) ? ComputeSha256(File.ReadAllBytes(recordPath)) : recordHash,
                LedgerEventPath = ledgerEventPath,
                LedgerEventHashSha256 = ledgerEventHash
            };
        }

        private static PassportStorageRedemptionResult Failed(string message)
        {
            return new PassportStorageRedemptionResult
            {
                Succeeded = false,
                Message = message
            };
        }
    }
}
