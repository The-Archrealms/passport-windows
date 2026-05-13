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
    public sealed class PassportWalletKeyService
    {
        private static readonly JsonSerializerOptions JsonOptions = new JsonSerializerOptions
        {
            WriteIndented = true
        };

        private readonly PassportReleaseLane releaseLane;

        public PassportWalletKeyService(PassportReleaseLane? releaseLane = null)
        {
            this.releaseLane = releaseLane ?? PassportEnvironment.GetReleaseLane();
        }

        public PassportWalletKeyBindingResult CreateAndBindWalletKey(
            string workspaceRoot,
            string identityId,
            string deviceId,
            string deviceKeyReferencePath)
        {
            try
            {
                var resolvedWorkspaceRoot = PassportEnvironment.ResolveWorkspaceRoot(workspaceRoot);
                var normalizedIdentityId = NormalizeRequired(identityId, "identity ID");
                var normalizedDeviceId = NormalizeRequired(deviceId, "device ID");
                var normalizedDeviceKeyReferencePath = NormalizeRequired(deviceKeyReferencePath, "device key reference path");
                var deviceRecord = FindLatestDeviceRecord(resolvedWorkspaceRoot, normalizedIdentityId, normalizedDeviceId, "active");
                if (deviceRecord == null)
                {
                    return FailedBinding("The active Passport device credential record could not be found.");
                }

                var devicePublicKeyPath = ResolvePublicKeyPath(resolvedWorkspaceRoot, deviceRecord.Value.RootElement);
                if (string.IsNullOrWhiteSpace(devicePublicKeyPath) || !File.Exists(devicePublicKeyPath))
                {
                    return FailedBinding("The Passport device public key could not be resolved.");
                }

                var walletKeyId = "wallet-" + Guid.NewGuid().ToString("N")[..16];
                var walletKeyRoot = Path.Combine(resolvedWorkspaceRoot, "records", "passport", "wallet", "keys");
                var walletPublicKeyRoot = Path.Combine(resolvedWorkspaceRoot, "records", "passport", "wallet", "public-keys");
                Directory.CreateDirectory(walletKeyRoot);
                Directory.CreateDirectory(walletPublicKeyRoot);

                using var rsa = RSA.Create(3072);
                var publicKeyBytes = rsa.ExportSubjectPublicKeyInfo();
                var privateKeyBytes = rsa.ExportPkcs8PrivateKey();
                var protectedPrivateKeyBytes = ProtectedData.Protect(
                    privateKeyBytes,
                    Encoding.UTF8.GetBytes("ArchrealmsPassportWindows"),
                    DataProtectionScope.CurrentUser);
                CryptographicOperations.ZeroMemory(privateKeyBytes);

                var walletKeyReferencePath = Path.Combine(walletKeyRoot, walletKeyId + ".pkcs8.protected");
                var walletPublicKeyPath = Path.Combine(walletPublicKeyRoot, walletKeyId + ".spki.der");
                File.WriteAllBytes(walletKeyReferencePath, protectedPrivateKeyBytes);
                File.WriteAllBytes(walletPublicKeyPath, publicKeyBytes);

                var timestamp = DateTime.UtcNow.ToString("yyyyMMddTHHmmssZ");
                var createdUtc = DateTime.UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ");
                var bindingsRoot = Path.Combine(resolvedWorkspaceRoot, "records", "passport", "wallet", "bindings");
                Directory.CreateDirectory(bindingsRoot);

                var bindingRecordPath = Path.Combine(bindingsRoot, timestamp + "-" + walletKeyId + ".json");
                var bindingRecord = new Dictionary<string, object?>
                {
                    ["schema_version"] = 1,
                    ["record_type"] = "passport_wallet_key_binding",
                    ["record_id"] = timestamp + "-" + walletKeyId,
                    ["created_utc"] = createdUtc,
                    ["release_lane"] = releaseLane.Lane,
                    ["ledger_namespace"] = releaseLane.LedgerNamespace,
                    ["policy_version"] = releaseLane.PolicyVersion,
                    ["status"] = "active",
                    ["archrealms_identity_id"] = normalizedIdentityId,
                    ["authorizing_device_id"] = normalizedDeviceId,
                    ["wallet_key_id"] = walletKeyId,
                    ["wallet_key_algorithm"] = "RSA",
                    ["wallet_key_size_bits"] = 3072,
                    ["wallet_public_key_path"] = ToWorkspaceRelativePath(resolvedWorkspaceRoot, walletPublicKeyPath),
                    ["wallet_public_key_sha256"] = ComputeSha256(publicKeyBytes),
                    ["authorized_scopes"] = new[]
                    {
                        "sign_arch_operations",
                        "sign_cc_operations",
                        "sign_conversion_quotes",
                        "sign_escrow_redemption"
                    },
                    ["prohibited_scopes"] = new[]
                    {
                        "alter_identity",
                        "alter_citizenship",
                        "alter_office",
                        "alter_registry_authority",
                        "alter_constitutional_status",
                        "alter_crown_authority"
                    },
                    ["summary"] = "Passport identity/device authorization binding a separate wallet key for monetary operations only."
                };
                File.WriteAllText(bindingRecordPath, JsonSerializer.Serialize(bindingRecord, JsonOptions), Encoding.UTF8);

                var bindingBytes = File.ReadAllBytes(bindingRecordPath);
                var signatureBytes = PassportDeviceKeyStore.SignData(normalizedDeviceKeyReferencePath, bindingBytes);
                var verified = VerifySignature(devicePublicKeyPath, bindingBytes, signatureBytes);
                var signaturePath = Path.Combine(bindingsRoot, timestamp + "-" + walletKeyId + ".signature.json");
                var signatureRecord = new Dictionary<string, object?>
                {
                    ["schema_version"] = 1,
                    ["record_type"] = "passport_wallet_key_binding_signature",
                    ["record_id"] = timestamp + "-" + walletKeyId + "-signature",
                    ["created_utc"] = createdUtc,
                    ["release_lane"] = releaseLane.Lane,
                    ["ledger_namespace"] = releaseLane.LedgerNamespace,
                    ["archrealms_identity_id"] = normalizedIdentityId,
                    ["authorizing_device_id"] = normalizedDeviceId,
                    ["wallet_key_id"] = walletKeyId,
                    ["binding_record_path"] = ToWorkspaceRelativePath(resolvedWorkspaceRoot, bindingRecordPath),
                    ["binding_record_sha256"] = ComputeSha256(bindingBytes),
                    ["signature_algorithm"] = "RSA_PKCS1_SHA256",
                    ["signature_base64"] = Convert.ToBase64String(signatureBytes),
                    ["device_public_key_path"] = ToWorkspaceRelativePath(resolvedWorkspaceRoot, devicePublicKeyPath),
                    ["verified_with_device_key"] = verified,
                    ["summary"] = "Identity/device signature authorizing the Passport wallet key binding."
                };
                File.WriteAllText(signaturePath, JsonSerializer.Serialize(signatureRecord, JsonOptions), Encoding.UTF8);

                return new PassportWalletKeyBindingResult
                {
                    Succeeded = true,
                    Message = "Wallet key created and bound to the Passport identity.",
                    WalletKeyId = walletKeyId,
                    WalletKeyReferencePath = walletKeyReferencePath,
                    WalletPublicKeyPath = walletPublicKeyPath,
                    BindingRecordPath = bindingRecordPath,
                    BindingSignaturePath = signaturePath,
                    VerifiedWithDeviceKey = verified
                };
            }
            catch (Exception ex)
            {
                return FailedBinding("Wallet key binding failed: " + ex.Message);
            }
        }

        public PassportWalletSignatureResult SignWalletPayload(string walletKeyReferencePath, string walletPublicKeyPath, byte[] payload)
        {
            try
            {
                if (payload == null || payload.Length == 0)
                {
                    return FailedSignature("A wallet payload is required before signing.");
                }

                var normalizedWalletKeyReferencePath = NormalizeRequired(walletKeyReferencePath, "wallet key reference path");
                var normalizedWalletPublicKeyPath = NormalizeRequired(walletPublicKeyPath, "wallet public key path");
                if (!File.Exists(normalizedWalletKeyReferencePath))
                {
                    return FailedSignature("The wallet key reference path could not be found.");
                }

                if (!File.Exists(normalizedWalletPublicKeyPath))
                {
                    return FailedSignature("The wallet public key path could not be found.");
                }

                var signatureBytes = PassportDeviceKeyStore.SignData(normalizedWalletKeyReferencePath, payload);
                var verified = VerifySignature(normalizedWalletPublicKeyPath, payload, signatureBytes);
                return new PassportWalletSignatureResult
                {
                    Succeeded = true,
                    Message = "Wallet payload signed.",
                    SignatureBase64 = Convert.ToBase64String(signatureBytes),
                    PayloadSha256 = ComputeSha256(payload),
                    VerifiedWithWalletKey = verified
                };
            }
            catch (Exception ex)
            {
                return FailedSignature("Wallet payload signing failed: " + ex.Message);
            }
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

        private static string ToWorkspaceRelativePath(string workspaceRoot, string path)
        {
            var normalizedRoot = Path.GetFullPath(workspaceRoot).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
            var normalizedPath = Path.GetFullPath(path);
            var relative = normalizedPath.Substring(normalizedRoot.Length).TrimStart(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
            return relative.Replace(Path.DirectorySeparatorChar, '/');
        }

        private static string ComputeSha256(byte[] value)
        {
            return Convert.ToHexString(SHA256.HashData(value)).ToLowerInvariant();
        }

        private static PassportWalletKeyBindingResult FailedBinding(string message)
        {
            return new PassportWalletKeyBindingResult
            {
                Succeeded = false,
                Message = message
            };
        }

        private static PassportWalletSignatureResult FailedSignature(string message)
        {
            return new PassportWalletSignatureResult
            {
                Succeeded = false,
                Message = message
            };
        }
    }
}
