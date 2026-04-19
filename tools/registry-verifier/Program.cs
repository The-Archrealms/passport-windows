using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Security.Cryptography;
using System.Text.Json;

namespace Archrealms.RegistryVerifier
{
    internal static class Program
    {
        private static int Main(string[] args)
        {
            try
            {
                if (args.Length < 1)
                {
                    Console.Error.WriteLine("Usage: Archrealms.RegistryVerifier <package-root> [output-path] [trusted-workspace-root]");
                    return 1;
                }

                var packageRoot = Path.GetFullPath(args[0]);
                var outputPath = args.Length > 1
                    ? Path.GetFullPath(args[1])
                    : Path.Combine(packageRoot, "verification-report.json");
                var trustedWorkspaceRoot = args.Length > 2 && !string.IsNullOrWhiteSpace(args[2])
                    ? Path.GetFullPath(args[2])
                    : string.Empty;

                var manifestPath = Path.Combine(packageRoot, "manifest.json");
                var signaturePath = Path.Combine(packageRoot, "manifest-signature.json");
                var submissionRecordPath = Path.Combine(packageRoot, "submission.json");
                var deviceRecordPath = Path.Combine(packageRoot, "package", "device-credential-record.json");
                var devicePublicKeyPath = Path.Combine(packageRoot, "package", "device-public-key.spki.der");

                if (!File.Exists(manifestPath) || !File.Exists(signaturePath) || !File.Exists(deviceRecordPath) || !File.Exists(devicePublicKeyPath))
                {
                    throw new FileNotFoundException("The package is missing required registry submission files.");
                }

                var manifestBytes = File.ReadAllBytes(manifestPath);
                var manifestSha256 = ComputeSha256(manifestBytes);

                using var manifestDocument = JsonDocument.Parse(File.ReadAllText(manifestPath));
                using var signatureDocument = JsonDocument.Parse(File.ReadAllText(signaturePath));
                using var deviceRecordDocument = JsonDocument.Parse(File.ReadAllText(deviceRecordPath));

                var documents = new List<Dictionary<string, object?>>();
                var allDocumentHashesValid = true;
                foreach (var document in manifestDocument.RootElement.GetProperty("documents").EnumerateArray())
                {
                    var relativePath = document.GetProperty("path").GetString() ?? string.Empty;
                    var documentPath = Path.Combine(packageRoot, relativePath.Replace('/', Path.DirectorySeparatorChar));
                    var exists = File.Exists(documentPath);
                    var expectedSha256 = document.GetProperty("sha256").GetString() ?? string.Empty;
                    var actualSha256 = exists ? ComputeSha256(File.ReadAllBytes(documentPath)) : string.Empty;
                    var hashMatches = exists && string.Equals(actualSha256, expectedSha256, StringComparison.OrdinalIgnoreCase);
                    if (!hashMatches)
                    {
                        allDocumentHashesValid = false;
                    }

                    documents.Add(new Dictionary<string, object?>
                    {
                        ["path"] = relativePath,
                        ["exists"] = exists,
                        ["expected_sha256"] = expectedSha256,
                        ["actual_sha256"] = actualSha256,
                        ["hash_matches"] = hashMatches
                    });
                }

                var signatureBase64 = signatureDocument.RootElement.GetProperty("signature_base64").GetString() ?? string.Empty;
                var signatureBytes = Convert.FromBase64String(signatureBase64);
                var signatureRecordManifestSha256 = signatureDocument.RootElement.GetProperty("manifest_sha256").GetString() ?? string.Empty;
                var signatureValid = VerifySignature(devicePublicKeyPath, manifestBytes, signatureBytes);
                var integrityVerified = allDocumentHashesValid
                    && signatureValid
                    && string.Equals(manifestSha256, signatureRecordManifestSha256, StringComparison.OrdinalIgnoreCase);

                var authorizationMode = TryGetString(deviceRecordDocument.RootElement, "authorization_mode", out var mode)
                    ? mode
                    : "unspecified";
                var authorizationReport = VerifyAuthorization(
                    packageRoot,
                    trustedWorkspaceRoot,
                    deviceRecordDocument.RootElement,
                    devicePublicKeyPath,
                    authorizationMode);

                var report = new Dictionary<string, object?>
                {
                    ["verified_utc"] = DateTime.UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ"),
                    ["package_root"] = packageRoot,
                    ["trusted_workspace_root"] = string.IsNullOrWhiteSpace(trustedWorkspaceRoot) ? null : trustedWorkspaceRoot,
                    ["submission_record_present"] = File.Exists(submissionRecordPath),
                    ["manifest_sha256"] = manifestSha256,
                    ["manifest_hash_matches_signature_record"] = string.Equals(manifestSha256, signatureRecordManifestSha256, StringComparison.OrdinalIgnoreCase),
                    ["document_hashes_valid"] = allDocumentHashesValid,
                    ["signature_valid"] = signatureValid,
                    ["integrity_verified"] = integrityVerified,
                    ["authorization_mode"] = authorizationMode,
                    ["authorization_integrity_verified"] = authorizationReport.AuthorizationIntegrityVerified,
                    ["authorization_anchored"] = authorizationReport.AuthorizationAnchored,
                    ["authorization_summary"] = authorizationReport.Summary,
                    ["verified"] = integrityVerified && authorizationReport.Verified,
                    ["documents"] = documents
                };

                var outputDirectory = Path.GetDirectoryName(outputPath);
                if (!string.IsNullOrWhiteSpace(outputDirectory))
                {
                    Directory.CreateDirectory(outputDirectory);
                }

                File.WriteAllText(outputPath, JsonSerializer.Serialize(report, new JsonSerializerOptions { WriteIndented = true }) + Environment.NewLine);

                Console.WriteLine();
                Console.WriteLine("Archrealms registry submission verification recorded:");
                Console.WriteLine("  Package  : " + packageRoot);
                Console.WriteLine("  Report   : " + outputPath);
                Console.WriteLine("  Verified : " + report["verified"]);
                Console.WriteLine("  Auth     : " + authorizationReport.Summary);
                return 0;
            }
            catch (Exception ex)
            {
                Console.Error.WriteLine(ex.Message);
                return 1;
            }
        }

