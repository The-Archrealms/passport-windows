using System;
using System.Collections.Generic;
using System.IO;
using System.Net;
using System.Net.Http;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using ArchrealmsPassport.Windows.Services;
using ArchrealmsPassport.Windows.Tests.Infrastructure;
using ArchrealmsPassport.Windows.ViewModels;
using Xunit;

namespace ArchrealmsPassport.Windows.Tests;

public sealed class PassportAiGatewayServiceTests
{
    [Fact]
    public void AiDisclosureStatesAuthorityPrivacyAndAdviceBoundaries()
    {
        Assert.Contains("AI can be wrong", PassportMainViewModel.AiDisclosure, StringComparison.Ordinal);
        Assert.Contains("not legal, financial, tax, accounting, securities, custody, or medical advice", PassportMainViewModel.AiDisclosure, StringComparison.Ordinal);
        Assert.Contains("cannot change wallet or credit status", PassportMainViewModel.AiDisclosure, StringComparison.Ordinal);
        Assert.Contains("Do not share secrets or sensitive files", PassportMainViewModel.AiDisclosure, StringComparison.Ordinal);
    }

    [Fact]
    public void AiGatewayCreatesSignedRequestAndShortLivedSessionWithoutStoringBearerToken()
    {
        using var workspace = PassportTestWorkspace.Create();
        var releaseLane = PassportReleaseLane.CreateDefault("production-mvp");
        var service = new PassportAiGatewayService(releaseLane);

        var request = service.CreateSessionRequest(
            workspace.Root,
            workspace.IdentityId,
            workspace.DeviceId,
            workspace.KeyReferencePath,
            "https://ai.archrealms.example",
            "archrealms-mvp-approved-knowledge",
            diagnosticsUploadOptIn: false);
        Assert.True(request.Succeeded, request.Message);

        var requestRecord = PassportTestWorkspace.ReadJson(request.RequestPath);
        Assert.Equal("passport_ai_session_request", PassportTestWorkspace.GetString(requestRecord, "record_type"));
        Assert.True(requestRecord.TryGetProperty("signature", out _));
        Assert.False(requestRecord.GetProperty("privacy").GetProperty("model_training_allowed").GetBoolean());
        Assert.False(requestRecord.GetProperty("session_token_policy").GetProperty("wallet_key_material_included").GetBoolean());
        Assert.False(requestRecord.GetProperty("authority_boundaries").GetProperty("can_execute_wallet_operations").GetBoolean());

        var session = service.CreateLocalGatewaySession(
            workspace.Root,
            request.RequestPath,
            request.RequestSha256,
            messageQuota: 25,
            tokenQuota: 10000,
            ttl: TimeSpan.FromMinutes(15));
        Assert.True(session.Succeeded, session.Message);
        Assert.False(string.IsNullOrWhiteSpace(session.SessionToken));

        var sessionJson = File.ReadAllText(session.SessionPath);
        Assert.DoesNotContain(session.SessionToken, sessionJson);
        Assert.Contains(session.SessionTokenSha256, sessionJson);

        var sessionRecord = PassportTestWorkspace.ReadJson(session.SessionPath);
        Assert.Equal("passport_ai_session_record", PassportTestWorkspace.GetString(sessionRecord, "record_type"));
        Assert.Equal(25, PassportTestWorkspace.GetInt64(sessionRecord.GetProperty("quota"), "message_limit"));
        Assert.False(sessionRecord.GetProperty("authority_boundaries").GetProperty("can_approve_recovery").GetBoolean());
    }

