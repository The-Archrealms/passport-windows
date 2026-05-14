namespace ArchrealmsPassport.Windows.Models
{
    public sealed class PassportCrownCreditCapacityReportResult
    {
        public bool Succeeded { get; set; }

        public string Message { get; set; } = string.Empty;

        public string ReportPath { get; set; } = string.Empty;

        public string ReportSha256 { get; set; } = string.Empty;

        public long MaxIssuanceBaseUnits { get; set; }
    }
}
