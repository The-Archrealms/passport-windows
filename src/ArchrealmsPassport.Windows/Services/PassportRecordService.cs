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
            return ProvisionIdentity(workspaceRoot, identityId, displayName, identityMode, deviceLabel, true);
        }

        public PassportProvisioningResult AddDeviceToIdentity(
            string workspaceRoot,
            string identityId,
            string displayName,
            string identityMode,
            string deviceLabel)
        {
            return ProvisionIdentity(workspaceRoot, identityId, displayName, identityMode, deviceLabel, false);
        }

        private PassportProvisioningResult ProvisionIdentity(
            string workspaceRoot,
            string identityId,
            string displayName,
            string identityMode,
            string deviceLabel,
            bool createIdentityRecord)
        {
            try
            {
                if (string.IsNullOrWhiteSpace(identityId))
                {
                    return Failed("A Passport identity identifier is required.");
                }

                var resolvedWorkspaceRoot = PassportEnvironment.ResolveWorkspaceRoot(workspaceRoot);
                var normalizedDisplayName = NormalizeDisplayName(displayName, identityMode, identityId);
                var normalizedDeviceLabel = string.IsNullOrWhiteSpace(deviceLabel)
                    ? Environment.MachineName
                    : deviceLabel.Trim();

                var registryRoot = Path.Combine(resolvedWorkspaceRoot, "records", "registry");
                var identitiesRoot = Path.Combine(registryRoot, "identities");
                var deviceCredentialsRoot = Path.Combine(registryRoot, "device-credentials");
                var publicKeysRoot = Path.Combine(registryRoot, "public-keys");

                Directory.CreateDirectory(registryRoot);
                Directory.CreateDirectory(identitiesRoot);
                Directory.CreateDirectory(deviceCredentialsRoot);
                Directory.CreateDirectory(publicKeysRoot);

                var timestamp = DateTime.UtcNow.ToString("yyyyMMddTHHmmssZ");
                var createdUtc = DateTime.UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ");
                var deviceId = CreateDeviceId(normalizedDeviceLabel);
                var deviceKeyPair = CreateDeviceKeyPair(deviceId);

                var publicKeyPath = Path.Combine(publicKeysRoot, deviceId + ".spki.der");
                File.WriteAllBytes(publicKeyPath, deviceKeyPair.PublicKeyBytes);

                string identityRecordPath = string.Empty;
                if (createIdentityRecord)
                {
                    identityRecordPath = Path.Combine(identitiesRoot, timestamp + "-" + identityId + ".json");
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
                }

                var deviceRecordPath = Path.Combine(deviceCredentialsRoot, timestamp + "-" + deviceId + ".json");
                var deviceRecord = new Dictionary<string, object?>
                {
                    ["schema_version"] = 1,
                    ["record_type"] = "device_credential_record",
                    ["record_id"] = timestamp + "-" + deviceId,
                    ["created_utc"] = createdUtc,
                    ["effective_utc"] = createdUtc,
                    ["status"] = "active",
                    ["archrealms_identity_id"] = identityId,
                    ["device_id"] = deviceId,
                    ["device_label"] = normalizedDeviceLabel,
                    ["device_class"] = "desktop",
                    ["client_platform"] = "windows",
                    ["credential_origin"] = "passport-windows",
                    ["public_key_algorithm"] = "RSA",
                    ["public_key_format"] = "SPKI_DER",
                    ["public_key_path"] = ToWorkspaceRelativePath(resolvedWorkspaceRoot, publicKeyPath),
                    ["public_key_sha256"] = ComputeSha256(deviceKeyPair.PublicKeyBytes),
                    ["authorized_scopes"] = new[]
                    {
                        "authenticate",
                        "submit_registry_record",
                        "publish_archive"
                    },
                    ["expires_utc"] = string.Empty,
                    ["revocation_record_id"] = string.Empty,
                    ["attestation_refs"] = Array.Empty<string>(),
                    ["summary"] = createIdentityRecord
                        ? "Initial Passport device credential created during identity provisioning."
                        : "Additional Passport device credential added to an existing Passport identity."
                };

                File.WriteAllText(deviceRecordPath, JsonSerializer.Serialize(deviceRecord, JsonOptions));

                return new PassportProvisioningResult
                {
                    Succeeded = true,
                    Message = createIdentityRecord
                        ? "Created a new Passport identity and authorized this device."
                        : "Authorized this device under an existing Passport identity.",
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
                return Failed("Passport provisioning failed: " + ex.Message);
            }
        }

        private static PassportProvisioningResult Failed(string message)
        {
            return new PassportProvisioningResult
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
