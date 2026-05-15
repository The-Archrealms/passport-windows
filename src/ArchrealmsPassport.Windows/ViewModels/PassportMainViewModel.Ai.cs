using System;
using System.Threading.Tasks;
using ArchrealmsPassport.Windows.Services;

namespace ArchrealmsPassport.Windows.ViewModels
{
    public sealed partial class PassportMainViewModel
    {
        private async Task CreateAiSessionAsync()
        {
            _settingsStore.Save(CreateSettingsSnapshot());

            var service = new PassportAiGatewayService(_releaseLane);
            var request = service.CreateSessionRequest(
                WorkspaceRoot,
                ActiveIdentityId,
                ActiveDeviceId,
                ActiveDeviceKeyPath,
                AiGatewayUrl,
                AiKnowledgePackId,
                AiDiagnosticsUploadOptIn);
            if (!request.Succeeded)
            {
                AiSessionStatusText = request.Message;
                AppendLog(request.Message);
                return;
            }

            LatestAiSessionRequestText = request.RequestPath;
            var session = await service.CreateGatewaySessionAsync(
                WorkspaceRoot,
                request.RequestPath,
                request.RequestSha256,
                messageQuota: 25,
                tokenQuota: 10000,
                ttl: TimeSpan.FromMinutes(30));
            if (!session.Succeeded)
            {
                AiSessionStatusText = session.Message;
                AppendLog(session.Message);
                return;
            }

            LatestAiSessionRecordText = session.SessionPath;
            _activeAiSessionToken = session.SessionToken;
            _activeAiSessionId = session.SessionId;
            AiSessionStatusText = "AI session active until " + session.ExpiresUtc + ".";
            AiQuotaSummaryText = session.MessageQuota + " messages; " + session.TokenQuota + " tokens.";
            AppendLog(request.Message);
            AppendLog("AI request: " + request.RequestPath);
            AppendLog(session.Message);
            AppendLog("AI session: " + session.SessionPath);
            RaiseCommandAvailability();
        }

        private async Task AskAiQuestionAsync()
        {
            _settingsStore.Save(CreateSettingsSnapshot());

            AiSessionStatusText = "Asking AI guide...";
            var service = new PassportAiGuideService(_releaseLane);
            var result = await service.AskAsync(
                WorkspaceRoot,
                _toolRoot,
                ActiveIdentityId,
                ActiveDeviceId,
                AiGatewayUrl,
                AiKnowledgePackId,
                LatestAiSessionRecordText,
                _activeAiSessionToken,
                AiQuestionText,
                AiDiagnosticsUploadOptIn);

            if (!result.Succeeded)
            {
                AiSessionStatusText = result.Message;
                AiAnswerText = result.AnswerText;
                AppendLog(result.Message);
                return;
            }

            AiAnswerText = result.AnswerText;
            LatestAiChatRecordText = result.ChatRecordPath;
            AiSessionStatusText = string.IsNullOrWhiteSpace(_activeAiSessionId)
                ? "AI answer ready."
                : "AI answer ready for session " + _activeAiSessionId + ".";
            if (!string.IsNullOrWhiteSpace(result.QuotaSummary))
            {
                AiQuotaSummaryText = result.QuotaSummary;
            }

            AppendLog(result.Message);
            AppendLog("AI chat record: " + result.ChatRecordPath);
        }

        private bool CanCreateAiSession()
        {
            return CanUseActiveDeviceCredential();
        }

        private bool CanAskAiQuestion()
        {
            return !string.IsNullOrWhiteSpace(_activeAiSessionToken)
                && !string.IsNullOrWhiteSpace(LatestAiSessionRecordText)
                && !string.Equals(LatestAiSessionRecordText, "No AI session yet.", StringComparison.Ordinal)
                && !string.IsNullOrWhiteSpace(AiQuestionText);
        }
    }
}
