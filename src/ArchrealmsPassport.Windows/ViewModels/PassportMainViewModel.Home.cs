using System;
using System.IO;
using System.Threading.Tasks;

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

            if (ParticipateInPublicRegistry && !HasActiveNode())
            {
                await InitializeNodeAsync();
                return;
            }

            if (!HasRegistrySubmissionPackage() && CanUseActiveDeviceCredential())
            {
                await CreateRegistrySubmissionAsync();
                return;
            }

            await RefreshStatusAsync();
        }

        private bool CanExecutePrimaryAction()
        {
            if (!HasActivePassport())
            {
                return CanProvisionIdentity();
            }

            if (ParticipateInPublicRegistry && !HasActiveNode())
            {
                return CanRunWorkspaceAction();
            }

            if (!HasRegistrySubmissionPackage())
            {
                return CanUseActiveDeviceCredential();
            }

            return true;
        }

        private bool HasActivePassport()
        {
            return !string.IsNullOrWhiteSpace(ActiveIdentityId);
        }

        private bool HasActiveNode()
        {
            return !string.IsNullOrWhiteSpace(_activeNodeId);
        }

        private bool HasRegistrySubmissionPackage()
        {
            return !string.IsNullOrWhiteSpace(RegistrySubmissionText)
                && !string.Equals(RegistrySubmissionText, "No registry submission package yet", StringComparison.Ordinal)
                && File.Exists(RegistrySubmissionText);
        }

        private bool IsPublishedRegistrySubmission()
        {
            return !string.IsNullOrWhiteSpace(RegistrySubmissionCidText)
                && !string.Equals(RegistrySubmissionCidText, "Not published", StringComparison.Ordinal);
        }

        private static string ShortenIdentifier(string value)
        {
            if (string.IsNullOrWhiteSpace(value) || value.Length <= 18)
            {
                return value;
            }

            return value.Substring(0, 10) + "..." + value.Substring(value.Length - 5);
        }

        private void RaiseHomePropertiesChanged()
        {
            OnPropertyChanged(nameof(PassportSummaryText));
            OnPropertyChanged(nameof(StorageSummaryText));
            OnPropertyChanged(nameof(LocalNodeSummaryText));
            OnPropertyChanged(nameof(RegistryPackageSummaryText));
            OnPropertyChanged(nameof(PrimaryActionLabel));
        }
    }
}
