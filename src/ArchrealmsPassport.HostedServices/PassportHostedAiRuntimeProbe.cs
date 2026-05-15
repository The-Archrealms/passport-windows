using System.Text.Json.Serialization;
using ArchrealmsPassport.HostedServices.Contracts;

namespace ArchrealmsPassport.HostedServices;

public sealed record PassportHostedAiRuntimeProbe
{
    [JsonPropertyName("schema")]
    public string Schema { get; init; } = "archrealms.passport.hosted_ai_runtime_probe.v1";

    [JsonPropertyName("ready")]
    public bool Ready { get; init; }

    [JsonPropertyName("model_id")]
    public string ModelId { get; init; } = string.Empty;

    [JsonPropertyName("runtime_answer_received")]
    public bool RuntimeAnswerReceived { get; init; }

    [JsonPropertyName("missing")]
    public string[] Missing { get; init; } = Array.Empty<string>();

    [JsonPropertyName("message")]
    public string Message { get; init; } = string.Empty;

    public static async Task<PassportHostedAiRuntimeProbe> CreateAsync(
        IPassportHostedAiInferenceGateway inferenceGateway,
        CancellationToken cancellationToken)
    {
        if (!inferenceGateway.IsConfigured)
        {
            return Failed("ARCHREALMS_PASSPORT_AI_INFERENCE_BASE_URL");
        }

        PassportHostedAiInferenceResult result;
        try
        {
            result = await inferenceGateway.CreateAnswerAsync(
                new PassportAiChatRequest
                {
                    KnowledgePackId = "archrealms-mvp-readiness-probe",
                    Message = "Readiness probe. Confirm the hosted AI runtime can answer.",
                    PolicyVersion = "passport-production-mvp-readiness"
                },
                new Dictionary<string, object?> { ["release_lane"] = "production-mvp" },
                new[]
                {
                    new PassportHostedKnowledgeChunk(
                        new PassportAiSourceRef
                        {
                            SourceId = "production-mvp-readiness-probe",
                            Title = "Production MVP Readiness Probe",
                            SourcePath = "hosted-readiness://ai-runtime-probe",
                            SourceSha256 = new string('0', 64),
                            ChunkSha256 = new string('1', 64)
                        },
                        "This is a non-mutating hosted AI runtime readiness probe. The AI guide remains non-authoritative.",
                        Approved: true)
                },
                cancellationToken);
        }
        catch (OperationCanceledException)
        {
            throw;
        }
        catch (Exception ex)
        {
            return new PassportHostedAiRuntimeProbe
            {
                Ready = false,
                RuntimeAnswerReceived = false,
                Missing = new[] { "hosted AI runtime answer" },
                Message = "Hosted AI runtime probe failed: " + ex.Message
            };
        }

        if (!result.Succeeded || string.IsNullOrWhiteSpace(result.AnswerText))
        {
            return new PassportHostedAiRuntimeProbe
            {
                Ready = false,
                ModelId = result.ModelId,
                RuntimeAnswerReceived = false,
                Missing = new[] { "hosted AI runtime answer" },
                Message = result.Message
            };
        }

        return new PassportHostedAiRuntimeProbe
        {
            Ready = true,
            ModelId = result.ModelId,
            RuntimeAnswerReceived = true,
            Message = "Hosted AI runtime probe answered."
        };
    }

    private static PassportHostedAiRuntimeProbe Failed(string missing)
    {
        return new PassportHostedAiRuntimeProbe
        {
            Ready = false,
            RuntimeAnswerReceived = false,
            Missing = new[] { missing },
            Message = "Hosted AI runtime probe is not configured."
        };
    }
}
