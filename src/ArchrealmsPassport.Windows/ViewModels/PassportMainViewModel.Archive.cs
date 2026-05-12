using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.IO;
using System.Runtime.CompilerServices;
using System.Threading.Tasks;
using ArchrealmsPassport.Windows.Models;
using ArchrealmsPassport.Windows.Services;

namespace ArchrealmsPassport.Windows.ViewModels
{
    public sealed partial class PassportMainViewModel
    {
        private string GetActiveNodeId()
        {
            return string.IsNullOrWhiteSpace(_activeNodeId) ? string.Empty : _activeNodeId;
        }

        private async Task InitializeNodeAsync()
        {
            try
            {
                EnableStorageParticipation();
                _settingsStore.Save(CreateSettingsSnapshot());

                StorageActionStatusText = "Enabling storage...";
                AppendLog("Enabling Passport storage.");

                var initializeResult = await _localNodeService.InitializeAsync(
                    _toolRoot,
                    WorkspaceRoot,
                    IpfsRepoPath,
                    StorageAllocationGb,
                    NodeParticipationMode,
                    NodeCachePolicy,
                    GetStorageGcWatermark(),
                    GetNodeProvideStrategy(),
                    IpfsCliPathOverride);

                AppendLocalNodeResult(initializeResult, "Prepared Archrealms storage node.");
                if (!initializeResult.Succeeded)
                {
                    StorageActionStatusText = "Storage setup failed: " + initializeResult.Message;
                    await RefreshStatusAsync();
                    return;
                }

                StorageActionStatusText = "Starting storage node...";
                var startResult = await _localNodeService.StartAsync(
                    _toolRoot,
                    WorkspaceRoot,
                    IpfsRepoPath,
                    IpfsCliPathOverride);

                AppendLocalNodeResult(startResult, "Started Archrealms storage node.");
                StorageActionStatusText = startResult.Succeeded
                    ? "Storage is enabled and the local node is running."
                    : "Storage was prepared, but node startup failed: " + startResult.Message;
                await RefreshStatusAsync();
            }
            catch (Exception ex)
            {
                StorageActionStatusText = "Storage setup failed: " + ex.Message;
                AppendLog(StorageActionStatusText);
                await RefreshStatusAsync();
            }
        }

        private async Task StartNodeAsync()
        {
            _settingsStore.Save(CreateSettingsSnapshot());

            var result = await _localNodeService.StartAsync(
                _toolRoot,
                WorkspaceRoot,
                IpfsRepoPath,
                IpfsCliPathOverride);

            AppendLocalNodeResult(result, "Started local IPFS node.");
            await RefreshStatusAsync();
        }

        private async Task StopNodeAsync()
        {
            _settingsStore.Save(CreateSettingsSnapshot());

            var result = await _localNodeService.StopAsync(
                _toolRoot,
                WorkspaceRoot,
                IpfsRepoPath,
                IpfsCliPathOverride);

            AppendLocalNodeResult(result, "Stopped local IPFS node.");
            await RefreshStatusAsync();
        }

        private async Task RestartNodeAsync()
        {
            _settingsStore.Save(CreateSettingsSnapshot());

            var result = await _localNodeService.RestartAsync(
                _toolRoot,
                WorkspaceRoot,
                IpfsRepoPath,
                IpfsCliPathOverride);

            AppendLocalNodeResult(result, "Restarted local IPFS node.");
            await RefreshStatusAsync();
        }

        private async Task RepairNodeAsync()
        {
            _settingsStore.Save(CreateSettingsSnapshot());

            var result = await _localNodeService.RepairAsync(
                _toolRoot,
                WorkspaceRoot,
                IpfsRepoPath,
                StorageAllocationGb,
                NodeParticipationMode,
                NodeCachePolicy,
                GetStorageGcWatermark(),
                GetNodeProvideStrategy(),
                IpfsCliPathOverride);

            AppendLocalNodeResult(result, "Repaired local IPFS node configuration and applied node settings.");
            await RefreshStatusAsync();
        }

        private async Task WriteNodeDiagnosticsAsync()
        {
            _settingsStore.Save(CreateSettingsSnapshot());

            var result = await _localNodeService.WriteDiagnosticsAsync(
                _toolRoot,
                WorkspaceRoot,
                IpfsRepoPath,
                IpfsCliPathOverride);

            if (result.Succeeded && !string.IsNullOrWhiteSpace(result.RecordPath))
            {
                LatestNodeDiagnosticsText = result.RecordPath;
            }

            AppendLocalNodeResult(result, "Wrote local node diagnostics.");
            await RefreshStatusAsync();
        }

