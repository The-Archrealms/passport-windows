namespace ArchrealmsPassport.Windows.Models
{
    public sealed class PassportAiSessionResult
    {
        public bool Succeeded { get; set; }

        public string Message { get; set; } = string.Empty;

        public string RequestId { get; set; } = string.Empty;

        public string RequestPath { get; set; } = string.Empty;

        public string RequestSha256 { get; set; } = string.Empty;

        public string SignaturePath { get; set; } = string.Empty;

        public string SessionId { get; set; } = string.Empty;

        public string SessionPath { get; set; } = string.Empty;

        public string SessionToken { get; set; } = string.Empty;

        public string SessionTokenSha256 { get; set; } = string.Empty;

        public string ExpiresUtc { get; set; } = string.Empty;

        public int MessageQuota { get; set; }

        public int TokenQuota { get; set; }
    }
}
