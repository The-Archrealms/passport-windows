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
    public sealed class PassportRecoveryService
    {
        private static readonly JsonSerializerOptions JsonOptions = new JsonSerializerOptions
        {
            WriteIndented = true
        };

        private readonly PassportReleaseLane releaseLane;

        public PassportRecoveryService(PassportReleaseLane? releaseLane = null)
        {
            this.releaseLane = releaseLane ?? PassportEnvironment.GetReleaseLane();
        }

        public PassportRecoveryRecordResult CreateDeviceDeauthorization(
            string workspaceRoot,
            string identityId,
            string authorizingDeviceId,
            string authorizingDeviceKeyReferencePath,
            string targetDeviceId,
            string reasonCode)
        {
            try
            {
                var resolvedWorkspaceRoot = PassportEnvironment.ResolveWorkspaceRoot(workspaceRoot);
                var normalizedIdentityId = NormalizeRequired(identityId, "identity ID");
                var normalizedAuthorizingDeviceId = NormalizeRequired(authorizingDeviceId, "authorizing device ID");
                var normalizedTargetDeviceId = NormalizeRequired(targetDeviceId, "target device ID");
                var normalizedReasonCode = NormalizeReasonCode(reasonCode);
                var authorizingDevice = FindLatestDeviceRecord(resolvedWorkspaceRoot, normalizedIdentityId, normalizedAuthorizingDeviceId, "active");
                if (authorizingDevice == null)
                {
                    return Failed("The active authorizing device credential record could not be found.", "passport_device_deauthorization");
                }

                if (IsDeviceDeauthorized(resolvedWorkspaceRoot, normalizedIdentityId, normalizedAuthorizingDeviceId))
                {
                    return Failed("The authorizing device has already been deauthorized.", "passport_device_deauthorization");
                }

                var targetDevice = FindLatestDeviceRecord(resolvedWorkspaceRoot, normalizedIdentityId, normalizedTargetDeviceId, "active");
                if (targetDevice == null)
                {
                    return Failed("The target device credential record could not be found.", "passport_device_deauthorization");
                }

                var publicKeyPath = ResolvePublicKeyPath(resolvedWorkspaceRoot, authorizingDevice.Value.RootElement);
                if (string.IsNullOrWhiteSpace(publicKeyPath) || !File.Exists(publicKeyPath))
                {
                    return Failed("The authorizing device public key could not be resolved.", "passport_device_deauthorization");
                }

                var timestamp = DateTime.UtcNow.ToString("yyyyMMddTHHmmssZ");
                var createdUtc = DateTime.UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ");
                var root = Path.Combine(resolvedWorkspaceRoot, "records", "passport", "recovery", "device-deauthorizations");
                Directory.CreateDirectory(root);
                var recordPath = Path.Combine(root, timestamp + "-" + normalizedTargetDeviceId + ".json");
                var record = new Dictionary<string, object?>
                {
                    ["schema_version"] = 1,
                    ["record_type"] = "passport_device_deauthorization",
                    ["record_id"] = timestamp + "-" + normalizedTargetDeviceId,
                    ["created_utc"] = createdUtc,
                    ["release_lane"] = releaseLane.Lane,
                    ["ledger_namespace"] = releaseLane.LedgerNamespace,
                    ["policy_version"] = releaseLane.PolicyVersion,
                    ["archrealms_identity_id"] = normalizedIdentityId,
                    ["authorizing_device_id"] = normalizedAuthorizingDeviceId,
                    ["target_device_id"] = normalizedTargetDeviceId,
                    ["target_device_record_path"] = ToWorkspaceRelativePath(resolvedWorkspaceRoot, targetDevice.Value.RecordPath),
                    ["reason_code"] = normalizedReasonCode,
                    ["ai_approved"] = false,
                    ["summary"] = "Passport signed device deauthorization record. AI is not an approval authority."
                };

                return WriteSignedRecoveryRecord(
                    resolvedWorkspaceRoot,
                    recordPath,
                    record,
                    authorizingDeviceKeyReferencePath,
                    publicKeyPath,
                    "passport_device_deauthorization_signature",
                    "device_deauthorization_record_path",
                    "device_deauthorization_record_sha256",
                    normalizedIdentityId,
                    normalizedAuthorizingDeviceId);
            }
            catch (Exception ex)
            {
                return Failed("Device deauthorization failed: " + ex.Message, "passport_device_deauthorization");
            }
        }

        public PassportRecoveryRecordResult CreateAccountSecurityFreeze(
            string workspaceRoot,
            string identityId,
            string authorizingDeviceId,
            string authorizingDeviceKeyReferencePath,
            string reasonCode,
            bool freezeWalletOperations,
            bool freezePendingEscrow,
            bool revokeAiSessions,
            bool pauseStorageNodeOperations)
        {
            try
            {
                var resolvedWorkspaceRoot = PassportEnvironment.ResolveWorkspaceRoot(workspaceRoot);
                var normalizedIdentityId = NormalizeRequired(identityId, "identity ID");
                var normalizedAuthorizingDeviceId = NormalizeRequired(authorizingDeviceId, "authorizing device ID");
                var normalizedReasonCode = NormalizeReasonCode(reasonCode);
                var authorizingDevice = FindLatestDeviceRecord(resolvedWorkspaceRoot, normalizedIdentityId, normalizedAuthorizingDeviceId, "active");
                if (authorizingDevice == null)
                {
                    return Failed("The active authorizing device credential record could not be found.", "passport_account_security_freeze");
                }

                if (IsDeviceDeauthorized(resolvedWorkspaceRoot, normalizedIdentityId, normalizedAuthorizingDeviceId))
                {
                    return Failed("The authorizing device has already been deauthorized.", "passport_account_security_freeze");
                }

                var publicKeyPath = ResolvePublicKeyPath(resolvedWorkspaceRoot, authorizingDevice.Value.RootElement);
                if (string.IsNullOrWhiteSpace(publicKeyPath) || !File.Exists(publicKeyPath))
                {
                    return Failed("The authorizing device public key could not be resolved.", "passport_account_security_freeze");
                }

                var timestamp = DateTime.UtcNow.ToString("yyyyMMddTHHmmssZ");
                var createdUtc = DateTime.UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ");
                var root = Path.Combine(resolvedWorkspaceRoot, "records", "passport", "recovery", "security-freezes");
                Directory.CreateDirectory(root);
                var recordPath = Path.Combine(root, timestamp + "-" + normalizedIdentityId + ".json");
                var record = new Dictionary<string, object?>
                {
                    ["schema_version"] = 1,
                    ["record_type"] = "passport_account_security_freeze",
                    ["record_id"] = timestamp + "-" + normalizedIdentityId,
                    ["created_utc"] = createdUtc,
                    ["release_lane"] = releaseLane.Lane,
                    ["ledger_namespace"] = releaseLane.LedgerNamespace,
                    ["policy_version"] = releaseLane.PolicyVersion,
                    ["archrealms_identity_id"] = normalizedIdentityId,
                    ["authorizing_device_id"] = normalizedAuthorizingDeviceId,
                    ["reason_code"] = normalizedReasonCode,
                    ["freeze_wallet_operations"] = freezeWalletOperations,
                    ["freeze_pending_escrow"] = freezePendingEscrow,
                    ["revoke_ai_sessions"] = revokeAiSessions,
                    ["pause_storage_node_operations"] = pauseStorageNodeOperations,
                    ["ai_approved"] = false,
                    ["summary"] = "Passport signed security freeze request for recovery, escrow, AI session, and storage-node operations. AI is not an approval authority."
                };

                return WriteSignedRecoveryRecord(
                    resolvedWorkspaceRoot,
                    recordPath,
                    record,
                    authorizingDeviceKeyReferencePath,
                    publicKeyPath,
                    "passport_account_security_freeze_signature",
                    "security_freeze_record_path",
                    "security_freeze_record_sha256",
                    normalizedIdentityId,
                    normalizedAuthorizingDeviceId);
            }
            catch (Exception ex)
            {
                return Failed("Account security freeze failed: " + ex.Message, "passport_account_security_freeze");
            }
        }

        public bool IsDeviceDeauthorized(string workspaceRoot, string identityId, string deviceId)
        {
            try
            {
                var resolvedWorkspaceRoot = PassportEnvironment.ResolveWorkspaceRoot(workspaceRoot);
                var recordsRoot = Path.Combine(resolvedWorkspaceRoot, "records", "passport", "recovery", "device-deauthorizations");
                if (!Directory.Exists(recordsRoot))
                {
                    return false;
                }

                return Directory.GetFiles(recordsRoot, "*.json")
                    .Where(file => !file.EndsWith(".signature.json", StringComparison.OrdinalIgnoreCase))
                    .Select(file =>
                    {
                        using var document = JsonDocument.Parse(File.ReadAllText(file));
                        return document.RootElement.Clone();
                    })
                    .Any(root => Matches(root, "record_type", "passport_device_deauthorization")
                        && Matches(root, "release_lane", releaseLane.Lane)
                        && Matches(root, "ledger_namespace", releaseLane.LedgerNamespace)
                        && Matches(root, "archrealms_identity_id", identityId)
                        && Matches(root, "target_device_id", deviceId));
            }
            catch
            {
                return false;
            }
        }

        private PassportRecoveryRecordResult WriteSignedRecoveryRecord(
            string workspaceRoot,
            string recordPath,
            Dictionary<string, object?> record,
            string authorizingDeviceKeyReferencePath,
            string publicKeyPath,
            string signatureRecordType,
            string recordPathPropertyName,
            string recordHashPropertyName,
            string identityId,
            string authorizingDeviceId)
        {
            File.WriteAllText(recordPath, JsonSerializer.Serialize(record, JsonOptions), Encoding.UTF8);
            var recordBytes = File.ReadAllBytes(recordPath);
            var signatureBytes = PassportDeviceKeyStore.SignData(authorizingDeviceKeyReferencePath, recordBytes);
            var verified = VerifySignature(publicKeyPath, recordBytes, signatureBytes);
            var timestamp = DateTime.UtcNow.ToString("yyyyMMddTHHmmssZ");
            var createdUtc = DateTime.UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ");
            var signaturePath = Path.Combine(
                Path.GetDirectoryName(recordPath) ?? workspaceRoot,
                Path.GetFileNameWithoutExtension(recordPath) + ".signature.json");
            var signatureRecord = new Dictionary<string, object?>
            {
                ["schema_version"] = 1,
                ["record_type"] = signatureRecordType,
                ["record_id"] = timestamp + "-" + signatureRecordType,
                ["created_utc"] = createdUtc,
                ["release_lane"] = releaseLane.Lane,
                ["ledger_namespace"] = releaseLane.LedgerNamespace,
                ["archrealms_identity_id"] = identityId,
                ["authorizing_device_id"] = authorizingDeviceId,
                [recordPathPropertyName] = ToWorkspaceRelativePath(workspaceRoot, recordPath),
                [recordHashPropertyName] = ComputeSha256(recordBytes),
                ["signature_algorithm"] = "RSA_PKCS1_SHA256",
                ["signature_base64"] = Convert.ToBase64String(signatureBytes),
                ["device_public_key_path"] = ToWorkspaceRelativePath(workspaceRoot, publicKeyPath),
                ["verified_with_device_key"] = verified,
                ["summary"] = "Passport recovery record signature."
            };
            File.WriteAllText(signaturePath, JsonSerializer.Serialize(signatureRecord, JsonOptions), Encoding.UTF8);

            return new PassportRecoveryRecordResult
            {
                Succeeded = true,
                Message = "Recovery record created.",
                RecordType = ReadStringFromObject(record, "record_type"),
                RecordPath = recordPath,
                SignaturePath = signaturePath,
                VerifiedWithDeviceKey = verified
            };
        }

        private static (string RecordPath, JsonElement RootElement)? FindLatestDeviceRecord(
            string workspaceRoot,
            string identityId,
            string deviceId,
            string requiredStatus)
        {
            var deviceRoot = Path.Combine(workspaceRoot, "records", "registry", "device-credentials");
            if (!Directory.Exists(deviceRoot))
            {
                return null;
            }

            foreach (var file in Directory.GetFiles(deviceRoot, "*.json").OrderByDescending(Path.GetFileName))
            {
                using var document = JsonDocument.Parse(File.ReadAllText(file));
                var root = document.RootElement.Clone();
                if (Matches(root, "record_type", "device_credential_record")
                    && Matches(root, "status", requiredStatus)
                    && Matches(root, "archrealms_identity_id", identityId)
                    && Matches(root, "device_id", deviceId))
                {
                    return (file, root);
                }
            }

            return null;
        }

        private static string ResolvePublicKeyPath(string workspaceRoot, JsonElement deviceRecord)
        {
            if (!TryGetString(deviceRecord, "public_key_path", out var publicKeyRelative))
            {
                return string.Empty;
            }

            return Path.Combine(workspaceRoot, publicKeyRelative.Replace('/', Path.DirectorySeparatorChar));
        }

        private static bool VerifySignature(string publicKeyPath, byte[] data, byte[] signatureBytes)
        {
            using var rsa = RSA.Create();
            rsa.ImportSubjectPublicKeyInfo(File.ReadAllBytes(publicKeyPath), out _);
            return rsa.VerifyData(data, signatureBytes, HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1);
        }

        private static bool Matches(JsonElement root, string propertyName, string expected)
        {
            return TryGetString(root, propertyName, out var actual)
                && string.Equals(actual, expected, StringComparison.Ordinal);
        }

        private static bool TryGetString(JsonElement root, string propertyName, out string value)
        {
            if (root.TryGetProperty(propertyName, out var element))
            {
                value = element.GetString() ?? string.Empty;
                return true;
            }

            value = string.Empty;
            return false;
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
            return normalized switch
            {
                "wallet_loss" => normalized,
                "wallet_compromise" => normalized,
                "device_loss" => normalized,
                "device_compromise" => normalized,
                "identity_compromise" => normalized,
                "escrow_freeze" => normalized,
                "recovery" => normalized,
                "user_request" => normalized,
                _ => "user_request"
            };
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

        private static string ReadStringFromObject(Dictionary<string, object?> value, string key)
        {
            return value.TryGetValue(key, out var raw) ? raw?.ToString() ?? string.Empty : string.Empty;
        }

        private static PassportRecoveryRecordResult Failed(string message, string recordType)
        {
            return new PassportRecoveryRecordResult
            {
                Succeeded = false,
                Message = message,
                RecordType = recordType
            };
        }
    }
}
