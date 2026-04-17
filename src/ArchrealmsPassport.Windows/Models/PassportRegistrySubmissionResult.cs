namespace ArchrealmsPassport.Windows.Models
{
    public sealed class PassportRegistrySubmissionResult
    {
        public bool Succeeded { get; set; }

        public string Message { get; set; } = string.Empty;

        public string SubmissionPath { get; set; } = string.Empty;

        public string ManifestPath { get; set; } = string.Empty;

        public string SignaturePath { get; set; } = string.Empty;

        public bool VerifiedWithPublicKey { get; set; }
    }
}
