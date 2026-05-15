using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;
using ArchrealmsPassport.Windows.Models;

namespace ArchrealmsPassport.Windows.Services
{
    public sealed class PassportAiGuideService
    {
        private static readonly JsonSerializerOptions JsonOptions = new JsonSerializerOptions
        {
            WriteIndented = true
        };

        private readonly PassportReleaseLane releaseLane;
        private readonly HttpClient httpClient;
        private readonly PassportAiKnowledgePackService knowledgePackService;

        public PassportAiGuideService(
            PassportReleaseLane? releaseLane = null,
            HttpClient? httpClient = null,
            PassportAiKnowledgePackService? knowledgePackService = null)
        {
            this.releaseLane = releaseLane ?? PassportEnvironment.GetReleaseLane();
            this.httpClient = httpClient ?? new HttpClient();
            this.knowledgePackService = knowledgePackService ?? new PassportAiKnowledgePackService();
        }

        public async Task<PassportAiGuideResult> AskAsync(
            string workspaceRoot,
            string toolRoot,
            string identityId,
            string deviceId,
            string gatewayUrl,
            string knowledgePackId,
            string sessionPath,
            string sessionToken,
            string question,
            bool diagnosticsUploadOptIn,
            CancellationToken cancellationToken = default(CancellationToken))
        {
            try
            {
                var resolvedWorkspaceRoot = PassportEnvironment.ResolveWorkspaceRoot(workspaceRoot);
                if (string.IsNullOrWhiteSpace(question))
                {
                    return Failed("Enter a question for the Archrealms AI guide.");
                }

                if (ContainsSecretMaterial(question))
                {
                    return Failed("Passport blocked this prompt because it appears to contain private key, seed, or recovery-secret material.");
                }

                var sessionValidation = ValidateSession(resolvedWorkspaceRoot, sessionPath, sessionToken);
                if (!sessionValidation.Succeeded)
                {
                    return sessionValidation;
                }

                var retrieval = knowledgePackService.Retrieve(toolRoot, knowledgePackId, question, maxChunks: 3);
                PassportAiGuideResult answer;
                if (ShouldUseHostedGateway(gatewayUrl))
                {
                    answer = await AskHostedGatewayAsync(
                        gatewayUrl,
                        sessionValidation.Message,
                        knowledgePackId,
                        sessionToken,
                        question,
                        diagnosticsUploadOptIn,
                        retrieval,
                        cancellationToken).ConfigureAwait(false);
                    if (!answer.Succeeded)
                    {
                        return answer;
                    }
                }
                else
                {
                    answer = CreateLocalApprovedKnowledgeAnswer(question, retrieval);
                }

                var chatRecord = WriteChatRecord(
                    resolvedWorkspaceRoot,
                    identityId,
                    deviceId,
                    gatewayUrl,
                    knowledgePackId,
                    sessionPath,
                    sessionValidation.Message,
                    sessionToken,
                    question,
                    answer.AnswerText,
                    diagnosticsUploadOptIn,
                    ShouldUseHostedGateway(gatewayUrl) ? "hosted_gateway" : "local_approved_knowledge_preview",
                    answer.Sources);

                answer.ChatRecordPath = chatRecord.RecordPath;
                answer.ChatRecordSha256 = chatRecord.RecordSha256;
                if (string.IsNullOrWhiteSpace(answer.QuotaSummary))
                {
                    answer.QuotaSummary = ReadQuotaSummary(resolvedWorkspaceRoot, sessionPath);
                }

                answer.Message = "AI guide answer created from approved knowledge context.";
                return answer;
            }
            catch (Exception ex)
            {
                return Failed("AI guide failed: " + ex.Message);
            }
        }

