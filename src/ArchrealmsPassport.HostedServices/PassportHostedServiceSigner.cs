using System.Security.Cryptography;
using System.Text.Json;
using ArchrealmsPassport.HostedServices.Contracts;

namespace ArchrealmsPassport.HostedServices;

public sealed class PassportHostedServiceSigner
{
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        WriteIndented = true
    };

    private readonly string keyPath;

    public PassportHostedServiceSigner(string keyPath)
    {
        this.keyPath = Path.GetFullPath(keyPath);
        Directory.CreateDirectory(Path.GetDirectoryName(this.keyPath) ?? string.Empty);
    }

    public static PassportHostedServiceSigner FromDataRoot(string dataRoot)
    {
        var configuredPath = Environment.GetEnvironmentVariable("ARCHREALMS_PASSPORT_HOSTED_SIGNING_KEY_PATH");
        var keyPath = string.IsNullOrWhiteSpace(configuredPath)
            ? Path.Combine(dataRoot, "keys", "hosted-service-signing-key.pkcs8")
            : configuredPath;
        return new PassportHostedServiceSigner(keyPath);
    }

    public PassportHostedRecordResponse Sign(PassportHostedRecordResponse response, string purpose)
    {
        if (!response.Succeeded || response.Record == null)
        {
            return response;
        }

        using var rsa = LoadOrCreateKey();
        var publicKey = rsa.ExportSubjectPublicKeyInfo();
        var record = new Dictionary<string, object?>(response.Record, StringComparer.Ordinal);
        record.Remove("service_signature");

        var payloadBytes = JsonSerializer.SerializeToUtf8Bytes(record, JsonOptions);
        var signature = rsa.SignData(payloadBytes, HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1);
        record["service_signature"] = new Dictionary<string, object?>
        {
            ["signature_algorithm"] = "RSA_PKCS1_SHA256",
            ["signature_purpose"] = string.IsNullOrWhiteSpace(purpose) ? "hosted_record" : purpose.Trim(),
            ["signer_id"] = "archrealms-passport-hosted-services",
            ["signed_record_sha256"] = ComputeSha256(payloadBytes),
            ["signature_base64"] = Convert.ToBase64String(signature),
            ["public_key_spki_der_base64"] = Convert.ToBase64String(publicKey),
            ["public_key_sha256"] = ComputeSha256(publicKey)
        };

        var finalHash = ComputeSha256(JsonSerializer.SerializeToUtf8Bytes(record, JsonOptions));
        return response with
        {
            Record = record,
            RecordSha256 = finalHash
        };
    }

    public static bool VerifySignedRecord(Dictionary<string, object?> record)
    {
        if (!record.TryGetValue("service_signature", out var signatureValue))
        {
            return false;
        }

        var signatureElement = JsonSerializer.SerializeToElement(signatureValue);
        var signedRecordSha256 = ReadString(signatureElement, "signed_record_sha256");
        var signatureBase64 = ReadString(signatureElement, "signature_base64");
        var publicKeyBase64 = ReadString(signatureElement, "public_key_spki_der_base64");
        if (string.IsNullOrWhiteSpace(signedRecordSha256)
            || string.IsNullOrWhiteSpace(signatureBase64)
            || string.IsNullOrWhiteSpace(publicKeyBase64))
        {
            return false;
        }

        var unsignedRecord = new Dictionary<string, object?>(record, StringComparer.Ordinal);
        unsignedRecord.Remove("service_signature");
        var payload = JsonSerializer.SerializeToUtf8Bytes(unsignedRecord, JsonOptions);
        if (!string.Equals(ComputeSha256(payload), signedRecordSha256, StringComparison.OrdinalIgnoreCase))
        {
            return false;
        }

        using var rsa = RSA.Create();
        rsa.ImportSubjectPublicKeyInfo(Convert.FromBase64String(publicKeyBase64), out _);
        return rsa.VerifyData(payload, Convert.FromBase64String(signatureBase64), HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1);
    }

    private RSA LoadOrCreateKey()
    {
        var rsa = RSA.Create(3072);
        if (File.Exists(keyPath))
        {
            rsa.ImportPkcs8PrivateKey(File.ReadAllBytes(keyPath), out _);
            return rsa;
        }

        File.WriteAllBytes(keyPath, rsa.ExportPkcs8PrivateKey());
        File.WriteAllBytes(Path.ChangeExtension(keyPath, ".spki.der"), rsa.ExportSubjectPublicKeyInfo());
        return rsa;
    }

    private static string ReadString(JsonElement root, string propertyName)
    {
        return root.TryGetProperty(propertyName, out var property) && property.ValueKind == JsonValueKind.String
            ? property.GetString() ?? string.Empty
            : string.Empty;
    }

    private static string ComputeSha256(byte[] value)
    {
        return Convert.ToHexString(SHA256.HashData(value)).ToLowerInvariant();
    }
}
