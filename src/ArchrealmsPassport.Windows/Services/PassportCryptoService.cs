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
    public sealed class PassportCryptoService
    {
        private static readonly JsonSerializerOptions JsonOptions = new JsonSerializerOptions
        {
            WriteIndented = true
        };

        public PassportChallengeSignatureResult SignChallenge(
            string workspaceRoot,
            string identityId,
            string deviceId,
            string privateKeyPath,
            string challenge)
        {
            try
            {
                if (string.IsNullOrWhiteSpace(challenge))
                {
                    return FailedChallenge("A challenge is required before signing.");
                }

                var resolvedWorkspaceRoot = PassportEnvironment.ResolveWorkspaceRoot(workspaceRoot);
                var deviceRecord = FindLatestActiveDeviceRecord(resolvedWorkspaceRoot, identityId, deviceId);
                if (deviceRecord == null)
                {
                    return FailedChallenge("The active device credential record could not be found.");
                }

                var publicKeyPath = ResolvePublicKeyPath(resolvedWorkspaceRoot, deviceRecord.Value);
                if (string.IsNullOrWhiteSpace(publicKeyPath) || !File.Exists(publicKeyPath))
                {
                    return FailedChallenge("The device public key could not be resolved.");
                }

                var challengeBytes = Encoding.UTF8.GetBytes(challenge);
                byte[] signatureBytes;
                using (var rsa = LoadPrivateKey(privateKeyPath))
                {
                    signatureBytes = rsa.SignData(challengeBytes, HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1);
                }

                bool verified;
                using (var rsa = RSA.Create())
                {
                    rsa.ImportSubjectPublicKeyInfo(File.ReadAllBytes(publicKeyPath), out _);
                    verified = rsa.VerifyData(challengeBytes, signatureBytes, HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1);
                }

                var createdUtc = DateTime.UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ");
                var timestamp = DateTime.UtcNow.ToString("yyyyMMddTHHmmssZ");
                var signaturesRoot = Path.Combine(resolvedWorkspaceRoot, "records", "registry", "signatures", "challenges");
                Directory.CreateDirectory(signaturesRoot);

                var signatureRecordPath = Path.Combine(signaturesRoot, timestamp + "-" + deviceId + ".json");
                var signatureRecord = new Dictionary<string, object?>
                {
                    ["schema_version"] = 1,
                    ["record_type"] = "passport_challenge_signature",
                    ["record_id"] = timestamp + "-" + deviceId,
                    ["created_utc"] = createdUtc,
                    ["archrealms_identity_id"] = identityId,
                    ["device_id"] = deviceId,
                    ["challenge"] = challenge,
                    ["challenge_sha256"] = ComputeSha256(challengeBytes),
                    ["signature_algorithm"] = "RSA_PKCS1_SHA256",
                    ["signature_base64"] = Convert.ToBase64String(signatureBytes),
                    ["public_key_path"] = ToWorkspaceRelativePath(resolvedWorkspaceRoot, publicKeyPath),
                    ["verified_with_public_key"] = verified,
                    ["summary"] = "Challenge signed by Passport device credential."
                };

                File.WriteAllText(signatureRecordPath, JsonSerializer.Serialize(signatureRecord, JsonOptions));

                return new PassportChallengeSignatureResult
                {
                    Succeeded = true,
                    Message = "Challenge signed successfully.",
                    SignatureRecordPath = signatureRecordPath,
                    SignatureBase64 = Convert.ToBase64String(signatureBytes),
                    VerifiedWithPublicKey = verified
                };
            }
            catch (Exception ex)
            {
                return FailedChallenge("Challenge signing failed: " + ex.Message);
            }
        }

        public PassportRegistrySubmissionResult CreateRegistrySubmission(
            string workspaceRoot,
            string identityId,
            string deviceId,
            string privateKeyPath)
        {
            try
            {
                var resolvedWorkspaceRoot = PassportEnvironment.ResolveWorkspaceRoot(workspaceRoot);
                var identityRecordPath = FindLatestIdentityRecordPath(resolvedWorkspaceRoot, identityId);
                if (string.IsNullOrWhiteSpace(identityRecordPath))
                {
                    return FailedSubmission("The Passport identity record could not be found.");
                }

                var deviceRecord = FindLatestActiveDeviceRecord(resolvedWorkspaceRoot, identityId, deviceId);
                if (deviceRecord == null)
                {
                    return FailedSubmission("The active device credential record could not be found.");
                }

                var deviceRecordPath = deviceRecord.Value.RecordPath;
                var publicKeyPath = ResolvePublicKeyPath(resolvedWorkspaceRoot, deviceRecord.Value);
                if (string.IsNullOrWhiteSpace(publicKeyPath) || !File.Exists(publicKeyPath))
                {
                    return FailedSubmission("The device public key could not be resolved.");
                }

                var timestamp = DateTime.UtcNow.ToString("yyyyMMddTHHmmssZ");
                var createdUtc = DateTime.UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ");
                var packageId = timestamp + "-" + identityId + "-" + deviceId;
                var submissionsRoot = Path.Combine(resolvedWorkspaceRoot, "records", "registry", "submissions");
                var packageRoot = Path.Combine(submissionsRoot, packageId);
                var packageFilesRoot = Path.Combine(packageRoot, "package");

                Directory.CreateDirectory(packageRoot);
                Directory.CreateDirectory(packageFilesRoot);

                var packagedIdentityPath = CopyIntoPackage(identityRecordPath, Path.Combine(packageFilesRoot, "passport-identity-record.json"));
                var packagedDevicePath = CopyIntoPackage(deviceRecordPath, Path.Combine(packageFilesRoot, "device-credential-record.json"));
                var packagedKeyPath = CopyIntoPackage(publicKeyPath, Path.Combine(packageFilesRoot, "device-public-key.spki.der"));

                var manifestPath = Path.Combine(packageRoot, "manifest.json");
                var manifest = new Dictionary<string, object?>
                {
                    ["package_name"] = "passport-registry-submission",
                    ["package_id"] = packageId,
                    ["created_utc"] = createdUtc,
                    ["archrealms_identity_id"] = identityId,
                    ["device_id"] = deviceId,
                    ["documents"] = new[]
                    {
                        CreateManifestDocumentEntry(packageRoot, packagedIdentityPath),
                        CreateManifestDocumentEntry(packageRoot, packagedDevicePath),
                        CreateManifestDocumentEntry(packageRoot, packagedKeyPath)
                    }
                };

                File.WriteAllText(manifestPath, JsonSerializer.Serialize(manifest, JsonOptions));

                var manifestBytes = File.ReadAllBytes(manifestPath);
                byte[] signatureBytes;
                using (var rsa = LoadPrivateKey(privateKeyPath))
                {
                    signatureBytes = rsa.SignData(manifestBytes, HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1);
                }

                bool verified;
                using (var rsa = RSA.Create())
                {
                    rsa.ImportSubjectPublicKeyInfo(File.ReadAllBytes(packagedKeyPath), out _);
                    verified = rsa.VerifyData(manifestBytes, signatureBytes, HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1);
                }

                var signaturePath = Path.Combine(packageRoot, "manifest-signature.json");
                var manifestSha256 = ComputeSha256(manifestBytes);
                var signatureRecord = new Dictionary<string, object?>
                {
                    ["schema_version"] = 1,
                    ["record_type"] = "manifest_signature_record",
                    ["record_id"] = packageId + "-manifest-signature",
                    ["created_utc"] = createdUtc,
                    ["archrealms_identity_id"] = identityId,
                    ["device_id"] = deviceId,
                    ["manifest_sha256"] = manifestSha256,
                    ["signature_algorithm"] = "RSA_PKCS1_SHA256",
                    ["signature_base64"] = Convert.ToBase64String(signatureBytes),
                    ["public_key_path"] = ToPackageRelativePath(packageRoot, packagedKeyPath),
                    ["verified_with_public_key"] = verified,
                    ["summary"] = "Manifest signature produced by the active Passport device credential."
                };

                File.WriteAllText(signaturePath, JsonSerializer.Serialize(signatureRecord, JsonOptions));

                var submissionPath = Path.Combine(packageRoot, "submission.json");
                var submissionRecord = new Dictionary<string, object?>
                {
                    ["schema_version"] = 1,
                    ["record_type"] = "registry_submission_package",
                    ["record_id"] = packageId,
                    ["created_utc"] = createdUtc,
                    ["archrealms_identity_id"] = identityId,
                    ["device_id"] = deviceId,
                    ["manifest_path"] = "manifest.json",
                    ["manifest_signature_path"] = "manifest-signature.json",
                    ["document_count"] = 3,
                    ["summary"] = "Registry submission package prepared by Windows Passport."
                };

                File.WriteAllText(submissionPath, JsonSerializer.Serialize(submissionRecord, JsonOptions));

                return new PassportRegistrySubmissionResult
                {
                    Succeeded = true,
                    Message = "Registry submission package prepared successfully.",
                    SubmissionPath = submissionPath,
                    ManifestPath = manifestPath,
                    SignaturePath = signaturePath,
                    VerifiedWithPublicKey = verified
                };
            }
            catch (Exception ex)
            {
                return FailedSubmission("Registry submission packaging failed: " + ex.Message);
            }
        }

        private static Dictionary<string, object?> CreateManifestDocumentEntry(string packageRoot, string path)
        {
            var bytes = File.ReadAllBytes(path);
            return new Dictionary<string, object?>
            {
                ["path"] = ToPackageRelativePath(packageRoot, path),
                ["size_bytes"] = bytes.LongLength,
                ["sha256"] = ComputeSha256(bytes)
            };
        }

        private static string CopyIntoPackage(string sourcePath, string destinationPath)
        {
            Directory.CreateDirectory(Path.GetDirectoryName(destinationPath) ?? string.Empty);
            File.Copy(sourcePath, destinationPath, true);
            return destinationPath;
        }

        private static (string RecordPath, JsonElement RootElement)? FindLatestActiveDeviceRecord(
            string workspaceRoot,
            string identityId,
            string deviceId)
        {
            var deviceRoot = Path.Combine(workspaceRoot, "records", "registry", "device-credentials");
            if (!Directory.Exists(deviceRoot))
            {
                return null;
            }

            foreach (var file in Directory.GetFiles(deviceRoot, "*.json").OrderByDescending(Path.GetFileName))
            {
                using (var document = JsonDocument.Parse(File.ReadAllText(file)))
                {
                    var root = document.RootElement.Clone();
                    if (Matches(root, "record_type", "device_credential_record")
                        && Matches(root, "status", "active")
                        && Matches(root, "archrealms_identity_id", identityId)
                        && Matches(root, "device_id", deviceId))
                    {
                        return (file, root);
                    }
                }
            }

            return null;
        }

        private static string FindLatestIdentityRecordPath(string workspaceRoot, string identityId)
        {
            var identitiesRoot = Path.Combine(workspaceRoot, "records", "registry", "identities");
            if (!Directory.Exists(identitiesRoot))
            {
                return string.Empty;
            }

            foreach (var file in Directory.GetFiles(identitiesRoot, "*.json").OrderByDescending(Path.GetFileName))
            {
                using (var document = JsonDocument.Parse(File.ReadAllText(file)))
                {
                    var root = document.RootElement;
                    if (Matches(root, "record_type", "passport_identity_record")
                        && Matches(root, "status", "active")
                        && Matches(root, "archrealms_identity_id", identityId))
                    {
                        return file;
                    }
                }
            }

            return string.Empty;
        }

        private static string ResolvePublicKeyPath(string workspaceRoot, (string RecordPath, JsonElement RootElement) deviceRecord)
        {
            if (!TryGetString(deviceRecord.RootElement, "public_key_path", out var publicKeyRelative))
            {
                return string.Empty;
            }

            var normalized = publicKeyRelative.Replace('/', Path.DirectorySeparatorChar);
            return Path.Combine(workspaceRoot, normalized);
        }

        private static RSA LoadPrivateKey(string privateKeyPath)
        {
            if (string.IsNullOrWhiteSpace(privateKeyPath) || !File.Exists(privateKeyPath))
            {
                throw new FileNotFoundException("Protected device key not found.", privateKeyPath);
            }

            var protectedPrivateKey = File.ReadAllBytes(privateKeyPath);
            var privateKeyBytes = ProtectedData.Unprotect(
                protectedPrivateKey,
                Encoding.UTF8.GetBytes("ArchrealmsPassportWindows"),
                DataProtectionScope.CurrentUser);

            var rsa = RSA.Create();
            rsa.ImportPkcs8PrivateKey(privateKeyBytes, out _);
            return rsa;
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

        private static string ToPackageRelativePath(string packageRoot, string path)
        {
            var normalizedRoot = Path.GetFullPath(packageRoot).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
            var normalizedPath = Path.GetFullPath(path);
            var relative = normalizedPath.Substring(normalizedRoot.Length).TrimStart(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
            return relative.Replace(Path.DirectorySeparatorChar, '/');
        }

        private static PassportChallengeSignatureResult FailedChallenge(string message)
        {
            return new PassportChallengeSignatureResult
            {
                Succeeded = false,
                Message = message
            };
        }

        private static PassportRegistrySubmissionResult FailedSubmission(string message)
        {
            return new PassportRegistrySubmissionResult
            {
                Succeeded = false,
                Message = message
            };
        }
    }
}
