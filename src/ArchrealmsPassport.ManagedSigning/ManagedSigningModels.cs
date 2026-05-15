using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace ArchrealmsPassport.ManagedSigning;

public sealed record ManagedSigningRequest
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

public sealed record ManagedSigningResponse
{
    [JsonPropertyName("signature_algorithm")]
    public string SignatureAlgorithm { get; init; } = "RSA_PKCS1_SHA256";

    [JsonPropertyName("signed_payload_sha256")]
    public string SignedPayloadSha256 { get; init; } = string.Empty;

    [JsonPropertyName("signature_base64")]
    public string SignatureBase64 { get; init; } = string.Empty;

    [JsonPropertyName("public_key_spki_der_base64")]
    public string PublicKeySpkiDerBase64 { get; init; } = string.Empty;

    [JsonPropertyName("public_key_sha256")]
    public string PublicKeySha256 { get; init; } = string.Empty;

    [JsonPropertyName("signing_key_provider")]
    public string SigningKeyProvider { get; init; } = string.Empty;

    [JsonPropertyName("signing_key_id")]
    public string SigningKeyId { get; init; } = string.Empty;

    [JsonPropertyName("signing_key_custody")]
    public string SigningKeyCustody { get; init; } = string.Empty;

    [JsonPropertyName("local_validation_only")]
    public bool LocalValidationOnly { get; init; }
}

public sealed record ManagedSigningResult(bool Succeeded, string Message, ManagedSigningResponse? Response)
{
    public static ManagedSigningResult Failed(string message)
    {
        return new ManagedSigningResult(false, message, null);
    }

    public static ManagedSigningResult Success(ManagedSigningResponse response)
    {
        return new ManagedSigningResult(true, "Managed signing response created.", response);
    }
}

public sealed record ManagedSigningStatus
{
    [JsonPropertyName("schema")]
    public string Schema { get; init; } = "archrealms.passport.managed_signing_status.v1";

    [JsonPropertyName("ready")]
    public bool Ready => Missing.Count == 0;

    [JsonPropertyName("provider")]
    public string Provider { get; init; } = string.Empty;

    [JsonPropertyName("key_id")]
    public string KeyId { get; init; } = string.Empty;

    [JsonPropertyName("custody")]
    public string Custody { get; init; } = string.Empty;

    [JsonPropertyName("mode")]
    public string Mode { get; init; } = string.Empty;

    [JsonPropertyName("local_validation_only")]
    public bool LocalValidationOnly { get; init; }

    [JsonPropertyName("api_key_required")]
    public bool ApiKeyRequired { get; init; }

    [JsonPropertyName("allowed_purposes")]
    public IReadOnlyList<string> AllowedPurposes { get; init; } = Array.Empty<string>();

    [JsonPropertyName("missing")]
    public IReadOnlyList<string> Missing { get; init; } = Array.Empty<string>();
}

public sealed record ManagedSigningOptions
{
    public string Provider { get; init; } = string.Empty;

    public string KeyId { get; init; } = string.Empty;

    public string Custody { get; init; } = string.Empty;

    public string ApiKeySha256 { get; init; } = string.Empty;

    public string LocalPkcs8Path { get; init; } = string.Empty;

    public string ExternalCommandPath { get; init; } = string.Empty;

    public string ExternalCommandArguments { get; init; } = string.Empty;

    public string[] AllowedPurposes { get; init; } = DefaultAllowedPurposes;

    public bool LocalValidationOnly => string.IsNullOrWhiteSpace(ExternalCommandPath);

    public string Mode => LocalValidationOnly ? "local-pkcs8-validation" : "external-command";

    public static string[] DefaultAllowedPurposes =>
        new[]
        {
            "production_mvp_readiness_probe",
            "hosted_record",
            "ai_feedback",
            "cc_capacity_report",
            "arch_genesis_manifest",
            "telemetry_access",
            "recovery_control_validation",
            "storage_delivery_acceptance",
            "hosted_storage_backup_manifest",
            "hosted_incident_report"
        };

    public static ManagedSigningOptions FromEnvironment()
    {
        return new ManagedSigningOptions
        {
            Provider = FirstEnvironment(
                "ARCHREALMS_MANAGED_SIGNING_KEY_PROVIDER",
                "ARCHREALMS_PASSPORT_HOSTED_SIGNING_KEY_PROVIDER"),
            KeyId = FirstEnvironment(
                "ARCHREALMS_MANAGED_SIGNING_KEY_ID",
                "ARCHREALMS_PASSPORT_HOSTED_SIGNING_KEY_ID"),
            Custody = FirstEnvironment(
                "ARCHREALMS_MANAGED_SIGNING_KEY_CUSTODY",
                "ARCHREALMS_PASSPORT_HOSTED_SIGNING_KEY_CUSTODY").ToLowerInvariant(),
            ApiKeySha256 = FirstEnvironment(
                "ARCHREALMS_MANAGED_SIGNING_API_KEY_SHA256",
                "ARCHREALMS_PASSPORT_HOSTED_SIGNING_ENDPOINT_API_KEY_SHA256"),
            LocalPkcs8Path = FirstEnvironment("ARCHREALMS_MANAGED_SIGNING_LOCAL_PKCS8_PATH"),
            ExternalCommandPath = FirstEnvironment("ARCHREALMS_MANAGED_SIGNING_COMMAND_PATH"),
            ExternalCommandArguments = FirstEnvironment("ARCHREALMS_MANAGED_SIGNING_COMMAND_ARGUMENTS"),
            AllowedPurposes = ReadCsv(FirstEnvironment("ARCHREALMS_MANAGED_SIGNING_ALLOWED_PURPOSES"), DefaultAllowedPurposes)
        };
    }

