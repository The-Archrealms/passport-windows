using System.Text.Json;
using System.Text.Json.Serialization;

namespace ArchrealmsPassport.HostedServices.Contracts;

public sealed record PassportAiSessionAuthorizationRequest
{
    [JsonPropertyName("request_record")]
    public JsonElement RequestRecord { get; init; }

    [JsonPropertyName("request_record_sha256")]
    public string RequestRecordSha256 { get; init; } = string.Empty;

    [JsonPropertyName("signed_payload_base64")]
    public string SignedPayloadBase64 { get; init; } = string.Empty;

    [JsonPropertyName("signature_base64")]
    public string SignatureBase64 { get; init; } = string.Empty;

    [JsonPropertyName("device_public_key_spki_der_base64")]
    public string DevicePublicKeySpkiDerBase64 { get; init; } = string.Empty;

    [JsonPropertyName("message_quota")]
    public int MessageQuota { get; init; } = 25;

    [JsonPropertyName("token_quota")]
    public int TokenQuota { get; init; } = 10000;

    [JsonPropertyName("ttl_minutes")]
    public int TtlMinutes { get; init; } = 30;
}

public sealed record PassportAiSessionAuthorizationResponse
{
    [JsonPropertyName("succeeded")]
    public bool Succeeded { get; init; }

    [JsonPropertyName("message")]
    public string Message { get; init; } = string.Empty;

    [JsonPropertyName("session_id")]
    public string SessionId { get; init; } = string.Empty;

    [JsonPropertyName("session_token")]
    public string SessionToken { get; init; } = string.Empty;

    [JsonPropertyName("session_token_sha256")]
    public string SessionTokenSha256 { get; init; } = string.Empty;

    [JsonPropertyName("expires_utc")]
    public string ExpiresUtc { get; init; } = string.Empty;

    [JsonPropertyName("message_quota")]
    public int MessageQuota { get; init; }

    [JsonPropertyName("token_quota")]
    public int TokenQuota { get; init; }

    [JsonPropertyName("session_record")]
    public Dictionary<string, object?>? Session { get; init; }
}

public sealed record PassportAiChatRequest
{
    [JsonPropertyName("session_id")]
    public string SessionId { get; init; } = string.Empty;

    [JsonPropertyName("knowledge_pack_id")]
    public string KnowledgePackId { get; init; } = string.Empty;

    [JsonPropertyName("message")]
    public string Message { get; init; } = string.Empty;

    [JsonPropertyName("diagnostics_upload_opt_in")]
    public bool DiagnosticsUploadOptIn { get; init; }

    [JsonPropertyName("release_lane")]
    public string ReleaseLane { get; init; } = string.Empty;

    [JsonPropertyName("policy_version")]
    public string PolicyVersion { get; init; } = string.Empty;

    [JsonPropertyName("client_approved_context_refs")]
    public PassportAiSourceRef[] ClientApprovedContextRefs { get; init; } = Array.Empty<PassportAiSourceRef>();
}

public sealed record PassportAiChatResponse
{
    [JsonPropertyName("succeeded")]
    public bool Succeeded { get; init; }

    [JsonPropertyName("message")]
    public string Message { get; init; } = string.Empty;

    [JsonPropertyName("answer_text")]
    public string AnswerText { get; init; } = string.Empty;

    [JsonPropertyName("quota_summary")]
    public string QuotaSummary { get; init; } = string.Empty;

    [JsonPropertyName("sources")]
    public PassportAiSourceRef[] Sources { get; init; } = Array.Empty<PassportAiSourceRef>();
}

public sealed record PassportAiSourceRef
{
    [JsonPropertyName("source_id")]
    public string SourceId { get; init; } = string.Empty;

    [JsonPropertyName("title")]
    public string Title { get; init; } = string.Empty;

    [JsonPropertyName("source_path")]
    public string SourcePath { get; init; } = string.Empty;

    [JsonPropertyName("source_sha256")]
    public string SourceSha256 { get; init; } = string.Empty;

    [JsonPropertyName("chunk_sha256")]
    public string ChunkSha256 { get; init; } = string.Empty;
}

public sealed record PassportCcCapacityReportRequest
{
    [JsonPropertyName("release_lane")]
    public string ReleaseLane { get; init; } = string.Empty;

    [JsonPropertyName("ledger_namespace")]
    public string LedgerNamespace { get; init; } = string.Empty;

    [JsonPropertyName("policy_version")]
    public string PolicyVersion { get; init; } = string.Empty;

    [JsonPropertyName("service_class")]
    public string ServiceClass { get; init; } = "aggregate";

