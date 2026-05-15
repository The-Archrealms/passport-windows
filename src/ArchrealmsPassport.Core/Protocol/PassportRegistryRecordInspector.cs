using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace ArchrealmsPassport.Core.Protocol;

public sealed record PassportRegistryRecordInspection
{
    public bool IsRecord { get; init; }

    public string SchemaVersion { get; init; } = string.Empty;

    public string RecordType { get; init; } = string.Empty;

    public string RecordId { get; init; } = string.Empty;

    public string CreatedUtc { get; init; } = string.Empty;

    public string Status { get; init; } = string.Empty;

    public string RelativePath { get; init; } = string.Empty;

    public string Sha256 { get; init; } = string.Empty;

    public string Cid { get; init; } = string.Empty;

    public string SignedPayloadPath { get; init; } = string.Empty;

    public string SignedPayloadSha256 { get; init; } = string.Empty;

    public string SignaturePath { get; init; } = string.Empty;

    public string WalletPublicKeyPath { get; init; } = string.Empty;

    public string WalletSignedPayloadSha256 { get; init; } = string.Empty;

    public IReadOnlyList<string> ValidationFailures { get; init; } = Array.Empty<string>();

    public bool IsEnvelopeValid => IsRecord && ValidationFailures.Count == 0;
}

