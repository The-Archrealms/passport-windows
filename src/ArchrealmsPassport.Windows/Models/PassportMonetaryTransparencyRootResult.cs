namespace ArchrealmsPassport.Windows.Models
{
    public sealed class PassportMonetaryTransparencyRootResult
    {
        public bool Succeeded { get; set; }

        public string Message { get; set; } = string.Empty;

        public string RecordPath { get; set; } = string.Empty;

        public string EpochRootSha256 { get; set; } = string.Empty;

        public int EventCount { get; set; }
    }
}
