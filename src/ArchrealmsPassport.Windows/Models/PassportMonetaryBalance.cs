using System.Text.Json.Serialization;

namespace ArchrealmsPassport.Windows.Models
{
    public sealed class PassportMonetaryBalance
    {
        [JsonPropertyName("account_id")]
        public string AccountId { get; set; } = string.Empty;

        [JsonPropertyName("asset_code")]
        public string AssetCode { get; set; } = string.Empty;

        [JsonPropertyName("available_base_units")]
        public long AvailableBaseUnits { get; set; }

        [JsonPropertyName("escrowed_base_units")]
        public long EscrowedBaseUnits { get; set; }

        [JsonPropertyName("burned_base_units")]
        public long BurnedBaseUnits { get; set; }
    }
}