public static class PassportRegistryRecordInspector
{
    private static readonly IReadOnlyDictionary<string, string[]> RequiredFieldsByRecordType = new Dictionary<string, string[]>(StringComparer.Ordinal)
    {
        ["passport_admin_authority"] = new[] { "record_id", "created_utc", "release_lane", "ledger_namespace", "policy_version", "status", "action_type", "authority_scope", "reason_code", "target_record_path", "target_record_sha256", "requested_payload_sha256", "requester_device_id", "approver_device_id", "requester_signature_path", "approver_signature_path", "ai_authority", "summary" },
        ["passport_arch_cc_conversion_execution"] = new[] { "execution_id", "created_utc", "release_lane", "ledger_namespace", "policy_version", "account_id", "archrealms_identity_id", "wallet_key_id", "quote_id", "quote_record_path", "quote_record_sha256", "source_ledger_event_path", "source_ledger_event_sha256", "destination_ledger_event_path", "destination_ledger_event_sha256", "status", "summary" },
        ["passport_arch_cc_conversion_quote"] = new[] { "quote_id", "created_utc", "expires_utc", "release_lane", "ledger_namespace", "policy_version", "account_id", "archrealms_identity_id", "wallet_key_id", "source_asset_code", "destination_asset_code", "source_amount_base_units", "destination_amount_base_units", "rate_numerator", "rate_denominator", "rate_source", "liquidity_source", "quote_method", "counterparty_class", "crown_is_counterparty", "spread_fee_base_units", "max_slippage_bps", "liquidity_limit_base_units", "guaranteed_conversion", "fixed_parity", "stable_value_claim", "legal_tender_claim", "unlimited_convertibility", "summary" },
        ["attestation_record"] = new[] { "record_id", "created_utc", "effective_utc", "status", "attestation_type", "subject_record_ids", "attestor_label", "attestation_statement", "evidence_refs", "summary" },
        ["blockchain_settlement_batch_record"] = new[] { "record_id", "created_utc", "effective_utc", "status", "settlement_batch_id", "settlement_epoch_id", "policy_version", "registrar_id", "target_settlement_layer", "source_handoff_record_ids", "participant_outputs", "chain_submission", "correction_record_ids", "dispute_record_ids", "summary" },
        ["blockchain_settlement_chain_evaluation"] = new[] { "record_id", "created_utc", "status", "candidate_chain", "finality", "cost_and_throughput", "contract_capability", "passport_read_only_access", "custody_and_authority", "legal_tax_treasury_review", "operational_risk", "decision", "release_gate_assessment", "summary" },
        ["blockchain_settlement_status_record"] = new[] { "record_id", "created_utc", "effective_utc", "status", "archrealms_identity_id", "node_id", "settlement_batch_id", "settlement_epoch_id", "source_settlement_batch_record_id", "chain_status", "participant_settlement", "summary" },
        ["passport_cc_capacity_report"] = new[] { "record_id", "created_utc", "release_lane", "ledger_namespace", "policy_version", "service_class", "reporting_period_start_utc", "reporting_period_end_utc", "conservative_service_liability_capacity_base_units", "outstanding_cc_before_base_units", "max_issuance_base_units", "capacity_haircut_basis_points", "independent_volume_qualified", "thin_market_issuance_zero", "continuity_reserve_excluded", "operational_reserve_excluded", "affiliate_trade_exclusion_applied", "proof_history_haircut", "uptime_haircut", "retrieval_haircut", "repair_haircut", "concentration_haircut", "churn_haircut", "audit_confidence_haircut", "capacity_evidence_refs", "summary" },
        ["device_credential_record"] = new[] { "record_id", "created_utc", "effective_utc", "status", "archrealms_identity_id", "device_id", "device_label", "device_class", "client_platform", "credential_origin", "public_key_algorithm", "public_key_format", "public_key_path", "public_key_sha256", "authorized_scopes", "attestation_refs", "summary" },
        ["device_revocation_record"] = new[] { "record_id", "created_utc", "effective_utc", "status", "archrealms_identity_id", "revoked_device_record_id", "device_id", "revocation_reason", "supersedes_credential_status", "summary" },
        ["passport_ledger_correction"] = new[] { "correction_id", "created_utc", "release_lane", "ledger_namespace", "policy_version", "account_id", "archrealms_identity_id", "wallet_key_id", "asset_code", "correction_event_type", "amount_base_units", "reason_code", "target_record_path", "target_record_sha256", "admin_authority_path", "admin_authority_sha256", "ledger_event_path", "ledger_event_sha256", "summary" },
        ["passport_metering_admission_record"] = new[] { "record_id", "created_utc", "effective_utc", "status", "admission_scope", "archrealms_identity_id", "device_id", "package_id", "package_root", "manifest_path", "package_verification_report_path", "source_metering_report_path", "source_metering_report_id", "package_verification", "admitted_metering", "settlement_status", "signature", "summary" },
        ["passport_metering_audit_challenge_record"] = new[] { "record_id", "created_utc", "effective_utc", "status", "registrar_id", "admission_record_id", "package_id", "challenge_scope", "challenge_reason", "sample_policy", "challenged_records", "response_due_utc", "audit_result", "settlement_status", "summary" },
        ["passport_metering_correction_record"] = new[] { "record_id", "created_utc", "effective_utc", "status", "registrar_id", "admission_record_id", "package_id", "correction_reason", "supersedes_record_ids", "affected_records", "prior_metering", "corrected_metering", "settlement_status", "summary" },
        ["passport_metering_dispute_record"] = new[] { "record_id", "created_utc", "effective_utc", "status", "opened_by_role", "opened_by_id", "admission_record_id", "package_id", "dispute_scope", "challenged_records", "requested_remedy", "evidence_refs", "response_due_utc", "disposition", "settlement_status", "summary" },
        ["passport_metering_settlement_handoff_record"] = new[] { "record_id", "created_utc", "effective_utc", "status", "registrar_id", "policy_version", "admission_record_id", "package_id", "audit_status", "dispute_status", "correction_record_ids", "excluded_record_ids", "final_metering", "handoff_status", "target_settlement_layer", "settlement_status", "summary" },
        ["metering_status_record"] = new[] { "record_id", "created_utc", "effective_utc", "status", "archrealms_identity_id", "device_id", "node_id", "measurement_epoch", "source", "verified_service", "reliability", "settlement_preview", "summary" },
        ["passport_monetary_account_export"] = new[] { "record_id", "created_utc", "release_lane", "ledger_namespace", "policy_version", "account_id", "event_count", "events", "balances", "account_hash_chain", "key_history", "transparency_root_sha256", "transparency_root_export_path", "verifier_replay_root", "verifier", "summary" },
        ["passport_monetary_ledger_event"] = new[] { "event_id", "event_type", "created_utc", "release_lane", "telemetry_environment", "ledger_namespace", "production_token_record", "staging_record", "account_id", "archrealms_identity_id", "wallet_key_id", "asset_code", "amount_base_units", "global_sequence", "account_sequence", "prior_account_event_hash", "server_received_utc", "anti_replay_nonce", "device_session_id", "policy_version", "evidence_references", "signature_status", "wallet_signature_algorithm", "wallet_signature_base64", "signed_event_hash_sha256", "wallet_public_key_path", "event_hash_sha256" },
        ["passport_monetary_transparency_root"] = new[] { "record_id", "created_utc", "release_lane", "ledger_namespace", "policy_version", "root_algorithm", "event_count", "first_global_sequence", "last_global_sequence", "event_hashes", "event_leaves", "epoch_root_sha256", "public_chain_anchor_status", "summary" },
        ["passport_hosted_incident_report"] = new[] { "record_id", "created_utc", "release_lane", "ledger_namespace", "policy_version", "severity", "incident_type", "detected_utc", "incident_response_runbook_uri", "incident_response_owner", "telemetry_retention_policy_uri", "contains_personal_data", "contains_raw_ai_prompts", "contains_storage_payload_details", "redaction_policy", "summary" },
        ["passport_hosted_storage_backup_manifest"] = new[] { "record_id", "created_utc", "release_lane", "ledger_namespace", "policy_version", "storage_provider", "backup_policy_uri", "restore_runbook_uri", "backup_snapshot_id", "manifest_file_count", "manifest_total_bytes", "manifest_root_sha256", "private_key_material_included", "raw_ai_prompts_included", "storage_payloads_included", "entries", "summary" },
        ["node_capacity_snapshot_record"] = new[] { "record_id", "created_utc", "effective_utc", "status", "archrealms_identity_id", "device_id", "node_id", "client_platform", "passport_client", "storage_mode", "storage_limit_bytes", "local_repo_path_hash", "ipfs_peer_id", "participation_scopes", "measurement_epoch", "observed_capacity", "signature", "summary" },
        ["passport_identity_record"] = new[] { "record_id", "created_utc", "effective_utc", "status", "archrealms_identity_id", "display_name", "identity_mode", "citizenship_class", "declared_scope", "recovery_authority", "attestation_refs", "summary" },
        ["passport_recovery_control_validation"] = new[] { "record_id", "created_utc", "release_lane", "ledger_namespace", "policy_version", "recovery_control_record_type", "recovery_control_record_id", "recovery_control_record_sha256", "validation_mode", "ai_approved", "summary" },
        ["repair_participation_record"] = new[] { "record_id", "created_utc", "effective_utc", "status", "archrealms_identity_id", "device_id", "node_id", "repair_id", "service_class", "content_ref", "repair_trigger", "repair_action", "metering_claim", "signature", "summary" },
        ["retrieval_observation_record"] = new[] { "record_id", "created_utc", "effective_utc", "status", "archrealms_identity_id", "device_id", "node_id", "service_class", "content_ref", "request", "delivery", "metering_claim", "signature", "summary" },
        ["storage_assignment_acknowledgment_record"] = new[] { "record_id", "created_utc", "effective_utc", "status", "archrealms_identity_id", "device_id", "node_id", "assignment_id", "assignment_issuer", "service_class", "content_ref", "assigned_replica", "measurement_epoch", "acknowledgment", "signature", "summary" },
        ["storage_epoch_proof_record"] = new[] { "record_id", "created_utc", "effective_utc", "status", "archrealms_identity_id", "device_id", "node_id", "assignment_id", "service_class", "content_ref", "measurement_epoch", "challenge", "proof_response", "metering_claim", "signature", "summary" },
        ["passport_storage_redemption"] = new[] { "record_id", "record_stage", "created_utc", "release_lane", "ledger_namespace", "policy_version", "account_id", "archrealms_identity_id", "wallet_key_id", "service_class", "storage_gb", "epoch_count", "cc_rate_per_gb_epoch_base_units", "total_cc_base_units", "quote_expires_utc", "accepted_redemption_id", "escrow_ledger_event_path", "escrow_ledger_event_sha256", "proof_record_path", "proof_record_sha256", "verified_gb_days", "burn_cc_base_units", "refund_cc_base_units", "failure_remedy", "summary" },
        ["passport_storage_redemption_quote"] = new[] { "record_id", "record_stage", "quote_id", "created_utc", "quote_expires_utc", "release_lane", "ledger_namespace", "policy_version", "account_id", "archrealms_identity_id", "wallet_key_id", "service_class", "storage_gb", "epoch_count", "cc_rate_per_gb_epoch_base_units", "total_cc_base_units", "quote_source", "failure_remedy", "summary" },
        ["passport_storage_redemption_accepted"] = new[] { "record_id", "record_stage", "redemption_id", "created_utc", "release_lane", "ledger_namespace", "policy_version", "account_id", "archrealms_identity_id", "wallet_key_id", "quote_id", "quote_path", "quote_sha256", "service_class", "storage_gb", "epoch_count", "cc_rate_per_gb_epoch_base_units", "total_cc_base_units", "quote_expires_utc", "accepted_redemption_id", "escrow_ledger_event_path", "escrow_ledger_event_sha256", "failure_remedy", "wallet_signature", "summary" },
        ["passport_storage_redemption_epoch_burn"] = new[] { "record_id", "record_stage", "redemption_id", "created_utc", "release_lane", "ledger_namespace", "policy_version", "account_id", "archrealms_identity_id", "wallet_key_id", "quote_id", "service_class", "storage_gb", "epoch_count", "cc_rate_per_gb_epoch_base_units", "total_cc_base_units", "accepted_redemption_id", "escrow_ledger_event_path", "escrow_ledger_event_sha256", "proof_record_path", "proof_record_sha256", "verified_gb_days", "burn_cc_base_units", "failure_remedy", "wallet_signature", "summary" },
        ["passport_storage_redemption_refund"] = new[] { "record_id", "record_stage", "redemption_id", "created_utc", "release_lane", "ledger_namespace", "policy_version", "account_id", "archrealms_identity_id", "wallet_key_id", "quote_id", "service_class", "storage_gb", "epoch_count", "cc_rate_per_gb_epoch_base_units", "total_cc_base_units", "accepted_redemption_id", "escrow_ledger_event_path", "escrow_ledger_event_sha256", "refund_cc_base_units", "failure_remedy", "wallet_signature", "summary" },
        ["passport_wallet_key_binding"] = new[] { "record_id", "created_utc", "release_lane", "ledger_namespace", "policy_version", "status", "archrealms_identity_id", "authorizing_device_id", "wallet_key_id", "wallet_key_algorithm", "wallet_key_size_bits", "wallet_public_key_path", "wallet_public_key_sha256", "authorized_scopes", "prohibited_scopes", "summary" },
    };

