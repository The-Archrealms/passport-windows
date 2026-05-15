using System;
using System.Collections.Generic;
using System.IO;
using System.Threading.Tasks;
using ArchrealmsPassport.Windows.Services;

namespace ArchrealmsPassport.Windows.ViewModels
{
    public sealed partial class PassportMainViewModel
    {
        private Task CreateStorageRedemptionQuoteAsync()
        {
            var quote = new PassportStorageRedemptionService(_releaseLane).CreateQuote(
                WorkspaceRoot,
                GetMonetaryAccountId(),
                ActiveIdentityId,
                ActiveWalletKeyId,
                storageGb: Math.Max(1, (long)Math.Round(StorageRedemptionGb)),
                serviceEpochCount: Math.Max(1, StorageRedemptionEpochCount),
                ccPerGbEpochBaseUnits: Math.Max(1, StorageRedemptionCcPerGbEpoch),
                expiresUtc: DateTime.UtcNow.AddMinutes(15),
                serviceClass: StorageRedemptionServiceClass,
                quoteSource: "admin_set_mvp_storage_quote");
            if (!quote.Succeeded)
            {
                StorageRedemptionStatusText = quote.Message;
                AppendLog(quote.Message);
                return Task.CompletedTask;
            }

            LatestStorageRedemptionQuoteText = quote.RecordPath;
            LatestStorageRedemptionQuoteSha256 = quote.RecordSha256;
            StorageRedemptionStatusText = "Storage quote ready.";
            AppendLog(quote.Message);
            AppendLog("Storage quote: " + quote.RecordPath);
            return Task.CompletedTask;
        }

        private Task AcceptStorageRedemptionQuoteAsync()
        {
            var accepted = new PassportStorageRedemptionService(_releaseLane).AcceptQuote(
                WorkspaceRoot,
                LatestStorageRedemptionQuoteText,
                LatestStorageRedemptionQuoteSha256,
                ActiveWalletKeyReferencePath,
                ActiveWalletPublicKeyPath);
            if (!accepted.Succeeded)
            {
                StorageRedemptionStatusText = accepted.Message;
                AppendLog(accepted.Message);
                return Task.CompletedTask;
            }

            LatestStorageRedemptionAcceptedText = accepted.RecordPath;
            StorageRedemptionStatusText = "Storage redemption escrowed.";
            AppendLog(accepted.Message);
            AppendLog("Accepted storage redemption: " + accepted.RecordPath);
            return Task.CompletedTask;
        }

        private Task BurnStorageRedemptionEpochAsync()
        {
            var proofHash = PassportStorageRedemptionProofHash();
            if (string.IsNullOrWhiteSpace(proofHash))
            {
                StorageRedemptionStatusText = "Storage proof record could not be found.";
                AppendLog(StorageRedemptionStatusText);
                return Task.CompletedTask;
            }

            var burn = new PassportStorageRedemptionService(_releaseLane).BurnVerifiedEpoch(
                WorkspaceRoot,
                LatestStorageRedemptionAcceptedText,
                Math.Max(1, StorageRedemptionBurnCc),
                Math.Max(1, StorageRedemptionVerifiedGbDays),
                StorageRedemptionProofRecordPath,
                proofHash,
                ActiveWalletKeyReferencePath,
                ActiveWalletPublicKeyPath);
            StorageRedemptionStatusText = burn.Message;
            AppendLog(burn.Message);
            if (burn.Succeeded)
            {
                AppendLog("Storage burn: " + burn.RecordPath);
                UpdateMonetaryStatus();
            }

            return Task.CompletedTask;
        }

        private Task RefundStorageRedemptionAsync()
        {
            var refund = new PassportStorageRedemptionService(_releaseLane).RefundRemaining(
                WorkspaceRoot,
                LatestStorageRedemptionAcceptedText,
                Math.Max(1, StorageRedemptionRefundCc),
                "unused_or_failed_epochs",
                ActiveWalletKeyReferencePath,
                ActiveWalletPublicKeyPath);
            StorageRedemptionStatusText = refund.Message;
            AppendLog(refund.Message);
            if (refund.Succeeded)
            {
                AppendLog("Storage refund: " + refund.RecordPath);
                UpdateMonetaryStatus();
            }

            return Task.CompletedTask;
        }

        private Task HashStorageFailureEvidenceAsync()
        {
            if (string.IsNullOrWhiteSpace(StorageRedemptionFailureEvidencePath) || !File.Exists(StorageRedemptionFailureEvidencePath))
            {
                StorageRedemptionStatusText = "Storage failure evidence record could not be found.";
                AppendLog(StorageRedemptionStatusText);
                return Task.CompletedTask;
            }

            StorageRedemptionFailureEvidenceSha256 = PassportAdminAuthorityService.ComputeFileSha256(StorageRedemptionFailureEvidencePath);
            StorageRedemptionStatusText = "Storage failure evidence hash calculated.";
            AppendLog("Storage failure evidence SHA-256: " + StorageRedemptionFailureEvidenceSha256);
            return Task.CompletedTask;
        }