        private static AuthorizationVerificationResult VerifyAuthorization(
            string packageRoot,
            string trustedWorkspaceRoot,
            JsonElement deviceRecordRoot,
            string devicePublicKeyPath,
            string authorizationMode)
        {
            if (string.Equals(authorizationMode, "genesis", StringComparison.Ordinal))
            {
                return new AuthorizationVerificationResult(true, true, true, "genesis-self-asserted");
            }

            if (!string.Equals(authorizationMode, "delegated", StringComparison.Ordinal))
            {
                return new AuthorizationVerificationResult(false, false, false, "unsupported-authorization-mode");
            }

            var authorizationRoot = Path.Combine(packageRoot, "package", "device-authorization");
            var requestPath = Path.Combine(authorizationRoot, "device-join-request.json");
            var requestSignaturePath = Path.Combine(authorizationRoot, "device-join-request-signature.json");
            var candidatePublicKeyPath = Path.Combine(authorizationRoot, "candidate-device-public-key.spki.der");
            var authorizerRecordPath = Path.Combine(authorizationRoot, "authorizer-device-credential-record.json");
            var authorizerPublicKeyPath = Path.Combine(authorizationRoot, "authorizer-device-public-key.spki.der");
            var authorizationPath = Path.Combine(authorizationRoot, "device-authorization.json");
            var authorizationSignaturePath = Path.Combine(authorizationRoot, "device-authorization-signature.json");

            var requiredPaths = new[]
            {
                requestPath, requestSignaturePath, candidatePublicKeyPath,
                authorizerRecordPath, authorizerPublicKeyPath, authorizationPath, authorizationSignaturePath
            };

            if (requiredPaths.Any(path => !File.Exists(path)))
            {
                return new AuthorizationVerificationResult(false, false, false, "missing-authorization-materials");
            }

            using var requestDocument = JsonDocument.Parse(File.ReadAllText(requestPath));
            using var requestSignatureDocument = JsonDocument.Parse(File.ReadAllText(requestSignaturePath));
            using var authorizerRecordDocument = JsonDocument.Parse(File.ReadAllText(authorizerRecordPath));
            using var authorizationDocument = JsonDocument.Parse(File.ReadAllText(authorizationPath));
            using var authorizationSignatureDocument = JsonDocument.Parse(File.ReadAllText(authorizationSignaturePath));

            var requestBytes = File.ReadAllBytes(requestPath);
            var requestSignatureBytes = Convert.FromBase64String(requestSignatureDocument.RootElement.GetProperty("signature_base64").GetString() ?? string.Empty);
            var requestSignatureValid = VerifySignature(candidatePublicKeyPath, requestBytes, requestSignatureBytes);

            var authorizationBytes = File.ReadAllBytes(authorizationPath);
            var authorizationSignatureBytes = Convert.FromBase64String(authorizationSignatureDocument.RootElement.GetProperty("signature_base64").GetString() ?? string.Empty);
            var authorizationSignatureValid = VerifySignature(authorizerPublicKeyPath, authorizationBytes, authorizationSignatureBytes);

            var candidatePublicKeySha256 = ComputeSha256(File.ReadAllBytes(candidatePublicKeyPath));
            var devicePublicKeySha256 = ComputeSha256(File.ReadAllBytes(devicePublicKeyPath));
            var authorizerPublicKeySha256 = ComputeSha256(File.ReadAllBytes(authorizerPublicKeyPath));

            var requestMatches = string.Equals(
                    GetRequiredString(requestDocument.RootElement, "device_id"),
                    GetRequiredString(deviceRecordRoot, "device_id"),
                    StringComparison.Ordinal)
                && string.Equals(
                    GetRequiredString(requestDocument.RootElement, "archrealms_identity_id"),
                    GetRequiredString(deviceRecordRoot, "archrealms_identity_id"),
                    StringComparison.Ordinal)
                && string.Equals(
                    GetRequiredString(requestDocument.RootElement, "public_key_sha256"),
                    candidatePublicKeySha256,
                    StringComparison.OrdinalIgnoreCase)
                && string.Equals(candidatePublicKeySha256, devicePublicKeySha256, StringComparison.OrdinalIgnoreCase);

            var authorizerRecordMatches = string.Equals(GetRequiredString(authorizerRecordDocument.RootElement, "status"), "active", StringComparison.Ordinal)
                && string.Equals(
                    GetRequiredString(authorizerRecordDocument.RootElement, "archrealms_identity_id"),
                    GetRequiredString(deviceRecordRoot, "archrealms_identity_id"),
                    StringComparison.Ordinal)
                && string.Equals(
                    GetRequiredString(authorizerRecordDocument.RootElement, "device_id"),
                    GetRequiredString(authorizationDocument.RootElement, "authorizer_device_id"),
                    StringComparison.Ordinal)
                && string.Equals(
                    GetRequiredString(authorizerRecordDocument.RootElement, "public_key_sha256"),
                    authorizerPublicKeySha256,
                    StringComparison.OrdinalIgnoreCase);

            var authorizationMatches = string.Equals(
                    GetRequiredString(authorizationDocument.RootElement, "candidate_device_id"),
                    GetRequiredString(deviceRecordRoot, "device_id"),
                    StringComparison.Ordinal)
                && string.Equals(
                    GetRequiredString(authorizationDocument.RootElement, "candidate_public_key_sha256"),
                    devicePublicKeySha256,
                    StringComparison.OrdinalIgnoreCase)
                && string.Equals(
                    GetRequiredString(authorizationDocument.RootElement, "archrealms_identity_id"),
                    GetRequiredString(deviceRecordRoot, "archrealms_identity_id"),
                    StringComparison.Ordinal)
                && string.Equals(
                    GetRequiredString(authorizationSignatureDocument.RootElement, "authorization_sha256"),
                    ComputeSha256(authorizationBytes),
                    StringComparison.OrdinalIgnoreCase);

            var authorizationIntegrityVerified = requestSignatureValid
                && authorizationSignatureValid
                && requestMatches
                && authorizerRecordMatches
                && authorizationMatches;

            var authorizationAnchored = false;
            if (authorizationIntegrityVerified && !string.IsNullOrWhiteSpace(trustedWorkspaceRoot))
            {
                authorizationAnchored = HasAnchoredAuthorizer(
                    trustedWorkspaceRoot,
                    GetRequiredString(authorizationDocument.RootElement, "archrealms_identity_id"),
                    GetRequiredString(authorizationDocument.RootElement, "authorizer_device_id"),
                    authorizerPublicKeySha256);
            }

            var verified = authorizationMode == "delegated"
                ? authorizationIntegrityVerified && authorizationAnchored
                : authorizationIntegrityVerified;

            var summary = !authorizationIntegrityVerified
                ? "delegated-invalid"
                : authorizationAnchored
                    ? "delegated-anchored"
                    : "delegated-unanchored";

            return new AuthorizationVerificationResult(verified, authorizationIntegrityVerified, authorizationAnchored, summary);
        }