        private Task RecordNodeCapacitySnapshotAsync()
        {
            _settingsStore.Save(CreateSettingsSnapshot());

            var result = _recordService.CreateNodeCapacitySnapshot(
                WorkspaceRoot,
                ActiveIdentityId,
                ActiveDeviceId,
                ActiveDeviceKeyPath,
                GetActiveNodeId(),
                StorageAllocationGb,
                NodeParticipationMode,
                NodeCachePolicy,
                GetStorageGcWatermark(),
                GetNodeProvideStrategy(),
                PreferWifiOnly,
                IpfsRepoPath);

            if (!result.Succeeded)
            {
                AppendLog(result.Message);
                return Task.CompletedTask;
            }

            LatestNodeCapacitySnapshotText = result.RecordPath;
            AppendLog(result.Message);
            AppendLog("Metering record: " + result.RecordPath);
            AppendLog("Metering signature: " + result.SignaturePath);
            AppendLog("Record type: " + result.RecordType);
            AppendLog("Record ID: " + result.RecordId);
            return Task.CompletedTask;
        }

        private Task AcknowledgeStorageAssignmentAsync()
        {
            _settingsStore.Save(CreateSettingsSnapshot());

            var result = _recordService.CreateStorageAssignmentAcknowledgment(
                WorkspaceRoot,
                ActiveIdentityId,
                ActiveDeviceId,
                ActiveDeviceKeyPath,
                GetActiveNodeId(),
                StorageAssignmentId,
                StorageAssignmentCid,
                StorageAssignmentManifestSha256,
                StorageAssignmentServiceClass,
                (long)Math.Max(0, Math.Round(StorageAssignmentBytes)),
                true);

            if (!result.Succeeded)
            {
                AppendLog(result.Message);
                return Task.CompletedTask;
            }

            LatestStorageAssignmentAcknowledgmentText = result.RecordPath;
            AppendLog(result.Message);
            AppendLog("Metering record: " + result.RecordPath);
            AppendLog("Metering signature: " + result.SignaturePath);
            AppendLog("Record type: " + result.RecordType);
            AppendLog("Record ID: " + result.RecordId);
            return Task.CompletedTask;
        }

        private Task CreateStorageEpochProofAsync()
        {
            _settingsStore.Save(CreateSettingsSnapshot());

            var result = _recordService.CreateStorageEpochProof(
                WorkspaceRoot,
                ActiveIdentityId,
                ActiveDeviceId,
                ActiveDeviceKeyPath,
                GetActiveNodeId(),
                StorageAssignmentId,
                StorageAssignmentCid,
                StorageAssignmentManifestSha256,
                StorageAssignmentServiceClass,
                StorageProofSourceFilePath);

            if (!result.Succeeded)
            {
                AppendLog(result.Message);
                return Task.CompletedTask;
            }

            LatestStorageEpochProofText = result.RecordPath;
            AppendLog(result.Message);
            AppendLog("Metering record: " + result.RecordPath);
            AppendLog("Metering signature: " + result.SignaturePath);
            AppendLog("Record type: " + result.RecordType);
            AppendLog("Record ID: " + result.RecordId);
            return Task.CompletedTask;
        }

        private Task CreateLocalMeteringStatusAsync()
        {
            _settingsStore.Save(CreateSettingsSnapshot());

            var result = _recordService.CreateLocalMeteringStatus(
                WorkspaceRoot,
                ActiveIdentityId,
                ActiveDeviceId,
                GetActiveNodeId());

            if (!result.Succeeded)
            {
                AppendLog(result.Message);
                return Task.CompletedTask;
            }

            LatestLocalMeteringStatusText = result.RecordPath;
            LocalMeteringSummaryText = "Local submitted proof summary recorded. No proofs accepted, paid, or settled by this status.";
            AppendLog(result.Message);
            AppendLog("Metering status: " + result.RecordPath);
            AppendLog("Record type: " + result.RecordType);
            AppendLog("Record ID: " + result.RecordId);
            return Task.CompletedTask;
        }

        private Task VerifyLocalMeteringRecordsAsync()
        {
            _settingsStore.Save(CreateSettingsSnapshot());

            var result = _recordService.VerifyLocalMeteringRecords(
                WorkspaceRoot,
                ActiveIdentityId,
                ActiveDeviceId,
                ActiveDeviceKeyPath);

            if (!result.Succeeded)
            {
                AppendLog(result.Message);
                if (!string.IsNullOrWhiteSpace(result.RecordPath))
                {
                    LatestLocalMeteringVerificationText = result.RecordPath;
                    AppendLog("Verification report: " + result.RecordPath);
                }

                return Task.CompletedTask;
            }

            LatestLocalMeteringVerificationText = result.RecordPath;
            AppendLog(result.Message);
            AppendLog("Verification report: " + result.RecordPath);
            AppendLog("Record type: " + result.RecordType);
            AppendLog("Record ID: " + result.RecordId);
            return Task.CompletedTask;
        }

