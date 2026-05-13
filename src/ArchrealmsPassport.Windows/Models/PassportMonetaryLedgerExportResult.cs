namespace ArchrealmsPassport.Windows.Models
{
    public sealed class PassportMonetaryLedgerExportResult
    {
        public bool Succeeded { get; set; }

        public string Message { get; set; } = string.Empty;

        public string ExportRoot { get; set; } = string.Empty;

        public string ManifestPath { get; set; } = string.Empty;

        public string TransparencyRootPath { get; set; } = string.Empty;

        public string ExportRootSha256 { get; set; } = string.Empty;

        public int EventCount { get; set; }
    }
}
