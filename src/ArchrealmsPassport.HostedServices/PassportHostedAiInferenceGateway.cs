using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using ArchrealmsPassport.HostedServices.Contracts;

namespace ArchrealmsPassport.HostedServices;

public interface IPassportHostedAiInferenceGateway
{
    bool IsConfigured { get; }

    Task<PassportHostedAiInferenceResult> CreateAnswerAsync(
        PassportAiChatRequest request,
        Dictionary<string, object?> sessionRecord,
        IReadOnlyList<PassportHostedKnowledgeChunk> retrievedChunks,
        CancellationToken cancellationToken = default);
}

public sealed class PassportHostedAiInferenceGateway : IPassportHostedAiInferenceGateway
{
    private static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web);

    private readonly HttpClient httpClient;
    private readonly string modelId;
    private readonly string systemPrompt;
    private readonly int maxOutputTokens;
    private readonly double temperature;

    public PassportHostedAiInferenceGateway(
        HttpClient httpClient,
        string modelId,
        string systemPrompt,
        int maxOutputTokens,
        double temperature)
    {
        this.httpClient = httpClient;
        this.modelId = string.IsNullOrWhiteSpace(modelId) ? "guide-small" : modelId.Trim();
        this.systemPrompt = string.IsNullOrWhiteSpace(systemPrompt) ? DefaultSystemPrompt : systemPrompt.Trim();
        this.maxOutputTokens = Math.Clamp(maxOutputTokens, 64, 4096);
        this.temperature = Math.Clamp(temperature, 0, 1);
    }

    public bool IsConfigured => httpClient.BaseAddress != null;

    private static string DefaultSystemPrompt =>
        "You are the Archrealms hosted Passport AI guide. Answer only as a non-authoritative guide. "
        + "Use approved context when it is available. Do not approve recovery, move wallet assets, issue or burn credits, "
        + "release escrow, mark storage delivered, change registry authority, or perform admin actions.";

    public static PassportHostedAiInferenceGateway FromEnvironment()
    {
        var baseUrl = Environment.GetEnvironmentVariable("ARCHREALMS_PASSPORT_AI_INFERENCE_BASE_URL");
        var modelId = Environment.GetEnvironmentVariable("ARCHREALMS_PASSPORT_AI_MODEL_ID") ?? "guide-small";
        var systemPrompt = Environment.GetEnvironmentVariable("ARCHREALMS_PASSPORT_AI_SYSTEM_PROMPT") ?? string.Empty;
        var apiKey = Environment.GetEnvironmentVariable("ARCHREALMS_PASSPORT_AI_INFERENCE_API_KEY");
        _ = int.TryParse(Environment.GetEnvironmentVariable("ARCHREALMS_PASSPORT_AI_MAX_OUTPUT_TOKENS"), out var maxOutputTokens);
        _ = double.TryParse(Environment.GetEnvironmentVariable("ARCHREALMS_PASSPORT_AI_TEMPERATURE"), out var temperature);

        var client = new HttpClient();
        if (!string.IsNullOrWhiteSpace(baseUrl))
        {
            client.BaseAddress = new Uri(baseUrl.Trim().TrimEnd('/') + "/");
        }

        if (!string.IsNullOrWhiteSpace(apiKey))
        {
            client.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", apiKey.Trim());
        }

        return new PassportHostedAiInferenceGateway(
            client,
            modelId,
            systemPrompt,
            maxOutputTokens == 0 ? 512 : maxOutputTokens,
            temperature == 0 ? 0.2 : temperature);
    }

    public async Task<PassportHostedAiInferenceResult> CreateAnswerAsync(
        PassportAiChatRequest request,
        Dictionary<string, object?> sessionRecord,
        IReadOnlyList<PassportHostedKnowledgeChunk> retrievedChunks,
        CancellationToken cancellationToken = default)
    {
        if (!IsConfigured)
        {
            return PassportHostedAiInferenceResult.NotConfigured();
        }

        var prompt = CreateUserPrompt(request, retrievedChunks);
        var body = new Dictionary<string, object?>
        {
            ["model"] = modelId,
            ["temperature"] = temperature,
            ["max_tokens"] = maxOutputTokens,
            ["messages"] = new[]
            {
                new Dictionary<string, object?>
                {
                    ["role"] = "system",
                    ["content"] = systemPrompt
                },
                new Dictionary<string, object?>
                {
                    ["role"] = "user",
                    ["content"] = prompt
                }
            },
            ["metadata"] = new Dictionary<string, object?>
            {
                ["release_lane"] = ReadString(sessionRecord, "release_lane"),
                ["policy_version"] = request.PolicyVersion,
                ["knowledge_pack_id"] = request.KnowledgePackId
            }
        };

        using var content = new StringContent(JsonSerializer.Serialize(body, JsonOptions), Encoding.UTF8, "application/json");
        using var response = await httpClient.PostAsync("chat/completions", content, cancellationToken).ConfigureAwait(false);
        var responseText = await response.Content.ReadAsStringAsync(cancellationToken).ConfigureAwait(false);
        if (!response.IsSuccessStatusCode)
        {
            return PassportHostedAiInferenceResult.Failed("Model runtime returned HTTP " + (int)response.StatusCode + ".");
        }

        var answer = ReadOpenAiCompatibleAnswer(responseText);
        return string.IsNullOrWhiteSpace(answer)
            ? PassportHostedAiInferenceResult.Failed("Model runtime response did not include a chat answer.")
            : PassportHostedAiInferenceResult.Success(answer.Trim(), modelId);
    }

    private static string CreateUserPrompt(PassportAiChatRequest request, IReadOnlyList<PassportHostedKnowledgeChunk> retrievedChunks)
    {
        var builder = new StringBuilder();
        builder.AppendLine("User question:");
        builder.AppendLine(request.Message.Trim());
        builder.AppendLine();
        builder.AppendLine("Approved context:");
        if (retrievedChunks.Count == 0)
        {
            builder.AppendLine("No approved hosted context chunks were retrieved.");
        }
        else
        {
            foreach (var chunk in retrievedChunks.Take(5))
            {
                builder.AppendLine("Source: " + chunk.Source.Title + " | " + chunk.Source.SourcePath + " | " + chunk.Source.ChunkSha256);
                builder.AppendLine(chunk.Text);
                builder.AppendLine();
            }
        }

        builder.AppendLine("Answer with source-aware caveats. Do not claim authority to perform Passport actions.");
        return builder.ToString();
    }

    private static string ReadOpenAiCompatibleAnswer(string responseText)
    {
        using var document = JsonDocument.Parse(responseText);
        if (!document.RootElement.TryGetProperty("choices", out var choices) || choices.ValueKind != JsonValueKind.Array)
        {
            return string.Empty;
        }

        foreach (var choice in choices.EnumerateArray())
        {
            if (choice.TryGetProperty("message", out var message)
                && message.TryGetProperty("content", out var content)
                && content.ValueKind == JsonValueKind.String)
            {
                return content.GetString() ?? string.Empty;
            }
        }

        return string.Empty;
    }

    private static string ReadString(Dictionary<string, object?> record, string key)
    {
        return record.TryGetValue(key, out var value) ? value?.ToString() ?? string.Empty : string.Empty;
    }
}

public sealed record PassportHostedAiInferenceResult(bool Succeeded, string Message, string AnswerText, string ModelId)
{
    public static PassportHostedAiInferenceResult NotConfigured()
    {
        return new PassportHostedAiInferenceResult(false, "AI model runtime is not configured.", string.Empty, string.Empty);
    }

    public static PassportHostedAiInferenceResult Failed(string message)
    {
        return new PassportHostedAiInferenceResult(false, message, string.Empty, string.Empty);
    }

    public static PassportHostedAiInferenceResult Success(string answerText, string modelId)
    {
        return new PassportHostedAiInferenceResult(true, "AI model runtime response created.", answerText, modelId);
    }
}