        private async Task<PassportAiGuideResult> AskHostedGatewayAsync(
            string gatewayUrl,
            string sessionId,
            string knowledgePackId,
            string sessionToken,
            string question,
            bool diagnosticsUploadOptIn,
            PassportAiKnowledgePackRetrievalResult retrieval,
            CancellationToken cancellationToken)
        {
            var endpoint = BuildGatewayEndpoint(gatewayUrl, "/ai/chat");
            var payload = new Dictionary<string, object?>
            {
                ["session_id"] = sessionId,
                ["knowledge_pack_id"] = knowledgePackId,
                ["message"] = question,
                ["diagnostics_upload_opt_in"] = diagnosticsUploadOptIn,
                ["release_lane"] = releaseLane.Lane,
                ["policy_version"] = releaseLane.PolicyVersion,
                ["client_approved_context_refs"] = retrieval.Chunks.Select(chunk => new Dictionary<string, object?>
                {
                    ["source_id"] = chunk.SourceId,
                    ["title"] = chunk.Title,
                    ["source_path"] = chunk.SourcePath,
                    ["source_sha256"] = chunk.SourceSha256,
                    ["chunk_sha256"] = chunk.ChunkSha256
                }).ToArray()
            };

            using var request = new HttpRequestMessage(HttpMethod.Post, endpoint);
            request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", sessionToken);
            request.Content = new StringContent(JsonSerializer.Serialize(payload, JsonOptions), Encoding.UTF8, "application/json");

            using var response = await httpClient.SendAsync(request, cancellationToken).ConfigureAwait(false);
            var responseText = await response.Content.ReadAsStringAsync(cancellationToken).ConfigureAwait(false);
            if (!response.IsSuccessStatusCode)
            {
                return Failed("Hosted AI gateway rejected the chat request: " + response.StatusCode);
            }

            using var document = JsonDocument.Parse(responseText);
            var root = document.RootElement;
            var answerText = ReadString(root, "answer_text");
            if (string.IsNullOrWhiteSpace(answerText))
            {
                answerText = ReadString(root, "answer");
            }

            if (string.IsNullOrWhiteSpace(answerText))
            {
                return Failed("Hosted AI gateway returned no answer text.");
            }

            var result = new PassportAiGuideResult
            {
                Succeeded = true,
                AnswerText = answerText,
                QuotaSummary = ReadString(root, "quota_summary")
            };

            if (root.TryGetProperty("sources", out var sources) && sources.ValueKind == JsonValueKind.Array)
            {
                foreach (var source in sources.EnumerateArray())
                {
                    result.Sources.Add(new PassportAiSourceReference
                    {
                        SourceId = ReadString(source, "source_id"),
                        Title = ReadString(source, "title"),
                        SourcePath = ReadString(source, "source_path"),
                        SourceSha256 = ReadString(source, "source_sha256"),
                        ChunkSha256 = ReadString(source, "chunk_sha256")
                    });
                }
            }

            if (result.Sources.Count == 0)
            {
                foreach (var source in retrieval.Chunks)
                {
                    result.Sources.Add(ToSourceReference(source));
                }
            }

            return result;
        }

        private static PassportAiGuideResult CreateLocalApprovedKnowledgeAnswer(
            string question,
            PassportAiKnowledgePackRetrievalResult retrieval)
        {
            if (retrieval.Chunks.Count == 0)
            {
                return new PassportAiGuideResult
                {
                    Succeeded = true,
                    AnswerText = "I could not find approved Archrealms source material for that question in the selected knowledge pack. No wallet, recovery, ledger, storage-delivery, registry-authority, or admin action was taken."
                };
            }

            var terms = PassportAiKnowledgePackService.Tokenize(question).ToArray();
            var answer = new StringBuilder();
            answer.AppendLine("From approved Archrealms MVP sources:");
            foreach (var chunk in retrieval.Chunks)
            {
                answer.Append("- ");
                answer.Append(chunk.Title);
                answer.Append(": ");
                answer.AppendLine(SelectRelevantExcerpt(chunk.Text, terms));
            }

            answer.AppendLine();
            answer.Append("AI boundary: this guide cannot approve recovery, move assets, issue or burn credits, release escrow, mark service delivered, change registry authority, execute wallet operations, or override identity status.");

            var result = new PassportAiGuideResult
            {
                Succeeded = true,
                AnswerText = answer.ToString()
            };
            foreach (var source in retrieval.Chunks)
            {
                result.Sources.Add(ToSourceReference(source));
            }

            return result;
        }

        private PassportAiGuideResult ValidateSession(string workspaceRoot, string sessionPath, string sessionToken)
        {
            if (string.IsNullOrWhiteSpace(sessionToken))
            {
                return Failed("Connect AI before asking a question.");
            }

            var resolvedSessionPath = ResolveWorkspaceRelativePath(workspaceRoot, sessionPath);
            if (string.IsNullOrWhiteSpace(resolvedSessionPath) || !File.Exists(resolvedSessionPath))
            {
                return Failed("AI session record could not be found. Connect AI again.");
            }

            using var document = JsonDocument.Parse(File.ReadAllText(resolvedSessionPath));
            var root = document.RootElement;
            if (!Matches(root, "record_type", "passport_ai_session_record"))
            {
                return Failed("AI session record has an unsupported type.");
            }

            if (!Matches(root, "release_lane", releaseLane.Lane) || !Matches(root, "ledger_namespace", releaseLane.LedgerNamespace))
            {
                return Failed("AI session belongs to another release lane or ledger namespace.");
            }

            if (!DateTime.TryParse(ReadString(root, "expires_utc"), out var expiresUtc) || expiresUtc.ToUniversalTime() <= DateTime.UtcNow)
            {
                return Failed("AI session expired. Connect AI again.");
            }

            var expectedTokenSha256 = ReadString(root, "session_token_sha256");
            var actualTokenSha256 = ComputeSha256(Encoding.UTF8.GetBytes(sessionToken));
            if (!string.Equals(expectedTokenSha256, actualTokenSha256, StringComparison.OrdinalIgnoreCase))
            {
                return Failed("AI session token does not match the active session.");
            }

            return new PassportAiGuideResult
            {
                Succeeded = true,
                Message = ReadString(root, "session_id")
            };
        }

