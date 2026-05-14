using System;
using System.Collections.Generic;
using System.IO;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using ArchrealmsPassport.Windows.Models;

namespace ArchrealmsPassport.Windows.Services
{
    public sealed class PassportLedgerCorrectionService
    {
        private static readonly JsonSerializerOptions JsonOptions = new JsonSerializerOptions
        {
            WriteIndented = true
        };

        private readonly PassportReleaseLane releaseLane;

        public PassportLedgerCorrectionService(PassportReleaseLane? releaseLane = null)
        {
            this.releaseLane = releaseLane ?? PassportEnvironment.GetReleaseLane();
        }

        public PassportLedgerCorrectionResult ExecuteCorrection(
            string workspaceRoot,
            string accountId,
            string identityId,
            string walletKeyId,
            string assetCode,
            long amountBaseUnits,
            string direction,
            string reasonCode,
            string targetEventId,
            string targetEventHashSha256,
            IDictionary<string, string> adminAuthorityEvidence,
            string walletKeyReferencePath,
            string walletPublicKeyPath)
        {
            try
            {
                var resolvedWorkspaceRoot = PassportEnvironment.ResolveWorkspaceRoot(workspaceRoot);
                var normalizedAsset = NormalizeAsset(assetCode);
                var normalizedDirection = NormalizeDirection(direction);
                if (amountBaseUnits <= 0)
                {
                    return Failed("Correction amount must be greater than zero.");
                }

                var normalizedTargetHash = NormalizeRequired(targetEventHashSha256, "target event hash").ToLowerInvariant();
                var intentHash = ComputeCorrectionIntentHash(
                    releaseLane,
                    accountId,
                    identityId,
                    walletKeyId,
                    normalizedAsset,
                    amountBaseUnits,
                    normalizedDirection,
                    reasonCode,
                    targetEventId,
                    normalizedTargetHash);
                var authority = new PassportAdminAuthorityService(releaseLane).ValidateDualControlActionEvidence(
                    resolvedWorkspaceRoot,
                    adminAuthorityEvidence,
                    "ledger_correction",
                    normalizedTargetHash,
                    intentHash);
                if (!authority.Succeeded)
                {
                    return Failed(authority.Message);
                }

                var correctionId = DateTime.UtcNow.ToString("yyyyMMddTHHmmssZ") + "-ledger-correction-" + Guid.NewGuid().ToString("N")[..10];
                var evidence = new Dictionary<string, string>(adminAuthorityEvidence, StringComparer.Ordinal)
                {
                    ["ledger_correction_id"] = correctionId,
                    ["ledger_correction_direction"] = normalizedDirection,
                    ["ledger_correction_reason_code"] = NormalizeReasonCode(reasonCode),
                    ["ledger_correction_target_event_id"] = NormalizeRequired(targetEventId, "target event ID"),
                    ["ledger_correction_target_event_hash_sha256"] = normalizedTargetHash,
                    ["ledger_correction_intent_hash_sha256"] = intentHash
                };
                var ledger = new PassportMonetaryLedgerService(releaseLane);
                var append = ledger.AppendEvent(
                    resolvedWorkspaceRoot,
                    accountId,
                    identityId,
                    walletKeyId,
                    GetCorrectionEventType(normalizedAsset, normalizedDirection),
                    normalizedAsset,
                    amountBaseUnits,
                    evidence,
                    walletKeyReferencePath: walletKeyReferencePath,
                    walletPublicKeyPath: walletPublicKeyPath);
                if (!append.Succeeded)
                {
                    return Failed("Correction ledger event append failed: " + append.Message);
                }

                var correctionRecordPath = WriteCorrectionRecord(
                    resolvedWorkspaceRoot,
                    correctionId,
                    accountId,
                    identityId,
                    walletKeyId,
                    normalizedAsset,
                    amountBaseUnits,
                    normalizedDirection,
                    reasonCode,
                    targetEventId,
                    normalizedTargetHash,
                    intentHash,
                    authority,
                    append,
                    walletKeyReferencePath,
                    walletPublicKeyPath);

                return new PassportLedgerCorrectionResult
                {
                    Succeeded = true,
                    Message = "Ledger correction executed as a new balancing event.",
                    CorrectionId = correctionId,
                    CorrectionRecordPath = correctionRecordPath,
                    LedgerEventPath = append.EventPath,
                    LedgerEventHashSha256 = append.EventHashSha256
                };
            }
            catch (Exception ex)
            {
                return Failed("Ledger correction failed: " + ex.Message);
            }
        }

