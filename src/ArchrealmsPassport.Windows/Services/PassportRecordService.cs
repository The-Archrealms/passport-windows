using System;
using System.Collections.Generic;
using System.IO;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using ArchrealmsPassport.Windows.Models;

namespace ArchrealmsPassport.Windows.Services
{
    public sealed class PassportRecordService
    {
        private static readonly JsonSerializerOptions JsonOptions = new JsonSerializerOptions
        {
            WriteIndented = true
        };

        public PassportProvisioningResult CreateNewIdentity(
            string workspaceRoot,
            string displayName,
            string identityMode,
            string deviceLabel)
        {
            var identityId = CreateIdentityId(displayName);

            try
            {
                var resolvedWorkspaceRoot = PassportEnvironment.ResolveWorkspaceRoot(workspaceRoot);
                var normalizedDisplayName = NormalizeDisplayName(displayName, identityMode, identityId);
                var normalizedDeviceLabel = NormalizeDeviceLabel(deviceLabel);
                EnsureRegistryFolders(resolvedWorkspaceRoot);

                var timestamp = DateTime.UtcNow.ToString("yyyyMMddTHHmmssZ");
                var createdUtc = DateTime.UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ");
                var deviceId = CreateDeviceId(normalizedDeviceLabel);
                var deviceKeyPair = CreateDeviceKeyPair(deviceId);
                var publicKeyPath = WritePublicKey(resolvedWorkspaceRoot, deviceId, deviceKeyPair.PublicKeyBytes);

                var identityRecordPath = Path.Combine(
                    resolvedWorkspaceRoot,
                    "records",
                    "registry",
                    "identities",
                    timestamp + "-" + identityId + ".json");

                var identityRecord = new Dictionary<string, object?>
                {
                    ["schema_version"] = 1,
                    ["record_type"] = "passport_identity_record",
                    ["record_id"] = timestamp + "-" + identityId,
                    ["created_utc"] = createdUtc,
                    ["effective_utc"] = createdUtc,
                    ["status"] = "active",
                    ["archrealms_identity_id"] = identityId,
                    ["display_name"] = normalizedDisplayName,
                    ["identity_mode"] = identityMode,
                    ["citizenship_class"] = "citizen",
                    ["declared_scope"] = "personal",
                    ["public_biography"] = string.Empty,
                    ["recovery_authority"] = new Dictionary<string, object?>
                    {
                        ["method"] = "device-recovery-to-be-defined",
                        ["reference"] = deviceId
                    },
                    ["attestation_refs"] = Array.Empty<string>(),
                    ["supersedes_record_id"] = string.Empty,
                    ["summary"] = "Passport identity established through Windows Passport onboarding."
                };

                File.WriteAllText(identityRecordPath, JsonSerializer.Serialize(identityRecord, JsonOptions));

                var deviceRecordPath = Path.Combine(
                    resolvedWorkspaceRoot,
                    "records",
                    "registry",
                    "device-credentials",
                    timestamp + "-" + deviceId + ".json");

                var deviceRecord = CreateDeviceCredentialRecord(
                    resolvedWorkspaceRoot,
                    timestamp,
                    createdUtc,
                    identityId,
                    deviceId,
                    normalizedDeviceLabel,
                    publicKeyPath,
                    deviceKeyPair.PublicKeyBytes,
                    "active",
                    "genesis",
                    string.Empty,
                    string.Empty,
                    string.Empty);

                File.WriteAllText(deviceRecordPath, JsonSerializer.Serialize(deviceRecord, JsonOptions));

                return new PassportProvisioningResult
                {
                    Succeeded = true,
                    Message = "Created a new Passport identity and authorized this device.",
                    IdentityId = identityId,
                    DeviceId = deviceId,
                    PrivateKeyPath = deviceKeyPair.PrivateKeyPath,
                    PublicKeyPath = publicKeyPath,
                    IdentityRecordPath = identityRecordPath,
                    DeviceRecordPath = deviceRecordPath
                };
            }
            catch (Exception ex)
            {
                return FailedProvisioning("Passport provisioning failed: " + ex.Message);
            }
        }

