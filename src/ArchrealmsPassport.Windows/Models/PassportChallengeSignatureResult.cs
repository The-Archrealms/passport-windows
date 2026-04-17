namespace ArchrealmsPassport.Windows.Models
{
    public sealed class PassportChallengeSignatureResult
    {
        public bool Succeeded { get; set; }

        public string Message { get; set; } = string.Empty;

        public string SignatureRecordPath { get; set; } = string.Empty;

        public string SignatureBase64 { get; set; } = string.Empty;

        public bool VerifiedWithPublicKey { get; set; }
    }
}
