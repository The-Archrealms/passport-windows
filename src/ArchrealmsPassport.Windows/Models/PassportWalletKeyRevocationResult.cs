namespace ArchrealmsPassport.Windows.Models
{
    public sealed class PassportWalletKeyRevocationResult
    {
        public bool Succeeded { get; set; }

        public string Message { get; set; } = string.Empty;

        public string WalletKeyId { get; set; } = string.Empty;

        public string RevocationRecordPath { get; set; } = string.Empty;

        public string RevocationSignaturePath { get; set; } = string.Empty;

        public bool VerifiedWithDeviceKey { get; set; }
    }
}
