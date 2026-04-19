namespace ArchrealmsPassport.Windows.Models
{
    public sealed class PassportSettings
    {
        public string CitizenName { get; set; } = string.Empty;
        public string SelectedProvisioningMode { get; set; } = "Create new Passport identity";
        public string SelectedIdentityMode { get; set; } = "pseudonymous";
        public string ExistingIdentityId { get; set; } = string.Empty;
        public string ActiveIdentityId { get; set; } = string.Empty;
        public string ActiveDeviceId { get; set; } = string.Empty;
        public string ActiveDeviceKeyPath { get; set; } = string.Empty;
        public string PendingDeviceId { get; set; } = string.Empty;
        public string PendingDeviceKeyPath { get; set; } = string.Empty;
        public string DeviceLabel { get; set; } = string.Empty;
        public string JoinRequestPath { get; set; } = string.Empty;
        public string JoinApprovalPath { get; set; } = string.Empty;
        public string WorkspaceRoot { get; set; } = string.Empty;
        public string IpfsRepoPath { get; set; } = string.Empty;
        public int StorageAllocationGb { get; set; } = 25;
        public bool ParticipateInPublicRegistry { get; set; } = true;
        public bool PreferWindowsHelloCredentials { get; set; }
        public bool PublishCarExports { get; set; } = true;
        public bool PreferWifiOnly { get; set; }
    }
}
