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
            if (!HasActivePassport())
            {
                await ProvisionIdentityAsync();
                return;
            }

            if (!HasPreparedStorageNode())
            {
                await InitializeNodeAsync();
                return;
            }

            if (!HasActiveNode())
            {
                await StartNodeAsync();
                return;
            }

            if (!IsPublishedRegistrySubmission() && CanRegisterWithArchrealms())
            {
                await RegisterWithArchrealmsAsync();
                return;
            }
        }

        private bool CanExecutePrimaryAction()
        {
            if (!HasActivePassport())
            {
                return CanProvisionIdentity();
            }

            if (!HasPreparedStorageNode())
            {
                return CanRunWorkspaceAction();
            }

            if (!HasActiveNode())
            {
                return CanRunWorkspaceAction();
            }

            if (!IsPublishedRegistrySubmission())
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
            bool storageNodePrepared,
            bool storageNodeRunning,
            bool isPublishedRegistrySubmission)
        {
            if (!hasActivePassport)
            {
                return isJoiningExistingIdentity ? "Request Access" : "Create Passport";
            }

            if (!storageNodePrepared)
            {
                return "Enable Storage";
            }

            if (!storageNodeRunning)
            {
                return "Start Storage";
            }

            if (!isPublishedRegistrySubmission)
            {
                return "Register Passport";
            }

            return "Passport Ready";
        }

        internal static Visibility BuildPrimaryActionVisibility(bool storageNodePrepared, bool storageNodeRunning, bool isPublishedRegistrySubmission)
        {
            return storageNodePrepared && storageNodeRunning && isPublishedRegistrySubmission
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
            OnPropertyChanged(nameof(PrimaryActionLabel));
            OnPropertyChanged(nameof(PrimaryActionVisibility));
            _primaryActionCommand.RaiseCanExecuteChanged();
        }
    }
}