    [JsonPropertyName("conservative_service_liability_capacity_base_units")]
    public long ConservativeServiceLiabilityCapacityBaseUnits { get; init; }

    [JsonPropertyName("outstanding_cc_before_base_units")]
    public long OutstandingCcBeforeBaseUnits { get; init; }

    [JsonPropertyName("max_issuance_base_units")]
    public long MaxIssuanceBaseUnits { get; init; }

    [JsonPropertyName("capacity_haircut_basis_points")]
    public int CapacityHaircutBasisPoints { get; init; }

    [JsonPropertyName("independent_volume_qualified")]
    public bool IndependentVolumeQualified { get; init; }

    [JsonPropertyName("thin_market_issuance_zero")]
    public bool ThinMarketIssuanceZero { get; init; }

    [JsonPropertyName("continuity_reserve_excluded")]
    public bool ContinuityReserveExcluded { get; init; }

    [JsonPropertyName("operational_reserve_excluded")]
    public bool OperationalReserveExcluded { get; init; }

    [JsonPropertyName("capacity_report_authority_record_sha256")]
    public string CapacityReportAuthorityRecordSha256 { get; init; } = string.Empty;
}

public sealed record PassportArchGenesisManifestRequest
{
    [JsonPropertyName("release_lane")]
    public string ReleaseLane { get; init; } = string.Empty;

    [JsonPropertyName("ledger_namespace")]
    public string LedgerNamespace { get; init; } = string.Empty;

    [JsonPropertyName("policy_version")]
    public string PolicyVersion { get; init; } = string.Empty;

    [JsonPropertyName("total_supply_base_units")]
    public long TotalSupplyBaseUnits { get; init; }

    [JsonPropertyName("base_unit_precision")]
    public int BaseUnitPrecision { get; init; }

    [JsonPropertyName("allocations")]
    public PassportArchGenesisAllocationRequest[] Allocations { get; init; } = Array.Empty<PassportArchGenesisAllocationRequest>();

    [JsonPropertyName("genesis_authority_record_sha256")]
    public string GenesisAuthorityRecordSha256 { get; init; } = string.Empty;
}

public sealed record PassportArchGenesisAllocationRequest
{
    [JsonPropertyName("allocation_id")]
    public string AllocationId { get; init; } = string.Empty;

    [JsonPropertyName("account_id")]
    public string AccountId { get; init; } = string.Empty;

    [JsonPropertyName("archrealms_identity_id")]
    public string IdentityId { get; init; } = string.Empty;

    [JsonPropertyName("wallet_key_id")]
    public string WalletKeyId { get; init; } = string.Empty;

    [JsonPropertyName("amount_base_units")]
    public long AmountBaseUnits { get; init; }
}

public sealed record PassportAdminAuthorityValidationRequest
{
    [JsonPropertyName("action_type")]
    public string ActionType { get; init; } = string.Empty;

    [JsonPropertyName("authority_scope")]
    public string AuthorityScope { get; init; } = string.Empty;

    [JsonPropertyName("target_record_sha256")]
    public string TargetRecordSha256 { get; init; } = string.Empty;

    [JsonPropertyName("requested_payload_sha256")]
    public string RequestedPayloadSha256 { get; init; } = string.Empty;

    [JsonPropertyName("admin_authority_record")]
    public JsonElement AdminAuthorityRecord { get; init; }

    [JsonPropertyName("admin_authority_record_payload_base64")]
    public string AdminAuthorityRecordPayloadBase64 { get; init; } = string.Empty;

    [JsonPropertyName("requester_signature_record")]
    public JsonElement RequesterSignatureRecord { get; init; }

    [JsonPropertyName("approver_signature_record")]
    public JsonElement ApproverSignatureRecord { get; init; }
}

public sealed record PassportStorageDeliveryRequest
{
    [JsonPropertyName("service_delivery_request_record")]
    public JsonElement ServiceDeliveryRequestRecord { get; init; }

    [JsonPropertyName("service_delivery_request_sha256")]
    public string ServiceDeliveryRequestSha256 { get; init; } = string.Empty;
}

public sealed record PassportHostedRecordResponse
{
    [JsonPropertyName("succeeded")]
    public bool Succeeded { get; init; }

    [JsonPropertyName("message")]
    public string Message { get; init; } = string.Empty;

    [JsonPropertyName("record_id")]
    public string RecordId { get; init; } = string.Empty;

    [JsonPropertyName("record_sha256")]
    public string RecordSha256 { get; init; } = string.Empty;

    [JsonPropertyName("record")]
    public Dictionary<string, object?>? Record { get; init; }
}
