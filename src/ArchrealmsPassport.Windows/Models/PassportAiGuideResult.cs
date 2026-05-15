using System.Collections.Generic;

namespace ArchrealmsPassport.Windows.Models
{
    public sealed class PassportAiGuideResult
    {
        public bool Succeeded { get; set; }

        public string Message { get; set; } = string.Empty;

        public string AnswerText { get; set; } = string.Empty;

        public string ChatRecordPath { get; set; } = string.Empty;

        public string ChatRecordSha256 { get; set; } = string.Empty;

        public string QuotaSummary { get; set; } = string.Empty;

        public List<PassportAiSourceReference> Sources { get; } = new List<PassportAiSourceReference>();
    }

    public class PassportAiSourceReference
    {
        public string SourceId { get; set; } = string.Empty;

        public string Title { get; set; } = string.Empty;

        public string SourcePath { get; set; } = string.Empty;

        public string SourceSha256 { get; set; } = string.Empty;

        public string ChunkSha256 { get; set; } = string.Empty;
    }
}