        private static bool HasAnchoredAuthorizer(
            string trustedWorkspaceRoot,
            string identityId,
            string authorizerDeviceId,
            string authorizerPublicKeySha256)
        {
            var deviceRoot = Path.Combine(trustedWorkspaceRoot, "records", "registry", "device-credentials");
            if (!Directory.Exists(deviceRoot))
            {
                return false;
            }

            foreach (var file in Directory.GetFiles(deviceRoot, "*.json"))
            {
                using var document = JsonDocument.Parse(File.ReadAllText(file));
                var root = document.RootElement;
                if (TryGetString(root, "record_type", out var recordType)
                    && TryGetString(root, "status", out var status)
                    && TryGetString(root, "archrealms_identity_id", out var recordIdentityId)
                    && TryGetString(root, "device_id", out var recordDeviceId)
                    && TryGetString(root, "public_key_sha256", out var publicKeySha256)
                    && string.Equals(recordType, "device_credential_record", StringComparison.Ordinal)
                    && string.Equals(status, "active", StringComparison.Ordinal)
                    && string.Equals(recordIdentityId, identityId, StringComparison.Ordinal)
                    && string.Equals(recordDeviceId, authorizerDeviceId, StringComparison.Ordinal)
                    && string.Equals(publicKeySha256, authorizerPublicKeySha256, StringComparison.OrdinalIgnoreCase))
                {
                    return true;
                }
            }

            return false;
        }

