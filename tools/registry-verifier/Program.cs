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
                    Console.Error.WriteLine("Usage: Archrealms.RegistryVerifier <package-root> [output-path]");
                    return 1;
                }

                var packageRoot = Path.GetFullPath(args[0]);
                var outputPath = args.Length > 1
                    ? Path.GetFullPath(args[1])
                    : Path.Combine(packageRoot, "verification-report.json");

                var manifestPath = Path.Combine(packageRoot, "manifest.json");
                var signaturePath = Path.Combine(packageRoot, "manifest-signature.json");
                var submissionRecordPath = Path.Combine(packageRoot, "submission.json");

                if (!File.Exists(manifestPath))
                {
                    throw new FileNotFoundException("The package does not contain manifest.json.", manifestPath);
                }

                if (!File.Exists(signaturePath))
                {
                    throw new FileNotFoundException("The package does not contain manifest-signature.json.", signaturePath);
                }

                var manifestBytes = File.ReadAllBytes(manifestPath);
                var manifestSha256 = ComputeSha256(manifestBytes);

                using var manifestDocument = JsonDocument.Parse(File.ReadAllText(manifestPath));
                using var signatureDocument = JsonDocument.Parse(File.ReadAllText(signaturePath));

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

                var publicKeyRelative = signatureDocument.RootElement.GetProperty("public_key_path").GetString() ?? string.Empty;
                var publicKeyPath = Path.Combine(packageRoot, publicKeyRelative.Replace('/', Path.DirectorySeparatorChar));
                if (!File.Exists(publicKeyPath))
                {
                    throw new FileNotFoundException("The package does not contain the public key referenced by the signature record.", publicKeyPath);
                }

                var signatureBase64 = signatureDocument.RootElement.GetProperty("signature_base64").GetString() ?? string.Empty;
                var signatureBytes = Convert.FromBase64String(signatureBase64);
                var signatureRecordManifestSha256 = signatureDocument.RootElement.GetProperty("manifest_sha256").GetString() ?? string.Empty;

                bool signatureValid;
                using (var rsa = RSA.Create())
                {
                    rsa.ImportSubjectPublicKeyInfo(File.ReadAllBytes(publicKeyPath), out _);
                    signatureValid = rsa.VerifyData(manifestBytes, signatureBytes, HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1);
                }

                var report = new Dictionary<string, object?>
                {
                    ["verified_utc"] = DateTime.UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ"),
                    ["package_root"] = packageRoot,
                    ["submission_record_present"] = File.Exists(submissionRecordPath),
                    ["manifest_sha256"] = manifestSha256,
                    ["manifest_hash_matches_signature_record"] = string.Equals(manifestSha256, signatureRecordManifestSha256, StringComparison.OrdinalIgnoreCase),
                    ["document_hashes_valid"] = allDocumentHashesValid,
                    ["signature_valid"] = signatureValid,
                    ["verified"] = allDocumentHashesValid
                        && signatureValid
                        && string.Equals(manifestSha256, signatureRecordManifestSha256, StringComparison.OrdinalIgnoreCase),
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
                return 0;
            }
            catch (Exception ex)
            {
                Console.Error.WriteLine(ex.Message);
                return 1;
            }
        }

        private static string ComputeSha256(byte[] bytes)
        {
            using var sha256 = SHA256.Create();
            return string.Concat(sha256.ComputeHash(bytes).Select(b => b.ToString("x2")));
        }
    }
}
