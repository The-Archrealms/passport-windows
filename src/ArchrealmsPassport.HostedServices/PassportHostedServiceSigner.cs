using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using ArchrealmsPassport.HostedServices.Contracts;

namespace ArchrealmsPassport.HostedServices;

public sealed class PassportHostedServiceSigner
{
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        WriteIndented = true
    };

    private readonly string? keyPath;
    private readonly PassportManagedSigningOptions? managedSigning;
    private readonly HttpMessageHandler? managedSigningHandler;

    public PassportHostedServiceSigner(string keyPath)
    {
        this.keyPath = Path.GetFullPath(keyPath);
        Directory.CreateDirectory(Path.GetDirectoryName(this.keyPath) ?? string.Empty);
    }

    public PassportHostedServiceSigner(PassportManagedSigningOptions managedSigning, HttpMessageHandler? managedSigningHandler = null)
    {
        this.managedSigning = managedSigning;
        this.managedSigningHandler = managedSigningHandler;
    }

    public static PassportHostedServiceSigner FromDataRoot(string dataRoot)
    {
        var managedSigning = PassportManagedSigningOptions.FromEnvironment();
        if (managedSigning != null)
        {
            return new PassportHostedServiceSigner(managedSigning);
        }

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

        var record = new Dictionary<string, object?>(response.Record, StringComparer.Ordinal);
        record.Remove("service_signature");

        var payloadBytes = JsonSerializer.SerializeToUtf8Bytes(record, JsonOptions);
        var signature = managedSigning != null
            ? SignWithManagedEndpoint(payloadBytes, purpose)
            : SignWithLocalKey(payloadBytes, purpose);
        record["service_signature"] = signature.ToRecord();

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
        if (string.IsNullOrWhiteSpace(keyPath))
        {
            throw new InvalidOperationException("Local hosted signing key path is not configured.");
        }

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

    private ServiceSignatureMaterial SignWithLocalKey(byte[] payloadBytes, string purpose)
    {
        using var rsa = LoadOrCreateKey();
        var publicKey = rsa.ExportSubjectPublicKeyInfo();
        var signature = rsa.SignData(payloadBytes, HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1);
        return new ServiceSignatureMaterial(
            SignatureAlgorithm: "RSA_PKCS1_SHA256",
            SignaturePurpose: string.IsNullOrWhiteSpace(purpose) ? "hosted_record" : purpose.Trim(),
            SignerId: "archrealms-passport-hosted-services",
            SignedRecordSha256: ComputeSha256(payloadBytes),
            SignatureBase64: Convert.ToBase64String(signature),
            PublicKeySpkiDerBase64: Convert.ToBase64String(publicKey),
            PublicKeySha256: ComputeSha256(publicKey),
            SigningKeyProvider: string.Empty,
            SigningKeyId: string.Empty,
            SigningKeyCustody: string.Empty);
    }

    private ServiceSignatureMaterial SignWithManagedEndpoint(byte[] payloadBytes, string purpose)
    {
        if (managedSigning == null)
        {
            throw new InvalidOperationException("Managed hosted signing is not configured.");
        }

        var payloadSha256 = ComputeSha256(payloadBytes);
        using var client = managedSigningHandler == null
            ? new HttpClient()
            : new HttpClient(managedSigningHandler, disposeHandler: false);
        client.Timeout = TimeSpan.FromSeconds(Math.Max(1, managedSigning.TimeoutSeconds));

        using var request = new HttpRequestMessage(HttpMethod.Post, managedSigning.Endpoint);
        if (!string.IsNullOrWhiteSpace(managedSigning.ApiKey))
        {
            request.Headers.TryAddWithoutValidation("X-Archrealms-Managed-Signing-Key", managedSigning.ApiKey);
        }

        var signingRequest = new ManagedSigningRequest
        {
            KeyId = managedSigning.KeyId,
            Provider = managedSigning.Provider,
            Custody = managedSigning.Custody,
            Purpose = string.IsNullOrWhiteSpace(purpose) ? "hosted_record" : purpose.Trim(),
            PayloadSha256 = payloadSha256,
            PayloadBase64 = Convert.ToBase64String(payloadBytes)
        };
        request.Content = new StringContent(JsonSerializer.Serialize(signingRequest, JsonOptions), Encoding.UTF8, "application/json");

        using var response = client.Send(request);
        response.EnsureSuccessStatusCode();
        using var stream = response.Content.ReadAsStream();
        var signingResponse = JsonSerializer.Deserialize<ManagedSigningResponse>(stream);
        if (signingResponse == null)
        {
            throw new InvalidOperationException("Managed signing endpoint returned no JSON body.");
        }

        var signedPayloadSha256 = Normalize(signingResponse.SignedPayloadSha256);
        if (!string.Equals(payloadSha256, signedPayloadSha256, StringComparison.OrdinalIgnoreCase))
        {
            throw new InvalidOperationException("Managed signing endpoint signed the wrong payload hash.");
        }

        var algorithm = Normalize(signingResponse.SignatureAlgorithm);
        var signatureBase64 = Normalize(signingResponse.SignatureBase64);
        var publicKeyBase64 = Normalize(signingResponse.PublicKeySpkiDerBase64);
        if (!string.Equals(algorithm, "RSA_PKCS1_SHA256", StringComparison.Ordinal)
            || string.IsNullOrWhiteSpace(signatureBase64)
            || string.IsNullOrWhiteSpace(publicKeyBase64))
        {
            throw new InvalidOperationException("Managed signing endpoint must return RSA_PKCS1_SHA256 signature and public key evidence.");
        }

        var publicKey = Convert.FromBase64String(publicKeyBase64);
        var publicKeySha256 = Normalize(signingResponse.PublicKeySha256);
        if (!string.Equals(publicKeySha256, ComputeSha256(publicKey), StringComparison.OrdinalIgnoreCase))
        {
            throw new InvalidOperationException("Managed signing endpoint returned public key hash mismatch.");
        }

        return new ServiceSignatureMaterial(
            SignatureAlgorithm: algorithm,
            SignaturePurpose: signingRequest.Purpose,
            SignerId: managedSigning.KeyId,
            SignedRecordSha256: payloadSha256,
            SignatureBase64: signatureBase64,
            PublicKeySpkiDerBase64: publicKeyBase64,
            PublicKeySha256: publicKeySha256,
            SigningKeyProvider: managedSigning.Provider,
            SigningKeyId: managedSigning.KeyId,
            SigningKeyCustody: managedSigning.Custody);
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

    private static string Normalize(string? value)
    {
        return (value ?? string.Empty).Trim();
    }

    private sealed record ServiceSignatureMaterial(
        string SignatureAlgorithm,
        string SignaturePurpose,
        string SignerId,
        string SignedRecordSha256,
        string SignatureBase64,
        string PublicKeySpkiDerBase64,
        string PublicKeySha256,
        string SigningKeyProvider,
        string SigningKeyId,
        string SigningKeyCustody)
    {
        public Dictionary<string, object?> ToRecord()
        {
            var record = new Dictionary<string, object?>
            {
                ["signature_algorithm"] = SignatureAlgorithm,
                ["signature_purpose"] = SignaturePurpose,
                ["signer_id"] = SignerId,
                ["signed_record_sha256"] = SignedRecordSha256,
                ["signature_base64"] = SignatureBase64,
                ["public_key_spki_der_base64"] = PublicKeySpkiDerBase64,
                ["public_key_sha256"] = PublicKeySha256
            };

            if (!string.IsNullOrWhiteSpace(SigningKeyProvider))
            {
                record["signing_key_provider"] = SigningKeyProvider;
            }

            if (!string.IsNullOrWhiteSpace(SigningKeyId))
            {
                record["signing_key_id"] = SigningKeyId;
            }

            if (!string.IsNullOrWhiteSpace(SigningKeyCustody))
            {
                record["signing_key_custody"] = SigningKeyCustody;
            }

            return record;
        }
    }

    private sealed record ManagedSigningRequest
    {
        [JsonPropertyName("key_id")]
        public string KeyId { get; init; } = string.Empty;

        [JsonPropertyName("provider")]
        public string Provider { get; init; } = string.Empty;

        [JsonPropertyName("custody")]
        public string Custody { get; init; } = string.Empty;

        [JsonPropertyName("purpose")]
        public string Purpose { get; init; } = string.Empty;

        [JsonPropertyName("payload_sha256")]
        public string PayloadSha256 { get; init; } = string.Empty;

        [JsonPropertyName("payload_base64")]
        public string PayloadBase64 { get; init; } = string.Empty;
    }

    private sealed record ManagedSigningResponse
    {
        [JsonPropertyName("signature_algorithm")]
        public string SignatureAlgorithm { get; init; } = string.Empty;

        [JsonPropertyName("signed_payload_sha256")]
        public string SignedPayloadSha256 { get; init; } = string.Empty;

        [JsonPropertyName("signature_base64")]
        public string SignatureBase64 { get; init; } = string.Empty;

        [JsonPropertyName("public_key_spki_der_base64")]
        public string PublicKeySpkiDerBase64 { get; init; } = string.Empty;

        [JsonPropertyName("public_key_sha256")]
        public string PublicKeySha256 { get; init; } = string.Empty;
    }
}

public sealed record PassportManagedSigningOptions
{
    public string Endpoint { get; init; } = string.Empty;

    public string Provider { get; init; } = string.Empty;

    public string KeyId { get; init; } = string.Empty;

    public string Custody { get; init; } = string.Empty;

    public string ApiKey { get; init; } = string.Empty;

    public int TimeoutSeconds { get; init; } = 10;

    public static PassportManagedSigningOptions? FromEnvironment()
    {
        var endpoint = Normalize(Environment.GetEnvironmentVariable("ARCHREALMS_PASSPORT_HOSTED_SIGNING_ENDPOINT"));
        if (string.IsNullOrWhiteSpace(endpoint))
        {
            return null;
        }

        return new PassportManagedSigningOptions
        {
            Endpoint = endpoint,
            Provider = Normalize(Environment.GetEnvironmentVariable("ARCHREALMS_PASSPORT_HOSTED_SIGNING_KEY_PROVIDER")),
            KeyId = Normalize(Environment.GetEnvironmentVariable("ARCHREALMS_PASSPORT_HOSTED_SIGNING_KEY_ID")),
            Custody = Normalize(Environment.GetEnvironmentVariable("ARCHREALMS_PASSPORT_HOSTED_SIGNING_KEY_CUSTODY")).ToLowerInvariant(),
            ApiKey = Normalize(Environment.GetEnvironmentVariable("ARCHREALMS_PASSPORT_HOSTED_SIGNING_ENDPOINT_API_KEY")),
            TimeoutSeconds = ReadTimeout(Environment.GetEnvironmentVariable("ARCHREALMS_PASSPORT_HOSTED_SIGNING_TIMEOUT_SECONDS"))
        };
    }

    private static int ReadTimeout(string? value)
    {
        return int.TryParse(value, out var seconds) && seconds > 0 ? Math.Min(seconds, 120) : 10;
    }

    private static string Normalize(string? value)
    {
        return (value ?? string.Empty).Trim();
    }
}
