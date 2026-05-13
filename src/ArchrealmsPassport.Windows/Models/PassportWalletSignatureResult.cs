namespace ArchrealmsPassport.Windows.Models
{
    public sealed class PassportWalletSignatureResult
    {
        public bool Succeeded { get; set; }

        public string Message { get; set; } = string.Empty;

        public string SignatureBase64 { get; set; } = string.Empty;

        public string PayloadSha256 { get; set; } = string.Empty;

        public bool VerifiedWithWalletKey { get; set; }
    }
}
