namespace ArchrealmsPassport.Windows.Models
{
    public sealed class ArchiveStatusSnapshot
    {
        public string WorkspaceRoot { get; set; } = string.Empty;
        public bool WorkspaceReady { get; set; }
        public bool IpfsCliDetected { get; set; }
        public string IpfsCliPath { get; set; } = string.Empty;
        public string IpfsCliSource { get; set; } = string.Empty;
        public string IpfsRepoPath { get; set; } = string.Empty;
        public bool IpfsNodePrepared { get; set; }
        public string NodePeerId { get; set; } = string.Empty;
        public string NodeHealthSummary { get; set; } = "Node not initialized";
        public string NodeApiEndpoint { get; set; } = string.Empty;
        public bool NodeApiReachable { get; set; }
        public string NodeIpfsVersion { get; set; } = string.Empty;
        public string NodeStorageMax { get; set; } = string.Empty;
        public string NodeStorageGcWatermark { get; set; } = string.Empty;
        public string NodeParticipationMode { get; set; } = string.Empty;
        public string NodeCachePolicy { get; set; } = string.Empty;
        public string NodeProvideStrategy { get; set; } = string.Empty;
        public string VerificationSummary { get; set; } = "No submission package yet";
        public string LatestSubmissionPath { get; set; } = string.Empty;
        public string RegistrySubmissionCid { get; set; } = "Not published";
    }
}
