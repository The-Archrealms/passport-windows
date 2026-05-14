namespace ArchrealmsPassport.Windows.Models
{
    public sealed class PassportRegistryRecordSummary
    {
        public string RecordType { get; set; } = string.Empty;

        public string RecordId { get; set; } = string.Empty;

        public string CreatedUtc { get; set; } = string.Empty;

        public string Status { get; set; } = string.Empty;

        public string RelativePath { get; set; } = string.Empty;

        public string Sha256 { get; set; } = string.Empty;
    }
}