    public static PassportRegistryRecordInspection Inspect(byte[] recordJson, string relativePath = "", bool allowTemplatePlaceholders = false)
    {
        var sha256 = ComputeSha256(recordJson);
        try
        {
            using var document = JsonDocument.Parse(DecodeJson(recordJson));
            var root = document.RootElement;
            if (root.ValueKind != JsonValueKind.Object)
            {
                return NotRecord(relativePath, sha256, "root_must_be_object");
            }

            var validationFailures = new List<string>();
            var schemaVersion = ReadSchemaVersion(root);
            if (string.IsNullOrWhiteSpace(schemaVersion))
            {
                validationFailures.Add("schema_version_required");
            }

            var recordType = ReadString(root, "record_type");
            if (string.IsNullOrWhiteSpace(recordType))
            {
                validationFailures.Add("record_type_required");
                return NotRecord(relativePath, sha256, validationFailures);
            }

            var recordId = ReadString(root, "record_id", "event_id", "quote_id", "execution_id", "correction_id");
            if (string.IsNullOrWhiteSpace(recordId))
            {
                validationFailures.Add("record_identifier_required");
            }

            var createdUtc = ReadString(root, "created_utc");
            if (string.IsNullOrWhiteSpace(createdUtc))
            {
                validationFailures.Add("created_utc_required");
            }
            else if (!DateTimeOffset.TryParse(createdUtc, out _))
            {
                if (!allowTemplatePlaceholders || !IsTemplatePlaceholder(createdUtc))
                {
                    validationFailures.Add("created_utc_invalid");
                }
            }

            ValidateRecordFamily(root, recordType, validationFailures, allowTemplatePlaceholders);

            var inspection = new PassportRegistryRecordInspection
            {
                IsRecord = true,
                SchemaVersion = schemaVersion,
                RecordType = recordType,
                RecordId = recordId,
                CreatedUtc = createdUtc,
                Status = ReadString(root, "status", "record_stage", "signature_status"),
                RelativePath = relativePath,
                Sha256 = sha256,
                Cid = ReadCid(root),
                ValidationFailures = validationFailures.ToArray()
            };

            if (root.TryGetProperty("signature", out var signature))
            {
                if (signature.ValueKind == JsonValueKind.Object)
                {
                    inspection = inspection with
                    {
                        SignedPayloadPath = ReadString(signature, "signed_payload_path"),
                        SignedPayloadSha256 = ReadString(signature, "signed_payload_sha256"),
                        SignaturePath = ReadString(signature, "signature_path")
                    };
                }
                else
                {
                    inspection = inspection with
                    {
                        ValidationFailures = inspection.ValidationFailures.Append("signature_must_be_object").ToArray()
                    };
                }
            }

            if (root.TryGetProperty("wallet_signature", out var walletSignature))
            {
                if (walletSignature.ValueKind == JsonValueKind.Object)
                {
                    inspection = inspection with
                    {
                        WalletPublicKeyPath = ReadString(walletSignature, "wallet_public_key_path"),
                        WalletSignedPayloadSha256 = ReadString(walletSignature, "signed_payload_sha256")
                    };
                }
                else
                {
                    inspection = inspection with
                    {
                        ValidationFailures = inspection.ValidationFailures.Append("wallet_signature_must_be_object").ToArray()
                    };
                }
            }

            return inspection;
        }
        catch
        {
            return NotRecord(relativePath, sha256, "invalid_json");
        }
    }

