using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.IO;
using System.Runtime.CompilerServices;
using System.Text;
using System.Threading.Tasks;
using ArchrealmsPassport.Windows.Models;
using ArchrealmsPassport.Windows.Services;

namespace ArchrealmsPassport.Windows.ViewModels
{
    public sealed partial class PassportMainViewModel
    {
        private async Task InitializeNodeAsync()
        {
            _settingsStore.Save(CreateSettingsSnapshot());

            var arguments = new List<string>
            {
                "-WorkspaceRoot", WorkspaceRoot,
                "-IpfsRepoPath", IpfsRepoPath,
                "-StorageMax", string.Format("{0:0}GB", Math.Round(StorageAllocationGb))
            };

            await RunScriptAsync(
                "tools\\ipfs\\Initialize-ArchrealmsIpfsNode.ps1",
                arguments,
                "Initialized Archrealms IPFS node.");
        }

        private async Task PublishRegistrySubmissionAsync()
        {
            _settingsStore.Save(CreateSettingsSnapshot());

            var arguments = new List<string>
            {
                "-SubmissionPath", RegistrySubmissionText,
                "-WorkspaceRoot", WorkspaceRoot,
                "-IpfsRepoPath", IpfsRepoPath
            };

            if (PublishCarExports)
            {
                arguments.Add("-ExportCar");
            }

            await RunScriptAsync(
                "tools\\passport\\Publish-ArchrealmsRegistrySubmissionToIpfs.ps1",
                arguments,
                "Published registry submission package to IPFS.");
        }

        private async Task RunScriptAsync(string scriptRelativePath, IReadOnlyList<string> arguments, string successMessage)
        {
            if (!CanRunWorkspaceAction())
            {
                AppendLog("Cannot run action because the Passport workspace or local tooling is not ready.");
                return;
            }

            var result = await _scriptRunner.RunAsync(_toolRoot, WorkspaceRoot, scriptRelativePath, arguments);
            if (result.Succeeded)
            {
                AppendLog(successMessage);
                if (!string.IsNullOrWhiteSpace(result.Stdout))
                {
                    AppendLog(result.Stdout);
                }
            }
            else
            {
                var builder = new StringBuilder();
                builder.AppendLine("Action failed: " + scriptRelativePath);
                if (!string.IsNullOrWhiteSpace(result.Stderr))
                {
                    builder.AppendLine(result.Stderr);
                }
                else if (!string.IsNullOrWhiteSpace(result.Stdout))
                {
                    builder.AppendLine(result.Stdout);
                }

                AppendLog(builder.ToString().Trim());
            }

            await RefreshStatusAsync();
        }

        private bool CanRunWorkspaceAction()
        {
            return Directory.Exists(PassportEnvironment.ResolveWorkspaceRoot(WorkspaceRoot))
                && PassportEnvironment.IsToolRoot(_toolRoot);
        }

        private bool CanProvisionIdentity()
        {
            if (!CanRunWorkspaceAction())
            {
                return false;
            }

            return !IsJoiningExistingIdentity || !string.IsNullOrWhiteSpace(ExistingIdentityId);
        }

        private bool CanApproveJoinRequest()
        {
            return CanUseActiveDeviceCredential()
                && !string.IsNullOrWhiteSpace(JoinRequestPath)
                && (File.Exists(JoinRequestPath) || Directory.Exists(JoinRequestPath));
        }

        private bool CanImportJoinApproval()
        {
            return CanRunWorkspaceAction()
                && !string.IsNullOrWhiteSpace(PendingDeviceId)
                && !string.IsNullOrWhiteSpace(PendingDeviceKeyPath)
                && PassportDeviceKeyStore.ReferenceExists(PendingDeviceKeyPath)
                && !string.IsNullOrWhiteSpace(JoinApprovalPath)
                && (File.Exists(JoinApprovalPath) || Directory.Exists(JoinApprovalPath));
        }

        private bool CanUseActiveDeviceCredential()
        {
            return CanRunWorkspaceAction()
                && !string.IsNullOrWhiteSpace(ActiveIdentityId)
                && !string.IsNullOrWhiteSpace(ActiveDeviceId)
                && !string.IsNullOrWhiteSpace(ActiveDeviceKeyPath)
                && PassportDeviceKeyStore.ReferenceExists(ActiveDeviceKeyPath);
        }

        private bool CanPublishRegistrySubmission()
        {
            return CanRunWorkspaceAction()
                && !string.IsNullOrWhiteSpace(RegistrySubmissionText)
                && File.Exists(RegistrySubmissionText);
        }

        private PassportSettings CreateSettingsSnapshot()
        {
            return new PassportSettings
            {
                CitizenName = CitizenName,
                SelectedProvisioningMode = SelectedProvisioningMode,
                SelectedIdentityMode = SelectedIdentityMode,
                ExistingIdentityId = ExistingIdentityId,
                ActiveIdentityId = ActiveIdentityId,
                ActiveDeviceId = ActiveDeviceId,
                ActiveDeviceKeyPath = ActiveDeviceKeyPath,
                PendingDeviceId = PendingDeviceId,
                PendingDeviceKeyPath = PendingDeviceKeyPath,
                DeviceLabel = DeviceLabel,
                JoinRequestPath = JoinRequestPath,
                JoinApprovalPath = JoinApprovalPath,
                WorkspaceRoot = WorkspaceRoot,
                IpfsRepoPath = IpfsRepoPath,
                StorageAllocationGb = Math.Max(5, (int)Math.Round(StorageAllocationGb)),
                ParticipateInPublicRegistry = ParticipateInPublicRegistry,
                PublishCarExports = PublishCarExports,
                PreferWifiOnly = PreferWifiOnly
            };
        }

        private void AppendLog(string message)
        {
            var timestamped = string.Format("[{0:yyyy-MM-dd HH:mm:ss}] {1}", DateTime.Now, message);
            ActivityLog = string.IsNullOrWhiteSpace(ActivityLog)
                ? timestamped
                : ActivityLog + Environment.NewLine + Environment.NewLine + timestamped;
        }

        private bool SetField<T>(ref T field, T value, [CallerMemberName] string? propertyName = null)
        {
            if (EqualityComparer<T>.Default.Equals(field, value))
            {
                return false;
            }

            field = value;
            OnPropertyChanged(propertyName);
            RaiseCommandAvailability();
            return true;
        }

        private void OnPropertyChanged([CallerMemberName] string? propertyName = null)
        {
            PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(propertyName));
        }

        private void RaiseCommandAvailability()
        {
            _saveSettingsCommand.RaiseCanExecuteChanged();
            _refreshStatusCommand.RaiseCanExecuteChanged();
            _initializeNodeCommand.RaiseCanExecuteChanged();
            _provisionIdentityCommand.RaiseCanExecuteChanged();
            _approveJoinRequestCommand.RaiseCanExecuteChanged();
            _importJoinApprovalCommand.RaiseCanExecuteChanged();
            _generateChallengeCommand.RaiseCanExecuteChanged();
            _signChallengeCommand.RaiseCanExecuteChanged();
            _createRegistrySubmissionCommand.RaiseCanExecuteChanged();
            _publishRegistrySubmissionCommand.RaiseCanExecuteChanged();
        }
    }
}
