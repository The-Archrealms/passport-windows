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
    public sealed class PassportAdminAuthorityService
    {
        private static readonly JsonSerializerOptions JsonOptions = new JsonSerializerOptions
        {
            WriteIndented = true
        };

        private readonly PassportReleaseLane releaseLane;

        public PassportAdminAuthorityService(PassportReleaseLane? releaseLane = null)
        {
            this.releaseLane = releaseLane ?? PassportEnvironment.GetReleaseLane();
        }

        public PassportAdminAuthorityResult CreateDualControlAction(
            string workspaceRoot,
            string authorityIdentityId,
            string requesterDeviceId,
            string requesterDeviceKeyReferencePath,
            string approverDeviceId,
            string approverDeviceKeyReferencePath,
            string actionType,
            string authorityScope,
            string reasonCode,
            string targetRecordId,
            string targetRecordSha256,
            string requestedPayloadSha256)
        {
            try
            {
                var resolvedWorkspaceRoot = PassportEnvironment.ResolveWorkspaceRoot(workspaceRoot);
                var normalizedIdentityId = NormalizeRequired(authorityIdentityId, "authority identity ID");
                var normalizedRequesterDeviceId = NormalizeRequired(requesterDeviceId, "requester device ID");
                var normalizedApproverDeviceId = NormalizeRequired(approverDeviceId, "approver device ID");
                if (string.Equals(normalizedRequesterDeviceId, normalizedApproverDeviceId, StringComparison.Ordinal))
                {
                    return Failed("Dual-control admin actions require two distinct authorizing devices.");
                }

                var normalizedActionType = NormalizeActionType(actionType);
                var normalizedReasonCode = NormalizeReasonCode(reasonCode);
                var requesterDevice = FindLatestDeviceRecord(resolvedWorkspaceRoot, normalizedIdentityId, normalizedRequesterDeviceId, "active");
                var approverDevice = FindLatestDeviceRecord(resolvedWorkspaceRoot, normalizedIdentityId, normalizedApproverDeviceId, "active");
                if (requesterDevice == null)
                {
                    return Failed("The requester device credential record could not be found.");
                }

                if (approverDevice == null)
                {
                    return Failed("The approver device credential record could not be found.");
                }

                var recovery = new PassportRecoveryService(releaseLane);
                if (recovery.IsDeviceDeauthorized(resolvedWorkspaceRoot, normalizedIdentityId, normalizedRequesterDeviceId)
                    || recovery.IsDeviceDeauthorized(resolvedWorkspaceRoot, normalizedIdentityId, normalizedApproverDeviceId))
                {
                    return Failed("Dual-control admin actions cannot be authorized by deauthorized devices.");
                }

                var requesterPublicKeyPath = ResolvePublicKeyPath(resolvedWorkspaceRoot, requesterDevice.Value.RootElement);
                var approverPublicKeyPath = ResolvePublicKeyPath(resolvedWorkspaceRoot, approverDevice.Value.RootElement);
                if (string.IsNullOrWhiteSpace(requesterPublicKeyPath) || !File.Exists(requesterPublicKeyPath))
                {
                    return Failed("The requester public key could not be resolved.");
                }

                if (string.IsNullOrWhiteSpace(approverPublicKeyPath) || !File.Exists(approverPublicKeyPath))
                {
                    return Failed("The approver public key could not be resolved.");
                }

                var timestamp = DateTime.UtcNow.ToString("yyyyMMddTHHmmssZ");
                var createdUtc = DateTime.UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ");
                var root = Path.Combine(resolvedWorkspaceRoot, "records", "passport", "admin-authority", normalizedActionType);
                Directory.CreateDirectory(root);
                var recordPath = Path.Combine(root, timestamp + "-" + normalizedActionType + ".json");
                var record = new Dictionary<string, object?>
                {
                    ["schema_version"] = 1,
                    ["record_type"] = "passport_admin_dual_control_action",
                    ["record_id"] = timestamp + "-" + normalizedActionType,
                    ["created_utc"] = createdUtc,
                    ["release_lane"] = releaseLane.Lane,
                    ["ledger_namespace"] = releaseLane.LedgerNamespace,
                    ["policy_version"] = releaseLane.PolicyVersion,
                    ["authority_identity_id"] = normalizedIdentityId,
                    ["action_type"] = normalizedActionType,
                    ["authority_scope"] = NormalizeRequired(authorityScope, "authority scope"),
                    ["reason_code"] = normalizedReasonCode,
                    ["target_record_id"] = (targetRecordId ?? string.Empty).Trim(),
                    ["target_record_sha256"] = (targetRecordSha256 ?? string.Empty).Trim().ToLowerInvariant(),
                    ["requested_payload_sha256"] = (requestedPayloadSha256 ?? string.Empty).Trim().ToLowerInvariant(),
                    ["requester_device_id"] = normalizedRequesterDeviceId,
                    ["approver_device_id"] = normalizedApproverDeviceId,
                    ["required_approval_count"] = 2,
                    ["approval_count"] = 2,
                    ["ai_approved"] = false,
                    ["summary"] = "Dual-control Passport admin authority record. AI is not an approval authority."
                };
                File.WriteAllText(recordPath, JsonSerializer.Serialize(record, JsonOptions), Encoding.UTF8);

                var recordBytes = File.ReadAllBytes(recordPath);
                var requesterSignature = WriteSignature(
                    root,
                    timestamp + "-" + normalizedActionType + ".requester-signature.json",
                    "passport_admin_dual_control_requester_signature",
                    resolvedWorkspaceRoot,
                    recordPath,
                    recordBytes,
                    normalizedIdentityId,
                    normalizedRequesterDeviceId,
                    requesterDeviceKeyReferencePath,
                    requesterPublicKeyPath);
                var approverSignature = WriteSignature(
                    root,
                    timestamp + "-" + normalizedActionType + ".approver-signature.json",
                    "passport_admin_dual_control_approver_signature",
                    resolvedWorkspaceRoot,
                    recordPath,
                    recordBytes,
                    normalizedIdentityId,
                    normalizedApproverDeviceId,
                    approverDeviceKeyReferencePath,
                    approverPublicKeyPath);

                return new PassportAdminAuthorityResult
                {
                    Succeeded = requesterSignature.Verified && approverSignature.Verified,
                    Message = requesterSignature.Verified && approverSignature.Verified
                        ? "Dual-control admin authority record created."
                        : "Dual-control admin authority signature verification failed.",
                    RecordPath = recordPath,
                    RequesterSignaturePath = requesterSignature.Path,
                    ApproverSignaturePath = approverSignature.Path,
                    RequesterSignatureVerified = requesterSignature.Verified,
                    ApproverSignatureVerified = approverSignature.Verified
                };
            }
            catch (Exception ex)
            {
                return Failed("Dual-control admin authority failed: " + ex.Message);
            }
        }

        private static (string Path, bool Verified) WriteSignature(
            string outputRoot,
            string fileName,
            string recordType,
            string workspaceRoot,
            string actionRecordPath,
            byte[] actionRecordBytes,
            string identityId,
            string deviceId,
            string deviceKeyReferencePath,
            string devicePublicKeyPath)
        {
            var timestamp = DateTime.UtcNow.ToString("yyyyMMddTHHmmssZ");
            var createdUtc = DateTime.UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ");
            var signatureBytes = PassportDeviceKeyStore.SignData(deviceKeyReferencePath, actionRecordBytes);
            var verified = VerifySignature(devicePublicKeyPath, actionRecordBytes, signatureBytes);
            var signaturePath = Path.Combine(outputRoot, fileName);
            var signatureRecord = new Dictionary<string, object?>
            {
                ["schema_version"] = 1,
                ["record_type"] = recordType,
                ["record_id"] = timestamp + "-" + recordType,
                ["created_utc"] = createdUtc,
                ["archrealms_identity_id"] = identityId,
                ["device_id"] = deviceId,
                ["admin_action_record_path"] = ToWorkspaceRelativePath(workspaceRoot, actionRecordPath),
                ["admin_action_record_sha256"] = ComputeSha256(actionRecordBytes),
                ["signature_algorithm"] = "RSA_PKCS1_SHA256",
                ["signature_base64"] = Convert.ToBase64String(signatureBytes),
                ["device_public_key_path"] = ToWorkspaceRelativePath(workspaceRoot, devicePublicKeyPath),
                ["verified_with_device_key"] = verified,
                ["summary"] = "Signature for a dual-control Passport admin authority record."
            };
            File.WriteAllText(signaturePath, JsonSerializer.Serialize(signatureRecord, JsonOptions), Encoding.UTF8);
            return (signaturePath, verified);
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

        private static string NormalizeActionType(string actionType)
        {
            var normalized = NormalizeRequired(actionType, "action type").Trim().ToLowerInvariant().Replace(" ", "_").Replace("-", "_");
            return normalized switch
            {
                "cc_issue" => normalized,
                "ledger_correction" => normalized,
                "wallet_revocation" => normalized,
                "device_revocation" => normalized,
                "recovery_override" => normalized,
                "escrow_release" => normalized,
                "burn_override" => normalized,
                "telemetry_access" => normalized,
                _ => throw new InvalidOperationException("Unsupported admin action type: " + actionType)
            };
        }

        private static string NormalizeReasonCode(string reasonCode)
        {
            var normalized = NormalizeRequired(reasonCode, "reason code").Trim().ToLowerInvariant().Replace(" ", "_").Replace("-", "_");
            return normalized.Length > 64 ? normalized[..64] : normalized;
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

        private static PassportAdminAuthorityResult Failed(string message)
        {
            return new PassportAdminAuthorityResult
            {
                Succeeded = false,
                Message = message
            };
        }
    }
}
