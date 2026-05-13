using System.Collections.Generic;

namespace ArchrealmsPassport.Windows.Models
{
    public sealed class PassportMonetaryLedgerReplayResult
    {
        public bool Succeeded
        {
            get
            {
                return Failures.Count == 0;
            }
        }

        public string Message { get; set; } = string.Empty;

        public int EventCount { get; set; }

        public List<string> Failures { get; } = new List<string>();

        public List<PassportMonetaryBalance> Balances { get; } = new List<PassportMonetaryBalance>();
    }
}