    public static bool MatchesFilter(PassportRegistryRecordInspection record, string filter)
    {
        if (!record.IsRecord)
        {
            return false;
        }

        if (string.IsNullOrWhiteSpace(filter))
        {
            return true;
        }

        return Contains(record.SchemaVersion, filter)
            || Contains(record.RecordType, filter)
            || Contains(record.RecordId, filter)
            || Contains(record.Status, filter)
            || Contains(record.RelativePath, filter)
            || Contains(record.Sha256, filter)
            || Contains(record.Cid, filter)
            || Contains(record.SignaturePath, filter)
            || Contains(record.SignedPayloadPath, filter)
            || Contains(record.SignedPayloadSha256, filter)
            || Contains(record.WalletPublicKeyPath, filter)
            || Contains(record.WalletSignedPayloadSha256, filter)
            || record.ValidationFailures.Any(failure => Contains(failure, filter));
    }

    private static string ReadCid(JsonElement root)
    {
        var direct = ReadString(root, "cid", "root_cid", "content_cid", "registry_submission_cid");
        if (!string.IsNullOrWhiteSpace(direct))
        {
            return direct;
        }

        if (root.TryGetProperty("content_ref", out var contentRef))
        {
            return ReadString(contentRef, "cid");
        }

        if (root.TryGetProperty("source", out var source))
        {
            return ReadString(source, "cid", "root_cid");
        }

        return string.Empty;
    }

    private static string ReadString(JsonElement root, params string[] propertyNames)
    {
        foreach (var propertyName in propertyNames)
        {
            if (root.TryGetProperty(propertyName, out var property) && property.ValueKind == JsonValueKind.String)
            {
                return property.GetString() ?? string.Empty;
            }
        }

        return string.Empty;
    }

    private static string ReadSchemaVersion(JsonElement root)
    {
        if (!root.TryGetProperty("schema_version", out var property))
        {
            return string.Empty;
        }

        return property.ValueKind switch
        {
            JsonValueKind.String => property.GetString() ?? string.Empty,
            JsonValueKind.Number => property.GetRawText(),
            _ => string.Empty
        };
    }