    public ManagedSigningStatus GetStatus()
    {
        var missing = new List<string>();
        AddMissing(missing, "ARCHREALMS_MANAGED_SIGNING_KEY_PROVIDER", Provider);
        AddMissing(missing, "ARCHREALMS_MANAGED_SIGNING_KEY_ID", KeyId);
        AddMissing(missing, "ARCHREALMS_MANAGED_SIGNING_KEY_CUSTODY", Custody);
        if (LocalValidationOnly)
        {
            AddMissing(missing, "ARCHREALMS_MANAGED_SIGNING_LOCAL_PKCS8_PATH", LocalPkcs8Path);
        }

        return new ManagedSigningStatus
        {
            Provider = Provider,
            KeyId = KeyId,
            Custody = Custody,
            Mode = Mode,
            LocalValidationOnly = LocalValidationOnly,
            ApiKeyRequired = !string.IsNullOrWhiteSpace(ApiKeySha256),
            AllowedPurposes = AllowedPurposes,
            Missing = missing
        };
    }

    public bool IsAuthorized(string providedApiKey)
    {
        if (string.IsNullOrWhiteSpace(ApiKeySha256))
        {
            return true;
        }

        if (string.IsNullOrWhiteSpace(providedApiKey))
        {
            return false;
        }

        var actual = ComputeSha256(Encoding.UTF8.GetBytes(providedApiKey.Trim()));
        return string.Equals(actual, ApiKeySha256.Trim(), StringComparison.OrdinalIgnoreCase);
    }

    public bool PurposeAllowed(string purpose)
    {
        return AllowedPurposes.Any(candidate => string.Equals(candidate, purpose, StringComparison.Ordinal));
    }

    private static void AddMissing(List<string> missing, string name, string value)
    {
        if (string.IsNullOrWhiteSpace(value))
        {
            missing.Add(name);
        }
    }

    private static string FirstEnvironment(params string[] names)
    {
        foreach (var name in names)
        {
            var value = Environment.GetEnvironmentVariable(name);
            if (!string.IsNullOrWhiteSpace(value))
            {
                return value.Trim();
            }
        }

        return string.Empty;
    }

    private static string[] ReadCsv(string value, string[] fallback)
    {
        if (string.IsNullOrWhiteSpace(value))
        {
            return fallback;
        }

        var items = value
            .Split(',', StringSplitOptions.TrimEntries | StringSplitOptions.RemoveEmptyEntries)
            .Distinct(StringComparer.Ordinal)
            .ToArray();
        return items.Length == 0 ? fallback : items;
    }

    internal static string ComputeSha256(byte[] bytes)
    {
        return Convert.ToHexString(SHA256.HashData(bytes)).ToLowerInvariant();
    }
}

