namespace ArchrealmsPassport.Core.Protocol;

public static class PassportRecordTypes
{
    public const string AiSessionRequest = "passport_ai_session_request";
    public const string AiSessionRecord = "passport_ai_session_record";
    public const string AiChatRecord = "passport_ai_chat_record";
    public const string AiChallenge = "passport_ai_challenge";
    public const string AiFeedbackRecord = "passport_ai_feedback_record";
    public const string CcCapacityReport = "passport_cc_capacity_report";
    public const string ArchGenesisManifest = "passport_arch_genesis_manifest";
    public const string AdminDualControlAction = "passport_admin_dual_control_action";
    public const string AdminDualControlRequesterSignature = "passport_admin_dual_control_requester_signature";
    public const string AdminDualControlApproverSignature = "passport_admin_dual_control_approver_signature";
    public const string AdminRoleMembership = "passport_admin_authority_role_membership";
    public const string AdminRoleMembershipSignature = "passport_admin_authority_role_membership_signature";
    public const string TelemetryAccessRequest = "passport_telemetry_access_request";
    public const string TelemetryAccessRecord = "passport_telemetry_access_record";
    public const string MonetaryLedgerEvent = "passport_monetary_ledger_event";
    public const string WalletKeyBinding = "passport_wallet_key_binding";
    public const string WalletKeyBindingSignature = "passport_wallet_key_binding_signature";
    public const string WalletKeyRevocation = "passport_wallet_key_revocation";
    public const string WalletKeyRevocationSignature = "passport_wallet_key_revocation_signature";
    public const string DeviceDeauthorization = "passport_device_deauthorization";
    public const string DeviceDeauthorizationSignature = "passport_device_deauthorization_signature";
    public const string AccountSecurityFreeze = "passport_account_security_freeze";
    public const string AccountSecurityFreezeSignature = "passport_account_security_freeze_signature";
    public const string SupportMediatedRecoveryOverride = "passport_support_mediated_recovery_override";
    public const string RecoveryControlValidation = "passport_recovery_control_validation";
    public const string StorageServiceDeliveryRequest = "passport_storage_service_delivery_request";
    public const string StorageDeliveryAcceptance = "passport_storage_delivery_acceptance";
    public const string HostedStorageBackupManifest = "passport_hosted_storage_backup_manifest";
    public const string HostedIncidentReport = "passport_hosted_incident_report";
}
