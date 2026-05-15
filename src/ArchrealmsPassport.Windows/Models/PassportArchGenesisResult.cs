namespace ArchrealmsPassport.Windows.Models
{
    public sealed class PassportArchGenesisResult
    {
        public bool Succeeded { get; set; }

        public string Message { get; set; } = string.Empty;

        public string ManifestPath { get; set; } = string.Empty;

        public string ManifestSha256 { get; set; } = string.Empty;

        public long TotalSupplyBaseUnits { get; set; }

        public long AllocationAmountBaseUnits { get; set; }
    }

    public sealed class PassportArchGenesisAllocation
    {
        public string AllocationId { get; set; } = string.Empty;

        public string AccountId { get; set; } = string.Empty;

        public string IdentityId { get; set; } = string.Empty;

        public string WalletKeyId { get; set; } = string.Empty;

        public long AmountBaseUnits { get; set; }
    }
}
