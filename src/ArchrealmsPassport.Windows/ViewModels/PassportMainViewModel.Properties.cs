using System;
using System.Collections.Generic;
using System.Windows;

namespace ArchrealmsPassport.Windows.ViewModels
{
    public sealed partial class PassportMainViewModel
    {
        public IReadOnlyList<string> ProvisioningModes
        {
            get
            {
                return new[]
                {
                    "Create a new Passport",
                    "Add this device to a Passport"
                };
            }
        }

        public IReadOnlyList<string> NodeParticipationModes
        {
            get
            {
                return new[]
                {
                    "Read-only cache",
                    "Public archive contributor",
                    "Steward reserve"
                };
            }
        }

        public IReadOnlyList<string> NodeCachePolicies
        {
            get
            {
                return new[]
                {
                    "Conservative cache",
                    "Balanced pinned archive",
                    "Archive-first reserve"
                };
            }
        }

        public string CitizenName
        {
            get { return _citizenName; }
            set
            {
                if (SetField(ref _citizenName, value))
                {
                    OnPropertyChanged(nameof(PassportSummaryText));
                }
            }
        }
        public string SelectedProvisioningMode
        {
            get { return _selectedProvisioningMode; }
            set
            {
                if (SetField(ref _selectedProvisioningMode, value))
                {
                    OnPropertyChanged(nameof(IsJoiningExistingIdentity));
                    OnPropertyChanged(nameof(ProvisioningButtonLabel));
                }
            }
        }
        public string SelectedIdentityMode { get { return _selectedIdentityMode; } set { SetField(ref _selectedIdentityMode, value); } }
        public string ExistingIdentityId { get { return _existingIdentityId; } set { SetField(ref _existingIdentityId, value); } }
        public string ActiveIdentityId { get { return _activeIdentityId; } set { SetField(ref _activeIdentityId, value); } }
        public string ActiveDeviceId { get { return _activeDeviceId; } set { SetField(ref _activeDeviceId, value); } }
        public string ActiveDeviceKeyPath { get { return _activeDeviceKeyPath; } set { SetField(ref _activeDeviceKeyPath, value); } }
        public string PendingDeviceId { get { return _pendingDeviceId; } set { SetField(ref _pendingDeviceId, value); } }
        public string PendingDeviceKeyPath { get { return _pendingDeviceKeyPath; } set { SetField(ref _pendingDeviceKeyPath, value); } }
        public string DeviceLabel { get { return _deviceLabel; } set { SetField(ref _deviceLabel, value); } }
        public string JoinRequestPath { get { return _joinRequestPath; } set { SetField(ref _joinRequestPath, value); } }
        public string JoinApprovalPath { get { return _joinApprovalPath; } set { SetField(ref _joinApprovalPath, value); } }
        public string ChallengeText { get { return _challengeText; } set { SetField(ref _challengeText, value); } }
        public string ChallengeSignatureText { get { return _challengeSignatureText; } set { SetField(ref _challengeSignatureText, value); } }
        public string RegistrySubmissionText { get { return _registrySubmissionText; } set { SetField(ref _registrySubmissionText, value); } }
        public string RegistrySubmissionCidText { get { return _registrySubmissionCidText; } set { SetField(ref _registrySubmissionCidText, value); } }
        public string ReadOnlyIpfsCid { get { return _readOnlyIpfsCid; } set { SetField(ref _readOnlyIpfsCid, value); } }
        public string ReadOnlyIpfsRelativePath { get { return _readOnlyIpfsRelativePath; } set { SetField(ref _readOnlyIpfsRelativePath, value); } }
        public string ReadOnlyIpfsPreviewText { get { return _readOnlyIpfsPreviewText; } set { SetField(ref _readOnlyIpfsPreviewText, value); } }
        public string ReadOnlyIpfsFetchedPathText { get { return _readOnlyIpfsFetchedPathText; } set { SetField(ref _readOnlyIpfsFetchedPathText, value); } }
        public string LatestCarExportText { get { return _latestCarExportText; } private set { SetField(ref _latestCarExportText, value); } }
        public string LatestNodeCapacitySnapshotText { get { return _latestNodeCapacitySnapshotText; } private set { SetField(ref _latestNodeCapacitySnapshotText, value); } }
        public string LatestNodeDiagnosticsText { get { return _latestNodeDiagnosticsText; } private set { SetField(ref _latestNodeDiagnosticsText, value); } }
        public string StorageAssignmentId { get { return _storageAssignmentId; } set { SetField(ref _storageAssignmentId, value); } }
        public string StorageAssignmentCid { get { return _storageAssignmentCid; } set { SetField(ref _storageAssignmentCid, value); } }
        public string StorageAssignmentManifestSha256 { get { return _storageAssignmentManifestSha256; } set { SetField(ref _storageAssignmentManifestSha256, value); } }
        public string StorageAssignmentServiceClass { get { return _storageAssignmentServiceClass; } set { SetField(ref _storageAssignmentServiceClass, value); } }
        public double StorageAssignmentBytes { get { return _storageAssignmentBytes; } set { SetField(ref _storageAssignmentBytes, value); } }
        public string LatestStorageAssignmentAcknowledgmentText { get { return _latestStorageAssignmentAcknowledgmentText; } private set { SetField(ref _latestStorageAssignmentAcknowledgmentText, value); } }
        public string StorageProofSourceFilePath { get { return _storageProofSourceFilePath; } set { SetField(ref _storageProofSourceFilePath, value); } }
        public string LatestStorageEpochProofText { get { return _latestStorageEpochProofText; } private set { SetField(ref _latestStorageEpochProofText, value); } }
        public string LatestLocalMeteringStatusText { get { return _latestLocalMeteringStatusText; } private set { SetField(ref _latestLocalMeteringStatusText, value); } }
        public string LocalMeteringSummaryText { get { return _localMeteringSummaryText; } private set { SetField(ref _localMeteringSummaryText, value); } }
        public string LatestLocalMeteringVerificationText { get { return _latestLocalMeteringVerificationText; } private set { SetField(ref _latestLocalMeteringVerificationText, value); } }

