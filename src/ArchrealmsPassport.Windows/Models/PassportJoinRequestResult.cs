namespace ArchrealmsPassport.Windows.Models
{
    public sealed class PassportJoinRequestResult
    {
        public bool Succeeded { get; set; }

        public string Message { get; set; } = string.Empty;

        public string IdentityId { get; set; } = string.Empty;

        public string DeviceId { get; set; } = string.Empty;

        public string PrivateKeyPath { get; set; } = string.Empty;

        public string PublicKeyPath { get; set; } = string.Empty;

        public string PendingDeviceRecordPath { get; set; } = string.Empty;

        public string JoinRequestPath { get; set; } = string.Empty;

        public string RequestSignaturePath { get; set; } = string.Empty;
    }
}
