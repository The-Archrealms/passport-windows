using System;
using System.Threading.Tasks;
using ArchrealmsPassport.Windows.Services;

namespace ArchrealmsPassport.Windows.ViewModels
{
    public sealed partial class PassportMainViewModel
    {
        private Task CreateAiSessionAsync()
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
                return Task.CompletedTask;
            }

            LatestAiSessionRequestText = request.RequestPath;
            var session = service.CreateLocalGatewaySession(
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
                return Task.CompletedTask;
            }

            LatestAiSessionRecordText = session.SessionPath;
            AiSessionStatusText = "AI session active until " + session.ExpiresUtc + ".";
            AiQuotaSummaryText = session.MessageQuota + " messages; " + session.TokenQuota + " tokens.";
            AppendLog(request.Message);
            AppendLog("AI request: " + request.RequestPath);
            AppendLog(session.Message);
            AppendLog("AI session: " + session.SessionPath);
            return Task.CompletedTask;
        }

        private bool CanCreateAiSession()
        {
            return CanUseActiveDeviceCredential();
        }
    }
}