    [Fact]
    public async Task AiGatewayCreatesHostedSessionWhenGatewayIsRemote()
    {
        using var workspace = PassportTestWorkspace.Create();
        var releaseLane = PassportReleaseLane.CreateDefault("production-mvp");
        var token = "hosted-token";
        var tokenSha256 = ComputeSha256(Encoding.UTF8.GetBytes(token));
        var challengeRequested = false;
        var handler = new DelegateHttpMessageHandler(async request =>
        {
            Assert.Equal(HttpMethod.Post, request.Method);
            if (request.RequestUri!.AbsolutePath.EndsWith("/ai/challenge", StringComparison.Ordinal))
            {
                using var challengeBody = JsonDocument.Parse(await request.Content!.ReadAsStringAsync());
                var challengeRoot = challengeBody.RootElement;
                Assert.Equal(workspace.IdentityId, PassportTestWorkspace.GetString(challengeRoot, "archrealms_identity_id"));
                Assert.Equal(workspace.DeviceId, PassportTestWorkspace.GetString(challengeRoot, "device_id"));
                challengeRequested = true;
                var challengeRecord = new Dictionary<string, object?>
                {
                    ["schema_version"] = 1,
                    ["record_type"] = "passport_ai_challenge",
                    ["record_id"] = "challenge-1",
                    ["challenge_id"] = "challenge-1",
                    ["expires_utc"] = DateTime.UtcNow.AddMinutes(5).ToString("yyyy-MM-ddTHH:mm:ssZ"),
                    ["challenge_nonce"] = "hosted-nonce",
                    ["challenge_audience"] = "archrealms-ai-gateway",
                    ["requested_scopes"] = new[] { "ai_guide" }
                };
                var challengeResponse = new Dictionary<string, object?>
                {
                    ["succeeded"] = true,
                    ["message"] = "AI challenge issued.",
                    ["challenge_id"] = "challenge-1",
                    ["challenge_nonce"] = "hosted-nonce",
                    ["challenge_audience"] = "archrealms-ai-gateway",
                    ["expires_utc"] = DateTime.UtcNow.AddMinutes(5).ToString("yyyy-MM-ddTHH:mm:ssZ"),
                    ["challenge_record_sha256"] = new string('c', 64),
                    ["challenge_record"] = challengeRecord
                };

                return new HttpResponseMessage(HttpStatusCode.OK)
                {
                    Content = new StringContent(JsonSerializer.Serialize(challengeResponse), Encoding.UTF8, "application/json")
                };
            }

            Assert.True(challengeRequested);
            Assert.EndsWith("/ai/session", request.RequestUri.AbsolutePath, StringComparison.Ordinal);
            using var body = JsonDocument.Parse(await request.Content!.ReadAsStringAsync());
            var root = body.RootElement;
            Assert.Equal("passport_ai_session_request", PassportTestWorkspace.GetString(root.GetProperty("request_record"), "record_type"));
            var signedChallenge = root.GetProperty("request_record").GetProperty("challenge");
            Assert.Equal("challenge-1", PassportTestWorkspace.GetString(signedChallenge, "challenge_id"));
            Assert.Equal("hosted-nonce", PassportTestWorkspace.GetString(signedChallenge, "challenge_nonce"));
            Assert.False(string.IsNullOrWhiteSpace(PassportTestWorkspace.GetString(root, "signed_payload_base64")));
            Assert.False(string.IsNullOrWhiteSpace(PassportTestWorkspace.GetString(root, "signature_base64")));
            Assert.False(string.IsNullOrWhiteSpace(PassportTestWorkspace.GetString(root, "device_public_key_spki_der_base64")));

            var sessionRecord = new Dictionary<string, object?>
            {
                ["schema_version"] = 1,
                ["record_type"] = "passport_ai_session_record",
                ["record_id"] = "hosted-session-1",
                ["session_id"] = "hosted-session-1",
                ["created_utc"] = DateTime.UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ"),
                ["expires_utc"] = DateTime.UtcNow.AddMinutes(30).ToString("yyyy-MM-ddTHH:mm:ssZ"),
                ["status"] = "active",
                ["release_lane"] = releaseLane.Lane,
                ["ledger_namespace"] = releaseLane.LedgerNamespace,
                ["policy_version"] = releaseLane.PolicyVersion,
                ["session_token_sha256"] = tokenSha256,
                ["quota"] = new Dictionary<string, object?>
                {
                    ["message_limit"] = 25,
                    ["token_limit"] = 10000,
                    ["messages_used"] = 0,
                    ["tokens_used"] = 0
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
                }
            };
            var response = new Dictionary<string, object?>
            {
                ["succeeded"] = true,
                ["message"] = "AI session authorized.",
                ["session_id"] = "hosted-session-1",
                ["session_token"] = token,
                ["session_token_sha256"] = tokenSha256,
                ["expires_utc"] = DateTime.UtcNow.AddMinutes(30).ToString("yyyy-MM-ddTHH:mm:ssZ"),
                ["message_quota"] = 25,
                ["token_quota"] = 10000,
                ["session_record"] = sessionRecord
            };

            return new HttpResponseMessage(HttpStatusCode.OK)
            {
                Content = new StringContent(JsonSerializer.Serialize(response), Encoding.UTF8, "application/json")
            };
        });
        var service = new PassportAiGatewayService(releaseLane, new HttpClient(handler));
        var requestRecord = await service.CreateSessionRequestAsync(
            workspace.Root,
            workspace.IdentityId,
            workspace.DeviceId,
            workspace.KeyReferencePath,
            "https://ai.archrealms.example",
            "archrealms-mvp-approved-knowledge",
            diagnosticsUploadOptIn: false);
        Assert.True(requestRecord.Succeeded, requestRecord.Message);

        var session = await service.CreateGatewaySessionAsync(
            workspace.Root,
            requestRecord.RequestPath,
            requestRecord.RequestSha256,
            messageQuota: 25,
            tokenQuota: 10000,
            ttl: TimeSpan.FromMinutes(30));

        Assert.True(session.Succeeded, session.Message);
        Assert.Equal("hosted-session-1", session.SessionId);
        Assert.Equal(token, session.SessionToken);
        Assert.True(File.Exists(session.SessionPath));
        var sessionJson = File.ReadAllText(session.SessionPath);
        Assert.DoesNotContain(token, sessionJson);
        Assert.Contains(tokenSha256, sessionJson);
        Assert.Contains("request_record_path", sessionJson);
    }