        private Task RecreditStorageRedemptionAsync()
        {
            var failureHash = ResolveStorageFailureEvidenceHash();
            if (string.IsNullOrWhiteSpace(failureHash))
            {
                StorageRedemptionStatusText = "Storage failure evidence record could not be found.";
                AppendLog(StorageRedemptionStatusText);
                return Task.CompletedTask;
            }

            var recredit = new PassportStorageRedemptionService(_releaseLane).RecreditFailedEpochByAdmin(
                WorkspaceRoot,
                LatestStorageRedemptionAcceptedText,
                Math.Max(1, StorageRedemptionRecreditCc),
                "failed_epoch",
                StorageRedemptionFailureEvidencePath,
                failureHash,
                GetStorageRedemptionAdminEvidence());
            StorageRedemptionStatusText = recredit.Message;
            AppendLog(recredit.Message);
            if (recredit.Succeeded)
            {
                AppendLog("Storage re-credit: " + recredit.RecordPath);
                UpdateMonetaryStatus();
            }

            return Task.CompletedTask;
        }

        private Task ExtendStorageRedemptionAsync()
        {
            var failureHash = ResolveStorageFailureEvidenceHash();
            if (string.IsNullOrWhiteSpace(failureHash))
            {
                StorageRedemptionStatusText = "Storage failure evidence record could not be found.";
                AppendLog(StorageRedemptionStatusText);
                return Task.CompletedTask;
            }

            var extension = new PassportStorageRedemptionService(_releaseLane).ExtendServiceByAdmin(
                WorkspaceRoot,
                LatestStorageRedemptionAcceptedText,
                Math.Max(1, StorageRedemptionExtensionEpochCount),
                "failed_epoch",
                StorageRedemptionFailureEvidencePath,
                failureHash,
                GetStorageRedemptionAdminEvidence());
            StorageRedemptionStatusText = extension.Message;
            AppendLog(extension.Message);
            if (extension.Succeeded)
            {
                AppendLog("Storage service extension: " + extension.RecordPath);
            }

            return Task.CompletedTask;
        }

        private bool CanCreateStorageRedemptionQuote()
        {
            return HasActiveWalletKey();
        }

        private bool CanAcceptStorageRedemptionQuote()
        {
            return HasActiveWalletKey()
                && !string.IsNullOrWhiteSpace(LatestStorageRedemptionQuoteSha256)
                && File.Exists(LatestStorageRedemptionQuoteText);
        }

        private bool CanBurnStorageRedemptionEpoch()
        {
            return HasActiveWalletKey()
                && File.Exists(LatestStorageRedemptionAcceptedText)
                && File.Exists(StorageRedemptionProofRecordPath);
        }

        private bool CanRefundStorageRedemption()
        {
            return HasActiveWalletKey() && File.Exists(LatestStorageRedemptionAcceptedText);
        }

        private bool CanHashStorageFailureEvidence()
        {
            return !string.IsNullOrWhiteSpace(StorageRedemptionFailureEvidencePath)
                && File.Exists(StorageRedemptionFailureEvidencePath);
        }

        private bool CanUseStorageAdminRemedy()
        {
            return File.Exists(LatestStorageRedemptionAcceptedText)
                && File.Exists(StorageRedemptionFailureEvidencePath)
                && GetStorageRedemptionAdminEvidence().Count > 0;
        }

        private string PassportStorageRedemptionProofHash()
        {
            if (string.IsNullOrWhiteSpace(StorageRedemptionProofRecordPath) || !File.Exists(StorageRedemptionProofRecordPath))
            {
                return string.Empty;
            }

            return PassportAdminAuthorityService.ComputeFileSha256(StorageRedemptionProofRecordPath);
        }

        private string ResolveStorageFailureEvidenceHash()
        {
            if (string.IsNullOrWhiteSpace(StorageRedemptionFailureEvidencePath) || !File.Exists(StorageRedemptionFailureEvidencePath))
            {
                return string.Empty;
            }

            if (string.IsNullOrWhiteSpace(StorageRedemptionFailureEvidenceSha256))
            {
                StorageRedemptionFailureEvidenceSha256 = PassportAdminAuthorityService.ComputeFileSha256(StorageRedemptionFailureEvidencePath);
            }

            return StorageRedemptionFailureEvidenceSha256;
        }

        private Dictionary<string, string> GetStorageRedemptionAdminEvidence()
        {
            var source = string.IsNullOrWhiteSpace(StorageRedemptionAdminEvidenceText)
                ? LatestAdminAuthorityEvidenceText
                : StorageRedemptionAdminEvidenceText;
            return ParseEvidenceText(source);
        }

        private static Dictionary<string, string> ParseEvidenceText(string text)
        {
            var values = new Dictionary<string, string>(StringComparer.Ordinal);
            if (string.IsNullOrWhiteSpace(text))
            {
                return values;
            }

            var lines = text.Split(new[] { "\r\n", "\n" }, StringSplitOptions.RemoveEmptyEntries);
            foreach (var line in lines)
            {
                var separator = line.IndexOf('=');
                if (separator <= 0)
                {
                    continue;
                }

                var key = line[..separator].Trim();
                var value = line[(separator + 1)..].Trim();
                if (!string.IsNullOrWhiteSpace(key) && !string.IsNullOrWhiteSpace(value))
                {
                    values[key] = value;
                }
            }

            return values;
        }
    }
}