        private static ChatRecordResult WriteChatRecord(
            string workspaceRoot,
            string identityId,
            string deviceId,
            string gatewayUrl,
            string knowledgePackId,
            string sessionPath,
            string sessionId,
            string sessionToken,
            string question,
            string answer,
            bool diagnosticsUploadOptIn,
            string mode,
            IReadOnlyList<PassportAiSourceReference> sources)
        {
            var chatRoot = Path.Combine(workspaceRoot, "records", "passport", "ai", "chats");
            Directory.CreateDirectory(chatRoot);
            var chatId = DateTime.UtcNow.ToString("yyyyMMddTHHmmssZ") + "-ai-chat-" + Guid.NewGuid().ToString("N")[..10];
            var recordPath = Path.Combine(chatRoot, chatId + ".json");
            var record = new Dictionary<string, object?>
            {
                ["schema_version"] = 1,
                ["record_type"] = "passport_ai_chat_record",
                ["record_id"] = chatId,
                ["created_utc"] = DateTime.UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ"),
                ["mode"] = mode,
                ["archrealms_identity_id"] = identityId,
                ["device_id"] = deviceId,
                ["session_id"] = sessionId,
                ["session_record_path"] = ToWorkspaceRelativePath(workspaceRoot, ResolveWorkspaceRelativePath(workspaceRoot, sessionPath)),
                ["session_token_sha256"] = ComputeSha256(Encoding.UTF8.GetBytes(sessionToken)),
                ["gateway_url"] = gatewayUrl,
                ["approved_knowledge_pack_id"] = knowledgePackId,
                ["question_sha256"] = ComputeSha256(Encoding.UTF8.GetBytes(question)),
                ["answer_sha256"] = ComputeSha256(Encoding.UTF8.GetBytes(answer)),
                ["diagnostics_upload_opt_in"] = diagnosticsUploadOptIn,
                ["model_training_allowed"] = false,
                ["raw_prompt_retention_days"] = 30,
                ["sources"] = sources.Select(source => new Dictionary<string, object?>
                {
                    ["source_id"] = source.SourceId,
                    ["title"] = source.Title,
                    ["source_path"] = source.SourcePath,
                    ["source_sha256"] = source.SourceSha256,
                    ["chunk_sha256"] = source.ChunkSha256
                }).ToArray(),
                ["runtime_contract"] = new Dictionary<string, object?>
                {
                    ["passport_calls_gateway_only"] = true,
                    ["gateway_chat_endpoint"] = "/ai/chat",
                    ["model_runtime"] = "gateway_managed_open_weight",
                    ["passport_calls_model_runtime_directly"] = false
                },
                ["authority_boundaries"] = new Dictionary<string, object?>
                {
                    ["can_approve_recovery"] = false,
                    ["can_issue_credits"] = false,
                    ["can_release_escrow"] = false,
                    ["can_mark_service_delivered"] = false,
                    ["can_burn_credits"] = false,
                    ["can_change_registry_authority"] = false,
                    ["can_execute_wallet_operations"] = false,
                    ["can_override_identity_status"] = false,
                    ["can_approve_admin_authority"] = false
                },
                ["summary"] = "AI guide chat audit record. Prompt and answer text are not stored; hashes and approved source references are retained for audit."
            };

            File.WriteAllText(recordPath, JsonSerializer.Serialize(record, JsonOptions), Encoding.UTF8);
            return new ChatRecordResult
            {
                RecordPath = recordPath,
                RecordSha256 = ComputeSha256(File.ReadAllBytes(recordPath))
            };
        }

        private static string ReadQuotaSummary(string workspaceRoot, string sessionPath)
        {
            var resolvedSessionPath = ResolveWorkspaceRelativePath(workspaceRoot, sessionPath);
            if (!File.Exists(resolvedSessionPath))
            {
                return string.Empty;
            }

            using var document = JsonDocument.Parse(File.ReadAllText(resolvedSessionPath));
            if (!document.RootElement.TryGetProperty("quota", out var quota))
            {
                return string.Empty;
            }

            return ReadInt64(quota, "message_limit") + " messages; " + ReadInt64(quota, "token_limit") + " tokens.";
        }