        public PassportJoinRequestResult CreateJoinRequest(
            string workspaceRoot,
            string identityId,
            string deviceLabel)
        {
            try
            {
                if (string.IsNullOrWhiteSpace(identityId))
                {
                    return FailedJoinRequest("An existing Passport identity identifier is required.");
                }

                var resolvedWorkspaceRoot = PassportEnvironment.ResolveWorkspaceRoot(workspaceRoot);
                var normalizedDeviceLabel = NormalizeDeviceLabel(deviceLabel);
                EnsureRegistryFolders(resolvedWorkspaceRoot);

                var timestamp = DateTime.UtcNow.ToString("yyyyMMddTHHmmssZ");
                var createdUtc = DateTime.UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ");
                var deviceId = CreateDeviceId(normalizedDeviceLabel);
                var deviceKeyPair = CreateDeviceKeyPair(deviceId);
                var publicKeyPath = WritePublicKey(resolvedWorkspaceRoot, deviceId, deviceKeyPair.PublicKeyBytes);

                var pendingRecordPath = Path.Combine(
                    resolvedWorkspaceRoot,
                    "records",
                    "registry",
                    "device-credentials",
                    timestamp + "-" + deviceId + ".pending.json");

                var pendingRecord = CreateDeviceCredentialRecord(
                    resolvedWorkspaceRoot,
                    timestamp,
                    createdUtc,
                    identityId,
                    deviceId,
                    normalizedDeviceLabel,
                    publicKeyPath,
                    deviceKeyPair.PublicKeyBytes,
                    "pending_authorization",
                    "pending",
                    string.Empty,
                    string.Empty,
                    string.Empty);

                File.WriteAllText(pendingRecordPath, JsonSerializer.Serialize(pendingRecord, JsonOptions));

                var joinRequestRoot = Path.Combine(
                    resolvedWorkspaceRoot,
                    "records",
                    "registry",
                    "join-requests",
                    timestamp + "-" + identityId + "-" + deviceId);
                Directory.CreateDirectory(joinRequestRoot);

                var packagedPublicKeyPath = Path.Combine(joinRequestRoot, "candidate-device-public-key.spki.der");
                File.WriteAllBytes(packagedPublicKeyPath, deviceKeyPair.PublicKeyBytes);

                var requestPath = Path.Combine(joinRequestRoot, "device-join-request.json");
                var requestRecord = new Dictionary<string, object?>
                {
                    ["schema_version"] = 1,
                    ["record_type"] = "device_join_request",
                    ["record_id"] = timestamp + "-" + deviceId,
                    ["created_utc"] = createdUtc,
                    ["archrealms_identity_id"] = identityId,
                    ["device_id"] = deviceId,
                    ["device_label"] = normalizedDeviceLabel,
                    ["client_platform"] = "windows",
                    ["public_key_path"] = "candidate-device-public-key.spki.der",
                    ["public_key_sha256"] = ComputeSha256(deviceKeyPair.PublicKeyBytes),
                    ["requested_scopes"] = new[]
                    {
                        "authenticate",
                        "submit_registry_record",
                        "publish_archive"
                    },
                    ["summary"] = "Join request generated by a new Passport device seeking approval from an existing authorized device."
                };

                File.WriteAllText(requestPath, JsonSerializer.Serialize(requestRecord, JsonOptions));

                var requestBytes = File.ReadAllBytes(requestPath);
                byte[] signatureBytes;
                using (var rsa = LoadPrivateKey(deviceKeyPair.PrivateKeyPath))
                {
                    signatureBytes = rsa.SignData(requestBytes, HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1);
                }

                bool verified;
                using (var rsa = RSA.Create())
                {
                    rsa.ImportSubjectPublicKeyInfo(deviceKeyPair.PublicKeyBytes, out _);
                    verified = rsa.VerifyData(requestBytes, signatureBytes, HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1);
                }

                var signaturePath = Path.Combine(joinRequestRoot, "device-join-request-signature.json");
                var signatureRecord = new Dictionary<string, object?>
                {
                    ["schema_version"] = 1,
                    ["record_type"] = "device_join_request_signature",
                    ["record_id"] = timestamp + "-" + deviceId + "-signature",
                    ["created_utc"] = createdUtc,
                    ["archrealms_identity_id"] = identityId,
                    ["device_id"] = deviceId,
                    ["request_sha256"] = ComputeSha256(requestBytes),
                    ["signature_algorithm"] = "RSA_PKCS1_SHA256",
                    ["signature_base64"] = Convert.ToBase64String(signatureBytes),
                    ["public_key_path"] = "candidate-device-public-key.spki.der",
                    ["verified_with_public_key"] = verified,
                    ["summary"] = "Join request signed by the candidate device key."
                };

                File.WriteAllText(signaturePath, JsonSerializer.Serialize(signatureRecord, JsonOptions));

                return new PassportJoinRequestResult
                {
                    Succeeded = true,
                    Message = "Prepared a join request for approval by an existing authorized device.",
                    IdentityId = identityId,
                    DeviceId = deviceId,
                    PrivateKeyPath = deviceKeyPair.PrivateKeyPath,
                    PublicKeyPath = publicKeyPath,
                    PendingDeviceRecordPath = pendingRecordPath,
                    JoinRequestPath = requestPath,
                    RequestSignaturePath = signaturePath
                };
            }
            catch (Exception ex)
            {
                return FailedJoinRequest("Join request generation failed: " + ex.Message);
            }
        }

