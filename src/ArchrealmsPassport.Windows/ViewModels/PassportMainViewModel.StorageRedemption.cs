using System;
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

        private string PassportStorageRedemptionProofHash()
        {
            if (string.IsNullOrWhiteSpace(StorageRedemptionProofRecordPath) || !File.Exists(StorageRedemptionProofRecordPath))
            {
                return string.Empty;
            }

            return PassportAdminAuthorityService.ComputeFileSha256(StorageRedemptionProofRecordPath);
        }
    }
}
