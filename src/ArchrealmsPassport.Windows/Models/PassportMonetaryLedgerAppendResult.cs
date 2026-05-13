namespace ArchrealmsPassport.Windows.Models
{
    public sealed class PassportMonetaryLedgerAppendResult
    {
        public bool Succeeded { get; set; }

        public string Message { get; set; } = string.Empty;

        public string EventId { get; set; } = string.Empty;

        public string EventPath { get; set; } = string.Empty;

        public string EventHashSha256 { get; set; } = string.Empty;

        public long AccountSequence { get; set; }
    }
}