        private static void EnsureRegistryFolders(string workspaceRoot)
        {
            Directory.CreateDirectory(Path.Combine(workspaceRoot, "records", "registry", "identities"));
            Directory.CreateDirectory(Path.Combine(workspaceRoot, "records", "registry", "device-credentials"));
            Directory.CreateDirectory(Path.Combine(workspaceRoot, "records", "registry", "public-keys"));
            Directory.CreateDirectory(Path.Combine(workspaceRoot, "records", "registry", "join-requests"));
            Directory.CreateDirectory(Path.Combine(workspaceRoot, "records", "registry", "join-approvals"));
            Directory.CreateDirectory(Path.Combine(workspaceRoot, "records", "registry", "device-authorizations"));
        }

        private static Dictionary<string, object?> CreateDeviceCredentialRecord(
            string workspaceRoot,
            string timestamp,
            string createdUtc,
            string identityId,
            string deviceId,
            string normalizedDeviceLabel,
            string publicKeyPath,
            byte[] publicKeyBytes,
            string status,
            string authorizationMode,
            string authorizationPackagePath,
            string authorizationRecordPath,
            string authorizerDeviceId)
        {
            return new Dictionary<string, object?>
            {
                ["schema_version"] = 1,
                ["record_type"] = "device_credential_record",
                ["record_id"] = timestamp + "-" + deviceId,
                ["created_utc"] = createdUtc,
                ["effective_utc"] = createdUtc,
                ["status"] = status,
                ["archrealms_identity_id"] = identityId,
                ["device_id"] = deviceId,
                ["device_label"] = normalizedDeviceLabel,
                ["device_class"] = "desktop",
                ["client_platform"] = "windows",
                ["credential_origin"] = "passport-windows",
                ["public_key_algorithm"] = "RSA",
                ["public_key_format"] = "SPKI_DER",
                ["public_key_path"] = ToWorkspaceRelativePath(workspaceRoot, publicKeyPath),
                ["public_key_sha256"] = ComputeSha256(publicKeyBytes),
                ["authorized_scopes"] = new[]
                {
                    "authenticate",
                    "submit_registry_record",
                    "publish_archive"
                },
                ["authorization_mode"] = authorizationMode,
                ["authorization_package_path"] = authorizationPackagePath,
                ["authorization_record_path"] = authorizationRecordPath,
                ["authorizer_device_id"] = authorizerDeviceId,
                ["expires_utc"] = string.Empty,
                ["revocation_record_id"] = string.Empty,
                ["attestation_refs"] = Array.Empty<string>()
            };
        }

        private static string NormalizeDeviceLabel(string deviceLabel)
        {
            return string.IsNullOrWhiteSpace(deviceLabel)
                ? Environment.MachineName
                : deviceLabel.Trim();
        }

        private static string WritePublicKey(string workspaceRoot, string deviceId, byte[] publicKeyBytes)
        {
            var publicKeyPath = Path.Combine(workspaceRoot, "records", "registry", "public-keys", deviceId + ".spki.der");
            File.WriteAllBytes(publicKeyPath, publicKeyBytes);
            return publicKeyPath;
        }

