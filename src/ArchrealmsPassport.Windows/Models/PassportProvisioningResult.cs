namespace ArchrealmsPassport.Windows.Models
{
    public sealed class PassportProvisioningResult
    {
        public bool Succeeded { get; set; }

        public string Message { get; set; } = string.Empty;

        public string IdentityId { get; set; } = string.Empty;

        public string DeviceId { get; set; } = string.Empty;

        public string PrivateKeyPath { get; set; } = string.Empty;

        public string PublicKeyPath { get; set; } = string.Empty;

        public string IdentityRecordPath { get; set; } = string.Empty;

        public string DeviceRecordPath { get; set; } = string.Empty;
    }
}