        public bool IsJoiningExistingIdentity
        {
            get
            {
                return string.Equals(
                    SelectedProvisioningMode,
                    "Add this device to a Passport",
                    StringComparison.Ordinal)
                    || string.Equals(
                        SelectedProvisioningMode,
                        "Add this device to existing identity",
                        StringComparison.Ordinal);
            }
        }

        public string ProvisioningButtonLabel
        {
            get
            {
                return IsJoiningExistingIdentity
                    ? "Request Access"
                    : "Create Passport";
            }
        }

        public string PassportSummaryText
        {
            get
            {
                return HasActivePassport()
                    ? "Ready: " + GetPassportDisplayName()
                    : "Not created";
            }
        }

        public string StorageSummaryText
        {
            get
            {
                if (!ParticipateInPublicRegistry)
                {
                    return "Read-only";
                }

                return HasActiveNode()
                    ? "Enabled: " + StorageAllocationLabel
                    : "Not enabled: " + StorageAllocationLabel;
            }
        }

        public string LocalNodeSummaryText
        {
            get
            {
                if (HasActiveNode())
                {
                    return "Online";
                }

                return ParticipateInPublicRegistry
                    ? "Not running"
                    : "Off";
            }
        }

        public string RegistryPackageSummaryText
        {
            get
            {
                if (IsPublishedRegistrySubmission())
                {
                    return "Registered";
                }

                return HasRegistrySubmissionPackage()
                    ? "Ready to publish"
                    : "Not registered";
            }
        }

        public string PrimaryActionLabel
        {
            get
            {
                if (!HasActivePassport())
                {
                    return IsJoiningExistingIdentity ? "Request Access" : "Create Passport";
                }

                if (!IsPublishedRegistrySubmission())
                {
                    return "Complete Registration";
                }

                return "Passport Ready";
            }
        }

        public Visibility PrimaryActionVisibility
        {
            get
            {
                return IsPublishedRegistrySubmission()
                    ? Visibility.Collapsed
                    : Visibility.Visible;
            }
        }

        public string WorkspaceRoot { get { return _workspaceRoot; } set { SetField(ref _workspaceRoot, value); } }
        public string IpfsRepoPath { get { return _ipfsRepoPath; } set { SetField(ref _ipfsRepoPath, value); } }
        public string IpfsCliPathOverride { get { return _ipfsCliPathOverride; } set { SetField(ref _ipfsCliPathOverride, value); } }
        public double StorageAllocationGb
        {
            get { return _storageAllocationGb; }
            set
            {
                if (SetField(ref _storageAllocationGb, value))
                {
                    OnPropertyChanged(nameof(StorageAllocationLabel));
                    RaiseNodeProfilePropertiesChanged();
                }
            }
        }

        public string StorageAllocationLabel { get { return string.Format("{0:0} GB", Math.Round(StorageAllocationGb)); } }
        public string NodeParticipationMode
        {
            get { return _nodeParticipationMode; }
            set
            {
                var normalized = NormalizeNodeParticipationMode(value);
                if (SetField(ref _nodeParticipationMode, normalized))
                {
                    _participateInPublicRegistry = !IsReadOnlyNodeParticipationMode(normalized);
                    OnPropertyChanged(nameof(ParticipateInPublicRegistry));
                    RaiseNodeProfilePropertiesChanged();
                    RaiseHomePropertiesChanged();
                }
            }
        }

