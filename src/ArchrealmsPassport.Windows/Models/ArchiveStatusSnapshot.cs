namespace ArchrealmsPassport.Windows.Models
{
    public sealed class ArchiveStatusSnapshot
    {
        public string WorkspaceRoot { get; set; } = string.Empty;
        public bool WorkspaceReady { get; set; }
        public bool IpfsCliDetected { get; set; }
        public string IpfsRepoPath { get; set; } = string.Empty;
        public bool IpfsNodePrepared { get; set; }
        public string NodePeerId { get; set; } = string.Empty;
        public string VerificationSummary { get; set; } = "No submission package yet";
        public string LatestSubmissionPath { get; set; } = string.Empty;
        public string RegistrySubmissionCid { get; set; } = "Not published";
    }
}
