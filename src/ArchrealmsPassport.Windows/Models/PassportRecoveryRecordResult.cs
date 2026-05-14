namespace ArchrealmsPassport.Windows.Models
{
    public sealed class PassportRecoveryRecordResult
    {
        public bool Succeeded { get; set; }

        public string Message { get; set; } = string.Empty;

        public string RecordType { get; set; } = string.Empty;

        public string RecordPath { get; set; } = string.Empty;

        public string SignaturePath { get; set; } = string.Empty;

        public bool VerifiedWithDeviceKey { get; set; }
    }
}
