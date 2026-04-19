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
                var deviceRecord = FindLatestDeviceRecord(resolvedWorkspaceRoot, identityId, deviceId, "active");
                if (deviceRecord == null)
                {
                    return FailedChallenge("The active device credential record could not be found.");
                }

                var publicKeyPath = ResolvePublicKeyPath(resolvedWorkspaceRoot, deviceRecord.Value.RootElement);
                if (string.IsNullOrWhiteSpace(publicKeyPath) || !File.Exists(publicKeyPath))
                {
                    return FailedChallenge("The device public key could not be resolved.");
                }

                var challengeBytes = Encoding.UTF8.GetBytes(challenge);
                byte[] signatureBytes;
                signatureBytes = PassportDeviceKeyStore.SignData(privateKeyPath, challengeBytes);

                var verified = VerifySignature(publicKeyPath, challengeBytes, signatureBytes);
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

        public PassportJoinApprovalResult ApproveJoinRequest(
            string workspaceRoot,
            string authorizerIdentityId,
            string authorizerDeviceId,
            string authorizerPrivateKeyPath,
            string joinRequestPath)
        {
            try
            {
                var resolvedWorkspaceRoot = PassportEnvironment.ResolveWorkspaceRoot(workspaceRoot);
                var authorizerRecord = FindLatestDeviceRecord(resolvedWorkspaceRoot, authorizerIdentityId, authorizerDeviceId, "active");
                if (authorizerRecord == null)
                {
                    return FailedJoinApproval("The approving device credential record could not be found.");
                }

                var requestPackageRoot = ResolvePackageRoot(joinRequestPath);
                var requestPath = Path.Combine(requestPackageRoot, "device-join-request.json");
                var requestSignaturePath = Path.Combine(requestPackageRoot, "device-join-request-signature.json");
                var candidatePublicKeyPath = Path.Combine(requestPackageRoot, "candidate-device-public-key.spki.der");

                var requestRoot = ReadJson(requestPath);
                var requestSignatureRoot = ReadJson(requestSignaturePath);
                var requestBytes = File.ReadAllBytes(requestPath);
                var requestSignatureBytes = Convert.FromBase64String(GetRequiredString(requestSignatureRoot, "signature_base64"));
                if (!VerifySignature(candidatePublicKeyPath, requestBytes, requestSignatureBytes))
                {
                    return FailedJoinApproval("The join request signature is invalid.");
                }

                var requestIdentityId = GetRequiredString(requestRoot, "archrealms_identity_id");
                if (!string.Equals(requestIdentityId, authorizerIdentityId, StringComparison.Ordinal))
                {
                    return FailedJoinApproval("The join request identity does not match the active authorizer identity.");
                }

                var identityRecordPath = FindLatestIdentityRecordPath(resolvedWorkspaceRoot, requestIdentityId);
                if (string.IsNullOrWhiteSpace(identityRecordPath))
                {
                    return FailedJoinApproval("The approving workspace does not contain the requested identity record.");
                }

                var authorizerPublicKeyPath = ResolvePublicKeyPath(resolvedWorkspaceRoot, authorizerRecord.Value.RootElement);
                if (string.IsNullOrWhiteSpace(authorizerPublicKeyPath) || !File.Exists(authorizerPublicKeyPath))
                {
                    return FailedJoinApproval("The approving device public key could not be resolved.");
                }

                var candidateDeviceId = GetRequiredString(requestRoot, "device_id");
                var candidatePublicKeyBytes = File.ReadAllBytes(candidatePublicKeyPath);
                var timestamp = DateTime.UtcNow.ToString("yyyyMMddTHHmmssZ");
                var createdUtc = DateTime.UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ");
                var approvalRoot = Path.Combine(
                    resolvedWorkspaceRoot,
                    "records",
                    "registry",
                    "join-approvals",
                    timestamp + "-" + requestIdentityId + "-" + candidateDeviceId);
                Directory.CreateDirectory(approvalRoot);

                var packagedIdentityPath = CopyFile(identityRecordPath, Path.Combine(approvalRoot, "passport-identity-record.json"));
                var packagedRequestPath = CopyFile(requestPath, Path.Combine(approvalRoot, "device-join-request.json"));
                var packagedRequestSignaturePath = CopyFile(requestSignaturePath, Path.Combine(approvalRoot, "device-join-request-signature.json"));
                var packagedCandidatePublicKeyPath = CopyFile(candidatePublicKeyPath, Path.Combine(approvalRoot, "candidate-device-public-key.spki.der"));
                var packagedAuthorizerRecordPath = CopyFile(authorizerRecord.Value.RecordPath, Path.Combine(approvalRoot, "authorizer-device-credential-record.json"));
                var packagedAuthorizerPublicKeyPath = CopyFile(authorizerPublicKeyPath, Path.Combine(approvalRoot, "authorizer-device-public-key.spki.der"));

                var authorizationPath = Path.Combine(approvalRoot, "device-authorization.json");
                var authorizationRecord = new Dictionary<string, object?>
                {
                    ["schema_version"] = 1,
                    ["record_type"] = "device_authorization_record",
                    ["record_id"] = timestamp + "-" + candidateDeviceId + "-authorization",
                    ["created_utc"] = createdUtc,
                    ["archrealms_identity_id"] = requestIdentityId,
                    ["candidate_device_id"] = candidateDeviceId,
                    ["candidate_public_key_sha256"] = ComputeSha256(candidatePublicKeyBytes),
                    ["authorizer_device_id"] = authorizerDeviceId,
                    ["authorizer_public_key_path"] = Path.GetFileName(packagedAuthorizerPublicKeyPath),
                    ["authorizer_device_record_path"] = Path.GetFileName(packagedAuthorizerRecordPath),
                    ["authorized_scopes"] = new[] { "authenticate", "submit_registry_record", "publish_archive" },
                    ["join_request_path"] = Path.GetFileName(packagedRequestPath),
                    ["join_request_signature_path"] = Path.GetFileName(packagedRequestSignaturePath),
                    ["identity_record_path"] = Path.GetFileName(packagedIdentityPath),
                    ["summary"] = "Candidate device authorized by an existing active Passport device."
                };

                File.WriteAllText(authorizationPath, JsonSerializer.Serialize(authorizationRecord, JsonOptions));

                var authorizationBytes = File.ReadAllBytes(authorizationPath);
                byte[] authorizationSignatureBytes;
                authorizationSignatureBytes = PassportDeviceKeyStore.SignData(authorizerPrivateKeyPath, authorizationBytes);

                var authorizationSignaturePath = Path.Combine(approvalRoot, "device-authorization-signature.json");
                var authorizationSignatureRecord = new Dictionary<string, object?>
                {
                    ["schema_version"] = 1,
                    ["record_type"] = "device_authorization_signature",
                    ["record_id"] = timestamp + "-" + candidateDeviceId + "-authorization-signature",
                    ["created_utc"] = createdUtc,
                    ["archrealms_identity_id"] = requestIdentityId,
                    ["candidate_device_id"] = candidateDeviceId,
                    ["authorization_sha256"] = ComputeSha256(authorizationBytes),
                    ["signature_algorithm"] = "RSA_PKCS1_SHA256",
                    ["signature_base64"] = Convert.ToBase64String(authorizationSignatureBytes),
                    ["public_key_path"] = Path.GetFileName(packagedAuthorizerPublicKeyPath),
                    ["verified_with_public_key"] = VerifySignature(packagedAuthorizerPublicKeyPath, authorizationBytes, authorizationSignatureBytes),
                    ["summary"] = "Authorization record signed by the approving Passport device."
                };

                File.WriteAllText(authorizationSignaturePath, JsonSerializer.Serialize(authorizationSignatureRecord, JsonOptions));

                return new PassportJoinApprovalResult
                {
                    Succeeded = true,
                    Message = "Approved the join request and prepared a transferable authorization package.",
                    ApprovalPackagePath = approvalRoot,
                    AuthorizationRecordPath = authorizationPath,
                    AuthorizationSignaturePath = authorizationSignaturePath
                };
            }
            catch (Exception ex)
            {
                return FailedJoinApproval("Join request approval failed: " + ex.Message);
            }
        }

        public PassportJoinActivationResult ImportJoinApproval(
            string workspaceRoot,
            string joinApprovalPath,
            string pendingDeviceId,
            string pendingDeviceKeyPath)
        {
            try
            {
                if (string.IsNullOrWhiteSpace(pendingDeviceId) || string.IsNullOrWhiteSpace(pendingDeviceKeyPath))
                {
                    return FailedJoinActivation("A pending device and protected private key are required before importing approval.");
                }

                var resolvedWorkspaceRoot = PassportEnvironment.ResolveWorkspaceRoot(workspaceRoot);
                var approvalRoot = ResolvePackageRoot(joinApprovalPath);
                var identityRecordPath = Path.Combine(approvalRoot, "passport-identity-record.json");
                var requestPath = Path.Combine(approvalRoot, "device-join-request.json");
                var requestSignaturePath = Path.Combine(approvalRoot, "device-join-request-signature.json");
                var candidatePublicKeyPath = Path.Combine(approvalRoot, "candidate-device-public-key.spki.der");
                var authorizerRecordPath = Path.Combine(approvalRoot, "authorizer-device-credential-record.json");
                var authorizerPublicKeyPath = Path.Combine(approvalRoot, "authorizer-device-public-key.spki.der");
                var authorizationPath = Path.Combine(approvalRoot, "device-authorization.json");
                var authorizationSignaturePath = Path.Combine(approvalRoot, "device-authorization-signature.json");

                var identityRoot = ReadJson(identityRecordPath);
                var requestRoot = ReadJson(requestPath);
                var requestSignatureRoot = ReadJson(requestSignaturePath);
                var authorizerRecordRoot = ReadJson(authorizerRecordPath);
                var authorizationRoot = ReadJson(authorizationPath);
                var authorizationSignatureRoot = ReadJson(authorizationSignaturePath);

                var requestBytes = File.ReadAllBytes(requestPath);
                var requestSignatureBytes = Convert.FromBase64String(GetRequiredString(requestSignatureRoot, "signature_base64"));
                if (!VerifySignature(candidatePublicKeyPath, requestBytes, requestSignatureBytes))
                {
                    return FailedJoinActivation("The approval package contains an invalid join request signature.");
                }

                var authorizationBytes = File.ReadAllBytes(authorizationPath);
                var authorizationSignatureBytes = Convert.FromBase64String(GetRequiredString(authorizationSignatureRoot, "signature_base64"));
                if (!VerifySignature(authorizerPublicKeyPath, authorizationBytes, authorizationSignatureBytes))
                {
                    return FailedJoinActivation("The approval package contains an invalid authorization signature.");
                }

                var localPublicKeyBytes = PassportDeviceKeyStore.ExportPublicKey(pendingDeviceKeyPath);
                var localPublicKeySha256 = ComputeSha256(localPublicKeyBytes);
                var requestDeviceId = GetRequiredString(requestRoot, "device_id");
                if (!string.Equals(requestDeviceId, pendingDeviceId, StringComparison.Ordinal))
                {
                    return FailedJoinActivation("The approval package is for a different pending device.");
                }

                var requestedPublicKeySha256 = GetRequiredString(requestRoot, "public_key_sha256");
                var authorizedPublicKeySha256 = GetRequiredString(authorizationRoot, "candidate_public_key_sha256");
                if (!string.Equals(localPublicKeySha256, requestedPublicKeySha256, StringComparison.OrdinalIgnoreCase)
                    || !string.Equals(localPublicKeySha256, authorizedPublicKeySha256, StringComparison.OrdinalIgnoreCase))
                {
                    return FailedJoinActivation("The approval package does not match this device key.");
                }

                var identityId = GetRequiredString(requestRoot, "archrealms_identity_id");
                if (!string.Equals(identityId, GetRequiredString(authorizationRoot, "archrealms_identity_id"), StringComparison.Ordinal)
                    || !string.Equals(identityId, GetRequiredString(identityRoot, "archrealms_identity_id"), StringComparison.Ordinal))
                {
                    return FailedJoinActivation("The approval package contains mismatched identity records.");
                }

                if (!string.Equals(GetRequiredString(authorizerRecordRoot, "status"), "active", StringComparison.Ordinal))
                {
                    return FailedJoinActivation("The approving device record is not active.");
                }

                if (!string.Equals(GetRequiredString(authorizerRecordRoot, "archrealms_identity_id"), identityId, StringComparison.Ordinal))
                {
                    return FailedJoinActivation("The approving device belongs to a different identity.");
                }

                Directory.CreateDirectory(Path.Combine(resolvedWorkspaceRoot, "records", "registry", "identities"));
                Directory.CreateDirectory(Path.Combine(resolvedWorkspaceRoot, "records", "registry", "device-credentials"));
                Directory.CreateDirectory(Path.Combine(resolvedWorkspaceRoot, "records", "registry", "public-keys"));
                Directory.CreateDirectory(Path.Combine(resolvedWorkspaceRoot, "records", "registry", "device-authorizations"));

                var importedIdentityPath = CopyFile(identityRecordPath, Path.Combine(resolvedWorkspaceRoot, "records", "registry", "identities", Path.GetFileName(identityRecordPath)));
                var localPublicKeyPath = Path.Combine(resolvedWorkspaceRoot, "records", "registry", "public-keys", pendingDeviceId + ".spki.der");
                File.WriteAllBytes(localPublicKeyPath, localPublicKeyBytes);

                var importedAuthorizationRoot = Path.Combine(
                    resolvedWorkspaceRoot,
                    "records",
                    "registry",
                    "device-authorizations",
                    Path.GetFileName(approvalRoot));
                CopyDirectory(approvalRoot, importedAuthorizationRoot);

                var timestamp = DateTime.UtcNow.ToString("yyyyMMddTHHmmssZ");
                var createdUtc = DateTime.UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ");
                var activationRecordPath = Path.Combine(
                    resolvedWorkspaceRoot,
                    "records",
                    "registry",
                    "device-credentials",
                    timestamp + "-" + pendingDeviceId + ".json");

                var activationRecord = new Dictionary<string, object?>
                {
                    ["schema_version"] = 1,
                    ["record_type"] = "device_credential_record",
                    ["record_id"] = timestamp + "-" + pendingDeviceId,
                    ["created_utc"] = createdUtc,
                    ["effective_utc"] = createdUtc,
                    ["status"] = "active",
                    ["archrealms_identity_id"] = identityId,
                    ["device_id"] = pendingDeviceId,
                    ["device_label"] = GetRequiredString(requestRoot, "device_label"),
                    ["device_class"] = "desktop",
                    ["client_platform"] = "windows",
                    ["credential_origin"] = "passport-windows",
                    ["public_key_algorithm"] = "RSA",
                    ["public_key_format"] = "SPKI_DER",
                    ["public_key_path"] = ToWorkspaceRelativePath(resolvedWorkspaceRoot, localPublicKeyPath),
                    ["public_key_sha256"] = localPublicKeySha256,
                    ["authorized_scopes"] = new[] { "authenticate", "submit_registry_record", "publish_archive" },
                    ["authorization_mode"] = "delegated",
                    ["authorization_package_path"] = ToWorkspaceRelativePath(resolvedWorkspaceRoot, importedAuthorizationRoot),
                    ["authorization_record_path"] = ToWorkspaceRelativePath(resolvedWorkspaceRoot, Path.Combine(importedAuthorizationRoot, "device-authorization.json")),
                    ["authorizer_device_id"] = GetRequiredString(authorizationRoot, "authorizer_device_id"),
                    ["expires_utc"] = string.Empty,
                    ["revocation_record_id"] = string.Empty,
                    ["attestation_refs"] = Array.Empty<string>()
                };

                File.WriteAllText(activationRecordPath, JsonSerializer.Serialize(activationRecord, JsonOptions));

                return new PassportJoinActivationResult
                {
                    Succeeded = true,
                    Message = "Imported the approval package and activated this device under the existing Passport identity.",
                    IdentityId = identityId,
                    DeviceId = pendingDeviceId,
                    IdentityRecordPath = importedIdentityPath,
                    DeviceRecordPath = activationRecordPath,
                    AuthorizationRecordPath = Path.Combine(importedAuthorizationRoot, "device-authorization.json")
                };
            }
            catch (Exception ex)
            {
                return FailedJoinActivation("Join approval import failed: " + ex.Message);
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

                var deviceRecord = FindLatestDeviceRecord(resolvedWorkspaceRoot, identityId, deviceId, "active");
                if (deviceRecord == null)
                {
                    return FailedSubmission("The active device credential record could not be found.");
                }

                var deviceRecordPath = deviceRecord.Value.RecordPath;
                var publicKeyPath = ResolvePublicKeyPath(resolvedWorkspaceRoot, deviceRecord.Value.RootElement);
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

                CopyFile(identityRecordPath, Path.Combine(packageFilesRoot, "passport-identity-record.json"));
                CopyFile(deviceRecordPath, Path.Combine(packageFilesRoot, "device-credential-record.json"));
                CopyFile(publicKeyPath, Path.Combine(packageFilesRoot, "device-public-key.spki.der"));

                if (TryGetString(deviceRecord.Value.RootElement, "authorization_package_path", out var authorizationPackageRelative)
                    && !string.IsNullOrWhiteSpace(authorizationPackageRelative))
                {
                    var authorizationPackagePath = Path.Combine(resolvedWorkspaceRoot, authorizationPackageRelative.Replace('/', Path.DirectorySeparatorChar));
                    if (Directory.Exists(authorizationPackagePath))
                    {
                        CopyDirectory(authorizationPackagePath, Path.Combine(packageFilesRoot, "device-authorization"));
                    }
                }

                var manifestPath = Path.Combine(packageRoot, "manifest.json");
                var documents = EnumeratePackageDocuments(packageRoot, packageFilesRoot);
                var manifest = new Dictionary<string, object?>
                {
                    ["package_name"] = "passport-registry-submission",
                    ["package_id"] = packageId,
                    ["created_utc"] = createdUtc,
                    ["archrealms_identity_id"] = identityId,
                    ["device_id"] = deviceId,
                    ["documents"] = documents
                };

                File.WriteAllText(manifestPath, JsonSerializer.Serialize(manifest, JsonOptions));

                var manifestBytes = File.ReadAllBytes(manifestPath);
                byte[] signatureBytes;
                signatureBytes = PassportDeviceKeyStore.SignData(privateKeyPath, manifestBytes);

                var verified = VerifySignature(publicKeyPath, manifestBytes, signatureBytes);
                var signaturePath = Path.Combine(packageRoot, "manifest-signature.json");
                var signatureRecord = new Dictionary<string, object?>
                {
                    ["schema_version"] = 1,
                    ["record_type"] = "manifest_signature_record",
                    ["record_id"] = packageId + "-manifest-signature",
                    ["created_utc"] = createdUtc,
                    ["archrealms_identity_id"] = identityId,
                    ["device_id"] = deviceId,
                    ["manifest_sha256"] = ComputeSha256(manifestBytes),
                    ["signature_algorithm"] = "RSA_PKCS1_SHA256",
                    ["signature_base64"] = Convert.ToBase64String(signatureBytes),
                    ["public_key_path"] = "package/device-public-key.spki.der",
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
                    ["document_count"] = documents.Count,
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

        private static IReadOnlyList<Dictionary<string, object?>> EnumeratePackageDocuments(string packageRoot, string packageFilesRoot)
        {
            var documents = new List<Dictionary<string, object?>>();
            foreach (var file in Directory.GetFiles(packageFilesRoot, "*", SearchOption.AllDirectories).OrderBy(path => path, StringComparer.OrdinalIgnoreCase))
            {
                var bytes = File.ReadAllBytes(file);
                documents.Add(new Dictionary<string, object?>
                {
                    ["path"] = ToPackageRelativePath(packageRoot, file),
                    ["size_bytes"] = bytes.LongLength,
                    ["sha256"] = ComputeSha256(bytes)
                });
            }

            return documents;
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
                using (var document = JsonDocument.Parse(File.ReadAllText(file)))
                {
                    var root = document.RootElement.Clone();
                    if (Matches(root, "record_type", "device_credential_record")
                        && Matches(root, "status", requiredStatus)
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

        private static string ResolvePublicKeyPath(string workspaceRoot, JsonElement deviceRecord)
        {
            if (!TryGetString(deviceRecord, "public_key_path", out var publicKeyRelative))
            {
                return string.Empty;
            }

            return Path.Combine(workspaceRoot, publicKeyRelative.Replace('/', Path.DirectorySeparatorChar));
        }

        private static string ResolvePackageRoot(string path)
        {
            var resolved = Path.GetFullPath(path);
            return Directory.Exists(resolved) ? resolved : Path.GetDirectoryName(resolved) ?? resolved;
        }

        private static JsonElement ReadJson(string path)
        {
            using (var document = JsonDocument.Parse(File.ReadAllText(path)))
            {
                return document.RootElement.Clone();
            }
        }

        private static bool VerifySignature(string publicKeyPath, byte[] data, byte[] signatureBytes)
        {
            using (var rsa = RSA.Create())
            {
                rsa.ImportSubjectPublicKeyInfo(File.ReadAllBytes(publicKeyPath), out _);
                return rsa.VerifyData(data, signatureBytes, HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1);
            }
        }

        private static string GetRequiredString(JsonElement root, string propertyName)
        {
            if (!TryGetString(root, propertyName, out var value) || string.IsNullOrWhiteSpace(value))
            {
                throw new InvalidOperationException("Missing required property: " + propertyName);
            }

            return value;
        }

        private static string CopyFile(string sourcePath, string destinationPath)
        {
            Directory.CreateDirectory(Path.GetDirectoryName(destinationPath) ?? string.Empty);
            File.Copy(sourcePath, destinationPath, true);
            return destinationPath;
        }

        private static void CopyDirectory(string sourceDirectory, string destinationDirectory)
        {
            Directory.CreateDirectory(destinationDirectory);
            foreach (var directory in Directory.GetDirectories(sourceDirectory, "*", SearchOption.AllDirectories))
            {
                var relative = directory.Substring(sourceDirectory.Length).TrimStart(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
                Directory.CreateDirectory(Path.Combine(destinationDirectory, relative));
            }

            foreach (var file in Directory.GetFiles(sourceDirectory, "*", SearchOption.AllDirectories))
            {
                var relative = file.Substring(sourceDirectory.Length).TrimStart(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
                var destinationPath = Path.Combine(destinationDirectory, relative);
                Directory.CreateDirectory(Path.GetDirectoryName(destinationPath) ?? string.Empty);
                File.Copy(file, destinationPath, true);
            }
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
            return new PassportChallengeSignatureResult { Succeeded = false, Message = message };
        }

        private static PassportJoinApprovalResult FailedJoinApproval(string message)
        {
            return new PassportJoinApprovalResult { Succeeded = false, Message = message };
        }

        private static PassportJoinActivationResult FailedJoinActivation(string message)
        {
            return new PassportJoinActivationResult { Succeeded = false, Message = message };
        }

        private static PassportRegistrySubmissionResult FailedSubmission(string message)
        {
            return new PassportRegistrySubmissionResult { Succeeded = false, Message = message };
        }
    }
}