    private static void ValidateRecordFamily(
        JsonElement root,
        string recordType,
        List<string> validationFailures,
        bool allowTemplatePlaceholders)
    {
        if (!RequiredFieldsByRecordType.TryGetValue(recordType, out var requiredFields))
        {
            return;
        }

        foreach (var field in requiredFields)
        {
            if (!root.TryGetProperty(field, out var property) || !HasRequiredValue(property))
            {
                validationFailures.Add("record_family_required_field_missing:" + field);
            }
        }

        if (allowTemplatePlaceholders)
        {
            return;
        }

        if (string.Equals(recordType, PassportRecordTypes.WalletKeyBinding, StringComparison.Ordinal))
        {
            ValidateWalletKeyBindingRecord(root, validationFailures);
        }

        if (string.Equals(recordType, "passport_arch_cc_conversion_quote", StringComparison.Ordinal))
        {
            ValidateConversionQuoteRecord(root, validationFailures);
        }

        if (string.Equals(recordType, "passport_arch_cc_conversion_execution", StringComparison.Ordinal))
        {
            ValidateConversionExecutionRecord(root, validationFailures);
        }

        if (string.Equals(recordType, PassportRecordTypes.CcCapacityReport, StringComparison.Ordinal))
        {
            ValidateCcCapacityReportRecord(root, validationFailures);
        }

        if (recordType.StartsWith("passport_storage_redemption", StringComparison.Ordinal))
        {
            ValidateStorageRedemptionRecord(root, recordType, validationFailures);
        }

        if (string.Equals(recordType, PassportRecordTypes.RecoveryControlValidation, StringComparison.Ordinal))
        {
            ValidateRecoveryControlValidationRecord(root, validationFailures);
        }

        if (string.Equals(recordType, PassportRecordTypes.HostedStorageBackupManifest, StringComparison.Ordinal))
        {
            ValidateHostedStorageBackupManifestRecord(root, validationFailures);
        }

        if (string.Equals(recordType, PassportRecordTypes.HostedIncidentReport, StringComparison.Ordinal))
        {
            ValidateHostedIncidentReportRecord(root, validationFailures);
        }
    }

    private static bool HasRequiredValue(JsonElement property)
    {
        return property.ValueKind is not JsonValueKind.Undefined and not JsonValueKind.Null;
    }

    private static void ValidateWalletKeyBindingRecord(JsonElement root, List<string> validationFailures)
    {
        var validation = PassportWalletKeyBindingValidator.Validate(new PassportWalletKeyBindingDescriptor
        {
            IdentityId = ReadString(root, "archrealms_identity_id"),
            AuthorizingDeviceId = ReadString(root, "authorizing_device_id"),
            WalletKeyId = ReadString(root, "wallet_key_id"),
            WalletKeyAlgorithm = ReadString(root, "wallet_key_algorithm"),
            WalletKeySizeBits = ReadInt(root, "wallet_key_size_bits"),
            WalletPublicKeyPath = ReadString(root, "wallet_public_key_path"),
            WalletPublicKeySha256 = ReadString(root, "wallet_public_key_sha256"),
            AuthorizedScopes = ReadStringArray(root, "authorized_scopes"),
            ProhibitedScopes = ReadStringArray(root, "prohibited_scopes")
        });

        foreach (var failure in validation.Failures)
        {
            validationFailures.Add("wallet_key_binding_policy:" + failure);
        }
    }

    private static void ValidateConversionQuoteRecord(JsonElement root, List<string> validationFailures)
    {
        var sourceAsset = ReadString(root, "source_asset_code");
        var destinationAsset = ReadString(root, "destination_asset_code");
        if (!IsArchOrCc(sourceAsset) || !IsArchOrCc(destinationAsset))
        {
            validationFailures.Add("conversion_quote_policy:asset_pair_must_be_arch_cc");
        }

        if (string.Equals(sourceAsset, destinationAsset, StringComparison.OrdinalIgnoreCase))
        {
            validationFailures.Add("conversion_quote_policy:source_destination_must_differ");
        }

        if (ReadInt64(root, "source_amount_base_units") <= 0
            || ReadInt64(root, "destination_amount_base_units") <= 0
            || ReadInt64(root, "rate_numerator") <= 0
            || ReadInt64(root, "rate_denominator") <= 0)
        {
            validationFailures.Add("conversion_quote_policy:positive_amounts_and_rate_required");
        }

        AddIfTrue(root, "guaranteed_conversion", "conversion_quote_policy:guaranteed_conversion_forbidden", validationFailures);
        AddIfTrue(root, "fixed_parity", "conversion_quote_policy:fixed_parity_forbidden", validationFailures);
        AddIfTrue(root, "stable_value_claim", "conversion_quote_policy:stable_value_claim_forbidden", validationFailures);
        AddIfTrue(root, "legal_tender_claim", "conversion_quote_policy:legal_tender_claim_forbidden", validationFailures);
        AddIfTrue(root, "unlimited_convertibility", "conversion_quote_policy:unlimited_convertibility_forbidden", validationFailures);
    }

