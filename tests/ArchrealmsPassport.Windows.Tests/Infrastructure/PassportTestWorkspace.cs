using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace ArchrealmsPassport.Windows.Tests.Infrastructure;

internal sealed class PassportTestWorkspace : IDisposable
{
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        WriteIndented = true
    };

    private PassportTestWorkspace(
        string root,
        string identityId,
        string deviceId,
        string keyReferencePath,
        string publicKeyPath,
        byte[] publicKeyBytes)
    {
        Root = root;
        IdentityId = identityId;
        DeviceId = deviceId;
        KeyReferencePath = keyReferencePath;
        PublicKeyPath = publicKeyPath;
        PublicKeyBytes = publicKeyBytes;
    }

    public string Root { get; }

    public string IdentityId { get; }

    public string DeviceId { get; }

    public string KeyReferencePath { get; }

    public string PublicKeyPath { get; }

    public byte[] PublicKeyBytes { get; }

    public static PassportTestWorkspace Create()
    {
        var root = Path.Combine(Path.GetTempPath(), "archrealms-passport-tests", Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        CreateRegistryFolders(root);

        var timestamp = DateTime.UtcNow.ToString("yyyyMMddTHHmmssZ");
        var createdUtc = DateTime.UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ");
        var identityId = "identity-test-" + Guid.NewGuid().ToString("N")[..10];
        var deviceId = "device-test-" + Guid.NewGuid().ToString("N")[..10];

        using var rsa = RSA.Create(2048);
        var publicKeyBytes = rsa.ExportSubjectPublicKeyInfo();
        var privateKeyBytes = rsa.ExportPkcs8PrivateKey();
        var protectedPrivateKeyBytes = ProtectedData.Protect(
            privateKeyBytes,
            Encoding.UTF8.GetBytes("ArchrealmsPassportWindows"),
            DataProtectionScope.CurrentUser);
        CryptographicOperations.ZeroMemory(privateKeyBytes);

        var keyReferencePath = Path.Combine(root, deviceId + ".pkcs8.protected");
        File.WriteAllBytes(keyReferencePath, protectedPrivateKeyBytes);

        var publicKeyPath = Path.Combine(root, "records", "registry", "public-keys", deviceId + ".spki.der");
        File.WriteAllBytes(publicKeyPath, publicKeyBytes);

        var identityRecordPath = Path.Combine(root, "records", "registry", "identities", timestamp + "-" + identityId + ".json");
        WriteJson(identityRecordPath, new Dictionary<string, object?>
        {
            ["schema_version"] = 1,
            ["record_type"] = "passport_identity_record",
            ["record_id"] = timestamp + "-" + identityId,
            ["created_utc"] = createdUtc,
            ["effective_utc"] = createdUtc,
            ["status"] = "active",
            ["archrealms_identity_id"] = identityId,
            ["display_name"] = "Test Passport Identity",
            ["identity_mode"] = "named",
            ["citizenship_class"] = "citizen",
            ["declared_scope"] = "personal",
            ["public_biography"] = string.Empty,
            ["recovery_authority"] = new Dictionary<string, object?>
            {
                ["method"] = "test-fixture",
                ["reference"] = deviceId
            },
            ["attestation_refs"] = Array.Empty<string>(),
            ["supersedes_record_id"] = string.Empty,
            ["summary"] = "Test identity fixture."
        });

        var deviceRecordPath = Path.Combine(root, "records", "registry", "device-credentials", timestamp + "-" + deviceId + ".json");
        WriteJson(deviceRecordPath, new Dictionary<string, object?>
        {
            ["schema_version"] = 1,
            ["record_type"] = "device_credential_record",
            ["record_id"] = timestamp + "-" + deviceId,
            ["created_utc"] = createdUtc,
            ["effective_utc"] = createdUtc,
            ["status"] = "active",
            ["archrealms_identity_id"] = identityId,
            ["device_id"] = deviceId,
            ["device_label"] = "Test Device",
            ["device_class"] = "desktop",
            ["client_platform"] = "windows",
            ["credential_origin"] = "passport-windows",
            ["public_key_algorithm"] = "RSA",
            ["public_key_format"] = "SPKI_DER",
            ["public_key_path"] = ToWorkspaceRelativePath(root, publicKeyPath),
            ["public_key_sha256"] = ComputeSha256(publicKeyBytes),
            ["authorized_scopes"] = new[] { "authenticate", "submit_registry_record", "publish_archive" },
            ["authorization_mode"] = "test-fixture",
            ["authorization_package_path"] = string.Empty,
            ["authorization_record_path"] = string.Empty,
            ["authorizer_device_id"] = string.Empty,
            ["expires_utc"] = string.Empty,
            ["revocation_record_id"] = string.Empty,
            ["attestation_refs"] = Array.Empty<string>()
        });

        return new PassportTestWorkspace(root, identityId, deviceId, keyReferencePath, publicKeyPath, publicKeyBytes);
    }

    public string WriteProofSource(string fileName, string content)
    {
        var path = Path.Combine(Root, fileName);
        File.WriteAllText(path, content, Encoding.UTF8);
        return path;
    }

    public string ResolveWorkspaceRelativePath(string path)
    {
        var normalized = path.Replace('/', Path.DirectorySeparatorChar);
        return Path.IsPathRooted(normalized)
            ? Path.GetFullPath(normalized)
            : Path.GetFullPath(Path.Combine(Root, normalized));
    }

    public bool SignedRecordVerifies(string recordPath)
    {
        using var document = JsonDocument.Parse(File.ReadAllText(recordPath));
        var root = document.RootElement;
        if (!root.TryGetProperty("signature", out var signatureElement))
        {
            return false;
        }

        var payloadPath = ResolveWorkspaceRelativePath(GetString(signatureElement, "signed_payload_path"));
        var signaturePath = ResolveWorkspaceRelativePath(GetString(signatureElement, "signature_path"));
        var expectedPayloadSha256 = GetString(signatureElement, "signed_payload_sha256");
        if (!File.Exists(payloadPath) || !File.Exists(signaturePath))
        {
            return false;
        }

        var payloadBytes = File.ReadAllBytes(payloadPath);
        if (!string.Equals(ComputeSha256(payloadBytes), expectedPayloadSha256, StringComparison.OrdinalIgnoreCase))
        {
            return false;
        }

        using var rsa = RSA.Create();
        rsa.ImportSubjectPublicKeyInfo(PublicKeyBytes, out _);
        return rsa.VerifyData(payloadBytes, File.ReadAllBytes(signaturePath), HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1);
    }

    public string CreateVerifiedMeteringPackage(string proofRecordPath, string proofRecordId)
    {
        var packageRoot = Path.Combine(Root, "records", "passport", "metering", "packages", "test-metering-package");
        var packageContentRoot = Path.Combine(packageRoot, "package");
        var sourceRecordRoot = Path.Combine(packageContentRoot, "source-records");
        Directory.CreateDirectory(sourceRecordRoot);

        var packagedProofPath = Path.Combine(sourceRecordRoot, "storage-epoch-proof.json");
        File.Copy(proofRecordPath, packagedProofPath, true);

        var reportPath = Path.Combine(packageContentRoot, "metering-report.json");
        WriteJson(reportPath, new Dictionary<string, object?>
        {
            ["report_id"] = "test-metering-report",
            ["record_id"] = "test-metering-report",
            ["accepted_proof_count"] = 1,
            ["rejected_proof_count"] = 0,
            ["verified_replicated_byte_seconds"] = 512,
            ["records"] = new[]
            {
                new Dictionary<string, object?>
                {
                    ["record_type"] = "storage_epoch_proof_record",
                    ["record_id"] = proofRecordId,
                    ["record_path"] = ToWorkspaceRelativePath(Root, proofRecordPath)
                }
            }
        });

        var documents = Directory
            .EnumerateFiles(packageContentRoot, "*", SearchOption.AllDirectories)
            .OrderBy(path => path, StringComparer.OrdinalIgnoreCase)
            .Select(path => new Dictionary<string, object?>
            {
                ["path"] = ToPackageRelativePath(packageRoot, path),
                ["size_bytes"] = new FileInfo(path).Length,
                ["sha256"] = ComputeFileSha256(path)
            })
            .ToArray();

        var manifestPath = Path.Combine(packageRoot, "manifest.json");
        WriteJson(manifestPath, new Dictionary<string, object?>
        {
            ["package_name"] = "passport-metering-report-package",
            ["package_id"] = "test-metering-package",
            ["created_utc"] = DateTime.UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ"),
            ["workspace_root"] = Root,
            ["metering_report_path"] = "package/metering-report.json",
            ["source_records"] = new[]
            {
                new Dictionary<string, object?>
                {
                    ["record_type"] = "storage_epoch_proof_record",
                    ["record_id"] = proofRecordId,
                    ["record_path"] = "package/source-records/storage-epoch-proof.json"
                }
            },
            ["documents"] = documents
        });

        WriteJson(Path.Combine(packageRoot, "metering-package-verification-report.json"), new Dictionary<string, object?>
        {
            ["verified_utc"] = DateTime.UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ"),
            ["package_root"] = packageRoot,
            ["package_name"] = "passport-metering-report-package",
            ["package_id"] = "test-metering-package",
            ["metering_report_present"] = true,
            ["document_hashes_valid"] = true,
            ["verified"] = true,
            ["accepted_proof_count"] = 1,
            ["rejected_proof_count"] = 0,
            ["settlement_status"] = "not_settled",
            ["documents"] = documents
        });

        return packageRoot;
    }

    public void Dispose()
    {
        try
        {
            if (Directory.Exists(Root))
            {
                Directory.Delete(Root, true);
            }
        }
        catch
        {
        }
    }

    public static JsonElement ReadJson(string path)
    {
        using var document = JsonDocument.Parse(File.ReadAllText(path));
        return document.RootElement.Clone();
    }

    public static string GetString(JsonElement root, string propertyName)
    {
        return root.TryGetProperty(propertyName, out var property) && property.ValueKind == JsonValueKind.String
            ? property.GetString() ?? string.Empty
            : string.Empty;
    }

    public static long GetInt64(JsonElement root, string propertyName)
    {
        return root.TryGetProperty(propertyName, out var property) && property.TryGetInt64(out var value)
            ? value
            : 0;
    }

    public static string ComputeFileSha256(string path)
    {
        return ComputeSha256(File.ReadAllBytes(path));
    }

    private static void CreateRegistryFolders(string root)
    {
        Directory.CreateDirectory(Path.Combine(root, "records", "registry", "identities"));
        Directory.CreateDirectory(Path.Combine(root, "records", "registry", "device-credentials"));
        Directory.CreateDirectory(Path.Combine(root, "records", "registry", "public-keys"));
    }

    private static void WriteJson(string path, object value)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(path) ?? string.Empty);
        File.WriteAllText(path, JsonSerializer.Serialize(value, JsonOptions), Encoding.UTF8);
    }

    private static string ToWorkspaceRelativePath(string workspaceRoot, string path)
    {
        var root = Path.GetFullPath(workspaceRoot).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
        var fullPath = Path.GetFullPath(path);
        return fullPath[root.Length..].TrimStart(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar).Replace(Path.DirectorySeparatorChar, '/');
    }

    private static string ToPackageRelativePath(string packageRoot, string path)
    {
        var root = Path.GetFullPath(packageRoot).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
        var fullPath = Path.GetFullPath(path);
        return fullPath[root.Length..].TrimStart(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar).Replace(Path.DirectorySeparatorChar, '/');
    }

    private static string ComputeSha256(byte[] value)
    {
        return Convert.ToHexString(SHA256.HashData(value)).ToLowerInvariant();
    }
}
