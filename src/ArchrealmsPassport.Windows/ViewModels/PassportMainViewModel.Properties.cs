using System;
using System.Collections.Generic;

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
                    "Create new Passport identity",
                    "Add this device to existing identity"
                };
            }
        }

        public IReadOnlyList<string> IdentityModes
        {
            get
            {
                return new[]
                {
                    "pseudonymous",
                    "named",
                    "anonymous",
                    "ceremonial"
                };
            }
        }

        public string CitizenName { get { return _citizenName; } set { SetField(ref _citizenName, value); } }
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

        public bool IsJoiningExistingIdentity
        {
            get
            {
                return string.Equals(
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
                    ? "Create Join Request"
                    : "Create New Identity and Authorize This Device";
            }
        }

        public string WorkspaceRoot { get { return _workspaceRoot; } set { SetField(ref _workspaceRoot, value); } }
        public string IpfsRepoPath { get { return _ipfsRepoPath; } set { SetField(ref _ipfsRepoPath, value); } }
        public double StorageAllocationGb
        {
            get { return _storageAllocationGb; }
            set
            {
                if (SetField(ref _storageAllocationGb, value))
                {
                    OnPropertyChanged(nameof(StorageAllocationLabel));
                }
            }
        }

        public string StorageAllocationLabel { get { return string.Format("{0:0} GB", Math.Round(StorageAllocationGb)); } }
        public bool ParticipateInPublicRegistry { get { return _participateInPublicRegistry; } set { SetField(ref _participateInPublicRegistry, value); } }
        public bool PreferWindowsHelloCredentials { get { return _preferWindowsHelloCredentials; } set { SetField(ref _preferWindowsHelloCredentials, value); } }
        public bool PublishCarExports { get { return _publishCarExports; } set { SetField(ref _publishCarExports, value); } }
        public bool PreferWifiOnly { get { return _preferWifiOnly; } set { SetField(ref _preferWifiOnly, value); } }
        public string WorkspaceStateText { get { return _workspaceStateText; } private set { SetField(ref _workspaceStateText, value); } }
        public string IpfsStateText { get { return _ipfsStateText; } private set { SetField(ref _ipfsStateText, value); } }
        public string NodeStateText { get { return _nodeStateText; } private set { SetField(ref _nodeStateText, value); } }
        public string VerificationStateText { get { return _verificationStateText; } private set { SetField(ref _verificationStateText, value); } }
        public string ActivityLog { get { return _activityLog; } private set { SetField(ref _activityLog, value); } }
    }
}
