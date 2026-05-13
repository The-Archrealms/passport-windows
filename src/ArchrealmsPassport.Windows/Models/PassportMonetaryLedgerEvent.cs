using System.Collections.Generic;
using System.Text.Json.Serialization;

namespace ArchrealmsPassport.Windows.Models
{
    public sealed class PassportMonetaryLedgerEvent
    {
        [JsonPropertyName("schema_version")]
        public int SchemaVersion { get; set; } = 1;

        [JsonPropertyName("record_type")]
        public string RecordType { get; set; } = "passport_monetary_ledger_event";

        [JsonPropertyName("event_id")]
        public string EventId { get; set; } = string.Empty;

        [JsonPropertyName("event_type")]
        public string EventType { get; set; } = string.Empty;

        [JsonPropertyName("created_utc")]
        public string CreatedUtc { get; set; } = string.Empty;

        [JsonPropertyName("release_lane")]
        public string ReleaseLane { get; set; } = string.Empty;

        [JsonPropertyName("telemetry_environment")]
        public string TelemetryEnvironment { get; set; } = string.Empty;

        [JsonPropertyName("ledger_namespace")]
        public string LedgerNamespace { get; set; } = string.Empty;

        [JsonPropertyName("production_token_record")]
        public bool ProductionTokenRecord { get; set; }

        [JsonPropertyName("staging_record")]
        public bool StagingRecord { get; set; }

        [JsonPropertyName("account_id")]
        public string AccountId { get; set; } = string.Empty;

        [JsonPropertyName("archrealms_identity_id")]
        public string IdentityId { get; set; } = string.Empty;

        [JsonPropertyName("wallet_key_id")]
        public string WalletKeyId { get; set; } = string.Empty;

        [JsonPropertyName("asset_code")]
        public string AssetCode { get; set; } = string.Empty;

        [JsonPropertyName("amount_base_units")]
        public long AmountBaseUnits { get; set; }

        [JsonPropertyName("global_sequence")]
        public long GlobalSequence { get; set; }

        [JsonPropertyName("account_sequence")]
        public long AccountSequence { get; set; }

        [JsonPropertyName("prior_account_event_hash")]
        public string PriorAccountEventHash { get; set; } = string.Empty;

        [JsonPropertyName("server_received_utc")]
        public string ServerReceivedUtc { get; set; } = string.Empty;

        [JsonPropertyName("anti_replay_nonce")]
        public string AntiReplayNonce { get; set; } = string.Empty;

        [JsonPropertyName("device_session_id")]
        public string DeviceSessionId { get; set; } = string.Empty;

        [JsonPropertyName("policy_version")]
        public string PolicyVersion { get; set; } = string.Empty;

        [JsonPropertyName("evidence_references")]
        public Dictionary<string, string> EvidenceReferences { get; set; } = new Dictionary<string, string>();

        [JsonPropertyName("signature_status")]
        public string SignatureStatus { get; set; } = string.Empty;

        [JsonPropertyName("event_hash_sha256")]
        public string EventHashSha256 { get; set; } = string.Empty;
    }
}
