using System;
using System.Collections.Generic;
using System.IO;
using System.Text.Json;
using System.Threading.Tasks;
using ArchrealmsPassport.Windows.Services;
using ArchrealmsPassport.Windows.Tests.Infrastructure;
using Xunit;

namespace ArchrealmsPassport.Windows.Tests;

public sealed class PassportAiGatewayServiceTests
{
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
}
