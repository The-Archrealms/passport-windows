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
            DeviceLabel = string.IsNullOrWhiteSpace(settings.DeviceLabel)
                ? Environment.MachineName
                : settings.DeviceLabel;
            WorkspaceRoot = string.IsNullOrWhiteSpace(settings.WorkspaceRoot)
                ? PassportEnvironment.GetDefaultWorkspaceRoot()
                : settings.WorkspaceRoot;
            IpfsRepoPath = string.IsNullOrWhiteSpace(settings.IpfsRepoPath)
                ? PassportEnvironment.GetDefaultIpfsRepoPath()
                : settings.IpfsRepoPath;
            StorageAllocationGb = settings.StorageAllocationGb <= 0 ? 25 : settings.StorageAllocationGb;
            ParticipateInPublicRegistry = settings.ParticipateInPublicRegistry;
            PublishCarExports = settings.PublishCarExports;
            PreferWifiOnly = settings.PreferWifiOnly;
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

            PassportProvisioningResult result;
            if (IsJoiningExistingIdentity)
            {
                result = _recordService.AddDeviceToIdentity(
                    WorkspaceRoot,
                    ExistingIdentityId.Trim(),
                    CitizenName,
                    SelectedIdentityMode,
                    DeviceLabel);
            }
            else
            {
                result = _recordService.CreateNewIdentity(
                    WorkspaceRoot,
                    CitizenName,
                    SelectedIdentityMode,
                    DeviceLabel);
            }

            if (!result.Succeeded)
            {
                AppendLog(result.Message);
                return;
            }

            ActiveIdentityId = result.IdentityId;
            ExistingIdentityId = result.IdentityId;
            ActiveDeviceId = result.DeviceId;
            ActiveDeviceKeyPath = result.PrivateKeyPath;
            _settingsStore.Save(CreateSettingsSnapshot());

            AppendLog(result.Message);
            AppendLog("Identity ID: " + result.IdentityId);
            AppendLog("Device ID: " + result.DeviceId);
            if (!string.IsNullOrWhiteSpace(result.IdentityRecordPath))
            {
                AppendLog("Identity record: " + result.IdentityRecordPath);
            }

            AppendLog("Device credential record: " + result.DeviceRecordPath);
            AppendLog("Public key: " + result.PublicKeyPath);
            AppendLog("Protected private key: " + result.PrivateKeyPath);

            await RefreshStatusAsync();
        }

        private Task GenerateChallengeAsync()
        {
            var bytes = new byte[24];
            RandomNumberGenerator.Fill(bytes);
            ChallengeText = Convert.ToBase64String(bytes)
                .TrimEnd('=')
                .Replace('+', '-')
                .Replace('/', '_');
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
