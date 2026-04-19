using System;
using System.IO;
using System.Security.Cryptography;
using System.Threading.Tasks;
using System.Windows;
using ArchrealmsPassport.Windows.Models;
using ArchrealmsPassport.Windows.Services;

namespace ArchrealmsPassport.Windows.ViewModels
{
    public sealed partial class PassportMainViewModel
    {
        private void LoadSettings()
        {
            var settings = _settingsStore.Load();

            CitizenName = settings.CitizenName;
            SelectedProvisioningMode = string.IsNullOrWhiteSpace(settings.SelectedProvisioningMode)
                ? "Create new Passport identity"
                : settings.SelectedProvisioningMode;
            SelectedIdentityMode = string.IsNullOrWhiteSpace(settings.SelectedIdentityMode)
                ? "pseudonymous"
                : settings.SelectedIdentityMode;
            ExistingIdentityId = settings.ExistingIdentityId;
            ActiveIdentityId = settings.ActiveIdentityId;
            ActiveDeviceId = settings.ActiveDeviceId;
            ActiveDeviceKeyPath = settings.ActiveDeviceKeyPath;
            PendingDeviceId = settings.PendingDeviceId;
            PendingDeviceKeyPath = settings.PendingDeviceKeyPath;
            DeviceLabel = string.IsNullOrWhiteSpace(settings.DeviceLabel) ? Environment.MachineName : settings.DeviceLabel;
            JoinRequestPath = settings.JoinRequestPath;
            JoinApprovalPath = settings.JoinApprovalPath;
            WorkspaceRoot = string.IsNullOrWhiteSpace(settings.WorkspaceRoot) ? PassportEnvironment.GetDefaultWorkspaceRoot() : settings.WorkspaceRoot;
            IpfsRepoPath = string.IsNullOrWhiteSpace(settings.IpfsRepoPath) ? PassportEnvironment.GetDefaultIpfsRepoPath() : settings.IpfsRepoPath;
            StorageAllocationGb = settings.StorageAllocationGb <= 0 ? 25 : settings.StorageAllocationGb;
            ParticipateInPublicRegistry = settings.ParticipateInPublicRegistry;
            PreferWindowsHelloCredentials = settings.PreferWindowsHelloCredentials;
            PublishCarExports = settings.PublishCarExports;
            PreferWifiOnly = settings.PreferWifiOnly;
            ReadOnlyIpfsCid = settings.ReadOnlyIpfsCid;
            ReadOnlyIpfsRelativePath = settings.ReadOnlyIpfsRelativePath;
            ReadOnlyIpfsFetchedPathText = string.IsNullOrWhiteSpace(settings.ReadOnlyIpfsFetchedPath)
                ? "No read-only copy yet"
                : settings.ReadOnlyIpfsFetchedPath;
        }

        private async Task SaveSettingsAsync()
        {
            _settingsStore.Save(CreateSettingsSnapshot());
            AppendLog("Saved Passport settings.");
            await RefreshStatusAsync();
        }

        private async Task RefreshStatusAsync()
        {
            var snapshot = _statusService.GetSnapshot(WorkspaceRoot, IpfsRepoPath);

            await Application.Current.Dispatcher.InvokeAsync(delegate
            {
                WorkspaceRoot = snapshot.WorkspaceRoot;
                if (string.IsNullOrWhiteSpace(IpfsRepoPath))
                {
                    IpfsRepoPath = snapshot.IpfsRepoPath;
                }

                WorkspaceStateText = snapshot.WorkspaceReady ? snapshot.WorkspaceRoot : "Workspace unavailable";
                IpfsStateText = snapshot.IpfsCliDetected ? "ipfs.exe detected on PATH" : "ipfs.exe not detected";
                NodeStateText = snapshot.IpfsNodePrepared ? snapshot.NodePeerId : "Node not initialized";
                VerificationStateText = snapshot.VerificationSummary;
                RegistrySubmissionCidText = snapshot.RegistrySubmissionCid;

                if ((string.IsNullOrWhiteSpace(RegistrySubmissionText) || !File.Exists(RegistrySubmissionText))
                    && !string.IsNullOrWhiteSpace(snapshot.LatestSubmissionPath))
                {
                    RegistrySubmissionText = snapshot.LatestSubmissionPath;
                }
            });
        }