    private static void ValidateConversionExecutionRecord(JsonElement root, List<string> validationFailures)
    {
        if (!LooksLikeSha256(ReadString(root, "quote_record_sha256")))
        {
            validationFailures.Add("conversion_execution_policy:quote_record_sha256_invalid");
        }

        if (!LooksLikeSha256(ReadString(root, "source_ledger_event_sha256")))
        {
            validationFailures.Add("conversion_execution_policy:source_ledger_event_sha256_invalid");
        }

        if (!LooksLikeSha256(ReadString(root, "destination_ledger_event_sha256")))
        {
            validationFailures.Add("conversion_execution_policy:destination_ledger_event_sha256_invalid");
        }

        var status = ReadString(root, "status", "execution_status");
        if (status is not "executed")
        {
            validationFailures.Add("conversion_execution_policy:status_invalid");
        }

        var sourceLedgerEventPath = ReadString(root, "source_ledger_event_path");
        var destinationLedgerEventPath = ReadString(root, "destination_ledger_event_path");
        if (!string.IsNullOrWhiteSpace(sourceLedgerEventPath)
            && string.Equals(sourceLedgerEventPath, destinationLedgerEventPath, StringComparison.OrdinalIgnoreCase))
        {
            validationFailures.Add("conversion_execution_policy:source_destination_events_must_differ");
        }

        var sourceAsset = ReadString(root, "source_asset_code");
        var destinationAsset = ReadString(root, "destination_asset_code");
        if (!string.IsNullOrWhiteSpace(sourceAsset) || !string.IsNullOrWhiteSpace(destinationAsset))
        {
            if (!IsArchOrCc(sourceAsset) || !IsArchOrCc(destinationAsset))
            {
                validationFailures.Add("conversion_execution_policy:asset_pair_must_be_arch_cc");
            }

            if (string.Equals(sourceAsset, destinationAsset, StringComparison.OrdinalIgnoreCase))
            {
                validationFailures.Add("conversion_execution_policy:source_destination_must_differ");
            }
        }

        if ((root.TryGetProperty("source_amount_base_units", out _) && ReadInt64(root, "source_amount_base_units") <= 0)
            || (root.TryGetProperty("destination_amount_base_units", out _) && ReadInt64(root, "destination_amount_base_units") <= 0))
        {
            validationFailures.Add("conversion_execution_policy:positive_amounts_required");
        }

        AddIfTrue(root, "guaranteed_conversion", "conversion_execution_policy:guaranteed_conversion_forbidden", validationFailures);
        AddIfTrue(root, "fixed_parity", "conversion_execution_policy:fixed_parity_forbidden", validationFailures);
        AddIfTrue(root, "stable_value_claim", "conversion_execution_policy:stable_value_claim_forbidden", validationFailures);
    }

    private static void ValidateCcCapacityReportRecord(JsonElement root, List<string> validationFailures)
    {
        if (!TryReadUtc(root, "reporting_period_start_utc", out var startUtc)
            || !TryReadUtc(root, "reporting_period_end_utc", out var endUtc)
            || endUtc <= startUtc)
        {
            validationFailures.Add("cc_capacity_policy:reporting_period_invalid");
        }

        var conservativeCapacity = ReadInt64(root, "conservative_service_liability_capacity_base_units");
        var outstanding = ReadInt64(root, "outstanding_cc_before_base_units");
        var maxIssuance = ReadInt64(root, "max_issuance_base_units");
        if (conservativeCapacity <= 0 || outstanding < 0 || maxIssuance < 0)
        {
            validationFailures.Add("cc_capacity_policy:capacity_amounts_invalid");
        }

        var haircutBasisPoints = ReadInt(root, "capacity_haircut_basis_points");
        if (haircutBasisPoints < 0 || haircutBasisPoints > 10_000)
        {
            validationFailures.Add("cc_capacity_policy:capacity_haircut_basis_points_invalid");
        }

        foreach (var haircutField in new[]
        {
            "proof_history_haircut",
            "uptime_haircut",
            "retrieval_haircut",
            "repair_haircut",
            "concentration_haircut",
            "churn_haircut",
            "audit_confidence_haircut"
        })
        {
            var haircut = ReadDouble(root, haircutField);
            if (haircut < 0.0 || haircut > 1.0)
            {
                validationFailures.Add("cc_capacity_policy:haircut_out_of_range:" + haircutField);
            }
        }

        if (!ReadBool(root, "continuity_reserve_excluded"))
        {
            validationFailures.Add("cc_capacity_policy:continuity_reserve_must_be_excluded");
        }

        if (!ReadBool(root, "operational_reserve_excluded"))
        {
            validationFailures.Add("cc_capacity_policy:operational_reserve_must_be_excluded");
        }

        if (!ReadBool(root, "affiliate_trade_exclusion_applied"))
        {
            validationFailures.Add("cc_capacity_policy:affiliate_trade_exclusion_required");
        }

        if (ReadBool(root, "thin_market_issuance_zero") && maxIssuance != 0)
        {
            validationFailures.Add("cc_capacity_policy:thin_market_requires_zero_issuance");
        }

        if (!ReadBool(root, "independent_volume_qualified") && maxIssuance != 0)
        {
            validationFailures.Add("cc_capacity_policy:unqualified_volume_requires_zero_issuance");
        }

        if (ReadStringArray(root, "capacity_evidence_refs").Length == 0)
        {
            validationFailures.Add("cc_capacity_policy:capacity_evidence_refs_required");
        }
    }

