namespace ArchrealmsPassport.Windows.Models
{
    public sealed class PassportAdminRoleMembershipResult
    {
        public bool Succeeded { get; set; }

        public string Message { get; set; } = string.Empty;

        public string RecordPath { get; set; } = string.Empty;

        public string SignaturePath { get; set; } = string.Empty;

        public bool SignatureVerified { get; set; }
    }
}