        private static string SelectRelevantExcerpt(string text, string[] terms)
        {
            var normalized = Regex.Replace(text, @"\s+", " ").Trim();
            var sentences = Regex.Split(normalized, @"(?<=[.!?])\s+");
            var selected = sentences
                .OrderByDescending(sentence => terms.Count(term => sentence.IndexOf(term, StringComparison.OrdinalIgnoreCase) >= 0))
                .ThenBy(sentence => sentence.Length)
                .FirstOrDefault(sentence => !string.IsNullOrWhiteSpace(sentence));

            if (string.IsNullOrWhiteSpace(selected))
            {
                selected = normalized;
            }

            return selected.Length <= 360 ? selected : selected.Substring(0, 357).TrimEnd() + "...";
        }

        private static bool ContainsSecretMaterial(string value)
        {
            if (string.IsNullOrWhiteSpace(value))
            {
                return false;
            }

            return Regex.IsMatch(value, "-----BEGIN [A-Z ]*PRIVATE KEY-----", RegexOptions.IgnoreCase)
                || Regex.IsMatch(value, "(wallet private key|device private key|recovery secret|seed phrase)\\s*[:=]\\s*\\S+", RegexOptions.IgnoreCase)
                || Regex.IsMatch(value, "\\b(seed|mnemonic)\\s*[:=]\\s*([a-z]+\\s+){11,23}[a-z]+\\b", RegexOptions.IgnoreCase);
        }

        private static bool ShouldUseHostedGateway(string gatewayUrl)
        {
            if (!Uri.TryCreate(gatewayUrl, UriKind.Absolute, out var uri))
            {
                return false;
            }

            return !string.Equals(uri.Host, "ai.archrealms.local", StringComparison.OrdinalIgnoreCase);
        }

        private static Uri BuildGatewayEndpoint(string gatewayUrl, string relativePath)
        {
            var baseUri = new Uri(gatewayUrl.TrimEnd('/') + "/");
            return new Uri(baseUri, relativePath.TrimStart('/'));
        }

        private static PassportAiSourceReference ToSourceReference(PassportAiSourceReference source)
        {
            return new PassportAiSourceReference
            {
                SourceId = source.SourceId,
                Title = source.Title,
                SourcePath = source.SourcePath,
                SourceSha256 = source.SourceSha256,
                ChunkSha256 = source.ChunkSha256
            };
        }

        private static bool Matches(JsonElement root, string propertyName, string expected)
        {
            return root.TryGetProperty(propertyName, out var property)
                && property.ValueKind == JsonValueKind.String
                && string.Equals(property.GetString() ?? string.Empty, expected, StringComparison.Ordinal);
        }

        private static string ReadString(JsonElement root, string propertyName)
        {
            return root.TryGetProperty(propertyName, out var property) && property.ValueKind == JsonValueKind.String
                ? property.GetString() ?? string.Empty
                : string.Empty;
        }

        private static long ReadInt64(JsonElement root, string propertyName)
        {
            return root.TryGetProperty(propertyName, out var property) && property.ValueKind == JsonValueKind.Number && property.TryGetInt64(out var value)
                ? value
                : 0;
        }

        private static string ResolveWorkspaceRelativePath(string workspaceRoot, string path)
        {
            if (string.IsNullOrWhiteSpace(path))
            {
                return string.Empty;
            }

            var normalized = path.Replace('/', Path.DirectorySeparatorChar);
            return Path.IsPathRooted(normalized)
                ? Path.GetFullPath(normalized)
                : Path.GetFullPath(Path.Combine(workspaceRoot, normalized));
        }

        private static string ToWorkspaceRelativePath(string workspaceRoot, string path)
        {
            var root = Path.GetFullPath(workspaceRoot).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
            var fullPath = Path.GetFullPath(path);
            return fullPath.StartsWith(root, StringComparison.OrdinalIgnoreCase)
                ? fullPath[root.Length..].TrimStart(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar).Replace(Path.DirectorySeparatorChar, '/')
                : path.Replace(Path.DirectorySeparatorChar, '/');
        }

        private static string ComputeSha256(byte[] value)
        {
            return Convert.ToHexString(SHA256.HashData(value)).ToLowerInvariant();
        }

        private static PassportAiGuideResult Failed(string message)
        {
            return new PassportAiGuideResult
            {
                Succeeded = false,
                Message = message,
                AnswerText = message
            };
        }

        private sealed class ChatRecordResult
        {
            public string RecordPath { get; set; } = string.Empty;

            public string RecordSha256 { get; set; } = string.Empty;
        }
    }
}
