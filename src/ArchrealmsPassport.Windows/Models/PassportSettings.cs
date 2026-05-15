namespace ArchrealmsPassport.Windows.Models
{
    public sealed class PassportSettings
    {
        public string CitizenName { get; set; } = string.Empty;
        public string SelectedProvisioningMode { get; set; } = "Create a new Passport";
        public string SelectedIdentityMode { get; set; } = "named";
        public string ExistingIdentityId { get; set; } = string.Empty;
        public string ActiveIdentityId { get; set; } = string.Empty;
        public string ActiveDeviceId { get; set; } = string.Empty;
        public string ActiveDeviceKeyPath { get; set; } = string.Empty;
        public string ActiveWalletKeyId { get; set; } = string.Empty;
        public string ActiveWalletKeyReferencePath { get; set; } = string.Empty;
        public string ActiveWalletPublicKeyPath { get; set; } = string.Empty;
        public string PendingDeviceId { get; set; } = string.Empty;
        public string PendingDeviceKeyPath { get; set; } = string.Empty;
        public string DeviceLabel { get; set; } = string.Empty;
        public string JoinRequestPath { get; set; } = string.Empty;
        public string JoinApprovalPath { get; set; } = string.Empty;
        public string WorkspaceRoot { get; set; } = string.Empty;
        public string IpfsRepoPath { get; set; } = string.Empty;
        public string IpfsCliPathOverride { get; set; } = string.Empty;
        public int StorageAllocationGb { get; set; } = 1;
        public string NodeParticipationMode { get; set; } = "Read-only cache";
        public string NodeCachePolicy { get; set; } = "Balanced pinned archive";
        public bool ParticipateInPublicRegistry { get; set; }
        public bool PreferWindowsHelloCredentials { get; set; }
        public bool PublishCarExports { get; set; } = true;
        public bool PreferWifiOnly { get; set; }
        public string ReadOnlyIpfsCid { get; set; } = string.Empty;
        public string ReadOnlyIpfsRelativePath { get; set; } = string.Empty;
        public string ReadOnlyIpfsFetchedPath { get; set; } = string.Empty;
        public string AiGatewayUrl { get; set; } = string.Empty;
        public string AiKnowledgePackId { get; set; } = "archrealms-mvp-approved-knowledge";
        public bool AiDiagnosticsUploadOptIn { get; set; }
    }
}
