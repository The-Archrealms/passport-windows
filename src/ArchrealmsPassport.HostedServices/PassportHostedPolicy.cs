using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using ArchrealmsPassport.Core.Protocol;
using ArchrealmsPassport.HostedServices.Contracts;

namespace ArchrealmsPassport.HostedServices;

public static class PassportHostedPolicy
{
    public const string ContractVersion = "passport-hosted-services-v1";

    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        WriteIndented = true
    };

    public static PassportAiSessionAuthorizationResponse AuthorizeAiSession(PassportAiSessionAuthorizationRequest request)
    {
        try
        {
            var record = request.RequestRecord;
            if (!Matches(record, "record_type", PassportRecordTypes.AiSessionRequest))
            {
                return FailedAiSession("AI session authorization requires a passport_ai_session_request record.");
            }

            var actualRequestHash = ComputeJsonSha256(record);
            if (!string.IsNullOrWhiteSpace(request.RequestRecordSha256)
                && !string.Equals(actualRequestHash, request.RequestRecordSha256.Trim(), StringComparison.OrdinalIgnoreCase))
            {
                return FailedAiSession("AI session request hash does not match.");
            }

            if (!DateTimeOffset.TryParse(ReadString(record, "expires_utc"), out var expiresUtc)
                || expiresUtc.ToUniversalTime() <= DateTimeOffset.UtcNow)
            {
                return FailedAiSession("AI session request is expired.");
            }

            if (!record.TryGetProperty("session_token_policy", out var tokenPolicy)
                || !ReadBoolean(tokenPolicy, "token_separate_from_wallet_keys")
                || ReadBoolean(tokenPolicy, "wallet_key_material_included")
                || ReadBoolean(tokenPolicy, "recovery_secret_material_included"))
            {
                return FailedAiSession("AI session request violates token/key separation policy.");
            }

            if (!record.TryGetProperty("authority_boundaries", out var authority)
                || !PassportAiAuthorityPolicy.IsNonAuthoritative(authority))
            {
                return FailedAiSession("AI session request must mark AI as non-authoritative.");
            }

            if (!VerifySessionSignature(request, record))
            {
                return FailedAiSession("AI session request signature verification failed.");
            }

            var token = CreateToken();
            var tokenSha256 = ComputeSha256(Encoding.UTF8.GetBytes(token));
            var sessionId = DateTime.UtcNow.ToString("yyyyMMddTHHmmssZ") + "-ai-session-" + Guid.NewGuid().ToString("N")[..10];
            var ttl = TimeSpan.FromMinutes(Math.Clamp(request.TtlMinutes, 1, 120));
            var sessionExpiresUtc = DateTimeOffset.UtcNow.Add(ttl).ToString("yyyy-MM-ddTHH:mm:ssZ");
            var messageQuota = Math.Clamp(request.MessageQuota, 1, 500);
            var tokenQuota = Math.Clamp(request.TokenQuota, 1, 500000);
            var session = new Dictionary<string, object?>
            {
                ["schema_version"] = 1,
                ["record_type"] = PassportRecordTypes.AiSessionRecord,
                ["record_id"] = sessionId,
                ["session_id"] = sessionId,
                ["created_utc"] = DateTimeOffset.UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ"),
                ["expires_utc"] = sessionExpiresUtc,
                ["status"] = "active",
                ["contract_version"] = ContractVersion,
                ["release_lane"] = ReadString(record, "release_lane"),
                ["ledger_namespace"] = ReadString(record, "ledger_namespace"),
                ["policy_version"] = ReadString(record, "policy_version"),
                ["archrealms_identity_id"] = ReadString(record, "archrealms_identity_id"),
                ["device_id"] = ReadString(record, "device_id"),
                ["gateway_url"] = ReadString(record, "gateway_url"),
                ["approved_knowledge_pack_id"] = ReadString(record, "approved_knowledge_pack_id"),
                ["request_record_sha256"] = actualRequestHash,
                ["session_token_sha256"] = tokenSha256,
                ["quota"] = new Dictionary<string, object?>
                {
                    ["message_limit"] = messageQuota,
                    ["token_limit"] = tokenQuota,
                    ["messages_used"] = 0,
                    ["tokens_used"] = 0
                },
                ["privacy"] = CopyObject(record, "privacy"),
                ["authority_boundaries"] = PassportAiAuthorityPolicy.CreateNonAuthorityBoundaries(),
                ["summary"] = "Hosted Passport AI session. The bearer token is returned to the caller and not stored in this record."
            };

            return new PassportAiSessionAuthorizationResponse
            {
                Succeeded = true,
                Message = "AI session authorized.",
                SessionId = sessionId,
                SessionToken = token,
                SessionTokenSha256 = tokenSha256,
                ExpiresUtc = sessionExpiresUtc,
                MessageQuota = messageQuota,
                TokenQuota = tokenQuota,
                Session = session
            };
        }
        catch (Exception ex)
        {
            return FailedAiSession("AI session authorization failed: " + ex.Message);
        }
    }

    public static PassportAiChatResponse CreateAiChatResponse(
        PassportAiChatRequest request,
        string bearerToken,
        IPassportHostedSessionStore sessionStore)
    {
        if (string.IsNullOrWhiteSpace(bearerToken))
        {
            return FailedChat("AI chat requires a bearer session token.");
        }

        if (!sessionStore.TryGetAiSession(request.SessionId, out var session)
            || session.Session == null)
        {
            return FailedChat("AI session was not found.");
        }

        if (!string.Equals(ComputeSha256(Encoding.UTF8.GetBytes(bearerToken)), session.SessionTokenSha256, StringComparison.OrdinalIgnoreCase))
        {
            return FailedChat("AI session token does not match.");
        }

        if (!DateTimeOffset.TryParse(session.ExpiresUtc, out var expiresUtc) || expiresUtc.ToUniversalTime() <= DateTimeOffset.UtcNow)
        {
            return FailedChat("AI session is expired.");
        }

        if (string.IsNullOrWhiteSpace(request.Message))
        {
            return FailedChat("AI chat requires a message.");
        }

        if (PassportAiAuthorityPolicy.ContainsSecretMaterial(request.Message))
        {
            return FailedChat("AI chat rejected private key, seed, or recovery-secret material.");
        }

        var sources = request.ClientApprovedContextRefs.Take(3).ToArray();
        var sourceSummary = sources.Length == 0
            ? "No approved source references were supplied by Passport."
            : "Sources: " + string.Join(", ", sources.Select(source => string.IsNullOrWhiteSpace(source.Title) ? source.SourceId : source.Title));
        var answer = "Archrealms AI guide response from the hosted gateway contract. "
            + sourceSummary
            + " AI cannot approve recovery, issue or burn credits, release escrow, mark service delivered, change registry authority, execute wallet operations, or approve admin authority.";

        return new PassportAiChatResponse
        {
            Succeeded = true,
            Message = "AI chat response created.",
            AnswerText = answer,
            QuotaSummary = session.MessageQuota + " messages; " + session.TokenQuota + " tokens.",
            Sources = sources
        };
    }

    public static PassportHostedRecordResponse CreateCcCapacityReport(PassportCcCapacityReportRequest request)
    {
        if (request.ConservativeServiceLiabilityCapacityBaseUnits <= 0)
        {
            return FailedRecord("Conservative service-liability capacity must be greater than zero.");
        }

        if (request.OutstandingCcBeforeBaseUnits < 0 || request.MaxIssuanceBaseUnits < 0)
        {
            return FailedRecord("Outstanding CC and max issuance cannot be negative.");
        }

        if (request.CapacityHaircutBasisPoints is < 0 or > 10000)
        {
            return FailedRecord("Capacity haircut must be between 0 and 10000 basis points.");
        }

        if (request.ThinMarketIssuanceZero)
        {
            return FailedRecord("Thin-market reports cannot authorize CC issuance.");
        }

        if (!request.IndependentVolumeQualified)
        {
            return FailedRecord("Capacity report requires qualified independent volume.");
        }

        if (!request.ContinuityReserveExcluded || !request.OperationalReserveExcluded)
        {
            return FailedRecord("Capacity report must exclude continuity and operational reserves.");
        }

        if (!LooksLikeSha256(request.CapacityReportAuthorityRecordSha256))
        {
            return FailedRecord("Capacity report requires authority record hash evidence.");
        }

        var recordId = NewRecordId("cc-capacity-" + NormalizeSlug(request.ServiceClass));
        var record = new Dictionary<string, object?>
        {
            ["schema_version"] = 1,
            ["record_type"] = PassportRecordTypes.CcCapacityReport,
            ["record_id"] = recordId,
            ["created_utc"] = DateTimeOffset.UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ"),
            ["contract_version"] = ContractVersion,
            ["release_lane"] = NormalizeRequired(request.ReleaseLane, "release lane"),
            ["ledger_namespace"] = NormalizeRequired(request.LedgerNamespace, "ledger namespace"),
            ["policy_version"] = NormalizeRequired(request.PolicyVersion, "policy version"),
            ["service_class"] = NormalizeSlug(request.ServiceClass),
            ["conservative_service_liability_capacity_base_units"] = request.ConservativeServiceLiabilityCapacityBaseUnits,
            ["outstanding_cc_before_base_units"] = request.OutstandingCcBeforeBaseUnits,
            ["max_issuance_base_units"] = request.MaxIssuanceBaseUnits,
            ["capacity_haircut_basis_points"] = request.CapacityHaircutBasisPoints,
            ["independent_volume_qualified"] = request.IndependentVolumeQualified,
            ["thin_market_issuance_zero"] = request.ThinMarketIssuanceZero,
            ["continuity_reserve_excluded"] = request.ContinuityReserveExcluded,
            ["operational_reserve_excluded"] = request.OperationalReserveExcluded,
            ["capacity_report_authority_record_sha256"] = request.CapacityReportAuthorityRecordSha256.Trim().ToLowerInvariant(),
            ["summary"] = "Hosted conservative Crown Credit issuance-capacity report."
        };

        return RecordResponse("CC capacity report created.", recordId, record);
    }

    public static PassportHostedRecordResponse CreateArchGenesisManifest(PassportArchGenesisManifestRequest request)
    {
        if (request.TotalSupplyBaseUnits <= 0)
        {
            return FailedRecord("ARCH genesis total supply must be greater than zero.");
        }

        if (request.BaseUnitPrecision is < 0 or > 18)
        {
            return FailedRecord("ARCH base-unit precision must be between 0 and 18.");
        }

        if (!LooksLikeSha256(request.GenesisAuthorityRecordSha256))
        {
            return FailedRecord("ARCH genesis manifest requires authority record hash evidence.");
        }

        var allocations = request.Allocations.Select(NormalizeAllocation).ToArray();
        if (allocations.Length == 0)
        {
            return FailedRecord("ARCH genesis manifest requires at least one allocation.");
        }

        if (allocations.GroupBy(item => item.AllocationId, StringComparer.Ordinal).Any(group => group.Count() > 1))
        {
            return FailedRecord("ARCH genesis allocation IDs must be unique.");
        }

        var allocationTotal = allocations.Sum(item => item.AmountBaseUnits);
        if (allocationTotal != request.TotalSupplyBaseUnits)
        {
            return FailedRecord("ARCH genesis allocation total must equal fixed total supply.");
        }

        var recordId = NewRecordId("arch-genesis-" + NormalizeRequired(request.ReleaseLane, "release lane"));
        var record = new Dictionary<string, object?>
        {
            ["schema_version"] = 1,
            ["record_type"] = PassportRecordTypes.ArchGenesisManifest,
            ["record_id"] = recordId,
            ["created_utc"] = DateTimeOffset.UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ"),
            ["contract_version"] = ContractVersion,
            ["release_lane"] = NormalizeRequired(request.ReleaseLane, "release lane"),
            ["ledger_namespace"] = NormalizeRequired(request.LedgerNamespace, "ledger namespace"),
            ["policy_version"] = NormalizeRequired(request.PolicyVersion, "policy version"),
            ["asset_code"] = "ARCH",
            ["total_supply_base_units"] = request.TotalSupplyBaseUnits,
            ["base_unit_precision"] = request.BaseUnitPrecision,
            ["allocation_total_base_units"] = allocationTotal,
            ["post_genesis_minting_allowed"] = false,
            ["sealed"] = true,
            ["genesis_authority_record_sha256"] = request.GenesisAuthorityRecordSha256.Trim().ToLowerInvariant(),
            ["allocations"] = allocations.Select(item => new Dictionary<string, object?>
            {
                ["allocation_id"] = item.AllocationId,
                ["account_id"] = item.AccountId,
                ["archrealms_identity_id"] = item.IdentityId,
                ["wallet_key_id"] = item.WalletKeyId,
                ["amount_base_units"] = item.AmountBaseUnits
            }).ToArray(),
            ["summary"] = "Hosted fixed-genesis ARCH manifest. The allocation total equals total supply and post-genesis minting is disabled."
        };

        return RecordResponse("ARCH genesis manifest created.", recordId, record);
    }

    public static PassportHostedRecordResponse ValidateAdminAuthority(PassportAdminAuthorityValidationRequest request)
    {
        if (!Matches(request.AdminAuthorityRecord, "record_type", PassportRecordTypes.AdminDualControlAction))
        {
            return FailedRecord("Admin authority validation requires a dual-control authority record.");
        }

        if (!Matches(request.AdminAuthorityRecord, "action_type", NormalizeActionType(request.ActionType)))
        {
            return FailedRecord("Admin authority action type does not match.");
        }

        if (!Matches(request.AdminAuthorityRecord, "authority_scope", NormalizeRequired(request.AuthorityScope, "authority scope")))
        {
            return FailedRecord("Admin authority scope does not match.");
        }

        if (!MatchesHash(request.AdminAuthorityRecord, "target_record_sha256", request.TargetRecordSha256)
            || !MatchesHash(request.AdminAuthorityRecord, "requested_payload_sha256", request.RequestedPayloadSha256))
        {
            return FailedRecord("Admin authority hash binding does not match.");
        }

        if (ReadString(request.AdminAuthorityRecord, "requester_device_id") == ReadString(request.AdminAuthorityRecord, "approver_device_id"))
        {
            return FailedRecord("Dual-control admin authority requires two distinct devices.");
        }

        if (ReadBoolean(request.AdminAuthorityRecord, "ai_approved"))
        {
            return FailedRecord("AI cannot approve admin authority.");
        }

        if (!Matches(request.RequesterSignatureRecord, "record_type", "passport_admin_dual_control_requester_signature")
            || !Matches(request.ApproverSignatureRecord, "record_type", "passport_admin_dual_control_approver_signature"))
        {
            return FailedRecord("Admin authority requires requester and approver signature records.");
        }

        return new PassportHostedRecordResponse
        {
            Succeeded = true,
            Message = "Admin authority evidence is structurally valid.",
            RecordId = ReadString(request.AdminAuthorityRecord, "record_id"),
            RecordSha256 = ComputeJsonSha256(request.AdminAuthorityRecord)
        };
    }

    public static PassportHostedRecordResponse ValidateAdminAuthority(
        PassportAdminAuthorityValidationRequest request,
        PassportHostedRegistryStore registryStore)
    {
        var structural = ValidateAdminAuthority(request);
        if (!structural.Succeeded)
        {
            return structural;
        }

        var actionPayload = DecodeBase64(request.AdminAuthorityRecordPayloadBase64);
        if (actionPayload.Length == 0)
        {
            return FailedRecord("Admin authority validation requires signed admin_authority_record_payload_base64.");
        }

        using var actionPayloadDocument = JsonDocument.Parse(actionPayload);
        var actionPayloadRoot = actionPayloadDocument.RootElement;
        var payloadMatch = AdminActionPayloadMatchesRequest(actionPayloadRoot, request.AdminAuthorityRecord);
        if (!payloadMatch.Succeeded)
        {
            return payloadMatch;
        }

        var requesterDeviceId = ReadString(request.AdminAuthorityRecord, "requester_device_id");
        var approverDeviceId = ReadString(request.AdminAuthorityRecord, "approver_device_id");
        var authorityIdentityId = ReadString(request.AdminAuthorityRecord, "authority_identity_id");
        var requesterRole = registryStore.ValidateActiveRoleMembership(
            authorityIdentityId,
            requesterDeviceId,
            request.ActionType,
            request.AuthorityScope);
        if (!requesterRole.Succeeded)
        {
            return FailedRecord("Requester device is not assigned an active hosted admin role: " + requesterRole.Message);
        }

        var approverRole = registryStore.ValidateActiveRoleMembership(
            authorityIdentityId,
            approverDeviceId,
            request.ActionType,
            request.AuthorityScope);
        if (!approverRole.Succeeded)
        {
            return FailedRecord("Approver device is not assigned an active hosted admin role: " + approverRole.Message);
        }

        var payloadHash = ComputeSha256(actionPayload);
        var requesterSignature = ValidateAdminSignature(
            request.RequesterSignatureRecord,
            PassportRecordTypes.AdminDualControlRequesterSignature,
            requesterDeviceId,
            actionPayload,
            payloadHash,
            registryStore);
        if (!requesterSignature.Succeeded)
        {
            return requesterSignature;
        }

        var approverSignature = ValidateAdminSignature(
            request.ApproverSignatureRecord,
            PassportRecordTypes.AdminDualControlApproverSignature,
            approverDeviceId,
            actionPayload,
            payloadHash,
            registryStore);
        if (!approverSignature.Succeeded)
        {
            return approverSignature;
        }

        return new PassportHostedRecordResponse
        {
            Succeeded = true,
            Message = "Admin authority evidence is valid against hosted registry roles and signatures.",
            RecordId = ReadString(request.AdminAuthorityRecord, "record_id"),
            RecordSha256 = payloadHash
        };
    }

    public static PassportHostedRecordResponse AcceptStorageDeliveryRequest(PassportStorageDeliveryRequest request)
    {
        var source = request.ServiceDeliveryRequestRecord;
        if (!Matches(source, "record_type", PassportRecordTypes.StorageServiceDeliveryRequest))
        {
            return FailedRecord("Storage delivery requires a passport_storage_service_delivery_request record.");
        }

        var actualHash = ComputeJsonSha256(source);
        if (!string.IsNullOrWhiteSpace(request.ServiceDeliveryRequestSha256)
            && !string.Equals(actualHash, request.ServiceDeliveryRequestSha256.Trim(), StringComparison.OrdinalIgnoreCase))
        {
            return FailedRecord("Storage delivery request hash does not match.");
        }

        if (ReadInt64(source, "storage_gb") <= 0 || ReadInt64(source, "service_epoch_count") <= 0)
        {
            return FailedRecord("Storage delivery request requires positive storage and epoch count.");
        }

        var recordId = NewRecordId("storage-delivery-accepted");
        var record = new Dictionary<string, object?>
        {
            ["schema_version"] = 1,
            ["record_type"] = PassportRecordTypes.StorageDeliveryAcceptance,
            ["record_id"] = recordId,
            ["created_utc"] = DateTimeOffset.UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ"),
            ["contract_version"] = ContractVersion,
            ["release_lane"] = ReadString(source, "release_lane"),
            ["ledger_namespace"] = ReadString(source, "ledger_namespace"),
            ["redemption_id"] = ReadString(source, "redemption_id"),
            ["service_delivery_request_sha256"] = actualHash,
            ["assignment_status"] = "accepted_pending_epoch_proofs",
            ["proof_requirements"] = new Dictionary<string, object?>
            {
                ["possession_challenge_required"] = true,
                ["retrieval_challenge_required"] = true,
                ["metering_record_required"] = true,
                ["repair_status_required"] = true,
                ["burn_without_verified_epoch_allowed"] = false
            },
            ["summary"] = "Hosted storage delivery acceptance. Burns remain blocked until verified service epoch proof records exist."
        };

        return RecordResponse("Storage delivery request accepted.", recordId, record);
    }

    public static string ReadBearerToken(string authorizationHeader)
    {
        const string prefix = "Bearer ";
        return authorizationHeader.StartsWith(prefix, StringComparison.OrdinalIgnoreCase)
            ? authorizationHeader[prefix.Length..].Trim()
            : string.Empty;
    }

    private static bool VerifySessionSignature(PassportAiSessionAuthorizationRequest request, JsonElement record)
    {
        if (!record.TryGetProperty("signature", out var signature))
        {
            return false;
        }

        var signedPayload = DecodeBase64(request.SignedPayloadBase64);
        var signatureBytes = DecodeBase64(request.SignatureBase64);
        var publicKeyBytes = DecodeBase64(request.DevicePublicKeySpkiDerBase64);
        if (signedPayload.Length == 0 || signatureBytes.Length == 0 || publicKeyBytes.Length == 0)
        {
            return false;
        }

        var expectedPayloadHash = ReadString(signature, "signed_payload_sha256");
        if (!string.Equals(ComputeSha256(signedPayload), expectedPayloadHash, StringComparison.OrdinalIgnoreCase))
        {
            return false;
        }

        if (!SignedPayloadMatchesRequest(signedPayload, record))
        {
            return false;
        }

        using var rsa = RSA.Create();
        rsa.ImportSubjectPublicKeyInfo(publicKeyBytes, out _);
        return rsa.VerifyData(signedPayload, signatureBytes, HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1);
    }

    private static PassportHostedRecordResponse ValidateAdminSignature(
        JsonElement signatureRecord,
        string expectedRecordType,
        string expectedDeviceId,
        byte[] actionPayload,
        string actionPayloadSha256,
        PassportHostedRegistryStore registryStore)
    {
        if (!Matches(signatureRecord, "record_type", expectedRecordType))
        {
            return FailedRecord("The hosted admin authority signature record type is invalid.");
        }

        if (!Matches(signatureRecord, "device_id", expectedDeviceId))
        {
            return FailedRecord("The hosted admin authority signature was made by an unexpected device.");
        }

        if (!string.Equals(ReadString(signatureRecord, "admin_action_record_sha256"), actionPayloadSha256, StringComparison.OrdinalIgnoreCase))
        {
            return FailedRecord("The hosted admin authority signature does not reference the signed action payload.");
        }

        if (!registryStore.TryGetPublicKey(expectedDeviceId, out var publicKey))
        {
            return FailedRecord("The hosted admin authority signer public key could not be found.");
        }

        var signatureBase64 = ReadString(signatureRecord, "signature_base64");
        if (string.IsNullOrWhiteSpace(signatureBase64))
        {
            return FailedRecord("The hosted admin authority signature is missing.");
        }

        using var rsa = RSA.Create();
        rsa.ImportSubjectPublicKeyInfo(publicKey, out _);
        if (!rsa.VerifyData(actionPayload, Convert.FromBase64String(signatureBase64), HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1))
        {
            return FailedRecord("The hosted admin authority signature verification failed.");
        }

        return new PassportHostedRecordResponse
        {
            Succeeded = true,
            Message = "Hosted admin authority signature verified.",
            RecordId = ReadString(signatureRecord, "record_id"),
            RecordSha256 = ComputeJsonSha256(signatureRecord)
        };
    }

    private static PassportHostedRecordResponse AdminActionPayloadMatchesRequest(JsonElement payload, JsonElement requestRecord)
    {
        var criticalFields = new[]
        {
            "record_type",
            "record_id",
            "authority_identity_id",
            "action_type",
            "authority_scope",
            "target_record_sha256",
            "requested_payload_sha256",
            "requester_device_id",
            "approver_device_id"
        };

        foreach (var field in criticalFields)
        {
            if (!string.Equals(ReadString(payload, field), ReadString(requestRecord, field), StringComparison.Ordinal))
            {
                return FailedRecord("Admin authority signed payload does not match request field: " + field + ".");
            }
        }

        return new PassportHostedRecordResponse
        {
            Succeeded = true,
            Message = "Admin authority signed payload matches request record."
        };
    }

    private static bool SignedPayloadMatchesRequest(byte[] signedPayload, JsonElement requestRecord)
    {
        using var payloadDocument = JsonDocument.Parse(signedPayload);
        var payload = payloadDocument.RootElement;
        var criticalFields = new[]
        {
            "record_type",
            "record_id",
            "release_lane",
            "ledger_namespace",
            "policy_version",
            "archrealms_identity_id",
            "device_id",
            "gateway_url",
            "approved_knowledge_pack_id"
        };

        return criticalFields.All(field => string.Equals(ReadString(payload, field), ReadString(requestRecord, field), StringComparison.Ordinal));
    }

    private static PassportArchGenesisAllocationRequest NormalizeAllocation(PassportArchGenesisAllocationRequest allocation)
    {
        if (allocation.AmountBaseUnits <= 0)
        {
            throw new InvalidOperationException("ARCH genesis allocation amount must be greater than zero.");
        }

        return allocation with
        {
            AllocationId = NormalizeRequired(allocation.AllocationId, "allocation ID"),
            AccountId = NormalizeRequired(allocation.AccountId, "account ID"),
            IdentityId = NormalizeRequired(allocation.IdentityId, "identity ID"),
            WalletKeyId = NormalizeRequired(allocation.WalletKeyId, "wallet key ID")
        };
    }

    private static Dictionary<string, object?> CopyObject(JsonElement root, string propertyName)
    {
        if (!root.TryGetProperty(propertyName, out var property) || property.ValueKind != JsonValueKind.Object)
        {
            return new Dictionary<string, object?>();
        }

        return JsonSerializer.Deserialize<Dictionary<string, object?>>(property.GetRawText()) ?? new Dictionary<string, object?>();
    }

    private static bool Matches(JsonElement root, string propertyName, string expected)
    {
        return string.Equals(ReadString(root, propertyName), expected, StringComparison.Ordinal);
    }

    private static bool MatchesHash(JsonElement root, string propertyName, string expected)
    {
        var normalizedExpected = (expected ?? string.Empty).Trim().ToLowerInvariant();
        return LooksLikeSha256(normalizedExpected)
            && string.Equals(ReadString(root, propertyName), normalizedExpected, StringComparison.OrdinalIgnoreCase);
    }

    private static string ReadString(JsonElement root, string propertyName)
    {
        return root.TryGetProperty(propertyName, out var property) && property.ValueKind == JsonValueKind.String
            ? property.GetString() ?? string.Empty
            : string.Empty;
    }

    private static long ReadInt64(JsonElement root, string propertyName)
    {
        return root.TryGetProperty(propertyName, out var property) && property.TryGetInt64(out var value) ? value : 0;
    }

    private static bool ReadBoolean(JsonElement root, string propertyName)
    {
        return root.TryGetProperty(propertyName, out var property)
            && (property.ValueKind == JsonValueKind.True
                || (property.ValueKind == JsonValueKind.String && bool.TryParse(property.GetString(), out var parsed) && parsed));
    }

    private static string NormalizeRequired(string value, string label)
    {
        var normalized = (value ?? string.Empty).Trim();
        if (string.IsNullOrWhiteSpace(normalized))
        {
            throw new InvalidOperationException("A " + label + " is required.");
        }

        return normalized;
    }

    private static string NormalizeSlug(string value)
    {
        var normalized = (value ?? string.Empty).Trim().ToLowerInvariant().Replace(" ", "_").Replace("-", "_");
        return string.IsNullOrWhiteSpace(normalized) ? "aggregate" : normalized;
    }

    private static string NormalizeActionType(string value)
    {
        return NormalizeSlug(value);
    }

    private static bool LooksLikeSha256(string value)
    {
        return !string.IsNullOrWhiteSpace(value)
            && value.Trim().Length == 64
            && value.Trim().All(Uri.IsHexDigit);
    }

    private static string NewRecordId(string prefix)
    {
        return DateTime.UtcNow.ToString("yyyyMMddTHHmmssZ") + "-" + prefix + "-" + Guid.NewGuid().ToString("N")[..10];
    }

    private static PassportAiSessionAuthorizationResponse FailedAiSession(string message)
    {
        return new PassportAiSessionAuthorizationResponse { Succeeded = false, Message = message };
    }

    private static PassportAiChatResponse FailedChat(string message)
    {
        return new PassportAiChatResponse { Succeeded = false, Message = message, AnswerText = message };
    }

    private static PassportHostedRecordResponse FailedRecord(string message)
    {
        return new PassportHostedRecordResponse { Succeeded = false, Message = message };
    }

    private static PassportHostedRecordResponse RecordResponse(string message, string recordId, Dictionary<string, object?> record)
    {
        return new PassportHostedRecordResponse
        {
            Succeeded = true,
            Message = message,
            RecordId = recordId,
            RecordSha256 = ComputeSha256(JsonSerializer.SerializeToUtf8Bytes(record, JsonOptions)),
            Record = record
        };
    }

    private static byte[] DecodeBase64(string value)
    {
        if (string.IsNullOrWhiteSpace(value))
        {
            return Array.Empty<byte>();
        }

        try
        {
            return Convert.FromBase64String(value);
        }
        catch (FormatException)
        {
            return Array.Empty<byte>();
        }
    }

    private static string CreateToken()
    {
        var bytes = new byte[32];
        RandomNumberGenerator.Fill(bytes);
        return Convert.ToBase64String(bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_');
    }

    private static string ComputeJsonSha256(JsonElement value)
    {
        return ComputeSha256(JsonSerializer.SerializeToUtf8Bytes(value, JsonOptions));
    }

    private static string ComputeSha256(byte[] value)
    {
        return Convert.ToHexString(SHA256.HashData(value)).ToLowerInvariant();
    }
}
