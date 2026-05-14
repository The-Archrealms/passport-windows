using System;
using System.Globalization;
using System.Linq;
using System.Threading.Tasks;
using ArchrealmsPassport.Windows.Models;
using ArchrealmsPassport.Windows.Services;

namespace ArchrealmsPassport.Windows.ViewModels
{
    public sealed partial class PassportMainViewModel
    {
        private Task BindWalletKeyAsync()
        {
            _settingsStore.Save(CreateSettingsSnapshot());

            var result = new PassportWalletKeyService(_releaseLane).CreateAndBindWalletKey(
                WorkspaceRoot,
                ActiveIdentityId,
                ActiveDeviceId,
                ActiveDeviceKeyPath);

            if (!result.Succeeded)
            {
                AppendLog(result.Message);
                UpdateMonetaryStatus();
                return Task.CompletedTask;
            }

            ActiveWalletKeyId = result.WalletKeyId;
            ActiveWalletKeyReferencePath = result.WalletKeyReferencePath;
            ActiveWalletPublicKeyPath = result.WalletPublicKeyPath;
            _settingsStore.Save(CreateSettingsSnapshot());

            AppendLog(result.Message);
            AppendLog("Wallet key ID: " + result.WalletKeyId);
            AppendLog("Wallet binding: " + result.BindingRecordPath);
            AppendLog("Wallet binding signature: " + result.BindingSignaturePath);
            AppendLog("Wallet key storage: " + PassportDeviceKeyStore.DescribeReference(result.WalletKeyReferencePath));
            AppendLog("Verified with Passport device key: " + result.VerifiedWithDeviceKey);

            UpdateMonetaryStatus();
            return Task.CompletedTask;
        }

        private Task RefreshMonetaryLedgerAsync()
        {
            UpdateMonetaryStatus();
            AppendLog("Refreshed ARCH/CC ledger status.");
            return Task.CompletedTask;
        }

        private Task ExportMonetaryLedgerAsync()
        {
            _settingsStore.Save(CreateSettingsSnapshot());

            var export = new PassportMonetaryLedgerService(_releaseLane).CreateAccountExport(
                WorkspaceRoot,
                GetMonetaryAccountId());

            if (!export.Succeeded)
            {
                MonetaryExportText = export.Message;
                AppendLog(export.Message);
                return Task.CompletedTask;
            }

            MonetaryExportText = export.ManifestPath;
            AppendLog(export.Message);
            AppendLog("Account export manifest: " + export.ManifestPath);
            AppendLog("Transparency root: " + export.TransparencyRootPath);
            AppendLog("Export SHA-256: " + export.ExportRootSha256);
            UpdateMonetaryStatus();
            return Task.CompletedTask;
        }

        private bool CanBindWalletKey()
        {
            return CanUseActiveDeviceCredential() && !HasActiveWalletKey();
        }

        private bool CanRefreshMonetaryLedger()
        {
            return CanRunWorkspaceAction();
        }

        private bool CanExportMonetaryLedger()
        {
            return CanRunWorkspaceAction()
                && HasActivePassport()
                && HasActiveWalletKey();
        }

        private bool HasActiveWalletKey()
        {
            if (string.IsNullOrWhiteSpace(ActiveIdentityId)
                || string.IsNullOrWhiteSpace(ActiveWalletKeyId)
                || string.IsNullOrWhiteSpace(ActiveWalletKeyReferencePath)
                || string.IsNullOrWhiteSpace(ActiveWalletPublicKeyPath))
            {
                return false;
            }

            try
            {
                return PassportDeviceKeyStore.ReferenceExists(ActiveWalletKeyReferencePath)
                    && System.IO.File.Exists(ActiveWalletPublicKeyPath)
                    && new PassportWalletKeyService(_releaseLane).IsWalletKeyActive(
                        WorkspaceRoot,
                        ActiveIdentityId,
                        ActiveWalletKeyId);
            }
            catch
            {
                return false;
            }
        }

        private string GetMonetaryAccountId()
        {
            return string.IsNullOrWhiteSpace(ActiveIdentityId)
                ? string.Empty
                : "passport-" + ActiveIdentityId.Trim();
        }

        private void UpdateMonetaryStatus()
        {
            if (!HasActivePassport())
            {
                WalletSummaryText = "Create a Passport before binding a wallet key.";
                MonetaryLedgerSummaryText = "No Passport account.";
                return;
            }

            if (!HasActiveWalletKey())
            {
                WalletSummaryText = string.IsNullOrWhiteSpace(ActiveWalletKeyId)
                    ? "No wallet key bound."
                    : "Wallet key needs attention: " + ShortenIdentifier(ActiveWalletKeyId);
                MonetaryLedgerSummaryText = "Bind a wallet key before ARCH/CC records can be signed.";
                return;
            }

            WalletSummaryText = "Ready: " + ShortenIdentifier(ActiveWalletKeyId);

            var replay = new PassportMonetaryLedgerService(_releaseLane).Replay(WorkspaceRoot);
            MonetaryLedgerSummaryText = BuildMonetaryLedgerSummary(
                hasActivePassport: true,
                hasActiveWallet: true,
                replay,
                GetMonetaryAccountId());
        }

        internal static string BuildMonetaryLedgerSummary(
            bool hasActivePassport,
            bool hasActiveWallet,
            PassportMonetaryLedgerReplayResult replay,
            string accountId)
        {
            if (!hasActivePassport)
            {
                return "No Passport account.";
            }

            if (!hasActiveWallet)
            {
                return "Bind a wallet key before ARCH/CC records can be signed.";
            }

            if (!replay.Succeeded)
            {
                return "Ledger replay failed: " + string.Join("; ", replay.Failures);
            }

            var accountBalances = replay.Balances
                .Where(balance => string.Equals(balance.AccountId, accountId, StringComparison.Ordinal))
                .OrderBy(balance => balance.AssetCode, StringComparer.Ordinal)
                .ToArray();

            if (accountBalances.Length == 0)
            {
                return replay.EventCount == 0
                    ? "Wallet ready; no ARCH/CC ledger events loaded."
                    : "Wallet ready; no ARCH/CC events for this Passport account.";
            }

            return string.Join("; ", accountBalances.Select(FormatBalance));
        }

        private static string FormatBalance(PassportMonetaryBalance balance)
        {
            if (string.Equals(balance.AssetCode, PassportMonetaryLedgerService.AssetCrownCredit, StringComparison.Ordinal))
            {
                return string.Format(
                    CultureInfo.InvariantCulture,
                    "CC available {0}, escrowed {1}, burned {2}",
                    balance.AvailableBaseUnits,
                    balance.EscrowedBaseUnits,
                    balance.BurnedBaseUnits);
            }

            return string.Format(
                CultureInfo.InvariantCulture,
                "{0} available {1}",
                balance.AssetCode,
                balance.AvailableBaseUnits);
        }
    }
}
