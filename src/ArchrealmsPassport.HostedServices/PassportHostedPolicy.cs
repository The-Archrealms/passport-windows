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

    public static PassportAiChallengeResponse CreateAiChallenge(PassportAiChallengeRequest request)
    {
        try
        {
            var identityId = NormalizeRequired(request.IdentityId, "identity ID");
            var deviceId = NormalizeRequired(request.DeviceId, "device ID");
            var releaseLane = NormalizeRequired(request.ReleaseLane, "release lane");
            var ledgerNamespace = NormalizeRequired(request.LedgerNamespace, "ledger namespace");
            var policyVersion = NormalizeRequired(request.PolicyVersion, "policy version");
            var now = DateTimeOffset.UtcNow;
            var expiresUtc = now.AddMinutes(5);
            var challengeId = NewRecordId("ai-challenge");
            var nonce = CreateToken();
            var scopes = NormalizeScopes(request.RequestedScopes);
            if (!scopes.Contains("ai_guide", StringComparer.Ordinal))
            {
                throw new InvalidOperationException("AI challenge requires the ai_guide scope.");
            }

            var record = new Dictionary<string, object?>
            {
                ["schema_version"] = 1,
                ["record_type"] = PassportRecordTypes.AiChallenge,
                ["record_id"] = challengeId,
                ["challenge_id"] = challengeId,
                ["created_utc"] = now.ToString("yyyy-MM-ddTHH:mm:ssZ"),
                ["expires_utc"] = expiresUtc.ToString("yyyy-MM-ddTHH:mm:ssZ"),
                ["status"] = "issued",
                ["contract_version"] = ContractVersion,
                ["release_lane"] = releaseLane,
                ["ledger_namespace"] = ledgerNamespace,
                ["policy_version"] = policyVersion,
                ["archrealms_identity_id"] = identityId,
                ["device_id"] = deviceId,
                ["client_build"] = NormalizeRequiredValue(request.ClientBuild),
                ["challenge_nonce"] = nonce,
                ["challenge_audience"] = PassportAiProtocolDefaults.GatewayAudience,
                ["requested_scopes"] = scopes,
                ["session_endpoint"] = PassportAiProtocolDefaults.SessionEndpoint,
                ["authority_boundaries"] = PassportAiAuthorityPolicy.CreateNonAuthorityBoundaries(),
                ["summary"] = "Passport-signable AI gateway challenge. This challenge cannot authorize wallet, recovery, ledger, storage-delivery, registry, or admin actions."
            };

            return new PassportAiChallengeResponse
            {
                Succeeded = true,
                Message = "AI challenge issued.",
                ChallengeId = challengeId,
                ChallengeNonce = nonce,
                ChallengeAudience = PassportAiProtocolDefaults.GatewayAudience,
                ExpiresUtc = expiresUtc.ToString("yyyy-MM-ddTHH:mm:ssZ"),
                ChallengeRecordSha256 = ComputeSha256(JsonSerializer.SerializeToUtf8Bytes(record, JsonOptions)),
                ChallengeRecord = record
            };
        }
        catch (Exception ex)
        {
            return FailedAiChallenge("AI challenge failed: " + ex.Message);
        }
    }

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

            var challengeValidation = ValidateAiChallengeObject(record);
            if (!challengeValidation.Succeeded)
            {
                return FailedAiSession(challengeValidation.Message);
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

    public static PassportAiQuotaResponse CreateAiQuotaResponse(
        string sessionId,
        string bearerToken,
        IPassportHostedSessionStore sessionStore)
    {
        var validation = ValidateAiSessionAccess(sessionId, bearerToken, sessionStore);
        if (!validation.Succeeded || validation.Session == null)
        {
            return FailedQuota(validation.Message);
        }

        var session = validation.Session;
        var quota = session.Session == null
            ? (MessageLimit: session.MessageQuota, MessagesUsed: 0, TokenLimit: session.TokenQuota, TokensUsed: 0)
            : ReadQuota(session.Session, session.MessageQuota, session.TokenQuota);
        return new PassportAiQuotaResponse
        {
            Succeeded = true,
            Message = "AI quota read.",
            SessionId = session.SessionId,
            ExpiresUtc = session.ExpiresUtc,
            MessageLimit = quota.MessageLimit,
            MessagesUsed = quota.MessagesUsed,
            MessagesRemaining = Math.Max(0, quota.MessageLimit - quota.MessagesUsed),
            TokenLimit = quota.TokenLimit,
            TokensUsed = quota.TokensUsed,
            TokensRemaining = Math.Max(0, quota.TokenLimit - quota.TokensUsed),
            ResetUtc = session.ExpiresUtc
        };
    }

    public static PassportHostedRecordResponse CreateAiFeedbackRecord(
        PassportAiFeedbackRequest request,
        string bearerToken,
        IPassportHostedSessionStore sessionStore)
    {
        var validation = ValidateAiSessionAccess(request.SessionId, bearerToken, sessionStore);
        if (!validation.Succeeded || validation.Session?.Session == null)
        {
            return FailedRecord(validation.Message);
        }

        if (request.Rating is < 1 or > 5)
        {
            return FailedRecord("AI feedback rating must be between 1 and 5.");
        }

        if (PassportAiAuthorityPolicy.ContainsSecretMaterial(request.FeedbackText))
        {
            return FailedRecord("AI feedback rejected private key, seed, or recovery-secret material.");
        }

        var sessionRecord = validation.Session.Session;
        var feedbackText = (request.FeedbackText ?? string.Empty).Trim();
        var recordId = NewRecordId("ai-feedback");
        var record = new Dictionary<string, object?>
        {
            ["schema_version"] = 1,
            ["record_type"] = PassportRecordTypes.AiFeedbackRecord,
            ["record_id"] = recordId,
            ["created_utc"] = DateTimeOffset.UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ"),
            ["status"] = "captured",
            ["contract_version"] = ContractVersion,
            ["release_lane"] = ReadString(sessionRecord, "release_lane"),
            ["ledger_namespace"] = ReadString(sessionRecord, "ledger_namespace"),
            ["policy_version"] = ReadString(sessionRecord, "policy_version"),
            ["archrealms_identity_id"] = ReadString(sessionRecord, "archrealms_identity_id"),
            ["device_id"] = ReadString(sessionRecord, "device_id"),
            ["session_id"] = validation.Session.SessionId,
            ["chat_record_id"] = NormalizeRequiredValue(request.ChatRecordId),
            ["rating"] = request.Rating,
            ["feedback_category"] = NormalizeSlug(request.FeedbackCategory),
            ["feedback_text_sha256"] = string.IsNullOrWhiteSpace(feedbackText)
                ? string.Empty
                : ComputeSha256(Encoding.UTF8.GetBytes(feedbackText)),
            ["feedback_text_stored"] = false,
            ["diagnostics_upload_opt_in"] = request.DiagnosticsUploadOptIn,
            ["model_training_allowed"] = false,
            ["changes_ledger_state"] = false,
            ["changes_identity_state"] = false,
            ["authority_boundaries"] = PassportAiAuthorityPolicy.CreateNonAuthorityBoundaries(),
            ["summary"] = "Metadata-only AI feedback. The hosted service stores a feedback hash and does not mutate Passport, wallet, ledger, storage, registry, recovery, or admin state."
        };

        return RecordResponse("AI feedback captured.", recordId, record);
    }

    public static PassportAiGatewayStatusResponse CreateAiGatewayStatus(PassportHostedAiRuntimeReadiness runtimeReadiness)
    {
        return new PassportAiGatewayStatusResponse
        {
            Status = runtimeReadiness.Ready ? "healthy" : "degraded",
            Message = runtimeReadiness.Ready
                ? "Hosted AI gateway is configured for the approved model runtime."
                : "Hosted AI gateway is available, but runtime configuration is incomplete.",
            ContractVersion = ContractVersion,
            RuntimeReady = runtimeReadiness.Ready,
            ModelId = runtimeReadiness.ModelId,
            ChallengeEndpoint = PassportAiProtocolDefaults.ChallengeEndpoint,
            SessionEndpoint = PassportAiProtocolDefaults.SessionEndpoint,
            ChatEndpoint = PassportAiProtocolDefaults.ChatEndpoint,
            QuotaEndpoint = PassportAiProtocolDefaults.QuotaEndpoint,
            FeedbackEndpoint = PassportAiProtocolDefaults.FeedbackEndpoint,
            AuthorityBoundaries = PassportAiAuthorityPolicy.CreateNonAuthorityBoundaries()
        };
    }

    public static PassportAiChatResponse CreateAiChatResponse(
        PassportAiChatRequest request,
        string bearerToken,
        IPassportHostedSessionStore sessionStore)
    {
        return CreateAiChatResponseAsync(request, bearerToken, sessionStore, null, null)
            .GetAwaiter()
            .GetResult();
    }

    public static async Task<PassportAiChatResponse> CreateAiChatResponseAsync(
        PassportAiChatRequest request,
        string bearerToken,
        IPassportHostedSessionStore sessionStore,
        PassportHostedKnowledgeStore? knowledgeStore,
        IPassportHostedAiInferenceGateway? inferenceGateway,
        CancellationToken cancellationToken = default)
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

        var quota = ReadQuota(session.Session, session.MessageQuota, session.TokenQuota);
        if (quota.MessagesUsed >= quota.MessageLimit || quota.TokensUsed >= quota.TokenLimit)
        {
            return FailedChat("AI session quota exceeded.");
        }

        var retrievedChunks = knowledgeStore?.Retrieve(request.KnowledgePackId, request.Message, maxChunks: 3) ?? Array.Empty<PassportHostedKnowledgeChunk>();
        var sources = retrievedChunks.Length == 0
            ? request.ClientApprovedContextRefs.Take(3).ToArray()
            : retrievedChunks.Select(chunk => chunk.Source).ToArray();
        var sourceSummary = sources.Length == 0
            ? "No approved source references were supplied by Passport."
            : "Sources: " + string.Join(", ", sources.Select(source => string.IsNullOrWhiteSpace(source.Title) ? source.SourceId : source.Title));
        var fallbackAnswer = "Archrealms AI guide response from the hosted gateway contract. "
            + sourceSummary
            + " AI cannot approve recovery, issue or burn credits, release escrow, mark service delivered, change registry authority, execute wallet operations, or approve admin authority.";

        if (inferenceGateway is { IsConfigured: true })
        {
            var inference = await inferenceGateway.CreateAnswerAsync(request, session.Session, retrievedChunks, cancellationToken).ConfigureAwait(false);
            if (!inference.Succeeded)
            {
                return FailedChat("AI model runtime failed: " + inference.Message);
            }

            fallbackAnswer = inference.AnswerText
                + Environment.NewLine
                + Environment.NewLine
                + "Runtime: " + inference.ModelId + ". " + sourceSummary;
        }

        var estimatedTokens = EstimateTokenUse(request.Message, fallbackAnswer);
        UpdateAiSessionQuota(session.Session, quota, estimatedTokens);
        sessionStore.SaveAiSession(session.Session);

        var updatedQuota = ReadQuota(session.Session, session.MessageQuota, session.TokenQuota);
        return new PassportAiChatResponse
        {
            Succeeded = true,
            Message = inferenceGateway is { IsConfigured: true }
                ? "AI chat response created by hosted open-weight model runtime."
                : "AI chat response created by hosted gateway contract fallback.",
            AnswerText = fallbackAnswer,
            QuotaSummary = Math.Max(0, updatedQuota.MessageLimit - updatedQuota.MessagesUsed) + " messages remaining; "
                + Math.Max(0, updatedQuota.TokenLimit - updatedQuota.TokensUsed) + " tokens remaining.",
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

        var now = DateTimeOffset.UtcNow;
        var recordId = NewRecordId("cc-capacity-" + NormalizeSlug(request.ServiceClass));
        var record = new Dictionary<string, object?>
        {
            ["schema_version"] = 1,
            ["record_type"] = PassportRecordTypes.CcCapacityReport,
            ["record_id"] = recordId,
            ["created_utc"] = now.ToString("yyyy-MM-ddTHH:mm:ssZ"),
            ["contract_version"] = ContractVersion,
            ["release_lane"] = NormalizeRequired(request.ReleaseLane, "release lane"),
            ["ledger_namespace"] = NormalizeRequired(request.LedgerNamespace, "ledger namespace"),
            ["policy_version"] = NormalizeRequired(request.PolicyVersion, "policy version"),
            ["service_class"] = NormalizeSlug(request.ServiceClass),
            ["reporting_period_start_utc"] = now.AddDays(-90).ToString("yyyy-MM-ddTHH:mm:ssZ"),
            ["reporting_period_end_utc"] = now.ToString("yyyy-MM-ddTHH:mm:ssZ"),
            ["conservative_service_liability_capacity_base_units"] = request.ConservativeServiceLiabilityCapacityBaseUnits,
            ["outstanding_cc_before_base_units"] = request.OutstandingCcBeforeBaseUnits,
            ["max_issuance_base_units"] = request.MaxIssuanceBaseUnits,
            ["capacity_haircut_basis_points"] = request.CapacityHaircutBasisPoints,
            ["independent_volume_qualified"] = request.IndependentVolumeQualified,
            ["thin_market_issuance_zero"] = request.ThinMarketIssuanceZero,
            ["continuity_reserve_excluded"] = request.ContinuityReserveExcluded,
            ["operational_reserve_excluded"] = request.OperationalReserveExcluded,
            ["affiliate_trade_exclusion_applied"] = true,
            ["proof_history_haircut"] = 0.0,
            ["uptime_haircut"] = 0.0,
            ["retrieval_haircut"] = 0.0,
            ["repair_haircut"] = 0.0,
            ["concentration_haircut"] = 0.0,
            ["churn_haircut"] = 0.0,
            ["audit_confidence_haircut"] = 0.0,
            ["capacity_evidence_refs"] = new[] { request.CapacityReportAuthorityRecordSha256.Trim().ToLowerInvariant() },
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

    public static string ComputeTelemetryAccessPayloadSha256(PassportTelemetryAccessRequest request)
    {
        return ComputeSha256(JsonSerializer.SerializeToUtf8Bytes(CreateTelemetryAccessPayload(request), JsonOptions));
    }

    public static PassportHostedRecordResponse CreateTelemetryAccessRecord(
        PassportTelemetryAccessRequest request,
        PassportHostedRegistryStore registryStore)
    {
        var releaseLane = NormalizeRequiredValue(request.ReleaseLane);
        var ledgerNamespace = NormalizeRequiredValue(request.LedgerNamespace);
        var policyVersion = NormalizeRequiredValue(request.PolicyVersion);
        if (string.IsNullOrWhiteSpace(releaseLane)
            || string.IsNullOrWhiteSpace(ledgerNamespace)
            || string.IsNullOrWhiteSpace(policyVersion))
        {
            return FailedRecord("Telemetry access requires release lane, ledger namespace, and policy version.");
        }

        var telemetryScope = NormalizeSlug(request.TelemetryScope);
        if (!string.Equals(telemetryScope, "hosted_append_log", StringComparison.Ordinal))
        {
            return FailedRecord("Telemetry access is currently limited to hosted append-log metadata.");
        }

        if (request.IncludePersonalData || request.IncludeRawAiPrompts || request.IncludeStoragePayloadDetails)
        {
            return FailedRecord("Telemetry access is metadata-only and cannot include personal data, raw AI prompts, or storage payload details.");
        }

        if (!TryReadUtc(request.FromUtc, out var fromUtc)
            || !TryReadUtc(request.ToUtc, out var toUtc)
            || toUtc <= fromUtc)
        {
            return FailedRecord("Telemetry access requires a valid UTC time window.");
        }

        if (toUtc - fromUtc > TimeSpan.FromDays(7))
        {
            return FailedRecord("Telemetry access windows cannot exceed seven days.");
        }

        if (request.MaxEntries is < 1 or > 500)
        {
            return FailedRecord("Telemetry access max_entries must be between 1 and 500.");
        }

        if (!string.Equals(NormalizeSlug(request.AdminAuthority.ActionType), "telemetry_access", StringComparison.Ordinal))
        {
            return FailedRecord("Telemetry access requires telemetry_access admin authority.");
        }

        if (!string.Equals(NormalizeSlug(request.AdminAuthority.AuthorityScope), NormalizeSlug(releaseLane), StringComparison.Ordinal))
        {
            return FailedRecord("Telemetry access authority scope must match the release lane.");
        }

        var payloadSha256 = ComputeTelemetryAccessPayloadSha256(request);
        if (!string.Equals(request.AdminAuthority.RequestedPayloadSha256, payloadSha256, StringComparison.OrdinalIgnoreCase))
        {
            return FailedRecord("Telemetry access authority is not bound to the requested telemetry payload.");
        }

        var authority = ValidateAdminAuthority(request.AdminAuthority, registryStore);
        if (!authority.Succeeded)
        {
            return FailedRecord("Telemetry access authority validation failed: " + authority.Message);
        }

        var recordId = NewRecordId("telemetry-access-" + telemetryScope);
        var record = new Dictionary<string, object?>
        {
            ["schema_version"] = 1,
            ["record_type"] = PassportRecordTypes.TelemetryAccessRecord,
            ["record_id"] = recordId,
            ["created_utc"] = DateTimeOffset.UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ"),
            ["contract_version"] = ContractVersion,
            ["release_lane"] = releaseLane,
            ["ledger_namespace"] = ledgerNamespace,
            ["policy_version"] = policyVersion,
            ["telemetry_scope"] = telemetryScope,
            ["from_utc"] = fromUtc.ToString("yyyy-MM-ddTHH:mm:ssZ"),
            ["to_utc"] = toUtc.ToString("yyyy-MM-ddTHH:mm:ssZ"),
            ["max_entries"] = request.MaxEntries,
            ["admin_authority_record_sha256"] = authority.RecordSha256,
            ["requested_payload_sha256"] = payloadSha256,
            ["include_personal_data"] = false,
            ["include_raw_ai_prompts"] = false,
            ["include_storage_payload_details"] = false,
            ["redaction_policy"] = "metadata_only_no_raw_prompts_no_personal_data_no_storage_payload_details",
            ["summary"] = "Hosted telemetry access authorization. The returned telemetry lane is redacted append-log metadata only."
        };

        return RecordResponse("Telemetry access authorized.", recordId, record);
    }

    public static PassportHostedRecordResponse ValidateRecoveryControl(
        PassportRecoveryControlValidationRequest request,
        PassportHostedRegistryStore registryStore)
    {
        var recordType = ReadString(request.RecoveryControlRecord, "record_type");
        if (recordType is not PassportRecordTypes.DeviceDeauthorization
            and not PassportRecordTypes.AccountSecurityFreeze
            and not PassportRecordTypes.SupportMediatedRecoveryOverride)
        {
            return FailedRecord("Recovery control validation requires a supported Passport recovery control record.");
        }

        if (ReadBoolean(request.RecoveryControlRecord, "ai_approved"))
        {
            return FailedRecord("AI cannot approve Passport recovery controls.");
        }

        var payload = DecodeBase64(request.RecoveryControlRecordPayloadBase64);
        if (payload.Length == 0)
        {
            return FailedRecord("Recovery control validation requires signed recovery_control_record_payload_base64.");
        }

        var payloadSha256 = ComputeSha256(payload);
        if (!string.IsNullOrWhiteSpace(request.RecoveryControlRecordSha256)
            && !string.Equals(payloadSha256, request.RecoveryControlRecordSha256.Trim(), StringComparison.OrdinalIgnoreCase))
        {
            return FailedRecord("Recovery control payload hash does not match.");
        }

        using var payloadDocument = JsonDocument.Parse(payload);
        var payloadMatch = RecoveryControlPayloadMatchesRequest(payloadDocument.RootElement, request.RecoveryControlRecord);
        if (!payloadMatch.Succeeded)
        {
            return payloadMatch;
        }

        if (recordType == PassportRecordTypes.DeviceDeauthorization
            && string.IsNullOrWhiteSpace(ReadString(request.RecoveryControlRecord, "target_device_id")))
        {
            return FailedRecord("Device deauthorization requires a target device.");
        }

        if (recordType == PassportRecordTypes.AccountSecurityFreeze
            && !ReadBoolean(request.RecoveryControlRecord, "freeze_wallet_operations")
            && !ReadBoolean(request.RecoveryControlRecord, "freeze_pending_escrow")
            && !ReadBoolean(request.RecoveryControlRecord, "revoke_ai_sessions")
            && !ReadBoolean(request.RecoveryControlRecord, "pause_storage_node_operations"))
        {
            return FailedRecord("Account security freeze requires at least one freeze scope.");
        }

        if (recordType == PassportRecordTypes.SupportMediatedRecoveryOverride)
        {
            if (!ReadBoolean(request.RecoveryControlRecord, "requires_dual_control"))
            {
                return FailedRecord("Support-mediated recovery override requires dual-control authority.");
            }

            if (!string.Equals(NormalizeSlug(request.AdminAuthority.ActionType), "recovery_override", StringComparison.Ordinal))
            {
                return FailedRecord("Support-mediated recovery override requires recovery_override admin authority.");
            }

            if (!string.Equals(request.AdminAuthority.RequestedPayloadSha256, ReadString(request.RecoveryControlRecord, "requested_payload_sha256"), StringComparison.OrdinalIgnoreCase))
            {
                return FailedRecord("Recovery override admin authority is not bound to the recovery payload.");
            }

            var adminAuthority = ValidateAdminAuthority(request.AdminAuthority, registryStore);
            if (!adminAuthority.Succeeded)
            {
                return FailedRecord("Recovery override admin authority validation failed: " + adminAuthority.Message);
            }

            return CreateRecoveryValidationRecord(
                "Support-mediated recovery override is valid against hosted admin authority.",
                request.RecoveryControlRecord,
                payloadSha256,
                "support_mediated_dual_control",
                adminAuthority.RecordSha256,
                string.Empty,
                string.Empty);
        }

        var signature = ValidateRecoveryDeviceSignature(
            request.RecoverySignatureRecord,
            recordType == PassportRecordTypes.DeviceDeauthorization
                ? PassportRecordTypes.DeviceDeauthorizationSignature
                : PassportRecordTypes.AccountSecurityFreezeSignature,
            recordType == PassportRecordTypes.DeviceDeauthorization
                ? "device_deauthorization_record_sha256"
                : "security_freeze_record_sha256",
            ReadString(request.RecoveryControlRecord, "authorizing_device_id"),
            payload,
            payloadSha256,
            registryStore);
        if (!signature.Succeeded)
        {
            return signature;
        }

        return CreateRecoveryValidationRecord(
            "Self-service recovery control is valid against hosted registry device signature.",
            request.RecoveryControlRecord,
            payloadSha256,
            "self_service_device_signature",
            string.Empty,
            signature.RecordId,
            signature.RecordSha256);
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

    private static PassportHostedRecordResponse CreateRecoveryValidationRecord(
        string message,
        JsonElement recoveryControlRecord,
        string recoveryControlRecordSha256,
        string validationMode,
        string adminAuthorityRecordSha256,
        string recoverySignatureRecordId,
        string recoverySignatureRecordSha256)
    {
        var recordId = NewRecordId("recovery-control-validation");
        var record = new Dictionary<string, object?>
        {
            ["schema_version"] = 1,
            ["record_type"] = PassportRecordTypes.RecoveryControlValidation,
            ["record_id"] = recordId,
            ["created_utc"] = DateTimeOffset.UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ"),
            ["contract_version"] = ContractVersion,
            ["release_lane"] = ReadString(recoveryControlRecord, "release_lane"),
            ["ledger_namespace"] = ReadString(recoveryControlRecord, "ledger_namespace"),
            ["policy_version"] = ReadString(recoveryControlRecord, "policy_version"),
            ["recovery_control_record_type"] = ReadString(recoveryControlRecord, "record_type"),
            ["recovery_control_record_id"] = ReadString(recoveryControlRecord, "record_id"),
            ["recovery_control_record_sha256"] = recoveryControlRecordSha256,
            ["validation_mode"] = validationMode,
            ["archrealms_identity_id"] = ReadString(recoveryControlRecord, "archrealms_identity_id"),
            ["target_identity_id"] = ReadString(recoveryControlRecord, "target_identity_id"),
            ["target_account_id"] = ReadString(recoveryControlRecord, "target_account_id"),
            ["authorizing_device_id"] = ReadString(recoveryControlRecord, "authorizing_device_id"),
            ["target_device_id"] = ReadString(recoveryControlRecord, "target_device_id"),
            ["authority_identity_id"] = ReadString(recoveryControlRecord, "authority_identity_id"),
            ["admin_authority_record_sha256"] = adminAuthorityRecordSha256,
            ["recovery_signature_record_id"] = recoverySignatureRecordId,
            ["recovery_signature_record_sha256"] = recoverySignatureRecordSha256,
            ["ai_approved"] = false,
            ["summary"] = "Hosted recovery control validation record. Recovery approval is cryptographic or dual-control and AI is not an approval authority."
        };

        return RecordResponse(message, recordId, record);
    }

    public static PassportHostedRecordResponse CreateBackupManifestRecord(
        PassportHostedBackupManifestRequest request,
        PassportHostedBackupManifestEntry[] entries)
    {
        var releaseLane = NormalizeRequiredValue(request.ReleaseLane);
        var ledgerNamespace = NormalizeRequiredValue(request.LedgerNamespace);
        var policyVersion = NormalizeRequiredValue(request.PolicyVersion);
        var storageProvider = NormalizeRequiredValue(request.StorageProvider);
        var backupPolicyUri = NormalizeRequiredValue(request.BackupPolicyUri);
        var restoreRunbookUri = NormalizeRequiredValue(request.RestoreRunbookUri);
        if (string.IsNullOrWhiteSpace(releaseLane)
            || string.IsNullOrWhiteSpace(ledgerNamespace)
            || string.IsNullOrWhiteSpace(policyVersion))
        {
            return FailedRecord("Backup manifest requires release lane, ledger namespace, and policy version.");
        }

        if (string.IsNullOrWhiteSpace(storageProvider)
            || string.IsNullOrWhiteSpace(backupPolicyUri)
            || string.IsNullOrWhiteSpace(restoreRunbookUri))
        {
            return FailedRecord("Backup manifest requires storage provider, backup policy URI, and restore runbook URI.");
        }

        if (entries.Length == 0)
        {
            return FailedRecord("Backup manifest requires at least one managed records or append-log file.");
        }

        var normalizedEntries = entries
            .Select(entry => new PassportHostedBackupManifestEntry
            {
                RelativePath = (entry.RelativePath ?? string.Empty).Trim().Replace('\\', '/'),
                Sha256 = (entry.Sha256 ?? string.Empty).Trim().ToLowerInvariant(),
                ByteCount = entry.ByteCount
            })
            .OrderBy(entry => entry.RelativePath, StringComparer.Ordinal)
            .ToArray();

        if (normalizedEntries.Any(entry => string.IsNullOrWhiteSpace(entry.RelativePath)
            || (!entry.RelativePath.StartsWith("records/", StringComparison.Ordinal)
                && !entry.RelativePath.StartsWith("append-log/", StringComparison.Ordinal))
            || entry.RelativePath.Contains("/keys/", StringComparison.Ordinal)
            || !LooksLikeSha256(entry.Sha256)
            || entry.ByteCount < 0))
        {
            return FailedRecord("Backup manifest entries must be managed record or append-log files with SHA-256 hashes and no key material.");
        }

        var recordId = NewRecordId("hosted-backup-manifest");
        var snapshotId = string.IsNullOrWhiteSpace(request.BackupSnapshotId)
            ? DateTimeOffset.UtcNow.ToString("yyyyMMddTHHmmssZ") + "-snapshot"
            : NormalizeRequiredValue(request.BackupSnapshotId);
        var record = new Dictionary<string, object?>
        {
            ["schema_version"] = 1,
            ["record_type"] = PassportRecordTypes.HostedStorageBackupManifest,
            ["record_id"] = recordId,
            ["created_utc"] = DateTimeOffset.UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ"),
            ["contract_version"] = ContractVersion,
            ["release_lane"] = releaseLane,
            ["ledger_namespace"] = ledgerNamespace,
            ["policy_version"] = policyVersion,
            ["storage_provider"] = storageProvider,
            ["backup_policy_uri"] = backupPolicyUri,
            ["restore_runbook_uri"] = restoreRunbookUri,
            ["backup_snapshot_id"] = snapshotId,
            ["manifest_file_count"] = normalizedEntries.Length,
            ["manifest_total_bytes"] = normalizedEntries.Sum(entry => entry.ByteCount),
            ["manifest_root_sha256"] = ComputeBackupManifestRootSha256(normalizedEntries),
            ["private_key_material_included"] = false,
            ["raw_ai_prompts_included"] = false,
            ["storage_payloads_included"] = false,
            ["entries"] = normalizedEntries.Select(entry => new Dictionary<string, object?>
            {
                ["relative_path"] = entry.RelativePath,
                ["sha256"] = entry.Sha256,
                ["byte_count"] = entry.ByteCount
            }).ToArray(),
            ["summary"] = "Hosted managed-storage backup manifest for record and append-log restore verification. Key material and raw payloads are excluded."
        };

        return RecordResponse("Hosted backup manifest created.", recordId, record);
    }

    public static PassportHostedRecordResponse CreateIncidentReportRecord(PassportHostedIncidentReportRequest request)
    {
        var releaseLane = NormalizeRequiredValue(request.ReleaseLane);
        var ledgerNamespace = NormalizeRequiredValue(request.LedgerNamespace);
        var policyVersion = NormalizeRequiredValue(request.PolicyVersion);
        if (string.IsNullOrWhiteSpace(releaseLane)
            || string.IsNullOrWhiteSpace(ledgerNamespace)
            || string.IsNullOrWhiteSpace(policyVersion))
        {
            return FailedRecord("Incident report requires release lane, ledger namespace, and policy version.");
        }

        var severity = NormalizeSlug(request.Severity);
        if (severity is not "low" and not "medium" and not "high" and not "critical")
        {
            return FailedRecord("Incident severity must be low, medium, high, or critical.");
        }

        var incidentType = NormalizeSlug(request.IncidentType);
        if (string.IsNullOrWhiteSpace(incidentType) || string.Equals(incidentType, "aggregate", StringComparison.Ordinal))
        {
            return FailedRecord("Incident report requires an incident type.");
        }

        if (string.IsNullOrWhiteSpace(request.Summary))
        {
            return FailedRecord("Incident report requires a summary.");
        }

        if (!TryReadUtc(request.DetectedUtc, out var detectedUtc))
        {
            return FailedRecord("Incident report requires detected_utc.");
        }

        if (string.IsNullOrWhiteSpace(request.IncidentResponseRunbookUri)
            || string.IsNullOrWhiteSpace(request.IncidentResponseOwner)
            || string.IsNullOrWhiteSpace(request.TelemetryRetentionPolicyUri))
        {
            return FailedRecord("Incident report requires runbook, owner, and telemetry retention policy references.");
        }

        if (request.ContainsPersonalData || request.ContainsRawAiPrompts || request.ContainsStoragePayloadDetails)
        {
            return FailedRecord("Hosted incident reports are metadata-only and cannot include personal data, raw AI prompts, or storage payload details.");
        }

        var relatedHashes = request.RelatedRecordSha256
            .Select(hash => (hash ?? string.Empty).Trim().ToLowerInvariant())
            .Where(hash => !string.IsNullOrWhiteSpace(hash))
            .Distinct(StringComparer.Ordinal)
            .ToArray();
        if (relatedHashes.Any(hash => !LooksLikeSha256(hash)))
        {
            return FailedRecord("Incident related record hashes must be SHA-256 values.");
        }

        var recordId = string.IsNullOrWhiteSpace(request.IncidentId)
            ? NewRecordId("hosted-incident-" + severity)
            : NormalizeRequiredValue(request.IncidentId);
        var record = new Dictionary<string, object?>
        {
            ["schema_version"] = 1,
            ["record_type"] = PassportRecordTypes.HostedIncidentReport,
            ["record_id"] = recordId,
            ["created_utc"] = DateTimeOffset.UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ"),
            ["contract_version"] = ContractVersion,
            ["release_lane"] = releaseLane,
            ["ledger_namespace"] = ledgerNamespace,
            ["policy_version"] = policyVersion,
            ["severity"] = severity,
            ["incident_type"] = incidentType,
            ["detected_utc"] = detectedUtc.ToString("yyyy-MM-ddTHH:mm:ssZ"),
            ["incident_response_runbook_uri"] = request.IncidentResponseRunbookUri.Trim(),
            ["incident_response_owner"] = request.IncidentResponseOwner.Trim(),
            ["telemetry_retention_policy_uri"] = request.TelemetryRetentionPolicyUri.Trim(),
            ["related_record_sha256"] = relatedHashes,
            ["contains_personal_data"] = false,
            ["contains_raw_ai_prompts"] = false,
            ["contains_storage_payload_details"] = false,
            ["redaction_policy"] = "metadata_only_no_personal_data_no_raw_ai_prompts_no_storage_payload_details",
            ["summary"] = request.Summary.Trim()
        };

        return RecordResponse("Hosted incident report created.", recordId, record);
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

    private static PassportAiSessionAuthorizationResponse ValidateAiChallengeObject(JsonElement record)
    {
        if (!record.TryGetProperty("challenge", out var challenge) || challenge.ValueKind != JsonValueKind.Object)
        {
            return FailedAiSession("AI session request must include a Passport AI challenge.");
        }

        if (string.IsNullOrWhiteSpace(ReadString(challenge, "challenge_nonce")))
        {
            return FailedAiSession("AI session challenge nonce is required.");
        }

        var audience = ReadString(challenge, "audience");
        if (string.IsNullOrWhiteSpace(audience))
        {
            audience = ReadString(challenge, "challenge_audience");
        }

        if (!string.Equals(audience, PassportAiProtocolDefaults.GatewayAudience, StringComparison.Ordinal))
        {
            return FailedAiSession("AI session challenge audience is invalid.");
        }

        var challengeExpiry = ReadString(challenge, "expires_utc");
        if (string.IsNullOrWhiteSpace(challengeExpiry))
        {
            challengeExpiry = ReadString(challenge, "challenge_expires_utc");
        }

        if (!string.IsNullOrWhiteSpace(challengeExpiry)
            && (!DateTimeOffset.TryParse(challengeExpiry, out var expiresUtc) || expiresUtc.ToUniversalTime() <= DateTimeOffset.UtcNow))
        {
            return FailedAiSession("AI session challenge is expired.");
        }

        if (!StringArrayContains(challenge, "requested_scopes", "ai_guide"))
        {
            return FailedAiSession("AI session challenge must request the ai_guide scope.");
        }

        return new PassportAiSessionAuthorizationResponse
        {
            Succeeded = true,
            Message = "AI session challenge is valid."
        };
    }

    private static AiSessionAccessResult ValidateAiSessionAccess(
        string sessionId,
        string bearerToken,
        IPassportHostedSessionStore sessionStore)
    {
        if (string.IsNullOrWhiteSpace(bearerToken))
        {
            return AiSessionAccessResult.Failed("AI session bearer token is required.");
        }

        if (string.IsNullOrWhiteSpace(sessionId)
            || !sessionStore.TryGetAiSession(sessionId, out var session)
            || session.Session == null)
        {
            return AiSessionAccessResult.Failed("AI session was not found.");
        }

        if (!string.Equals(ComputeSha256(Encoding.UTF8.GetBytes(bearerToken)), session.SessionTokenSha256, StringComparison.OrdinalIgnoreCase))
        {
            return AiSessionAccessResult.Failed("AI session token does not match.");
        }

        if (!DateTimeOffset.TryParse(session.ExpiresUtc, out var expiresUtc) || expiresUtc.ToUniversalTime() <= DateTimeOffset.UtcNow)
        {
            return AiSessionAccessResult.Failed("AI session is expired.");
        }

        return AiSessionAccessResult.Success(session);
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

    private static PassportHostedRecordResponse RecoveryControlPayloadMatchesRequest(JsonElement payload, JsonElement requestRecord)
    {
        var criticalFields = new[]
        {
            "record_type",
            "record_id",
            "release_lane",
            "ledger_namespace",
            "policy_version"
        };

        foreach (var field in criticalFields)
        {
            if (!string.Equals(ReadString(payload, field), ReadString(requestRecord, field), StringComparison.Ordinal))
            {
                return FailedRecord("Recovery control signed payload does not match request field: " + field + ".");
            }
        }

        return new PassportHostedRecordResponse
        {
            Succeeded = true,
            Message = "Recovery control signed payload matches request record."
        };
    }

    private static PassportHostedRecordResponse ValidateRecoveryDeviceSignature(
        JsonElement signatureRecord,
        string expectedRecordType,
        string hashPropertyName,
        string expectedAuthorizingDeviceId,
        byte[] recoveryPayload,
        string recoveryPayloadSha256,
        PassportHostedRegistryStore registryStore)
    {
        if (!Matches(signatureRecord, "record_type", expectedRecordType))
        {
            return FailedRecord("Recovery control signature record type is invalid.");
        }

        if (!Matches(signatureRecord, "authorizing_device_id", expectedAuthorizingDeviceId))
        {
            return FailedRecord("Recovery control signature was made by an unexpected device.");
        }

        if (!string.Equals(ReadString(signatureRecord, hashPropertyName), recoveryPayloadSha256, StringComparison.OrdinalIgnoreCase))
        {
            return FailedRecord("Recovery control signature does not reference the signed payload.");
        }

        if (!registryStore.TryGetPublicKey(expectedAuthorizingDeviceId, out var publicKey))
        {
            return FailedRecord("Recovery control signer public key could not be found.");
        }

        var signatureBytes = DecodeBase64(ReadString(signatureRecord, "signature_base64"));
        if (signatureBytes.Length == 0)
        {
            return FailedRecord("Recovery control signature is missing.");
        }

        using var rsa = RSA.Create();
        rsa.ImportSubjectPublicKeyInfo(publicKey, out _);
        if (!rsa.VerifyData(recoveryPayload, signatureBytes, HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1))
        {
            return FailedRecord("Recovery control signature verification failed.");
        }

        return new PassportHostedRecordResponse
        {
            Succeeded = true,
            Message = "Recovery control signature verified.",
            RecordId = ReadString(signatureRecord, "record_id"),
            RecordSha256 = ComputeJsonSha256(signatureRecord)
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

        return criticalFields.All(field => string.Equals(ReadString(payload, field), ReadString(requestRecord, field), StringComparison.Ordinal))
            && JsonPropertyMatches(payload, requestRecord, "challenge");
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

    private static Dictionary<string, object?> CreateTelemetryAccessPayload(PassportTelemetryAccessRequest request)
    {
        return new Dictionary<string, object?>
        {
            ["schema_version"] = 1,
            ["record_type"] = PassportRecordTypes.TelemetryAccessRequest,
            ["release_lane"] = NormalizeRequiredValue(request.ReleaseLane),
            ["ledger_namespace"] = NormalizeRequiredValue(request.LedgerNamespace),
            ["policy_version"] = NormalizeRequiredValue(request.PolicyVersion),
            ["telemetry_scope"] = NormalizeSlug(request.TelemetryScope),
            ["from_utc"] = (request.FromUtc ?? string.Empty).Trim(),
            ["to_utc"] = (request.ToUtc ?? string.Empty).Trim(),
            ["max_entries"] = request.MaxEntries,
            ["include_personal_data"] = request.IncludePersonalData,
            ["include_raw_ai_prompts"] = request.IncludeRawAiPrompts,
            ["include_storage_payload_details"] = request.IncludeStoragePayloadDetails
        };
    }

    private static string ComputeBackupManifestRootSha256(PassportHostedBackupManifestEntry[] entries)
    {
        var payload = entries
            .OrderBy(entry => entry.RelativePath, StringComparer.Ordinal)
            .Select(entry => entry.RelativePath + "|" + entry.Sha256 + "|" + entry.ByteCount);
        return ComputeSha256(Encoding.UTF8.GetBytes(string.Join("\n", payload)));
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

    private static string ReadString(Dictionary<string, object?> record, string propertyName)
    {
        if (!record.TryGetValue(propertyName, out var value) || value == null)
        {
            return string.Empty;
        }

        if (value is JsonElement element)
        {
            return element.ValueKind == JsonValueKind.String ? element.GetString() ?? string.Empty : element.ToString();
        }

        return value.ToString() ?? string.Empty;
    }

    private static (int MessageLimit, int MessagesUsed, int TokenLimit, int TokensUsed) ReadQuota(
        Dictionary<string, object?> sessionRecord,
        int fallbackMessageLimit,
        int fallbackTokenLimit)
    {
        var messageLimit = fallbackMessageLimit;
        var tokenLimit = fallbackTokenLimit;
        var messagesUsed = 0;
        var tokensUsed = 0;

        if (sessionRecord.TryGetValue("quota", out var quotaValue))
        {
            if (quotaValue is JsonElement quotaElement && quotaElement.ValueKind == JsonValueKind.Object)
            {
                messageLimit = ReadInt32(quotaElement, "message_limit", fallbackMessageLimit);
                tokenLimit = ReadInt32(quotaElement, "token_limit", fallbackTokenLimit);
                messagesUsed = ReadInt32(quotaElement, "messages_used", 0);
                tokensUsed = ReadInt32(quotaElement, "tokens_used", 0);
            }
            else if (quotaValue is Dictionary<string, object?> quota)
            {
                messageLimit = ReadInt32(quota, "message_limit", fallbackMessageLimit);
                tokenLimit = ReadInt32(quota, "token_limit", fallbackTokenLimit);
                messagesUsed = ReadInt32(quota, "messages_used", 0);
                tokensUsed = ReadInt32(quota, "tokens_used", 0);
            }
        }

        return (Math.Max(0, messageLimit), Math.Max(0, messagesUsed), Math.Max(0, tokenLimit), Math.Max(0, tokensUsed));
    }

    private static void UpdateAiSessionQuota(
        Dictionary<string, object?> sessionRecord,
        (int MessageLimit, int MessagesUsed, int TokenLimit, int TokensUsed) quota,
        int estimatedTokens)
    {
        sessionRecord["quota"] = new Dictionary<string, object?>
        {
            ["message_limit"] = quota.MessageLimit,
            ["token_limit"] = quota.TokenLimit,
            ["messages_used"] = Math.Min(quota.MessageLimit, quota.MessagesUsed + 1),
            ["tokens_used"] = Math.Min(quota.TokenLimit, quota.TokensUsed + Math.Max(1, estimatedTokens))
        };
    }

    private static int EstimateTokenUse(string prompt, string answer)
    {
        var characterCount = (prompt?.Length ?? 0) + (answer?.Length ?? 0);
        return Math.Max(1, (int)Math.Ceiling(characterCount / 4.0));
    }

    private static int ReadInt32(JsonElement root, string propertyName, int fallback)
    {
        return root.TryGetProperty(propertyName, out var property) && property.TryGetInt32(out var value) ? value : fallback;
    }

    private static int ReadInt32(Dictionary<string, object?> record, string propertyName, int fallback)
    {
        if (!record.TryGetValue(propertyName, out var value) || value == null)
        {
            return fallback;
        }

        if (value is JsonElement element)
        {
            return element.TryGetInt32(out var parsed) ? parsed : fallback;
        }

        try
        {
            return Convert.ToInt32(value);
        }
        catch
        {
            return fallback;
        }
    }

    private static bool StringArrayContains(JsonElement root, string propertyName, string expected)
    {
        if (!root.TryGetProperty(propertyName, out var property) || property.ValueKind != JsonValueKind.Array)
        {
            return false;
        }

        return property.EnumerateArray()
            .Any(item => item.ValueKind == JsonValueKind.String
                && string.Equals(item.GetString(), expected, StringComparison.Ordinal));
    }

    private static bool JsonPropertyMatches(JsonElement payload, JsonElement requestRecord, string propertyName)
    {
        var payloadHasProperty = payload.TryGetProperty(propertyName, out var payloadProperty);
        var requestHasProperty = requestRecord.TryGetProperty(propertyName, out var requestProperty);
        if (!payloadHasProperty || !requestHasProperty)
        {
            return payloadHasProperty == requestHasProperty;
        }

        return JsonSerializer.Serialize(payloadProperty, JsonOptions) == JsonSerializer.Serialize(requestProperty, JsonOptions);
    }

    private static string NormalizeRequired(string value, string label)
    {
        var normalized = NormalizeRequiredValue(value);
        if (string.IsNullOrWhiteSpace(normalized))
        {
            throw new InvalidOperationException("A " + label + " is required.");
        }

        return normalized;
    }

    private static string NormalizeRequiredValue(string value)
    {
        return (value ?? string.Empty).Trim();
    }

    private static string NormalizeSlug(string value)
    {
        var normalized = (value ?? string.Empty).Trim().ToLowerInvariant().Replace(" ", "_").Replace("-", "_");
        return string.IsNullOrWhiteSpace(normalized) ? "aggregate" : normalized;
    }

    private static string[] NormalizeScopes(IEnumerable<string> requestedScopes)
    {
        var scopes = requestedScopes
            .Select(scope => (scope ?? string.Empty).Trim())
            .Where(scope => !string.IsNullOrWhiteSpace(scope))
            .Distinct(StringComparer.Ordinal)
            .ToArray();
        return scopes.Length == 0 ? new[] { "ai_guide" } : scopes;
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

    public static bool TryReadUtc(string value, out DateTimeOffset utc)
    {
        if (DateTimeOffset.TryParse(value, out var parsed))
        {
            utc = parsed.ToUniversalTime();
            return true;
        }

        utc = default;
        return false;
    }

    private static PassportAiSessionAuthorizationResponse FailedAiSession(string message)
    {
        return new PassportAiSessionAuthorizationResponse { Succeeded = false, Message = message };
    }

    private static PassportAiChallengeResponse FailedAiChallenge(string message)
    {
        return new PassportAiChallengeResponse { Succeeded = false, Message = message };
    }

    private static PassportAiChatResponse FailedChat(string message)
    {
        return new PassportAiChatResponse { Succeeded = false, Message = message, AnswerText = message };
    }

    private static PassportAiQuotaResponse FailedQuota(string message)
    {
        return new PassportAiQuotaResponse { Succeeded = false, Message = message };
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

    private sealed record AiSessionAccessResult(bool Succeeded, string Message, PassportAiSessionAuthorizationResponse? Session)
    {
        public static AiSessionAccessResult Success(PassportAiSessionAuthorizationResponse session)
        {
            return new AiSessionAccessResult(true, "AI session authorized.", session);
        }

        public static AiSessionAccessResult Failed(string message)
        {
            return new AiSessionAccessResult(false, message, null);
        }
    }
}
