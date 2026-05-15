using System;
using System.IO;
using System.Threading.Tasks;
using System.Windows;

namespace ArchrealmsPassport.Windows.ViewModels
{
    public sealed partial class PassportMainViewModel
    {
        private async Task ExecutePrimaryActionAsync()
        {
            await RunPassportSetupAsync();
        }

        private async Task RunPassportSetupAsync()
        {
            if (!HasActivePassport())
            {
                await ProvisionIdentityAsync();
                if (!HasActivePassport())
                {
                    return;
                }
            }

            if (!HasActiveWalletKey())
            {
                if (!CanBindWalletKey())
                {
                    AppendLog("Passport is active, but wallet key binding is not available yet.");
                    return;
                }

                await BindWalletKeyAsync();
                if (!HasActiveWalletKey())
                {
                    return;
                }
            }

            if (!ParticipateInPublicRegistry)
            {
                if (!HasRegistrySubmissionPackage())
                {
                    TryCreateRegistrySubmission();
                    await RefreshRegistryBrowserAsync();
                }

                return;
            }

            if (!HasPreparedStorageNode())
            {
                await InitializeNodeAsync();
                if (!HasPreparedStorageNode())
                {
                    return;
                }
            }

            if (!HasActiveNode())
            {
                await StartNodeAsync();
                if (!HasActiveNode())
                {
                    return;
                }
            }

            if (!IsRegistrationCompleteForCurrentMode() && CanRegisterWithArchrealms())
            {
                await RegisterWithArchrealmsAsync();
                await RefreshRegistryBrowserAsync();
            }
        }

        private bool CanExecutePrimaryAction()
        {
            if (!HasActivePassport())
            {
                return CanProvisionIdentity();
            }

            if (!HasActiveWalletKey())
            {
                return CanBindWalletKey();
            }

            if (!ParticipateInPublicRegistry)
            {
                return !HasRegistrySubmissionPackage() && CanUseActiveDeviceCredential();
            }

            if (!HasPreparedStorageNode())
            {
                return CanRunWorkspaceAction();
            }

            if (!HasActiveNode())
            {
                return CanRunWorkspaceAction();
            }

            if (!IsRegistrationCompleteForCurrentMode())
            {
                return CanRegisterWithArchrealms();
            }

            return false;
        }

        private async Task RegisterWithArchrealmsAsync()
        {
            if (!HasRegistrySubmissionPackage() && !TryCreateRegistrySubmission())
            {
                return;
            }

            if (!CanPublishRegistrySubmission())
            {
                AppendLog("Registration package is ready, but the local node must be enabled before it can be published.");
                return;
            }

            await PublishRegistrySubmissionAsync();
        }

        private bool CanRegisterWithArchrealms()
        {
            if (IsPublishedRegistrySubmission() || !HasActiveNode())
            {
                return false;
            }

            return HasRegistrySubmissionPackage()
                ? CanPublishRegistrySubmission()
                : CanUseActiveDeviceCredential();
        }

        private bool HasActivePassport()
        {
            return !string.IsNullOrWhiteSpace(ActiveIdentityId);
        }

        private bool HasActiveNode()
        {
            return _storageNodeRunning;
        }

        private bool HasPreparedStorageNode()
        {
            return _storageNodePrepared;
        }

        private bool HasRegistrySubmissionPackage()
        {
            return !string.IsNullOrWhiteSpace(RegistrySubmissionText)
                && !string.Equals(RegistrySubmissionText, "No registry submission package yet", StringComparison.Ordinal)
                && !string.Equals(RegistrySubmissionText, "No registration package yet", StringComparison.Ordinal)
                && File.Exists(RegistrySubmissionText);
        }

        private bool IsPublishedRegistrySubmission()
        {
            return !string.IsNullOrWhiteSpace(RegistrySubmissionCidText)
                && !string.Equals(RegistrySubmissionCidText, "Not published", StringComparison.Ordinal);
        }

        private bool IsRegistrationCompleteForCurrentMode()
        {
            return ParticipateInPublicRegistry
                ? IsPublishedRegistrySubmission()
                : HasRegistrySubmissionPackage();
        }

        private static string ShortenIdentifier(string value)
        {
            if (string.IsNullOrWhiteSpace(value) || value.Length <= 24)
            {
                return value;
            }

            return value.Substring(0, 10) + "..." + value.Substring(value.Length - 5);
        }

        private string GetPassportDisplayName()
        {
            if (!string.IsNullOrWhiteSpace(CitizenName))
            {
                return CitizenName.Trim();
            }

            return ShortenIdentifier(ActiveIdentityId);
        }

        internal static string BuildStorageSummaryText(bool participatesInPublicRegistry, bool storageNodePrepared, bool storageNodeRunning, string storageAllocationLabel)
        {
            if (!participatesInPublicRegistry)
            {
                return "Read-only";
            }

            if (storageNodeRunning)
            {
                return "Running: " + storageAllocationLabel;
            }

            return storageNodePrepared
                ? "Paused: " + storageAllocationLabel
                : "Not enabled";
        }

        internal static string BuildHomeStorageOptInLabel(string storageAllocationLabel)
        {
            return "Contribute " + storageAllocationLabel + " storage";
        }

        internal static string BuildLocalNodeSummaryText(bool participatesInPublicRegistry, bool storageNodePrepared, bool storageNodeRunning)
        {
            if (storageNodeRunning)
            {
                return "Online";
            }

            if (storageNodePrepared)
            {
                return "Paused";
            }

            return participatesInPublicRegistry
                ? "Not running"
                : "Off";
        }

        internal static string BuildPrimaryActionLabel(
            bool hasActivePassport,
            bool isJoiningExistingIdentity,
            bool hasActiveWallet,
            bool participatesInPublicRegistry,
            bool storageNodePrepared,
            bool storageNodeRunning,
            bool isRegistrationComplete)
        {
            if (!hasActivePassport)
            {
                return isJoiningExistingIdentity ? "Request Access" : "Create Passport";
            }

            if (!hasActiveWallet)
            {
                return "Finish Setup";
            }

            if (!participatesInPublicRegistry)
            {
                return isRegistrationComplete ? "Passport Ready" : "Prepare Registration";
            }

            if (!storageNodePrepared)
            {
                return "Enable Storage";
            }

            if (!storageNodeRunning)
            {
                return "Start Storage";
            }

            if (!isRegistrationComplete)
            {
                return "Register Passport";
            }

            return "Passport Ready";
        }

        internal static Visibility BuildPrimaryActionVisibility(
            bool hasActiveWallet,
            bool participatesInPublicRegistry,
            bool storageNodePrepared,
            bool storageNodeRunning,
            bool isRegistrationComplete)
        {
            var storageReady = !participatesInPublicRegistry || (storageNodePrepared && storageNodeRunning);
            return hasActiveWallet && storageReady && isRegistrationComplete
                ? Visibility.Collapsed
                : Visibility.Visible;
        }

        private void RaiseHomePropertiesChanged()
        {
            OnPropertyChanged(nameof(PassportSummaryText));
            OnPropertyChanged(nameof(StorageSummaryText));
            OnPropertyChanged(nameof(LocalNodeSummaryText));
            OnPropertyChanged(nameof(RegistryPackageSummaryText));
            OnPropertyChanged(nameof(HomePassportNameInputVisibility));
            OnPropertyChanged(nameof(HomeStorageOptInLabel));
            OnPropertyChanged(nameof(PrimaryActionLabel));
            OnPropertyChanged(nameof(PrimaryActionVisibility));
            _primaryActionCommand.RaiseCanExecuteChanged();
        }
    }
}