        public string NodeCachePolicy
        {
            get { return _nodeCachePolicy; }
            set
            {
                if (SetField(ref _nodeCachePolicy, NormalizeNodeCachePolicy(value)))
                {
                    RaiseNodeProfilePropertiesChanged();
                }
            }
        }

        public bool ParticipateInPublicRegistry
        {
            get { return _participateInPublicRegistry; }
            set
            {
                if (SetField(ref _participateInPublicRegistry, value))
                {
                    var derivedMode = value ? "Public archive contributor" : "Read-only cache";
                    if (!string.Equals(_nodeParticipationMode, derivedMode, StringComparison.Ordinal))
                    {
                        _nodeParticipationMode = derivedMode;
                        OnPropertyChanged(nameof(NodeParticipationMode));
                    }

                    RaiseNodeProfilePropertiesChanged();
                    RaiseHomePropertiesChanged();
                }
            }
        }
        public bool PreferWindowsHelloCredentials { get { return _preferWindowsHelloCredentials; } set { SetField(ref _preferWindowsHelloCredentials, value); } }
        public bool PublishCarExports { get { return _publishCarExports; } set { SetField(ref _publishCarExports, value); } }
        public bool PreferWifiOnly
        {
            get { return _preferWifiOnly; }
            set
            {
                if (SetField(ref _preferWifiOnly, value))
                {
                    RaiseNodeProfilePropertiesChanged();
                }
            }
        }
        public string ParticipationProfileSummary { get { return BuildParticipationProfileSummary(); } }
        public string NodeConfigSummary { get { return BuildNodeConfigSummary(); } }
        public string WorkspaceStateText { get { return _workspaceStateText; } private set { SetField(ref _workspaceStateText, value); } }
        public string IpfsStateText { get { return _ipfsStateText; } private set { SetField(ref _ipfsStateText, value); } }
        public string ResolvedIpfsCliPathText { get { return _resolvedIpfsCliPathText; } private set { SetField(ref _resolvedIpfsCliPathText, value); } }
        public string NodeStateText { get { return _nodeStateText; } private set { SetField(ref _nodeStateText, value); } }
        public string VerificationStateText { get { return _verificationStateText; } private set { SetField(ref _verificationStateText, value); } }
        public string StorageActionStatusText { get { return _storageActionStatusText; } private set { SetField(ref _storageActionStatusText, value); } }
        public string ActivityLog { get { return _activityLog; } private set { SetField(ref _activityLog, value); } }

        private void RaiseNodeProfilePropertiesChanged()
        {
            OnPropertyChanged(nameof(ParticipationProfileSummary));
            OnPropertyChanged(nameof(NodeConfigSummary));
        }

        private string BuildParticipationProfileSummary()
        {
            return NodeParticipationMode
                + "; "
                + NodeCachePolicy
                + "; "
                + (PreferWifiOnly ? "unmetered network preferred" : "standard network use");
        }

        private string BuildNodeConfigSummary()
        {
            return string.Format(
                "StorageMax {0:0}GB; GC {1:0}%; Provide {2}",
                Math.Round(StorageAllocationGb),
                GetStorageGcWatermark(),
                GetNodeProvideStrategy());
        }

        private int GetStorageGcWatermark()
        {
            if (string.Equals(NodeCachePolicy, "Conservative cache", StringComparison.Ordinal))
            {
                return 70;
            }

            if (string.Equals(NodeCachePolicy, "Archive-first reserve", StringComparison.Ordinal))
            {
                return 90;
            }

            return 80;
        }

        private string GetNodeProvideStrategy()
        {
            return "pinned";
        }

        private static string NormalizeNodeParticipationMode(string value)
        {
            if (string.Equals(value, "Read-only cache", StringComparison.Ordinal)
                || string.Equals(value, "Public archive contributor", StringComparison.Ordinal)
                || string.Equals(value, "Steward reserve", StringComparison.Ordinal))
            {
                return value;
            }

            return "Public archive contributor";
        }

        private static string NormalizeNodeCachePolicy(string value)
        {
            if (string.Equals(value, "Conservative cache", StringComparison.Ordinal)
                || string.Equals(value, "Balanced pinned archive", StringComparison.Ordinal)
                || string.Equals(value, "Archive-first reserve", StringComparison.Ordinal))
            {
                return value;
            }

            return "Balanced pinned archive";
        }

        private static bool IsReadOnlyNodeParticipationMode(string value)
        {
            return string.Equals(value, "Read-only cache", StringComparison.Ordinal);
        }
    }
}
