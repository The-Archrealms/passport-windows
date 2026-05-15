using System.Text.Json.Serialization;

namespace ArchrealmsPassport.HostedServices;

public sealed record PassportHostedAiRuntimeReadiness
{
    [JsonPropertyName("schema")]
    public string Schema { get; init; } = "archrealms.passport.hosted_ai_runtime_readiness.v1";

    [JsonPropertyName("created_utc")]
    public string CreatedUtc { get; init; } = DateTimeOffset.UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ");

    [JsonPropertyName("ready")]
    public bool Ready => Missing.Count == 0;

    [JsonPropertyName("model_id")]
    public string ModelId { get; init; } = string.Empty;

    [JsonPropertyName("inference_base_url_configured")]
    public bool InferenceBaseUrlConfigured { get; init; }

    [JsonPropertyName("model_artifact_sha256")]
    public string ModelArtifactSha256 { get; init; } = string.Empty;

    [JsonPropertyName("model_license_approval_id")]
    public string ModelLicenseApprovalId { get; init; } = string.Empty;

    [JsonPropertyName("vector_store_provider")]
    public string VectorStoreProvider { get; init; } = string.Empty;

    [JsonPropertyName("vector_store_id")]
    public string VectorStoreId { get; init; } = string.Empty;

    [JsonPropertyName("knowledge_approval_root")]
    public string KnowledgeApprovalRoot { get; init; } = string.Empty;

    [JsonPropertyName("missing")]
    public IReadOnlyList<string> Missing { get; init; } = Array.Empty<string>();

    public static PassportHostedAiRuntimeReadiness FromEnvironment()
    {
        return FromValues(
            Environment.GetEnvironmentVariable("ARCHREALMS_PASSPORT_AI_INFERENCE_BASE_URL"),
            Environment.GetEnvironmentVariable("ARCHREALMS_PASSPORT_AI_MODEL_ID"),
            Environment.GetEnvironmentVariable("ARCHREALMS_PASSPORT_AI_MODEL_ARTIFACT_SHA256"),
            Environment.GetEnvironmentVariable("ARCHREALMS_PASSPORT_AI_MODEL_LICENSE_APPROVAL_ID"),
            Environment.GetEnvironmentVariable("ARCHREALMS_PASSPORT_AI_VECTOR_STORE_PROVIDER"),
            Environment.GetEnvironmentVariable("ARCHREALMS_PASSPORT_AI_VECTOR_STORE_ID"),
            Environment.GetEnvironmentVariable("ARCHREALMS_PASSPORT_AI_KNOWLEDGE_APPROVAL_ROOT"));
    }

    public static PassportHostedAiRuntimeReadiness FromValues(
        string? inferenceBaseUrl,
        string? modelId,
        string? modelArtifactSha256,
        string? modelLicenseApprovalId,
        string? vectorStoreProvider,
        string? vectorStoreId,
        string? knowledgeApprovalRoot)
    {
        var missing = new List<string>();
        var normalizedBaseUrl = Normalize(inferenceBaseUrl);
        var normalizedModelId = Normalize(modelId);
        var normalizedArtifactSha256 = Normalize(modelArtifactSha256).ToLowerInvariant();
        var normalizedLicenseApprovalId = Normalize(modelLicenseApprovalId);
        var normalizedVectorStoreProvider = Normalize(vectorStoreProvider);
        var normalizedVectorStoreId = Normalize(vectorStoreId);
        var normalizedKnowledgeApprovalRoot = Normalize(knowledgeApprovalRoot);

        if (!IsHttpsUrl(normalizedBaseUrl))
        {
            missing.Add("ARCHREALMS_PASSPORT_AI_INFERENCE_BASE_URL");
        }

        if (string.IsNullOrWhiteSpace(normalizedModelId))
        {
            missing.Add("ARCHREALMS_PASSPORT_AI_MODEL_ID");
        }

        if (!LooksLikeSha256(normalizedArtifactSha256))
        {
            missing.Add("ARCHREALMS_PASSPORT_AI_MODEL_ARTIFACT_SHA256");
        }

        if (string.IsNullOrWhiteSpace(normalizedLicenseApprovalId))
        {
            missing.Add("ARCHREALMS_PASSPORT_AI_MODEL_LICENSE_APPROVAL_ID");
        }

        if (string.IsNullOrWhiteSpace(normalizedVectorStoreProvider))
        {
            missing.Add("ARCHREALMS_PASSPORT_AI_VECTOR_STORE_PROVIDER");
        }

        if (string.IsNullOrWhiteSpace(normalizedVectorStoreId))
        {
            missing.Add("ARCHREALMS_PASSPORT_AI_VECTOR_STORE_ID");
        }

        if (string.IsNullOrWhiteSpace(normalizedKnowledgeApprovalRoot))
        {
            missing.Add("ARCHREALMS_PASSPORT_AI_KNOWLEDGE_APPROVAL_ROOT");
        }

        return new PassportHostedAiRuntimeReadiness
        {
            ModelId = normalizedModelId,
            InferenceBaseUrlConfigured = IsHttpsUrl(normalizedBaseUrl),
            ModelArtifactSha256 = LooksLikeSha256(normalizedArtifactSha256) ? normalizedArtifactSha256 : string.Empty,
            ModelLicenseApprovalId = normalizedLicenseApprovalId,
            VectorStoreProvider = normalizedVectorStoreProvider,
            VectorStoreId = normalizedVectorStoreId,
            KnowledgeApprovalRoot = normalizedKnowledgeApprovalRoot,
            Missing = missing.ToArray()
        };
    }

    private static string Normalize(string? value)
    {
        return (value ?? string.Empty).Trim();
    }

    private static bool IsHttpsUrl(string value)
    {
        return Uri.TryCreate(value, UriKind.Absolute, out var uri)
            && string.Equals(uri.Scheme, Uri.UriSchemeHttps, StringComparison.OrdinalIgnoreCase);
    }

    private static bool LooksLikeSha256(string value)
    {
        return value.Length == 64 && value.All(Uri.IsHexDigit);
    }
}