        private async Task ProvisionIdentityAsync()
        {
            _settingsStore.Save(CreateSettingsSnapshot());

            if (IsJoiningExistingIdentity)
            {
                var joinResult = _recordService.CreateJoinRequest(
                    WorkspaceRoot,
                    ExistingIdentityId.Trim(),
                    DeviceLabel,
                    PreferWindowsHelloCredentials);

                if (!joinResult.Succeeded)
                {
                    AppendLog(joinResult.Message);
                    return;
                }

                PendingDeviceId = joinResult.DeviceId;
                PendingDeviceKeyPath = joinResult.PrivateKeyPath;
                JoinRequestPath = joinResult.JoinRequestPath;
                JoinApprovalPath = string.Empty;
                _settingsStore.Save(CreateSettingsSnapshot());

                AppendLog(joinResult.Message);
                AppendLog("Identity ID: " + joinResult.IdentityId);
                AppendLog("Pending device ID: " + joinResult.DeviceId);
                AppendLog("Join request: " + joinResult.JoinRequestPath);
                AppendLog("Join request signature: " + joinResult.RequestSignaturePath);
                AppendLog("Candidate public key: " + joinResult.PublicKeyPath);
                AppendLog("Device key reference: " + joinResult.PrivateKeyPath);
                AppendLog("Key storage: " + PassportDeviceKeyStore.DescribeReference(joinResult.PrivateKeyPath));
                await RefreshStatusAsync();
                return;
            }

            var result = _recordService.CreateNewIdentity(
                WorkspaceRoot,
                CitizenName,
                SelectedIdentityMode,
                DeviceLabel,
                PreferWindowsHelloCredentials);

            if (!result.Succeeded)
            {
                AppendLog(result.Message);
                return;
            }

            ActiveIdentityId = result.IdentityId;
            ExistingIdentityId = result.IdentityId;
            ActiveDeviceId = result.DeviceId;
            ActiveDeviceKeyPath = result.PrivateKeyPath;
            PendingDeviceId = string.Empty;
            PendingDeviceKeyPath = string.Empty;
            _settingsStore.Save(CreateSettingsSnapshot());

            AppendLog(result.Message);
            AppendLog("Identity ID: " + result.IdentityId);
            AppendLog("Device ID: " + result.DeviceId);
            AppendLog("Identity record: " + result.IdentityRecordPath);
            AppendLog("Device credential record: " + result.DeviceRecordPath);
            AppendLog("Public key: " + result.PublicKeyPath);
            AppendLog("Device key reference: " + result.PrivateKeyPath);
            AppendLog("Key storage: " + PassportDeviceKeyStore.DescribeReference(result.PrivateKeyPath));

            await RefreshStatusAsync();
        }

        private Task ApproveJoinRequestAsync()
        {
            var result = _cryptoService.ApproveJoinRequest(
                WorkspaceRoot,
                ActiveIdentityId,
                ActiveDeviceId,
                ActiveDeviceKeyPath,
                JoinRequestPath);

            if (!result.Succeeded)
            {
                AppendLog(result.Message);
                return Task.CompletedTask;
            }

            JoinApprovalPath = result.ApprovalPackagePath;
            AppendLog(result.Message);
            AppendLog("Approval package: " + result.ApprovalPackagePath);
            AppendLog("Authorization record: " + result.AuthorizationRecordPath);
            AppendLog("Authorization signature: " + result.AuthorizationSignaturePath);
            _settingsStore.Save(CreateSettingsSnapshot());
            return Task.CompletedTask;
        }

        private async Task ImportJoinApprovalAsync()
        {
            var result = _cryptoService.ImportJoinApproval(
                WorkspaceRoot,
                JoinApprovalPath,
                PendingDeviceId,
                PendingDeviceKeyPath);

            if (!result.Succeeded)
            {
                AppendLog(result.Message);
                return;
            }

            ActiveIdentityId = result.IdentityId;
            ExistingIdentityId = result.IdentityId;
            ActiveDeviceId = result.DeviceId;
            ActiveDeviceKeyPath = PendingDeviceKeyPath;
            PendingDeviceId = string.Empty;
            PendingDeviceKeyPath = string.Empty;
            _settingsStore.Save(CreateSettingsSnapshot());

            AppendLog(result.Message);
            AppendLog("Identity record: " + result.IdentityRecordPath);
            AppendLog("Device credential record: " + result.DeviceRecordPath);
            AppendLog("Authorization record: " + result.AuthorizationRecordPath);

            await RefreshStatusAsync();
        }

        private Task GenerateChallengeAsync()
        {
            var bytes = new byte[24];
            RandomNumberGenerator.Fill(bytes);
            ChallengeText = Convert.ToBase64String(bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_');
            AppendLog("Generated a new Passport challenge.");
            return Task.CompletedTask;
        }

        private Task SignChallengeAsync()
        {
            var result = _cryptoService.SignChallenge(
                WorkspaceRoot,
                ActiveIdentityId,
                ActiveDeviceId,
                ActiveDeviceKeyPath,
                ChallengeText);

            if (!result.Succeeded)
            {
                AppendLog(result.Message);
                return Task.CompletedTask;
            }

            ChallengeSignatureText = result.SignatureRecordPath;
            AppendLog(result.Message);
            AppendLog("Challenge signature record: " + result.SignatureRecordPath);
            AppendLog("Verified with public key: " + result.VerifiedWithPublicKey);
            return Task.CompletedTask;
        }

        private Task CreateRegistrySubmissionAsync()
        {
            var result = _cryptoService.CreateRegistrySubmission(
                WorkspaceRoot,
                ActiveIdentityId,
                ActiveDeviceId,
                ActiveDeviceKeyPath);

            if (!result.Succeeded)
            {
                AppendLog(result.Message);
                return Task.CompletedTask;
            }

            RegistrySubmissionText = result.SubmissionPath;
            RegistrySubmissionCidText = "Not published";
            AppendLog(result.Message);
            AppendLog("Submission package: " + result.SubmissionPath);
            AppendLog("Manifest: " + result.ManifestPath);
            AppendLog("Manifest signature: " + result.SignaturePath);
            AppendLog("Verified with public key: " + result.VerifiedWithPublicKey);
            return Task.CompletedTask;
        }
    }
}
