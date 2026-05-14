using System.Collections.Generic;

namespace ArchrealmsPassport.Windows.Models
{
    public sealed class PassportMonetaryLedgerExportVerificationResult
    {
        public bool Succeeded { get; set; }

        public string Message { get; set; } = string.Empty;

        public string ExportRootSha256 { get; set; } = string.Empty;

        public int EventCount { get; set; }

        public List<string> Failures { get; } = new List<string>();
    }
}
