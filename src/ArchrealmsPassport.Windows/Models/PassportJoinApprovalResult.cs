namespace ArchrealmsPassport.Windows.Models
{
    public sealed class PassportJoinApprovalResult
    {
        public bool Succeeded { get; set; }

        public string Message { get; set; } = string.Empty;

        public string ApprovalPackagePath { get; set; } = string.Empty;

        public string AuthorizationRecordPath { get; set; } = string.Empty;

        public string AuthorizationSignaturePath { get; set; } = string.Empty;
    }
}