        private static PassportProvisioningResult FailedProvisioning(string message)
        {
            return new PassportProvisioningResult
            {
                Succeeded = false,
                Message = message
            };
        }

        private static PassportJoinRequestResult FailedJoinRequest(string message)
        {
            return new PassportJoinRequestResult
            {
                Succeeded = false,
                Message = message
            };
        }

        private static string CreateIdentityId(string displayName)
        {
            var slug = Slugify(displayName);
            if (string.IsNullOrWhiteSpace(slug))
            {
                slug = "persona";
            }

            return "identity-" + slug + "-" + Guid.NewGuid().ToString("N").Substring(0, 10);
        }

        private static string CreateDeviceId(string deviceLabel)
        {
            var slug = Slugify(deviceLabel);
            if (string.IsNullOrWhiteSpace(slug))
            {
                slug = "device";
            }

            return "device-" + slug + "-" + Guid.NewGuid().ToString("N").Substring(0, 10);
        }

        private static string NormalizeDisplayName(string displayName, string identityMode, string identityId)
        {
            if (!string.IsNullOrWhiteSpace(displayName))
            {
                return displayName.Trim();
            }

            if (string.Equals(identityMode, "anonymous", StringComparison.OrdinalIgnoreCase))
            {
                return "Anonymous " + identityId.Substring(Math.Max(0, identityId.Length - 6));
            }

            return identityId;
        }

        private static string Slugify(string value)
        {
            if (string.IsNullOrWhiteSpace(value))
            {
                return string.Empty;
            }

            var builder = new StringBuilder();
            foreach (var character in value.Trim().ToLowerInvariant())
            {
                if (char.IsLetterOrDigit(character))
                {
                    builder.Append(character);
                }
                else if (builder.Length > 0 && builder[builder.Length - 1] != '-')
                {
                    builder.Append('-');
                }
            }

            return builder.ToString().Trim('-');
        }

        private static (byte[] PublicKeyBytes, string PrivateKeyPath) CreateDeviceKeyPair(string deviceId)
        {
            using (var rsa = RSA.Create(3072))
            {
                var publicKeyBytes = rsa.ExportSubjectPublicKeyInfo();
                var privateKeyBytes = rsa.ExportPkcs8PrivateKey();
                var protectedPrivateKey = ProtectedData.Protect(
                    privateKeyBytes,
                    Encoding.UTF8.GetBytes("ArchrealmsPassportWindows"),
                    DataProtectionScope.CurrentUser);

                var privateKeyPath = Path.Combine(PassportEnvironment.GetKeysRoot(), deviceId + ".pkcs8.protected");
                File.WriteAllBytes(privateKeyPath, protectedPrivateKey);

                return (publicKeyBytes, privateKeyPath);
            }
        }

        private static RSA LoadPrivateKey(string privateKeyPath)
        {
            var protectedPrivateKey = File.ReadAllBytes(privateKeyPath);
            var privateKeyBytes = ProtectedData.Unprotect(
                protectedPrivateKey,
                Encoding.UTF8.GetBytes("ArchrealmsPassportWindows"),
                DataProtectionScope.CurrentUser);

            var rsa = RSA.Create();
            rsa.ImportPkcs8PrivateKey(privateKeyBytes, out _);
            return rsa;
        }

        private static string ComputeSha256(byte[] value)
        {
            using (var sha256 = SHA256.Create())
            {
                var hash = sha256.ComputeHash(value);
                var builder = new StringBuilder(hash.Length * 2);
                foreach (var b in hash)
                {
                    builder.Append(b.ToString("x2"));
                }

                return builder.ToString();
            }
        }

        private static string ToWorkspaceRelativePath(string workspaceRoot, string path)
        {
            var normalizedRoot = Path.GetFullPath(workspaceRoot).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
            var normalizedPath = Path.GetFullPath(path);

            if (normalizedPath.StartsWith(normalizedRoot, StringComparison.OrdinalIgnoreCase))
            {
                var relative = normalizedPath.Substring(normalizedRoot.Length).TrimStart(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
                return relative.Replace(Path.DirectorySeparatorChar, '/');
            }

            return path.Replace(Path.DirectorySeparatorChar, '/');
        }
    }
}
