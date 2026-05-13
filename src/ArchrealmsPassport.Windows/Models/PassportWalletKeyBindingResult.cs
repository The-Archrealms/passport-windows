namespace ArchrealmsPassport.Windows.Models
{
    public sealed class PassportWalletKeyBindingResult
    {
        public bool Succeeded { get; set; }

        public string Message { get; set; } = string.Empty;

        public string WalletKeyId { get; set; } = string.Empty;

        public string WalletKeyReferencePath { get; set; } = string.Empty;

        public string WalletPublicKeyPath { get; set; } = string.Empty;

        public string BindingRecordPath { get; set; } = string.Empty;

        public string BindingSignaturePath { get; set; } = string.Empty;

        public bool VerifiedWithDeviceKey { get; set; }
    }
}
