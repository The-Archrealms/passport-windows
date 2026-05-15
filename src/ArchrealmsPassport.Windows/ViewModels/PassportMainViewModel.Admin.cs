using System;
using System.IO;
using System.Threading.Tasks;
using ArchrealmsPassport.Windows.Models;
using ArchrealmsPassport.Windows.Services;

namespace ArchrealmsPassport.Windows.ViewModels
{
    public sealed partial class PassportMainViewModel
    {
        private Task HashAdminTargetRecordAsync()
        {
            if (string.IsNullOrWhiteSpace(AdminTargetRecordPath) || !File.Exists(AdminTargetRecordPath))
            {
                AdminAuthorityStatusText = "Admin target record path could not be found.";
                AppendLog(AdminAuthorityStatusText);
                return Task.CompletedTask;
            }

            AdminTargetRecordSha256 = PassportAdminAuthorityService.ComputeFileSha256(AdminTargetRecordPath);
            if (string.IsNullOrWhiteSpace(AdminTargetRecordId))
            {
                AdminTargetRecordId = Path.GetFileNameWithoutExtension(AdminTargetRecordPath);
            }

            AdminAuthorityStatusText = "Admin target record hash calculated.";
            AppendLog("Admin target SHA-256: " + AdminTargetRecordSha256);
            return Task.CompletedTask;
        }

        private Task CreateAdminAuthorityAsync()
        {
            if (string.IsNullOrWhiteSpace(AdminTargetRecordSha256))
            {
                AdminAuthorityStatusText = "Target record SHA-256 is required.";
                AppendLog(AdminAuthorityStatusText);
                return Task.CompletedTask;
            }

            if (string.IsNullOrWhiteSpace(AdminRequestedPayloadSha256))
            {
                AdminAuthorityStatusText = "Requested payload SHA-256 is required.";
                AppendLog(AdminAuthorityStatusText);
                return Task.CompletedTask;
            }

            var result = new PassportAdminAuthorityService(_releaseLane).CreateDualControlAction(
                WorkspaceRoot,
                ActiveIdentityId,
                ActiveDeviceId,
                ActiveDeviceKeyPath,
                AdminApproverDeviceId,
                AdminApproverDeviceKeyPath,
                AdminActionType,
                AdminAuthorityScope,
                AdminReasonCode,
                AdminTargetRecordId,
                AdminTargetRecordSha256,
                AdminRequestedPayloadSha256);

            AdminAuthorityStatusText = result.Message;
            AppendLog(result.Message);
            if (result.Succeeded)
            {
                LatestAdminAuthorityRecordText = result.RecordPath;
                LatestAdminRequesterSignatureText = result.RequesterSignaturePath;
                LatestAdminApproverSignatureText = result.ApproverSignaturePath;
                LatestAdminAuthorityEvidenceText = BuildAdminAuthorityEvidenceText(
                    result,
                    PassportAdminAuthorityService.ComputeFileSha256(result.RecordPath));
                AppendLog("Admin authority record: " + result.RecordPath);
                AppendLog("Admin authority requester signature: " + result.RequesterSignaturePath);
                AppendLog("Admin authority approver signature: " + result.ApproverSignaturePath);
            }

            return Task.CompletedTask;
        }

        public static string BuildAdminAuthorityEvidenceText(
            PassportAdminAuthorityResult result,
            string adminAuthorityRecordSha256)
        {
            if (result == null || string.IsNullOrWhiteSpace(result.RecordPath))
            {
                return "No admin authority evidence yet.";
            }

            return "admin_authority_record_path=" + result.RecordPath
                + Environment.NewLine
                + "admin_authority_record_sha256=" + (adminAuthorityRecordSha256 ?? string.Empty)
                + Environment.NewLine
                + "admin_authority_requester_signature_path=" + result.RequesterSignaturePath
                + Environment.NewLine
                + "admin_authority_approver_signature_path=" + result.ApproverSignaturePath;
        }

        private bool CanHashAdminTargetRecord()
        {
            return !string.IsNullOrWhiteSpace(AdminTargetRecordPath)
                && File.Exists(AdminTargetRecordPath);
        }

        private bool CanCreateAdminAuthority()
        {
            return CanUseActiveDeviceCredential()
                && !string.IsNullOrWhiteSpace(AdminApproverDeviceId)
                && !string.IsNullOrWhiteSpace(AdminApproverDeviceKeyPath)
                && PassportDeviceKeyStore.ReferenceExists(AdminApproverDeviceKeyPath);
        }
    }
}
