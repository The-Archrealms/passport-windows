namespace ArchrealmsPassport.Core.Protocol;

public static class PassportRecordTypes
{
    public const string AiSessionRequest = "passport_ai_session_request";
    public const string AiSessionRecord = "passport_ai_session_record";
    public const string AiChatRecord = "passport_ai_chat_record";
    public const string CcCapacityReport = "passport_cc_capacity_report";
    public const string ArchGenesisManifest = "passport_arch_genesis_manifest";
    public const string AdminDualControlAction = "passport_admin_dual_control_action";
    public const string AdminDualControlRequesterSignature = "passport_admin_dual_control_requester_signature";
    public const string AdminDualControlApproverSignature = "passport_admin_dual_control_approver_signature";
    public const string AdminRoleMembership = "passport_admin_authority_role_membership";
    public const string AdminRoleMembershipSignature = "passport_admin_authority_role_membership_signature";
    public const string TelemetryAccessRequest = "passport_telemetry_access_request";
    public const string TelemetryAccessRecord = "passport_telemetry_access_record";
    public const string StorageServiceDeliveryRequest = "passport_storage_service_delivery_request";
    public const string StorageDeliveryAcceptance = "passport_storage_delivery_acceptance";
}