        private async Task PublishRegistrySubmissionAsync()
        {
            _settingsStore.Save(CreateSettingsSnapshot());

            var result = await _localNodeService.PublishRegistrySubmissionAsync(
                _toolRoot,
                WorkspaceRoot,
                RegistrySubmissionText,
                IpfsRepoPath,
                IpfsCliPathOverride,
                PublishCarExports);

            AppendLocalNodeResult(result, "Published registry submission package to IPFS.");
            if (!string.IsNullOrWhiteSpace(result.RootCid))
            {
                RegistrySubmissionCidText = result.RootCid;
                AppendLog("Root CID: " + result.RootCid);
            }

            if (!string.IsNullOrWhiteSpace(result.CarPath))
            {
                AppendLog("CAR archive: " + result.CarPath);
            }

            if (result.Succeeded)
            {
                await RefreshStatusAsync();
            }
        }

        private async Task PreviewReadOnlyIpfsFileAsync()
        {
            _settingsStore.Save(CreateSettingsSnapshot());

            var result = await _localNodeService.PreviewReadOnlyIpfsFileAsync(
                _toolRoot,
                WorkspaceRoot,
                ReadOnlyIpfsCid,
                ReadOnlyIpfsRelativePath,
                IpfsRepoPath,
                IpfsCliPathOverride);

            if (!result.Succeeded)
            {
                AppendLocalNodeResult(result, "Previewed read-only IPFS file.");
                return;
            }

            ReadOnlyIpfsPreviewText = result.PreviewText;
            AppendLog("Previewed read-only IPFS file: " + result.IpfsPath);
            AppendLog("Content bytes: " + result.ByteCount);
            if (!string.IsNullOrWhiteSpace(result.Sha256))
            {
                AppendLog("Content SHA-256: " + result.Sha256);
            }
            if (result.Truncated)
            {
                AppendLog("Preview is truncated to the configured maximum byte count.");
            }

            _settingsStore.Save(CreateSettingsSnapshot());
        }

        private async Task FetchReadOnlyIpfsFileAsync()
        {
            _settingsStore.Save(CreateSettingsSnapshot());

            var result = await _localNodeService.FetchReadOnlyIpfsFileAsync(
                _toolRoot,
                WorkspaceRoot,
                ReadOnlyIpfsCid,
                ReadOnlyIpfsRelativePath,
                IpfsRepoPath,
                IpfsCliPathOverride);

            if (!result.Succeeded)
            {
                AppendLocalNodeResult(result, "Fetched read-only IPFS file.");
                return;
            }

            ReadOnlyIpfsFetchedPathText = string.IsNullOrWhiteSpace(result.DestinationPath)
                ? "No read-only copy yet"
                : result.DestinationPath;

            AppendLog("Fetched read-only IPFS file: " + result.IpfsPath);
            AppendLog("Read-only copy: " + ReadOnlyIpfsFetchedPathText);
            if (!string.IsNullOrWhiteSpace(result.MetadataPath))
            {
                AppendLog("Metadata: " + result.MetadataPath);
            }

            _settingsStore.Save(CreateSettingsSnapshot());
        }

        private async Task ExportCarAsync()
        {
            _settingsStore.Save(CreateSettingsSnapshot());

            var result = await _localNodeService.ExportCarAsync(
                _toolRoot,
                WorkspaceRoot,
                ReadOnlyIpfsCid,
                IpfsRepoPath,
                IpfsCliPathOverride);

            if (!result.Succeeded)
            {
                AppendLocalNodeResult(result, "Exported CAR archive.");
                return;
            }

            LatestCarExportText = string.IsNullOrWhiteSpace(result.CarPath)
                ? "No CAR export yet"
                : result.CarPath;

            AppendLog("Exported CAR archive for CID: " + result.RootCid);
            AppendLog("CAR archive: " + LatestCarExportText);
            if (!string.IsNullOrWhiteSpace(result.RecordPath))
            {
                AppendLog("CAR export record: " + result.RecordPath);
            }
            if (!string.IsNullOrWhiteSpace(result.Sha256))
            {
                AppendLog("CAR SHA-256: " + result.Sha256);
            }
            if (result.ByteCount > 0)
            {
                AppendLog("CAR bytes: " + result.ByteCount);
            }

            await RefreshStatusAsync();
        }

