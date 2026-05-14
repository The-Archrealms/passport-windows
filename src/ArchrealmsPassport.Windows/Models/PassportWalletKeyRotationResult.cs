namespace ArchrealmsPassport.Windows.Models
{
    public sealed class PassportWalletKeyRotationResult
    {
        public bool Succeeded { get; set; }

        public string Message { get; set; } = string.Empty;

        public PassportWalletKeyRevocationResult Revocation { get; set; } = new PassportWalletKeyRevocationResult();

        public PassportWalletKeyBindingResult Binding { get; set; } = new PassportWalletKeyBindingResult();
    }
}
