namespace ArchrealmsPassport.Windows.Models
{
    public sealed class PassportLedgerCorrectionResult
    {
        public bool Succeeded { get; set; }

        public string Message { get; set; } = string.Empty;

        public string CorrectionId { get; set; } = string.Empty;

        public string CorrectionRecordPath { get; set; } = string.Empty;

        public string LedgerEventPath { get; set; } = string.Empty;

        public string LedgerEventHashSha256 { get; set; } = string.Empty;
    }
}
