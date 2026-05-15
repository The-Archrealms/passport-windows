using System.Net;
using System.Text;
using System.Text.Json;
using ArchrealmsPassport.HostedServices;
using ArchrealmsPassport.HostedServices.Contracts;
using Xunit;

namespace ArchrealmsPassport.HostedServices.Tests;

public sealed class PassportHostedAiRuntimeTests
{
    [Fact]
    public void KnowledgeStoreRetrievesApprovedChunksOnly()
    {
        using var workspace = TemporaryDirectory.Create();
        var packRoot = Path.Combine(workspace.Path, "records", "ai", "knowledge-packs", "archrealms-mvp-approved-knowledge");
        Directory.CreateDirectory(packRoot);
        File.WriteAllLines(
            Path.Combine(packRoot, "chunks.jsonl"),
            new[]
            {
                JsonSerializer.Serialize(new Dictionary<string, object?>
                {
                    ["source_id"] = "recovery-1",
                    ["title"] = "Recovery Rules",
                    ["source_path"] = "docs/recovery.md",
                    ["source_sha256"] = new string('a', 64),
                    ["chunk_sha256"] = new string('b', 64),
                    ["approval_status"] = "approved",
                    ["text"] = "AI cannot approve recovery, wallet rotation, or Crown authority actions."
                }),
                JsonSerializer.Serialize(new Dictionary<string, object?>
                {
                    ["source_id"] = "draft-1",
                    ["title"] = "Draft",
                    ["source_path"] = "docs/draft.md",
                    ["source_sha256"] = new string('c', 64),
                    ["chunk_sha256"] = new string('d', 64),
                    ["approval_status"] = "draft",
                    ["text"] = "This draft must not be used."
                })
            });
        var store = new PassportHostedKnowledgeStore(workspace.Path);

        var chunks = store.Retrieve("archrealms-mvp-approved-knowledge", "Can AI approve recovery?", 3);

        var chunk = Assert.Single(chunks);
        Assert.Equal("recovery-1", chunk.Source.SourceId);
        Assert.Contains("cannot approve recovery", chunk.Text, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public async Task InferenceGatewayCallsOpenAiCompatibleRuntime()
    {
        var handler = new CapturingHandler();
        using var client = new HttpClient(handler)
        {
            BaseAddress = new Uri("https://model-runtime.example/v1/")
        };
        var gateway = new PassportHostedAiInferenceGateway(
            client,
            "Qwen/Qwen3-8B",
            "system prompt",
            maxOutputTokens: 128,
            temperature: 0.1);

        var result = await gateway.CreateAnswerAsync(
            new PassportAiChatRequest
            {
                KnowledgePackId = "archrealms-mvp-approved-knowledge",
                Message = "What can AI approve?",
                PolicyVersion = "passport-release-lanes-v1"
            },
            new Dictionary<string, object?> { ["release_lane"] = "staging" },
            new[]
            {
                new PassportHostedKnowledgeChunk(
                    new PassportAiSourceRef
                    {
                        SourceId = "source-1",
                        Title = "Authority",
                        SourcePath = "docs/authority.md",
                        SourceSha256 = new string('e', 64),
                        ChunkSha256 = new string('f', 64)
                    },
                    "AI cannot approve wallet, recovery, ledger, or admin actions.",
                    Approved: true)
            });

        Assert.True(result.Succeeded, result.Message);
        Assert.Equal("Qwen/Qwen3-8B", result.ModelId);
        Assert.Equal("Runtime answer.", result.AnswerText);
        Assert.Equal("https://model-runtime.example/v1/chat/completions", handler.RequestUri);
        Assert.Contains("AI cannot approve wallet", handler.RequestBody, StringComparison.Ordinal);
        Assert.Contains("\"model\":\"Qwen/Qwen3-8B\"", handler.RequestBody, StringComparison.Ordinal);
    }

    private sealed class CapturingHandler : HttpMessageHandler
    {
        public string RequestUri { get; private set; } = string.Empty;

        public string RequestBody { get; private set; } = string.Empty;

        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            RequestUri = request.RequestUri?.ToString() ?? string.Empty;
            RequestBody = request.Content == null ? string.Empty : await request.Content.ReadAsStringAsync(cancellationToken);
            return new HttpResponseMessage(HttpStatusCode.OK)
            {
                Content = new StringContent(
                    "{\"choices\":[{\"message\":{\"content\":\"Runtime answer.\"}}]}",
                    Encoding.UTF8,
                    "application/json")
            };
        }
    }

    private sealed class TemporaryDirectory : IDisposable
    {
        private TemporaryDirectory(string path)
        {
            Path = path;
            Directory.CreateDirectory(path);
        }

        public string Path { get; }

        public static TemporaryDirectory Create()
        {
            return new TemporaryDirectory(System.IO.Path.Combine(System.IO.Path.GetTempPath(), "archrealms-hosted-ai-tests", Guid.NewGuid().ToString("N")));
        }

        public void Dispose()
        {
            try
            {
                if (Directory.Exists(Path))
                {
                    Directory.Delete(Path, true);
                }
            }
            catch
            {
            }
        }
    }
}
