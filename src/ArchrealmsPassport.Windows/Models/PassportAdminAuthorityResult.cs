namespace ArchrealmsPassport.Windows.Models
{
    public sealed class PassportAdminAuthorityResult
    {
        public bool Succeeded { get; set; }

        public string Message { get; set; } = string.Empty;

        public string RecordPath { get; set; } = string.Empty;

        public string RequesterSignaturePath { get; set; } = string.Empty;

        public string ApproverSignaturePath { get; set; } = string.Empty;

        public bool RequesterSignatureVerified { get; set; }

        public bool ApproverSignatureVerified { get; set; }
    }
}