    [Fact]
    public void AiGatewayRejectsRequestsWhenAiSessionsAreRevoked()
    {
        using var workspace = PassportTestWorkspace.Create();
        var releaseLane = PassportReleaseLane.CreateDefault("production-mvp");
        var freeze = new PassportRecoveryService(releaseLane).CreateAccountSecurityFreeze(
            workspace.Root,
            workspace.IdentityId,
            workspace.DeviceId,
            workspace.KeyReferencePath,
            "compromised_device",
            freezeWalletOperations: true,
            freezePendingEscrow: true,
            revokeAiSessions: true,
            pauseStorageNodeOperations: true);
        Assert.True(freeze.Succeeded, freeze.Message);

        var request = new PassportAiGatewayService(releaseLane).CreateSessionRequest(
            workspace.Root,
            workspace.IdentityId,
            workspace.DeviceId,
            workspace.KeyReferencePath,
            "https://ai.archrealms.example",
            "archrealms-mvp-approved-knowledge",
            diagnosticsUploadOptIn: false);

        Assert.False(request.Succeeded);
        Assert.Contains("revoked", request.Message, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public void AiGatewayRejectsTamperedSessionRequestHash()
    {
        using var workspace = PassportTestWorkspace.Create();
        var releaseLane = PassportReleaseLane.CreateDefault("production-mvp");
        var service = new PassportAiGatewayService(releaseLane);
        var request = service.CreateSessionRequest(
            workspace.Root,
            workspace.IdentityId,
            workspace.DeviceId,
            workspace.KeyReferencePath,
            "https://ai.archrealms.example",
            "archrealms-mvp-approved-knowledge",
            diagnosticsUploadOptIn: false);
        Assert.True(request.Succeeded, request.Message);

        var session = service.CreateLocalGatewaySession(
            workspace.Root,
            request.RequestPath,
            new string('0', 64),
            messageQuota: 25,
            tokenQuota: 10000,
            ttl: TimeSpan.FromMinutes(15));

        Assert.False(session.Succeeded);
        Assert.Contains("hash", session.Message, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public async Task AiGuideAnswersFromApprovedKnowledgePackWithoutStoringBearerTokenOrPrompt()
    {
        using var workspace = PassportTestWorkspace.Create();
        var releaseLane = PassportReleaseLane.CreateDefault("production-mvp");
        var gateway = new PassportAiGatewayService(releaseLane);
        var request = gateway.CreateSessionRequest(
            workspace.Root,
            workspace.IdentityId,
            workspace.DeviceId,
            workspace.KeyReferencePath,
            "https://ai.archrealms.local",
            "archrealms-mvp-approved-knowledge",
            diagnosticsUploadOptIn: false);
        Assert.True(request.Succeeded, request.Message);

        var session = gateway.CreateLocalGatewaySession(
            workspace.Root,
            request.RequestPath,
            request.RequestSha256,
            messageQuota: 25,
            tokenQuota: 10000,
            ttl: TimeSpan.FromMinutes(15));
        Assert.True(session.Succeeded, session.Message);

        var question = "Can the AI approve recovery or move wallet assets?";
        var guide = await new PassportAiGuideService(releaseLane).AskAsync(
            workspace.Root,
            AppContext.BaseDirectory,
            workspace.IdentityId,
            workspace.DeviceId,
            "https://ai.archrealms.local",
            "archrealms-mvp-approved-knowledge",
            session.SessionPath,
            session.SessionToken,
            question,
            diagnosticsUploadOptIn: false);

        Assert.True(guide.Succeeded, guide.Message);
        Assert.Contains("cannot approve recovery", guide.AnswerText, StringComparison.OrdinalIgnoreCase);
        Assert.NotEmpty(guide.Sources);
        Assert.True(File.Exists(guide.ChatRecordPath));

        var chatJson = File.ReadAllText(guide.ChatRecordPath);
        Assert.DoesNotContain(session.SessionToken, chatJson);
        Assert.DoesNotContain(question, chatJson);
        Assert.Contains(session.SessionTokenSha256, chatJson);

        var chatRecord = PassportTestWorkspace.ReadJson(guide.ChatRecordPath);
        Assert.Equal("passport_ai_chat_record", PassportTestWorkspace.GetString(chatRecord, "record_type"));
        Assert.False(chatRecord.GetProperty("model_training_allowed").GetBoolean());
        Assert.False(chatRecord.GetProperty("authority_boundaries").GetProperty("can_execute_wallet_operations").GetBoolean());
    }

    [Fact]
    public async Task AiGuideBlocksPrivateKeyMaterialBeforeChatRecordIsCreated()
    {
        using var workspace = PassportTestWorkspace.Create();
        var releaseLane = PassportReleaseLane.CreateDefault("production-mvp");

        var guide = await new PassportAiGuideService(releaseLane).AskAsync(
            workspace.Root,
            AppContext.BaseDirectory,
            workspace.IdentityId,
            workspace.DeviceId,
            "https://ai.archrealms.local",
            "archrealms-mvp-approved-knowledge",
            sessionPath: string.Empty,
            sessionToken: string.Empty,
            question: "wallet private key: abc123",
            diagnosticsUploadOptIn: false);

        Assert.False(guide.Succeeded);
        Assert.Contains("blocked", guide.Message, StringComparison.OrdinalIgnoreCase);
        Assert.False(Directory.Exists(Path.Combine(workspace.Root, "records", "passport", "ai", "chats")));
    }

    private static string ComputeSha256(byte[] value)
    {
        return Convert.ToHexString(SHA256.HashData(value)).ToLowerInvariant();
    }

    private sealed class DelegateHttpMessageHandler : HttpMessageHandler
    {
        private readonly Func<HttpRequestMessage, Task<HttpResponseMessage>> handler;

        public DelegateHttpMessageHandler(Func<HttpRequestMessage, Task<HttpResponseMessage>> handler)
        {
            this.handler = handler;
        }

        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            return handler(request);
        }
    }
}