public sealed class ManagedSigningService
{
    private static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web);

    private readonly ManagedSigningOptions options;

    public ManagedSigningService(ManagedSigningOptions options)
    {
        this.options = options;
    }

    public ManagedSigningResult Sign(ManagedSigningRequest request)
    {
        var validation = ValidateRequest(request);
        if (!string.IsNullOrWhiteSpace(validation))
        {
            return ManagedSigningResult.Failed(validation);
        }

        return options.LocalValidationOnly
            ? SignWithLocalPkcs8(request)
            : SignWithExternalCommand(request);
    }

    private string ValidateRequest(ManagedSigningRequest request)
    {
        if (!string.Equals(request.KeyId, options.KeyId, StringComparison.Ordinal))
        {
            return "Signing request key_id does not match configured key.";
        }

        if (!string.Equals(request.Provider, options.Provider, StringComparison.Ordinal))
        {
            return "Signing request provider does not match configured provider.";
        }

        if (!string.Equals(request.Custody, options.Custody, StringComparison.Ordinal))
        {
            return "Signing request custody does not match configured custody.";
        }

        if (!options.PurposeAllowed(request.Purpose))
        {
            return "Signing request purpose is not allowed.";
        }

        byte[] payload;
        try
        {
            payload = Convert.FromBase64String(request.PayloadBase64);
        }
        catch
        {
            return "Signing request payload_base64 is invalid.";
        }

        var actualHash = ManagedSigningOptions.ComputeSha256(payload);
        if (!string.Equals(actualHash, request.PayloadSha256, StringComparison.OrdinalIgnoreCase))
        {
            return "Signing request payload_sha256 does not match payload_base64.";
        }

        return string.Empty;
    }

    private ManagedSigningResult SignWithLocalPkcs8(ManagedSigningRequest request)
    {
        if (string.IsNullOrWhiteSpace(options.LocalPkcs8Path))
        {
            return ManagedSigningResult.Failed("ARCHREALMS_MANAGED_SIGNING_LOCAL_PKCS8_PATH is required for local validation signing.");
        }

        using var rsa = RSA.Create();
        if (File.Exists(options.LocalPkcs8Path))
        {
            rsa.ImportPkcs8PrivateKey(File.ReadAllBytes(options.LocalPkcs8Path), out _);
        }
        else
        {
            Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(options.LocalPkcs8Path)) ?? string.Empty);
            using var generated = RSA.Create(3072);
            File.WriteAllBytes(options.LocalPkcs8Path, generated.ExportPkcs8PrivateKey());
            rsa.ImportPkcs8PrivateKey(File.ReadAllBytes(options.LocalPkcs8Path), out _);
        }

        return ManagedSigningResult.Success(CreateResponse(request, rsa, localValidationOnly: true));
    }

    private ManagedSigningResult SignWithExternalCommand(ManagedSigningRequest request)
    {
        var startInfo = new System.Diagnostics.ProcessStartInfo
        {
            FileName = options.ExternalCommandPath,
            Arguments = options.ExternalCommandArguments,
            RedirectStandardInput = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false
        };

        using var process = System.Diagnostics.Process.Start(startInfo);
        if (process == null)
        {
            return ManagedSigningResult.Failed("Managed signing external command could not start.");
        }

        process.StandardInput.Write(JsonSerializer.Serialize(request, JsonOptions));
        process.StandardInput.Close();
        var output = process.StandardOutput.ReadToEnd();
        var error = process.StandardError.ReadToEnd();
        process.WaitForExit();
        if (process.ExitCode != 0)
        {
            return ManagedSigningResult.Failed("Managed signing external command failed: " + error.Trim());
        }

        try
        {
            var response = JsonSerializer.Deserialize<ManagedSigningResponse>(output, JsonOptions);
            if (response == null)
            {
                return ManagedSigningResult.Failed("Managed signing external command returned no JSON response.");
            }

            var failure = ValidateResponse(request, response);
            return string.IsNullOrWhiteSpace(failure)
                ? ManagedSigningResult.Success(response)
                : ManagedSigningResult.Failed(failure);
        }
        catch (Exception ex)
        {
            return ManagedSigningResult.Failed("Managed signing external command returned invalid JSON: " + ex.Message);
        }
    }

    private ManagedSigningResponse CreateResponse(ManagedSigningRequest request, RSA rsa, bool localValidationOnly)
    {
        var payload = Convert.FromBase64String(request.PayloadBase64);
        var publicKey = rsa.ExportSubjectPublicKeyInfo();
        return new ManagedSigningResponse
        {
            SignatureAlgorithm = "RSA_PKCS1_SHA256",
            SignedPayloadSha256 = request.PayloadSha256.ToLowerInvariant(),
            SignatureBase64 = Convert.ToBase64String(rsa.SignData(payload, HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1)),
            PublicKeySpkiDerBase64 = Convert.ToBase64String(publicKey),
            PublicKeySha256 = ManagedSigningOptions.ComputeSha256(publicKey),
            SigningKeyProvider = options.Provider,
            SigningKeyId = options.KeyId,
            SigningKeyCustody = options.Custody,
            LocalValidationOnly = localValidationOnly
        };
    }

    public string ValidateResponse(ManagedSigningRequest request, ManagedSigningResponse response)
    {
        if (!string.Equals(response.SignatureAlgorithm, "RSA_PKCS1_SHA256", StringComparison.Ordinal))
        {
            return "Managed signing response must use RSA_PKCS1_SHA256.";
        }

        if (!string.Equals(response.SignedPayloadSha256, request.PayloadSha256, StringComparison.OrdinalIgnoreCase))
        {
            return "Managed signing response signed the wrong payload hash.";
        }

        if (!string.Equals(response.SigningKeyProvider, options.Provider, StringComparison.Ordinal)
            || !string.Equals(response.SigningKeyId, options.KeyId, StringComparison.Ordinal)
            || !string.Equals(response.SigningKeyCustody, options.Custody, StringComparison.Ordinal))
        {
            return "Managed signing response key provider, key ID, or custody does not match configured values.";
        }

        byte[] signature;
        byte[] publicKey;
        try
        {
            signature = Convert.FromBase64String(response.SignatureBase64);
            publicKey = Convert.FromBase64String(response.PublicKeySpkiDerBase64);
        }
        catch
        {
            return "Managed signing response returned invalid base64 signature or public key.";
        }

        if (!string.Equals(response.PublicKeySha256, ManagedSigningOptions.ComputeSha256(publicKey), StringComparison.OrdinalIgnoreCase))
        {
            return "Managed signing response returned public key hash mismatch.";
        }

        using var rsa = RSA.Create();
        rsa.ImportSubjectPublicKeyInfo(publicKey, out _);
        var payload = Convert.FromBase64String(request.PayloadBase64);
        return rsa.VerifyData(payload, signature, HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1)
            ? string.Empty
            : "Managed signing response signature verification failed.";
    }
}
