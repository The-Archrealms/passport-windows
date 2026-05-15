namespace ArchrealmsPassport.Windows.Models
{
    public sealed class PassportRecoveryReadiness
    {
        public int ActiveDeviceCount { get; set; }

        public int DeauthorizedDeviceCount { get; set; }

        public int RecoverableDeviceCount { get; set; }

        public bool QuorumReady { get; set; }

        public bool WalletOperationsFrozen { get; set; }

        public bool PendingEscrowFrozen { get; set; }

        public bool AiSessionsRevoked { get; set; }

        public bool StorageNodeOperationsPaused { get; set; }

        public string Summary { get; set; } = string.Empty;
    }
}