        public static string ComputeCorrectionIntentHash(
            PassportReleaseLane releaseLane,
            string accountId,
            string identityId,
            string walletKeyId,
            string assetCode,
            long amountBaseUnits,
            string direction,
            string reasonCode,
            string targetEventId,
            string targetEventHashSha256)
        {
            var intent = new SortedDictionary<string, object?>(StringComparer.Ordinal)
            {
                ["release_lane"] = releaseLane.Lane,
                ["ledger_namespace"] = releaseLane.LedgerNamespace,
                ["action_type"] = "ledger_correction",
                ["account_id"] = (accountId ?? string.Empty).Trim(),
                ["archrealms_identity_id"] = (identityId ?? string.Empty).Trim(),
                ["wallet_key_id"] = (walletKeyId ?? string.Empty).Trim(),
                ["asset_code"] = NormalizeAsset(assetCode),
                ["amount_base_units"] = amountBaseUnits,
                ["direction"] = NormalizeDirection(direction),
                ["reason_code"] = NormalizeReasonCode(reasonCode),
                ["target_event_id"] = (targetEventId ?? string.Empty).Trim(),
                ["target_event_hash_sha256"] = (targetEventHashSha256 ?? string.Empty).Trim().ToLowerInvariant()
            };
            return ComputeSha256(Encoding.UTF8.GetBytes(JsonSerializer.Serialize(intent, JsonOptions)));
        }

        private string WriteCorrectionRecord(
            string workspaceRoot,
            string correctionId,
            string accountId,
            string identityId,
            string walletKeyId,
            string assetCode,
            long amountBaseUnits,
            string direction,
            string reasonCode,
            string targetEventId,
            string targetEventHashSha256,
            string intentHash,
            PassportAdminAuthorityResult authority,
            PassportMonetaryLedgerAppendResult append,
            string walletKeyReferencePath,
            string walletPublicKeyPath)
        {
            var root = Path.Combine(workspaceRoot, "records", "passport", "monetary", "ledger-corrections");
            Directory.CreateDirectory(root);
            var path = Path.Combine(root, correctionId + ".json");
            var record = new Dictionary<string, object?>
            {
                ["schema_version"] = 1,
                ["record_type"] = "passport_monetary_ledger_correction",
                ["record_id"] = correctionId,
                ["correction_id"] = correctionId,
                ["created_utc"] = DateTime.UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ"),
                ["release_lane"] = releaseLane.Lane,
                ["ledger_namespace"] = releaseLane.LedgerNamespace,
                ["policy_version"] = releaseLane.PolicyVersion,
                ["account_id"] = accountId,
                ["archrealms_identity_id"] = identityId,
                ["wallet_key_id"] = walletKeyId,
                ["asset_code"] = assetCode,
                ["amount_base_units"] = amountBaseUnits,
                ["direction"] = direction,
                ["reason_code"] = NormalizeReasonCode(reasonCode),
                ["target_event_id"] = targetEventId,
                ["target_event_hash_sha256"] = targetEventHashSha256,
                ["correction_intent_hash_sha256"] = intentHash,
                ["admin_authority_record_path"] = ToWorkspaceRelativePath(workspaceRoot, authority.RecordPath),
                ["admin_authority_requester_signature_path"] = ToWorkspaceRelativePath(workspaceRoot, authority.RequesterSignaturePath),
                ["admin_authority_approver_signature_path"] = ToWorkspaceRelativePath(workspaceRoot, authority.ApproverSignaturePath),
                ["ledger_event_id"] = append.EventId,
                ["ledger_event_path"] = ToWorkspaceRelativePath(workspaceRoot, append.EventPath),
                ["ledger_event_hash_sha256"] = append.EventHashSha256,
                ["correction_is_new_event_only"] = true,
                ["summary"] = "Dual-control ledger correction executed as a new balancing event. No prior ledger event was deleted, mutated, silently overwritten, or backdated."
            };
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

        private static string GetCorrectionEventType(string assetCode, string direction)
        {
            if (assetCode == PassportMonetaryLedgerService.AssetArch)
            {
                return direction == "credit"
                    ? PassportMonetaryLedgerService.EventArchTransferIn
                    : PassportMonetaryLedgerService.EventArchTransferOut;
            }

            return direction == "credit"
                ? PassportMonetaryLedgerService.EventCrownCreditTransferIn
                : PassportMonetaryLedgerService.EventCrownCreditTransferOut;
        }

        private static string NormalizeAsset(string assetCode)
        {
            var normalized = NormalizeRequired(assetCode, "asset code").ToUpperInvariant();
            if (normalized == "CROWN_CREDIT" || normalized == "CROWN-CREDIT")
            {
                return PassportMonetaryLedgerService.AssetCrownCredit;
            }

            if (normalized != PassportMonetaryLedgerService.AssetArch && normalized != PassportMonetaryLedgerService.AssetCrownCredit)
            {
                throw new InvalidOperationException("Corrections are limited to ARCH and CC.");
            }

            return normalized;
        }

        private static string NormalizeDirection(string direction)
        {
            var normalized = NormalizeRequired(direction, "direction").ToLowerInvariant();
            if (normalized != "credit" && normalized != "debit")
            {
                throw new InvalidOperationException("Correction direction must be credit or debit.");
            }

            return normalized;
        }

        private static string NormalizeReasonCode(string reasonCode)
        {
            var normalized = NormalizeRequired(reasonCode, "reason code").Trim().ToLowerInvariant().Replace(" ", "_").Replace("-", "_");
            return normalized.Length > 64 ? normalized[..64] : normalized;
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

        private static PassportLedgerCorrectionResult Failed(string message)
        {
            return new PassportLedgerCorrectionResult
            {
                Succeeded = false,
                Message = message
            };
        }
    }
}
