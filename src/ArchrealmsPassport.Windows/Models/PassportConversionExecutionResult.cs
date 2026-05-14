namespace ArchrealmsPassport.Windows.Models
{
    public sealed class PassportConversionExecutionResult
    {
        public bool Succeeded { get; set; }

        public string Message { get; set; } = string.Empty;

        public string ExecutionId { get; set; } = string.Empty;

        public string ExecutionRecordPath { get; set; } = string.Empty;

        public string SourceLedgerEventPath { get; set; } = string.Empty;

        public string DestinationLedgerEventPath { get; set; } = string.Empty;
    }
}