    private static void ValidateStorageRedemptionRecord(JsonElement root, string recordType, List<string> validationFailures)
    {
        var recordStage = ReadString(root, "record_stage");
        var expectedStage = recordType switch
        {
            "passport_storage_redemption_quote" => "quote",
            "passport_storage_redemption_accepted" => "accepted",
            "passport_storage_redemption_epoch_burn" => "epoch_burn",
            "passport_storage_redemption_refund" => "refund",
            _ => string.Empty
        };

        if (!string.IsNullOrWhiteSpace(expectedStage)
            && !string.Equals(recordStage, expectedStage, StringComparison.Ordinal))
        {
            validationFailures.Add("storage_redemption_policy:record_stage_invalid");
        }

        if (recordType == "passport_storage_redemption"
            && recordStage is not "quote" and not "accepted" and not "epoch_burn" and not "refund" and not "recredit" and not "service_extension" and not "admin_escrow_release" and not "admin_burn_override")
        {
            validationFailures.Add("storage_redemption_policy:record_stage_invalid");
        }

        var storageGb = ReadInt64(root, "storage_gb");
        var epochCount = ReadInt64(root, "epoch_count");
        var rate = ReadInt64(root, "cc_rate_per_gb_epoch_base_units");
        var total = ReadInt64(root, "total_cc_base_units");
        if (storageGb <= 0 || epochCount <= 0 || rate <= 0 || total <= 0)
        {
            validationFailures.Add("storage_redemption_policy:positive_quote_terms_required");
        }
        else if (!TryMultiply(storageGb, epochCount, rate, out var expectedTotal) || total != expectedTotal)
        {
            validationFailures.Add("storage_redemption_policy:total_cc_must_match_quote_terms");
        }

        var failureRemedy = ReadString(root, "failure_remedy");
        if (failureRemedy is not "refund_or_service_extension_if_service_fails"
            and not "automatic_cc_recredit_or_service_extension"
            and not "refund"
            and not "recredit"
            and not "service_extension"
            and not "refund_or_extension"
            and not "recredit_or_extension")
        {
            validationFailures.Add("storage_redemption_policy:failure_remedy_invalid");
        }

        if (!TryReadUtc(root, "quote_expires_utc", out _))
        {
            validationFailures.Add("storage_redemption_policy:quote_expires_utc_invalid");
        }

        if (recordType is "passport_storage_redemption_accepted" or "passport_storage_redemption_epoch_burn" or "passport_storage_redemption_refund")
        {
            if (string.IsNullOrWhiteSpace(ReadString(root, "accepted_redemption_id")))
            {
                validationFailures.Add("storage_redemption_policy:accepted_redemption_id_required");
            }

            if (!LooksLikeSha256(ReadString(root, "escrow_ledger_event_sha256")))
            {
                validationFailures.Add("storage_redemption_policy:escrow_ledger_event_sha256_invalid");
            }
        }

        if (recordType == "passport_storage_redemption_accepted" && !LooksLikeSha256(ReadString(root, "quote_sha256")))
        {
            validationFailures.Add("storage_redemption_policy:quote_sha256_invalid");
        }

        if (recordType == "passport_storage_redemption_epoch_burn")
        {
            var burn = ReadInt64(root, "burn_cc_base_units");
            if (!LooksLikeSha256(ReadString(root, "proof_record_sha256")))
            {
                validationFailures.Add("storage_redemption_policy:proof_record_sha256_invalid");
            }

            if (ReadInt64(root, "verified_gb_days") <= 0 || burn <= 0)
            {
                validationFailures.Add("storage_redemption_policy:positive_burn_required");
            }

            if (burn > total)
            {
                validationFailures.Add("storage_redemption_policy:burn_exceeds_total");
            }
        }

        if (recordType == "passport_storage_redemption_refund")
        {
            var refund = ReadInt64(root, "refund_cc_base_units");
            if (refund <= 0)
            {
                validationFailures.Add("storage_redemption_policy:positive_refund_required");
            }

            if (refund > total)
            {
                validationFailures.Add("storage_redemption_policy:refund_exceeds_total");
            }
        }
    }

    private static void ValidateRecoveryControlValidationRecord(JsonElement root, List<string> validationFailures)
    {
        var validationMode = ReadString(root, "validation_mode");
        if (validationMode is not "self_service_device_signature" and not "support_mediated_dual_control")
        {
            validationFailures.Add("recovery_validation_policy:validation_mode_invalid");
        }

        if (!LooksLikeSha256(ReadString(root, "recovery_control_record_sha256")))
        {
            validationFailures.Add("recovery_validation_policy:recovery_control_record_sha256_invalid");
        }

        AddIfTrue(root, "ai_approved", "recovery_validation_policy:ai_approval_forbidden", validationFailures);
    }

    private static void ValidateHostedStorageBackupManifestRecord(JsonElement root, List<string> validationFailures)
    {
        if (!LooksLikeSha256(ReadString(root, "manifest_root_sha256")))
        {
            validationFailures.Add("hosted_backup_policy:manifest_root_sha256_invalid");
        }

        if (ReadInt64(root, "manifest_file_count") <= 0 || ReadInt64(root, "manifest_total_bytes") < 0)
        {
            validationFailures.Add("hosted_backup_policy:manifest_counts_invalid");
        }

        AddIfTrue(root, "private_key_material_included", "hosted_backup_policy:private_key_material_forbidden", validationFailures);
        AddIfTrue(root, "raw_ai_prompts_included", "hosted_backup_policy:raw_ai_prompts_forbidden", validationFailures);
        AddIfTrue(root, "storage_payloads_included", "hosted_backup_policy:storage_payloads_forbidden", validationFailures);
    }