        private static bool VerifySignature(string publicKeyPath, byte[] data, byte[] signatureBytes)
        {
            using var rsa = RSA.Create();
            rsa.ImportSubjectPublicKeyInfo(File.ReadAllBytes(publicKeyPath), out _);
            return rsa.VerifyData(data, signatureBytes, HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1);
        }

        private static string GetRequiredString(JsonElement root, string propertyName)
        {
            if (!TryGetString(root, propertyName, out var value) || string.IsNullOrWhiteSpace(value))
            {
                throw new InvalidOperationException("Missing required property: " + propertyName);
            }

            return value;
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

        private static string ComputeSha256(byte[] bytes)
        {
            using var sha256 = SHA256.Create();
            return string.Concat(sha256.ComputeHash(bytes).Select(b => b.ToString("x2")));
        }

        private sealed class AuthorizationVerificationResult
        {
            public AuthorizationVerificationResult(bool verified, bool authorizationIntegrityVerified, bool authorizationAnchored, string summary)
            {
                Verified = verified;
                AuthorizationIntegrityVerified = authorizationIntegrityVerified;
                AuthorizationAnchored = authorizationAnchored;
                Summary = summary;
            }

            public bool Verified { get; }
            public bool AuthorizationIntegrityVerified { get; }
            public bool AuthorizationAnchored { get; }
            public string Summary { get; }
        }
    }
}
