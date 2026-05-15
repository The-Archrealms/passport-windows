using System;
using System.IO;
using System.Security.Cryptography;
using System.Threading;
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
            SelectedProvisioningMode = NormalizeProvisioningMode(settings.SelectedProvisioningMode);
            SelectedIdentityMode = "named";
            ExistingIdentityId = settings.ExistingIdentityId;
            ActiveIdentityId = settings.ActiveIdentityId;
            ActiveDeviceId = settings.ActiveDeviceId;
            ActiveDeviceKeyPath = settings.ActiveDeviceKeyPath;
            ActiveWalletKeyId = settings.ActiveWalletKeyId;
            ActiveWalletKeyReferencePath = settings.ActiveWalletKeyReferencePath;
            ActiveWalletPublicKeyPath = settings.ActiveWalletPublicKeyPath;
            PendingDeviceId = settings.PendingDeviceId;
            PendingDeviceKeyPath = settings.PendingDeviceKeyPath;
            DeviceLabel = string.IsNullOrWhiteSpace(settings.DeviceLabel) ? Environment.MachineName : settings.DeviceLabel;
            JoinRequestPath = settings.JoinRequestPath;
            JoinApprovalPath = settings.JoinApprovalPath;
            WorkspaceRoot = string.IsNullOrWhiteSpace(settings.WorkspaceRoot) ? PassportEnvironment.GetDefaultWorkspaceRoot() : settings.WorkspaceRoot;
            IpfsRepoPath = string.IsNullOrWhiteSpace(settings.IpfsRepoPath) ? PassportEnvironment.GetDefaultIpfsRepoPath() : settings.IpfsRepoPath;
            IpfsCliPathOverride = settings.IpfsCliPathOverride;
            StorageAllocationGb = settings.StorageAllocationGb <= 0 ? 1 : settings.StorageAllocationGb;
            NodeParticipationMode = settings.ParticipateInPublicRegistry
                ? settings.NodeParticipationMode
                : "Read-only cache";
            NodeCachePolicy = settings.NodeCachePolicy;
            PreferWindowsHelloCredentials = settings.PreferWindowsHelloCredentials;
            PublishCarExports = settings.PublishCarExports;
            PreferWifiOnly = settings.PreferWifiOnly;
            ReadOnlyIpfsCid = settings.ReadOnlyIpfsCid;
            ReadOnlyIpfsRelativePath = settings.ReadOnlyIpfsRelativePath;
            ReadOnlyIpfsFetchedPathText = string.IsNullOrWhiteSpace(settings.ReadOnlyIpfsFetchedPath)
                ? "No read-only copy yet"
                : settings.ReadOnlyIpfsFetchedPath;
            AiGatewayUrl = ResolveAiGatewayUrl(settings.AiGatewayUrl);
            AiKnowledgePackId = string.IsNullOrWhiteSpace(settings.AiKnowledgePackId) ? "archrealms-mvp-approved-knowledge" : settings.AiKnowledgePackId;
            AiDiagnosticsUploadOptIn = settings.AiDiagnosticsUploadOptIn;
            UpdateMonetaryStatus();
            UpdateRecoveryReadiness();
        }

        private string ResolveAiGatewayUrl(string configuredGatewayUrl)
        {
            if (!string.IsNullOrWhiteSpace(configuredGatewayUrl)
                && !string.Equals(configuredGatewayUrl.Trim(), "https://ai.archrealms.local", StringComparison.OrdinalIgnoreCase))
            {
                return configuredGatewayUrl.Trim();
            }

            if (!string.IsNullOrWhiteSpace(_releaseLane.AiGatewayUrl))
            {
                return _releaseLane.AiGatewayUrl.Trim();
            }

            if (_releaseLane.ProductionLedger && !string.IsNullOrWhiteSpace(_releaseLane.ApiBaseUrl))
            {
                return _releaseLane.ApiBaseUrl.TrimEnd('/');
            }

            return "https://ai.archrealms.local";
        }

        private async Task SaveSettingsAsync()
        {
            _settingsStore.Save(CreateSettingsSnapshot());
            AppendLog("Saved Passport settings.");
            await RefreshStatusAsync();
        }

        private async Task RefreshStatusAsync()
        {
            var snapshot = await _statusService.GetSnapshotAsync(WorkspaceRoot, IpfsRepoPath, _toolRoot, IpfsCliPathOverride);
            var dispatcher = Application.Current?.Dispatcher;
            if (SynchronizationContext.Current == null
                || dispatcher == null
                || dispatcher.HasShutdownStarted
                || dispatcher.HasShutdownFinished
                || dispatcher.CheckAccess())
            {
                ApplyStatusSnapshot(snapshot);
                return;
            }

            await dispatcher.InvokeAsync(delegate { ApplyStatusSnapshot(snapshot); });
        }

        private void ApplyStatusSnapshot(ArchiveStatusSnapshot snapshot)
        {
            WorkspaceRoot = snapshot.WorkspaceRoot;
            if (string.IsNullOrWhiteSpace(IpfsRepoPath))
            {
                IpfsRepoPath = snapshot.IpfsRepoPath;
            }

            WorkspaceStateText = snapshot.WorkspaceReady ? snapshot.WorkspaceRoot : "Workspace unavailable";
            IpfsStateText = snapshot.IpfsCliSource;
            ResolvedIpfsCliPathText = snapshot.IpfsCliDetected ? snapshot.IpfsCliPath : "No runtime resolved";
            _storageNodePrepared = snapshot.IpfsNodePrepared;
            _storageNodeRunning = snapshot.NodeApiReachable;
            _preparedNodeId = snapshot.IpfsNodePrepared ? snapshot.NodePeerId : string.Empty;
            _activeNodeId = snapshot.NodeApiReachable ? snapshot.NodePeerId : string.Empty;
            var nodeState = string.IsNullOrWhiteSpace(snapshot.NodeHealthSummary)
                ? "Node not initialized"
                : snapshot.NodeHealthSummary;
            if (!string.IsNullOrWhiteSpace(snapshot.NodeStorageMax))
            {
                nodeState += "; storage " + snapshot.NodeStorageMax;
            }
            if (!string.IsNullOrWhiteSpace(snapshot.NodeParticipationMode))
            {
                nodeState += "; " + snapshot.NodeParticipationMode;
            }
            if (!string.IsNullOrWhiteSpace(snapshot.NodeCachePolicy))
            {
                nodeState += "; " + snapshot.NodeCachePolicy;
            }

            NodeStateText = nodeState;
            VerificationStateText = snapshot.VerificationSummary;
            RegistrySubmissionCidText = snapshot.RegistrySubmissionCid;

            if ((string.IsNullOrWhiteSpace(RegistrySubmissionText) || !File.Exists(RegistrySubmissionText))
                && !string.IsNullOrWhiteSpace(snapshot.LatestSubmissionPath))
            {
                RegistrySubmissionText = snapshot.LatestSubmissionPath;
            }

            RaiseHomePropertiesChanged();
            UpdateMonetaryStatus();
            UpdateRecoveryReadiness();
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
                AppendLog("Passport ID: " + joinResult.IdentityId);
                AppendLog("Pending device ID: " + joinResult.DeviceId);
                AppendLog("Device request: " + joinResult.JoinRequestPath);
                AppendLog("Device request signature: " + joinResult.RequestSignaturePath);
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
            ActiveWalletKeyId = string.Empty;
            ActiveWalletKeyReferencePath = string.Empty;
            ActiveWalletPublicKeyPath = string.Empty;
            PendingDeviceId = string.Empty;
            PendingDeviceKeyPath = string.Empty;
            _settingsStore.Save(CreateSettingsSnapshot());

            AppendLog(result.Message);
            AppendLog("Passport ID: " + result.IdentityId);
            AppendLog("This device ID: " + result.DeviceId);
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
            ActiveWalletKeyId = string.Empty;
            ActiveWalletKeyReferencePath = string.Empty;
            ActiveWalletPublicKeyPath = string.Empty;
            PendingDeviceId = string.Empty;
            PendingDeviceKeyPath = string.Empty;
            _settingsStore.Save(CreateSettingsSnapshot());

            AppendLog(result.Message);
            AppendLog("Identity record: " + result.IdentityRecordPath);
            AppendLog("Device credential record: " + result.DeviceRecordPath);
            AppendLog("Authorization record: " + result.AuthorizationRecordPath);

            await RefreshStatusAsync();
        }

        private static string NormalizeProvisioningMode(string provisioningMode)
        {
            if (string.Equals(
                provisioningMode,
                "Add this device to existing identity",
                StringComparison.Ordinal))
            {
                return "Add this device to a Passport";
            }

            if (string.Equals(
                provisioningMode,
                "Add this device to a Passport",
                StringComparison.Ordinal))
            {
                return provisioningMode;
            }

            return "Create a new Passport";
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
            TryCreateRegistrySubmission();
            return Task.CompletedTask;
        }

        private bool TryCreateRegistrySubmission()
        {
            var result = _cryptoService.CreateRegistrySubmission(
                WorkspaceRoot,
                ActiveIdentityId,
                ActiveDeviceId,
                ActiveDeviceKeyPath);

            if (!result.Succeeded)
            {
                AppendLog(result.Message);
                return false;
            }

            RegistrySubmissionText = result.SubmissionPath;
            RegistrySubmissionCidText = "Not published";
            AppendLog(result.Message);
            AppendLog("Submission package: " + result.SubmissionPath);
            AppendLog("Manifest: " + result.ManifestPath);
            AppendLog("Manifest signature: " + result.SignaturePath);
            AppendLog("Verified with public key: " + result.VerifiedWithPublicKey);
            return true;
        }
    }
}