    private static void ValidateHostedIncidentReportRecord(JsonElement root, List<string> validationFailures)
    {
        var severity = ReadString(root, "severity");
        if (severity is not "low" and not "medium" and not "high" and not "critical")
        {
            validationFailures.Add("hosted_incident_policy:severity_invalid");
        }

        var detectedUtc = ReadString(root, "detected_utc");
        if (string.IsNullOrWhiteSpace(detectedUtc) || !DateTimeOffset.TryParse(detectedUtc, out _))
        {
            validationFailures.Add("hosted_incident_policy:detected_utc_invalid");
        }

        AddIfTrue(root, "contains_personal_data", "hosted_incident_policy:personal_data_forbidden", validationFailures);
        AddIfTrue(root, "contains_raw_ai_prompts", "hosted_incident_policy:raw_ai_prompts_forbidden", validationFailures);
        AddIfTrue(root, "contains_storage_payload_details", "hosted_incident_policy:storage_payload_details_forbidden", validationFailures);
    }

    private static bool IsArchOrCc(string assetCode)
    {
        return string.Equals(assetCode, "ARCH", StringComparison.OrdinalIgnoreCase)
            || string.Equals(assetCode, "CC", StringComparison.OrdinalIgnoreCase);
    }

    private static void AddIfTrue(JsonElement root, string propertyName, string failure, List<string> validationFailures)
    {
        if (ReadBool(root, propertyName))
        {
            validationFailures.Add(failure);
        }
    }

    private static int ReadInt(JsonElement root, string propertyName)
    {
        if (!root.TryGetProperty(propertyName, out var element))
        {
            return 0;
        }

        if (element.ValueKind == JsonValueKind.Number && element.TryGetInt32(out var value))
        {
            return value;
        }

        return 0;
    }

    private static double ReadDouble(JsonElement root, string propertyName)
    {
        if (!root.TryGetProperty(propertyName, out var element))
        {
            return 0.0;
        }

        if (element.ValueKind == JsonValueKind.Number && element.TryGetDouble(out var value))
        {
            return value;
        }

        return 0.0;
    }

    private static long ReadInt64(JsonElement root, string propertyName)
    {
        if (!root.TryGetProperty(propertyName, out var element))
        {
            return 0;
        }

        if (element.ValueKind == JsonValueKind.Number && element.TryGetInt64(out var value))
        {
            return value;
        }

        return 0;
    }

    private static bool ReadBool(JsonElement root, string propertyName)
    {
        return root.TryGetProperty(propertyName, out var element)
            && (element.ValueKind == JsonValueKind.True
                || (element.ValueKind == JsonValueKind.String && bool.TryParse(element.GetString(), out var parsed) && parsed));
    }

    private static bool LooksLikeSha256(string value)
    {
        var normalized = (value ?? string.Empty).Trim();
        return normalized.Length == 64 && normalized.All(Uri.IsHexDigit);
    }

    private static bool TryReadUtc(JsonElement root, string propertyName, out DateTimeOffset value)
    {
        if (DateTimeOffset.TryParse(ReadString(root, propertyName), out var parsed))
        {
            value = parsed.ToUniversalTime();
            return true;
        }

        value = default;
        return false;
    }

    private static bool TryMultiply(long left, long middle, long right, out long result)
    {
        try
        {
            result = checked(left * middle * right);
            return true;
        }
        catch (OverflowException)
        {
            result = 0;
            return false;
        }
    }

    private static string[] ReadStringArray(JsonElement root, string propertyName)
    {
        if (!root.TryGetProperty(propertyName, out var element) || element.ValueKind != JsonValueKind.Array)
        {
            return Array.Empty<string>();
        }

        return element.EnumerateArray()
            .Where(item => item.ValueKind == JsonValueKind.String)
            .Select(item => item.GetString() ?? string.Empty)
            .ToArray();
    }

    private static bool IsTemplatePlaceholder(string value)
    {
        var trimmed = (value ?? string.Empty).Trim();
        return trimmed.Length >= 2 && trimmed.StartsWith("<", StringComparison.Ordinal) && trimmed.EndsWith(">", StringComparison.Ordinal);
    }

    private static bool Contains(string value, string filter)
    {
        return (value ?? string.Empty).IndexOf(filter, StringComparison.OrdinalIgnoreCase) >= 0;
    }

    private static string ComputeSha256(byte[] value)
    {
        return Convert.ToHexString(SHA256.HashData(value)).ToLowerInvariant();
    }

    private static string DecodeJson(byte[] value)
    {
        return Encoding.UTF8.GetString(value).TrimStart('\uFEFF');
    }

    private static PassportRegistryRecordInspection NotRecord(
        string relativePath,
        string sha256,
        params string[] validationFailures)
    {
        return new PassportRegistryRecordInspection
        {
            IsRecord = false,
            RelativePath = relativePath,
            Sha256 = sha256,
            ValidationFailures = validationFailures
        };
    }

    private static PassportRegistryRecordInspection NotRecord(
        string relativePath,
        string sha256,
        IReadOnlyList<string> validationFailures)
    {
        return new PassportRegistryRecordInspection
        {
            IsRecord = false,
            RelativePath = relativePath,
            Sha256 = sha256,
            ValidationFailures = validationFailures
        };
    }
}