        private void AppendLocalNodeResult(LocalNodeOperationResult result, string successMessage)
        {
            if (result.Succeeded)
            {
                AppendLog(successMessage);
                if (!string.IsNullOrWhiteSpace(result.ResolvedIpfsCliPath))
                {
                    AppendLog("Using IPFS runtime: " + result.ResolvedIpfsCliPath);
                }
                if (!string.IsNullOrWhiteSpace(result.RecordPath))
                {
                    AppendLog("Record: " + result.RecordPath);
                }
                if (result.ProcessId > 0)
                {
                    AppendLog("Process ID: " + result.ProcessId);
                }
                if (!string.IsNullOrWhiteSpace(result.ApiEndpoint))
                {
                    AppendLog("API endpoint: " + result.ApiEndpoint);
                }
                if (!string.IsNullOrWhiteSpace(result.Stdout))
                {
                    AppendLog(result.Stdout);
                }
                return;
            }

            AppendLog(result.Message);
            if (!string.IsNullOrWhiteSpace(result.Stderr))
            {
                AppendLog(result.Stderr);
            }
            else if (!string.IsNullOrWhiteSpace(result.Stdout))
            {
                AppendLog(result.Stdout);
            }
        }

        private bool CanRunWorkspaceAction()
        {
            return Directory.Exists(PassportEnvironment.ResolveWorkspaceRoot(WorkspaceRoot))
                && PassportEnvironment.IsToolRoot(_toolRoot);
        }

        private void EnableStorageParticipation()
        {
            if (!ParticipateInPublicRegistry)
            {
                ParticipateInPublicRegistry = true;
            }

            if (IsReadOnlyNodeParticipationMode(NodeParticipationMode))
            {
                NodeParticipationMode = "Public archive contributor";
            }
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

        private bool CanReadOnlyAccessIpfsFile()
        {
            return CanRunWorkspaceAction()
                && !string.IsNullOrWhiteSpace(ReadOnlyIpfsCid);
        }

        private bool CanAcknowledgeStorageAssignment()
        {
            return CanUseActiveDeviceCredential()
                && !string.IsNullOrWhiteSpace(StorageAssignmentCid);
        }

        private bool CanCreateStorageEpochProof()
        {
            return CanAcknowledgeStorageAssignment()
                && !string.IsNullOrWhiteSpace(StorageProofSourceFilePath)
                && File.Exists(StorageProofSourceFilePath);
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
                IpfsCliPathOverride = IpfsCliPathOverride,
                StorageAllocationGb = Math.Max(1, (int)Math.Round(StorageAllocationGb)),
                NodeParticipationMode = NodeParticipationMode,
                NodeCachePolicy = NodeCachePolicy,
                ParticipateInPublicRegistry = ParticipateInPublicRegistry,
                PreferWindowsHelloCredentials = PreferWindowsHelloCredentials,
                PublishCarExports = PublishCarExports,
                PreferWifiOnly = PreferWifiOnly,
                ReadOnlyIpfsCid = ReadOnlyIpfsCid,
                ReadOnlyIpfsRelativePath = ReadOnlyIpfsRelativePath,
                ReadOnlyIpfsFetchedPath = string.Equals(ReadOnlyIpfsFetchedPathText, "No read-only copy yet", System.StringComparison.Ordinal)
                    ? string.Empty
                    : ReadOnlyIpfsFetchedPathText
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
            RaiseHomePropertiesChanged();
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
            _startNodeCommand.RaiseCanExecuteChanged();
            _stopNodeCommand.RaiseCanExecuteChanged();
            _restartNodeCommand.RaiseCanExecuteChanged();
            _repairNodeCommand.RaiseCanExecuteChanged();
            _writeNodeDiagnosticsCommand.RaiseCanExecuteChanged();
            _recordNodeCapacitySnapshotCommand.RaiseCanExecuteChanged();
            _acknowledgeStorageAssignmentCommand.RaiseCanExecuteChanged();
            _createStorageEpochProofCommand.RaiseCanExecuteChanged();
            _createLocalMeteringStatusCommand.RaiseCanExecuteChanged();
            _verifyLocalMeteringRecordsCommand.RaiseCanExecuteChanged();
            _provisionIdentityCommand.RaiseCanExecuteChanged();
            _approveJoinRequestCommand.RaiseCanExecuteChanged();
            _importJoinApprovalCommand.RaiseCanExecuteChanged();
            _generateChallengeCommand.RaiseCanExecuteChanged();
            _signChallengeCommand.RaiseCanExecuteChanged();
            _createRegistrySubmissionCommand.RaiseCanExecuteChanged();
            _publishRegistrySubmissionCommand.RaiseCanExecuteChanged();
            _previewReadOnlyIpfsFileCommand.RaiseCanExecuteChanged();
            _fetchReadOnlyIpfsFileCommand.RaiseCanExecuteChanged();
            _exportCarCommand.RaiseCanExecuteChanged();
            _primaryActionCommand.RaiseCanExecuteChanged();
        }
    }
}
