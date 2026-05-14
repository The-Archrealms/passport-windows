namespace ArchrealmsPassport.Windows.Models
{
    public sealed class PassportStorageRedemptionResult
    {
        public bool Succeeded { get; set; }

        public string Message { get; set; } = string.Empty;

        public string RecordId { get; set; } = string.Empty;

        public string RecordPath { get; set; } = string.Empty;

        public string RecordSha256 { get; set; } = string.Empty;

        public string LedgerEventPath { get; set; } = string.Empty;

        public string LedgerEventHashSha256 { get; set; } = string.Empty;
    }
}
