namespace ArchrealmsPassport.Windows.Models
{
    public sealed class PassportConversionQuoteResult
    {
        public bool Succeeded { get; set; }

        public string Message { get; set; } = string.Empty;

        public string QuoteId { get; set; } = string.Empty;

        public string QuotePath { get; set; } = string.Empty;

        public string QuoteSha256 { get; set; } = string.Empty;
    }
}
