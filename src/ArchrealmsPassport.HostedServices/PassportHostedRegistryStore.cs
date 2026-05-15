using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using ArchrealmsPassport.Core.Protocol;
using ArchrealmsPassport.HostedServices.Contracts;

namespace ArchrealmsPassport.HostedServices;

public sealed class PassportHostedRegistryStore
{
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        WriteIndented = true
    };

    private readonly string root;

    public PassportHostedRegistryStore(string root)
    {
        this.root = Path.GetFullPath(root);
        Directory.CreateDirectory(PublicKeyRoot);
        Directory.CreateDirectory(RoleRoot);
    }

    private string PublicKeyRoot => Path.Combine(root, "records", "registry", "public-keys");

    private string RoleRoot => Path.Combine(root, "records", "registry", "admin-authority", "roles");

    public static PassportHostedRegistryStore FromDataRoot(string dataRoot)
    {
        return new PassportHostedRegistryStore(dataRoot);
    }

    public void SavePublicKey(string deviceId, byte[] publicKeySpkiDer)
    {
        File.WriteAllBytes(Path.Combine(PublicKeyRoot, NormalizeFileName(deviceId) + ".spki.der"), publicKeySpkiDer);
    }

    public bool TryGetPublicKey(string deviceId, out byte[] publicKeySpkiDer)
    {
        var path = Path.Combine(PublicKeyRoot, NormalizeFileName(deviceId) + ".spki.der");
        if (!File.Exists(path))
        {
            publicKeySpkiDer = Array.Empty<byte>();
            return false;
        }

        publicKeySpkiDer = File.ReadAllBytes(path);
        return true;
    }

    public void SaveRoleMembership(string roleRecordId, byte[] roleRecordBytes, string issuerDeviceId, byte[] signatureBytes)
    {
        var normalizedRoleRecordId = NormalizeFileName(roleRecordId);
        var rolePath = Path.Combine(RoleRoot, normalizedRoleRecordId + ".json");
        File.WriteAllBytes(rolePath, roleRecordBytes);
        var signature = new Dictionary<string, object?>
        {
            ["schema_version"] = 1,
            ["record_type"] = PassportRecordTypes.AdminRoleMembershipSignature,
            ["record_id"] = normalizedRoleRecordId + "-signature",
            ["created_utc"] = DateTimeOffset.UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ"),
            ["issuer_device_id"] = issuerDeviceId,
            ["role_membership_record_sha256"] = ComputeSha256(roleRecordBytes),
            ["signature_algorithm"] = "RSA_PKCS1_SHA256",
            ["signature_base64"] = Convert.ToBase64String(signatureBytes)
        };
        File.WriteAllText(
            Path.Combine(RoleRoot, normalizedRoleRecordId + ".signature.json"),
            JsonSerializer.Serialize(signature, JsonOptions),
            Encoding.UTF8);
    }

    public PassportHostedRecordResponse ValidateActiveRoleMembership(
        string authorityIdentityId,
        string deviceId,
        string actionType,
        string authorityScope)
    {
        if (!Directory.Exists(RoleRoot))
        {
            return Failed("No hosted admin role membership records were found.");
        }

        var normalizedAction = NormalizeSlug(actionType);
        var normalizedScope = NormalizeSlug(authorityScope);
        foreach (var file in Directory.GetFiles(RoleRoot, "*.json").OrderByDescending(Path.GetFileName))
        {
            if (file.EndsWith(".signature.json", StringComparison.OrdinalIgnoreCase))
            {
                continue;
            }

            var roleBytes = File.ReadAllBytes(file);
            using var document = JsonDocument.Parse(roleBytes);
            var role = document.RootElement;
            if (!Matches(role, "record_type", PassportRecordTypes.AdminRoleMembership)
                || !Matches(role, "status", "active")
                || !Matches(role, "authority_identity_id", authorityIdentityId)
                || !Matches(role, "device_id", deviceId)
                || !ReadBoolean(role, "dual_control_eligible")
                || ReadBoolean(role, "ai_approved")
                || IsExpired(role)
                || !AuthorizedArrayContains(role, "authorized_action_types", normalizedAction)
                || !AuthorizedArrayContains(role, "authorized_authority_scopes", normalizedScope))
            {
                continue;
            }

            var signature = ValidateRoleSignature(file, roleBytes, ReadString(role, "issued_by_device_id"));
            if (!signature.Succeeded)
            {
                return signature;
            }

            return new PassportHostedRecordResponse
            {
                Succeeded = true,
                Message = "Hosted admin role membership is active.",
                RecordId = ReadString(role, "record_id"),
                RecordSha256 = ComputeSha256(roleBytes)
            };
        }

        return Failed("No active hosted admin role membership permits " + normalizedAction + " for " + normalizedScope + ".");
    }

    private PassportHostedRecordResponse ValidateRoleSignature(string rolePath, byte[] roleBytes, string expectedIssuerDeviceId)
    {
        var roleHash = ComputeSha256(roleBytes);
        foreach (var candidate in Directory.GetFiles(RoleRoot, "*.signature.json").OrderBy(Path.GetFileName))
        {
            using var document = JsonDocument.Parse(File.ReadAllText(candidate));
            var signature = document.RootElement;
            if (!Matches(signature, "record_type", PassportRecordTypes.AdminRoleMembershipSignature)
                || !Matches(signature, "issuer_device_id", expectedIssuerDeviceId)
                || !string.Equals(ReadString(signature, "role_membership_record_sha256"), roleHash, StringComparison.OrdinalIgnoreCase))
            {
                continue;
            }

            if (!TryGetPublicKey(expectedIssuerDeviceId, out var publicKey))
            {
                return Failed("The hosted admin role issuer public key could not be found.");
            }

            var signatureBase64 = ReadString(signature, "signature_base64");
            if (string.IsNullOrWhiteSpace(signatureBase64))
            {
                return Failed("The hosted admin role membership signature is missing.");
            }

            if (!Verify(publicKey, roleBytes, Convert.FromBase64String(signatureBase64)))
            {
                return Failed("The hosted admin role membership signature verification failed.");
            }

            return new PassportHostedRecordResponse
            {
                Succeeded = true,
                Message = "Hosted admin role membership signature verified.",
                RecordId = Path.GetFileNameWithoutExtension(rolePath),
                RecordSha256 = roleHash
            };
        }

        return Failed("A hosted admin role membership signature could not be found.");
    }

    private static bool Verify(byte[] publicKeySpkiDer, byte[] payload, byte[] signature)
    {
        using var rsa = RSA.Create();
        rsa.ImportSubjectPublicKeyInfo(publicKeySpkiDer, out _);
        return rsa.VerifyData(payload, signature, HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1);
    }

    private static bool Matches(JsonElement root, string propertyName, string expected)
    {
        return string.Equals(ReadString(root, propertyName), expected, StringComparison.Ordinal);
    }

    private static string ReadString(JsonElement root, string propertyName)
    {
        return root.TryGetProperty(propertyName, out var property) && property.ValueKind == JsonValueKind.String
            ? property.GetString() ?? string.Empty
            : string.Empty;
    }

    private static bool ReadBoolean(JsonElement root, string propertyName)
    {
        return root.TryGetProperty(propertyName, out var property)
            && (property.ValueKind == JsonValueKind.True
                || (property.ValueKind == JsonValueKind.String && bool.TryParse(property.GetString(), out var parsed) && parsed));
    }

    private static bool AuthorizedArrayContains(JsonElement root, string propertyName, string expected)
    {
        if (!root.TryGetProperty(propertyName, out var property) || property.ValueKind != JsonValueKind.Array)
        {
            return false;
        }

        foreach (var item in property.EnumerateArray())
        {
            if (item.ValueKind != JsonValueKind.String)
            {
                continue;
            }

            var value = item.GetString() ?? string.Empty;
            if (string.Equals(value, "*", StringComparison.Ordinal) || string.Equals(value, expected, StringComparison.Ordinal))
            {
                return true;
            }
        }

        return false;
    }

    private static bool IsExpired(JsonElement root)
    {
        var expiresUtc = ReadString(root, "expires_utc");
        return !string.IsNullOrWhiteSpace(expiresUtc)
            && DateTimeOffset.TryParse(expiresUtc, out var parsed)
            && parsed.ToUniversalTime() <= DateTimeOffset.UtcNow;
    }

    private static string NormalizeSlug(string value)
    {
        var normalized = (value ?? string.Empty).Trim().ToLowerInvariant().Replace(" ", "_").Replace("-", "_");
        return normalized.Length > 96 ? normalized[..96] : normalized;
    }

    private static string NormalizeFileName(string value)
    {
        var normalized = new string((value ?? string.Empty)
            .Select(character => char.IsLetterOrDigit(character) || character is '-' or '_' or '.' ? character : '_')
            .ToArray());
        return string.IsNullOrWhiteSpace(normalized) ? "record" : normalized;
    }

    private static string ComputeSha256(byte[] value)
    {
        return Convert.ToHexString(SHA256.HashData(value)).ToLowerInvariant();
    }

    private static PassportHostedRecordResponse Failed(string message)
    {
        return new PassportHostedRecordResponse { Succeeded = false, Message = message };
    }
}
