using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using ArchrealmsPassport.Core.Protocol;
using ArchrealmsPassport.HostedServices;
using ArchrealmsPassport.HostedServices.Contracts;
using Xunit;

namespace ArchrealmsPassport.HostedServices.Tests;

public sealed class PassportHostedPolicyTests
{
    private static readonly JsonSerializerOptions JsonOptions = new() { WriteIndented = true };

    [Fact]
    public void AiChallengeCreatesSignableChallengeAndSessionRequiresChallenge()
    {
        var challenge = PassportHostedPolicy.CreateAiChallenge(new PassportAiChallengeRequest
        {
            IdentityId = "identity-1",
            DeviceId = "device-1",
            ReleaseLane = "production-mvp",
            LedgerNamespace = "archrealms-passport-production-mvp",
            PolicyVersion = "passport-release-lanes-v1",
            ClientBuild = "test-build",
            RequestedScopes = ["ai_guide"]
        });

        Assert.True(challenge.Succeeded, challenge.Message);
        Assert.Equal("archrealms-ai-gateway", challenge.ChallengeAudience);
        Assert.NotNull(challenge.ChallengeRecord);
        Assert.Equal("passport_ai_challenge", challenge.ChallengeRecord!["record_type"]);
        Assert.Matches("^[0-9a-f]{64}$", challenge.ChallengeRecordSha256);

        using var rsa = RSA.Create(2048);
        var missingChallenge = CreateAiSessionRequest(rsa, includeChallenge: false);
        var rejected = PassportHostedPolicy.AuthorizeAiSession(missingChallenge);

        Assert.False(rejected.Succeeded);
        Assert.Contains("challenge", rejected.Message, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public void AuthorizeAiSessionVerifiesDeviceSignatureAndDoesNotStoreBearerToken()
    {
        using var rsa = RSA.Create(2048);
        var request = CreateAiSessionRequest(rsa);

        var result = PassportHostedPolicy.AuthorizeAiSession(request);

        Assert.True(result.Succeeded, result.Message);
        Assert.False(string.IsNullOrWhiteSpace(result.SessionToken));
        Assert.False(JsonSerializer.Serialize(result.Session, JsonOptions).Contains(result.SessionToken, StringComparison.Ordinal));
        Assert.Equal(25, result.MessageQuota);
        Assert.NotNull(result.Session);
        Assert.False((bool)ReadNested(result.Session!, "authority_boundaries", "can_execute_wallet_operations"));
    }

    [Fact]
    public void AuthorizeAiSessionRejectsTamperedSignature()
    {
        using var rsa = RSA.Create(2048);
        var request = CreateAiSessionRequest(rsa) with
        {
            SignedPayloadBase64 = Convert.ToBase64String(Encoding.UTF8.GetBytes("{\"tampered\":true}"))
        };

        var result = PassportHostedPolicy.AuthorizeAiSession(request);

        Assert.False(result.Succeeded);
        Assert.Contains("signature", result.Message, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public void AuthorizeAiSessionRejectsRequestRecordThatDoesNotMatchSignedPayload()
    {
        using var rsa = RSA.Create(2048);
        var request = CreateAiSessionRequest(rsa);
        var tampered = JsonSerializer.Deserialize<Dictionary<string, object?>>(request.RequestRecord.GetRawText(), JsonOptions)!;
        tampered["gateway_url"] = "https://attacker.example";
        var tamperedRecord = JsonDocument.Parse(JsonSerializer.Serialize(tampered, JsonOptions)).RootElement.Clone();

        var result = PassportHostedPolicy.AuthorizeAiSession(request with
        {
            RequestRecord = tamperedRecord,
            RequestRecordSha256 = ComputeJsonSha256(tamperedRecord)
        });

        Assert.False(result.Succeeded);
        Assert.Contains("signature", result.Message, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public void ChatRequiresMatchingSessionTokenAndRejectsSecrets()
    {
        using var rsa = RSA.Create(2048);
        var session = PassportHostedPolicy.AuthorizeAiSession(CreateAiSessionRequest(rsa));
        Assert.True(session.Succeeded, session.Message);

        var store = new PassportHostedInMemoryStore();
        store.SaveAiSession(session.Session!);

        var badToken = PassportHostedPolicy.CreateAiChatResponse(
            new PassportAiChatRequest { SessionId = session.SessionId, Message = "hello" },
            "wrong-token",
            store);
        Assert.False(badToken.Succeeded);

        var secret = PassportHostedPolicy.CreateAiChatResponse(
            new PassportAiChatRequest { SessionId = session.SessionId, Message = "wallet private key: abc123" },
            session.SessionToken,
            store);
        Assert.False(secret.Succeeded);
        Assert.Contains("private key", secret.Message, StringComparison.OrdinalIgnoreCase);

        var answer = PassportHostedPolicy.CreateAiChatResponse(
            new PassportAiChatRequest
            {
                SessionId = session.SessionId,
                Message = "What can the AI do?",
                ClientApprovedContextRefs =
                [
                    new PassportAiSourceRef
                    {
                        SourceId = "mvp-guide",
                        Title = "MVP Guide",
                        SourcePath = "knowledge-packs/passport-mvp-guide.md",
                        SourceSha256 = new string('a', 64),
                        ChunkSha256 = new string('b', 64)
                    }
                ]
            },
            session.SessionToken,
            store);
        Assert.True(answer.Succeeded, answer.Message);
        Assert.Contains("cannot approve recovery", answer.AnswerText, StringComparison.OrdinalIgnoreCase);
        Assert.Single(answer.Sources);
    }

    [Fact]
    public void AiQuotaAndFeedbackRequireSessionTokenAndRemainNonAuthoritative()
    {
        using var rsa = RSA.Create(2048);
        var session = PassportHostedPolicy.AuthorizeAiSession(CreateAiSessionRequest(rsa));
        Assert.True(session.Succeeded, session.Message);

        var store = new PassportHostedInMemoryStore();
        store.SaveAiSession(session.Session!);

        var badQuota = PassportHostedPolicy.CreateAiQuotaResponse(session.SessionId, "wrong-token", store);
        Assert.False(badQuota.Succeeded);

        var quota = PassportHostedPolicy.CreateAiQuotaResponse(session.SessionId, session.SessionToken, store);
        Assert.True(quota.Succeeded, quota.Message);
        Assert.Equal(25, quota.MessageLimit);
        Assert.Equal(25, quota.MessagesRemaining);
        Assert.Equal(10000, quota.TokenLimit);

        var feedback = PassportHostedPolicy.CreateAiFeedbackRecord(new PassportAiFeedbackRequest
        {
            SessionId = session.SessionId,
            ChatRecordId = "chat-1",
            Rating = 5,
            FeedbackCategory = "helpful",
            FeedbackText = "Helpful answer.",
            DiagnosticsUploadOptIn = false
        }, session.SessionToken, store);

        Assert.True(feedback.Succeeded, feedback.Message);
        Assert.Equal("passport_ai_feedback_record", feedback.Record!["record_type"]);
        Assert.Equal(false, feedback.Record["feedback_text_stored"]);
        Assert.Equal(false, feedback.Record["changes_ledger_state"]);
        Assert.DoesNotContain("Helpful answer.", JsonSerializer.Serialize(feedback.Record, JsonOptions), StringComparison.Ordinal);

        var secretFeedback = PassportHostedPolicy.CreateAiFeedbackRecord(new PassportAiFeedbackRequest
        {
            SessionId = session.SessionId,
            Rating = 1,
            FeedbackText = "recovery seed phrase: secret"
        }, session.SessionToken, store);
        Assert.False(secretFeedback.Succeeded);
        Assert.Contains("recovery-secret", secretFeedback.Message, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public void AiGatewayStatusReportsRuntimeReadinessWithoutAuthority()
    {
        var status = PassportHostedPolicy.CreateAiGatewayStatus(PassportHostedAiRuntimeReadiness.FromValues(
            "https://model-runtime.example/v1",
            "Qwen/Qwen3-8B",
            new string('a', 64),
            "license-approval-1",
            "managed-vector-store",
            "archrealms-passport-mvp",
            "knowledge-root-2026-05-15"));

        Assert.Equal("healthy", status.Status);
        Assert.True(status.RuntimeReady);
        Assert.Equal("/ai/challenge", status.ChallengeEndpoint);
        Assert.False((bool)status.AuthorityBoundaries["can_execute_wallet_operations"]!);
    }

    [Fact]
    public void CapacityReportRequiresConservativeIssuanceGates()
    {
        var accepted = PassportHostedPolicy.CreateCcCapacityReport(new PassportCcCapacityReportRequest
        {
            ReleaseLane = "production-mvp",
            LedgerNamespace = "archrealms-passport-production-mvp",
            PolicyVersion = "passport-release-lanes-v1",
            ServiceClass = "storage_standard",
            ConservativeServiceLiabilityCapacityBaseUnits = 1000,
            OutstandingCcBeforeBaseUnits = 100,
            MaxIssuanceBaseUnits = 250,
            CapacityHaircutBasisPoints = 6500,
            IndependentVolumeQualified = true,
            ThinMarketIssuanceZero = false,
            ContinuityReserveExcluded = true,
            OperationalReserveExcluded = true,
            CapacityReportAuthorityRecordSha256 = new string('c', 64)
        });
        Assert.True(accepted.Succeeded, accepted.Message);
        Assert.Equal("passport_cc_capacity_report", accepted.Record!["record_type"]);
        var inspection = PassportRegistryRecordInspector.Inspect(JsonSerializer.SerializeToUtf8Bytes(accepted.Record, JsonOptions));
        Assert.True(inspection.IsEnvelopeValid, string.Join("; ", inspection.ValidationFailures));

        var rejected = PassportHostedPolicy.CreateCcCapacityReport(new PassportCcCapacityReportRequest
        {
            ReleaseLane = "production-mvp",
            LedgerNamespace = "archrealms-passport-production-mvp",
            PolicyVersion = "passport-release-lanes-v1",
            ServiceClass = "storage_standard",
            ConservativeServiceLiabilityCapacityBaseUnits = 1000,
            MaxIssuanceBaseUnits = 250,
            CapacityHaircutBasisPoints = 6500,
            IndependentVolumeQualified = true,
            ThinMarketIssuanceZero = true,
            ContinuityReserveExcluded = true,
            OperationalReserveExcluded = true,
            CapacityReportAuthorityRecordSha256 = new string('c', 64)
        });
        Assert.False(rejected.Succeeded);
        Assert.Contains("Thin-market", rejected.Message, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public void ArchGenesisManifestRejectsPostGenesisSupplyGaps()
    {
        var result = PassportHostedPolicy.CreateArchGenesisManifest(new PassportArchGenesisManifestRequest
        {
            ReleaseLane = "production-mvp",
            LedgerNamespace = "archrealms-passport-production-mvp",
            PolicyVersion = "passport-release-lanes-v1",
            TotalSupplyBaseUnits = 1000,
            BaseUnitPrecision = 18,
            GenesisAuthorityRecordSha256 = new string('d', 64),
            Allocations =
            [
                new PassportArchGenesisAllocationRequest
                {
                    AllocationId = "allocation-1",
                    AccountId = "account-1",
                    IdentityId = "identity-1",
                    WalletKeyId = "wallet-1",
                    AmountBaseUnits = 1000
                }
            ]
        });
        Assert.True(result.Succeeded, result.Message);
        Assert.Equal(false, result.Record!["post_genesis_minting_allowed"]);

        var rejected = PassportHostedPolicy.CreateArchGenesisManifest(new PassportArchGenesisManifestRequest
        {
            ReleaseLane = "production-mvp",
            LedgerNamespace = "archrealms-passport-production-mvp",
            PolicyVersion = "passport-release-lanes-v1",
            TotalSupplyBaseUnits = 1000,
            BaseUnitPrecision = 18,
            GenesisAuthorityRecordSha256 = new string('d', 64),
            Allocations =
            [
                new PassportArchGenesisAllocationRequest
                {
                    AllocationId = "allocation-1",
                    AccountId = "account-1",
                    IdentityId = "identity-1",
                    WalletKeyId = "wallet-1",
                    AmountBaseUnits = 999
                }
            ]
        });
        Assert.False(rejected.Succeeded);
        Assert.Contains("allocation total", rejected.Message, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public void AdminAuthorityAndStorageDeliveryHaveStructuralGates()
    {
        var targetHash = new string('e', 64);
        var payloadHash = new string('f', 64);
        var authority = JsonDocument.Parse(JsonSerializer.Serialize(new Dictionary<string, object?>
        {
            ["record_type"] = "passport_admin_dual_control_action",
            ["record_id"] = "authority-1",
            ["action_type"] = "cc_issuance",
            ["authority_scope"] = "production-mvp",
            ["target_record_sha256"] = targetHash,
            ["requested_payload_sha256"] = payloadHash,
            ["requester_device_id"] = "device-1",
            ["approver_device_id"] = "device-2",
            ["ai_approved"] = false
        })).RootElement.Clone();
        var requester = JsonDocument.Parse("{\"record_type\":\"passport_admin_dual_control_requester_signature\"}").RootElement.Clone();
        var approver = JsonDocument.Parse("{\"record_type\":\"passport_admin_dual_control_approver_signature\"}").RootElement.Clone();

        var authorityResult = PassportHostedPolicy.ValidateAdminAuthority(new PassportAdminAuthorityValidationRequest
        {
            ActionType = "cc_issuance",
            AuthorityScope = "production-mvp",
            TargetRecordSha256 = targetHash,
            RequestedPayloadSha256 = payloadHash,
            AdminAuthorityRecord = authority,
            RequesterSignatureRecord = requester,
            ApproverSignatureRecord = approver
        });
        Assert.True(authorityResult.Succeeded, authorityResult.Message);

        var deliveryRecord = JsonDocument.Parse(JsonSerializer.Serialize(new Dictionary<string, object?>
        {
            ["record_type"] = "passport_storage_service_delivery_request",
            ["record_id"] = "delivery-1",
            ["release_lane"] = "production-mvp",
            ["ledger_namespace"] = "archrealms-passport-production-mvp",
            ["redemption_id"] = "redemption-1",
            ["storage_gb"] = 1,
            ["service_epoch_count"] = 1
        }, JsonOptions)).RootElement.Clone();
        var deliveryHash = ComputeJsonSha256(deliveryRecord);
        var deliveryResult = PassportHostedPolicy.AcceptStorageDeliveryRequest(new PassportStorageDeliveryRequest
        {
            ServiceDeliveryRequestRecord = deliveryRecord,
            ServiceDeliveryRequestSha256 = deliveryHash
        });
        Assert.True(deliveryResult.Succeeded, deliveryResult.Message);
        Assert.Equal("passport_storage_delivery_acceptance", deliveryResult.Record!["record_type"]);
    }

    [Fact]
    public void AdminAuthorityValidatesAgainstHostedRegistryRolesAndSignatures()
    {
        using var workspace = TemporaryDirectory.Create();
        using var issuer = RSA.Create(2048);
        using var requester = RSA.Create(2048);
        using var approver = RSA.Create(2048);
        var registry = new PassportHostedRegistryStore(workspace.Path);
        registry.SavePublicKey("issuer-device", issuer.ExportSubjectPublicKeyInfo());
        registry.SavePublicKey("requester-device", requester.ExportSubjectPublicKeyInfo());
        registry.SavePublicKey("approver-device", approver.ExportSubjectPublicKeyInfo());
        AddRole(registry, issuer, "role-requester", "authority-identity", "requester-device", "cc_issuance", "production_mvp");
        AddRole(registry, issuer, "role-approver", "authority-identity", "approver-device", "cc_issuance", "production_mvp");

        var request = CreateSignedAdminRequest(
            requester,
            approver,
            "authority-identity",
            "requester-device",
            "approver-device",
            "cc_issuance",
            "production_mvp");

        var result = PassportHostedPolicy.ValidateAdminAuthority(request, registry);

        Assert.True(result.Succeeded, result.Message);
        Assert.Contains("hosted registry", result.Message, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public void AdminAuthorityRejectsHostedRegistryRoleOrSignatureGaps()
    {
        using var workspace = TemporaryDirectory.Create();
        using var issuer = RSA.Create(2048);
        using var requester = RSA.Create(2048);
        using var approver = RSA.Create(2048);
        var registry = new PassportHostedRegistryStore(workspace.Path);
        registry.SavePublicKey("issuer-device", issuer.ExportSubjectPublicKeyInfo());
        registry.SavePublicKey("requester-device", requester.ExportSubjectPublicKeyInfo());
        registry.SavePublicKey("approver-device", approver.ExportSubjectPublicKeyInfo());
        AddRole(registry, issuer, "role-requester", "authority-identity", "requester-device", "cc_issuance", "production_mvp");
        var request = CreateSignedAdminRequest(
            requester,
            approver,
            "authority-identity",
            "requester-device",
            "approver-device",
            "cc_issuance",
            "production_mvp");

        var missingRole = PassportHostedPolicy.ValidateAdminAuthority(request, registry);
        Assert.False(missingRole.Succeeded);
        Assert.Contains("Approver", missingRole.Message, StringComparison.OrdinalIgnoreCase);

        AddRole(registry, issuer, "role-approver", "authority-identity", "approver-device", "cc_issuance", "production_mvp");
        var tamperedSignature = request with
        {
            ApproverSignatureRecord = JsonDocument.Parse(request.ApproverSignatureRecord.GetRawText().Replace("approver-device", "requester-device")).RootElement.Clone()
        };
        var badSignature = PassportHostedPolicy.ValidateAdminAuthority(tamperedSignature, registry);
        Assert.False(badSignature.Succeeded);
        Assert.Contains("unexpected device", badSignature.Message, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public void TelemetryAccessRequiresBoundedAdminAuthorityAndMetadataOnlyPolicy()
    {
        using var workspace = TemporaryDirectory.Create();
        using var issuer = RSA.Create(2048);
        using var requester = RSA.Create(2048);
        using var approver = RSA.Create(2048);
        var registry = new PassportHostedRegistryStore(workspace.Path);
        registry.SavePublicKey("issuer-device", issuer.ExportSubjectPublicKeyInfo());
        registry.SavePublicKey("requester-device", requester.ExportSubjectPublicKeyInfo());
        registry.SavePublicKey("approver-device", approver.ExportSubjectPublicKeyInfo());
        AddRole(registry, issuer, "role-requester", "authority-identity", "requester-device", "telemetry_access", "production_mvp");
        AddRole(registry, issuer, "role-approver", "authority-identity", "approver-device", "telemetry_access", "production_mvp");

        var baseRequest = new PassportTelemetryAccessRequest
        {
            ReleaseLane = "production-mvp",
            LedgerNamespace = "archrealms-passport-production-mvp",
            PolicyVersion = "passport-release-lanes-v1",
            TelemetryScope = "hosted_append_log",
            FromUtc = DateTimeOffset.UtcNow.AddHours(-1).ToString("yyyy-MM-ddTHH:mm:ssZ"),
            ToUtc = DateTimeOffset.UtcNow.AddMinutes(1).ToString("yyyy-MM-ddTHH:mm:ssZ"),
            MaxEntries = 50
        };
        var payloadHash = PassportHostedPolicy.ComputeTelemetryAccessPayloadSha256(baseRequest);
        var request = baseRequest with
        {
            AdminAuthority = CreateSignedAdminRequest(
                requester,
                approver,
                "authority-identity",
                "requester-device",
                "approver-device",
                "telemetry_access",
                "production_mvp",
                payloadHash: payloadHash)
        };

        var result = PassportHostedPolicy.CreateTelemetryAccessRecord(request, registry);

        Assert.True(result.Succeeded, result.Message);
        Assert.Equal("passport_telemetry_access_record", result.Record!["record_type"]);
        Assert.Equal("metadata_only_no_raw_prompts_no_personal_data_no_storage_payload_details", result.Record["redaction_policy"]);

        var rawPromptRequest = request with { IncludeRawAiPrompts = true };
        var rejectedRawPromptAccess = PassportHostedPolicy.CreateTelemetryAccessRecord(rawPromptRequest, registry);
        Assert.False(rejectedRawPromptAccess.Succeeded);
        Assert.Contains("metadata-only", rejectedRawPromptAccess.Message, StringComparison.OrdinalIgnoreCase);

        var unboundAuthority = request with
        {
            AdminAuthority = CreateSignedAdminRequest(
                requester,
                approver,
                "authority-identity",
                "requester-device",
                "approver-device",
                "telemetry_access",
                "production_mvp",
                payloadHash: new string('a', 64))
        };
        var rejectedUnbound = PassportHostedPolicy.CreateTelemetryAccessRecord(unboundAuthority, registry);
        Assert.False(rejectedUnbound.Succeeded);
        Assert.Contains("not bound", rejectedUnbound.Message, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public void BackupManifestRequiresManagedRecordEntriesAndRestorePolicy()
    {
        var result = PassportHostedPolicy.CreateBackupManifestRecord(new PassportHostedBackupManifestRequest
        {
            ReleaseLane = "production-mvp",
            LedgerNamespace = "archrealms-passport-production-mvp",
            PolicyVersion = "passport-release-lanes-v1",
            StorageProvider = "managed-object-storage",
            BackupPolicyUri = "archrealms://runbooks/backup-policy-v1",
            RestoreRunbookUri = "archrealms://runbooks/restore-v1",
            BackupSnapshotId = "snapshot-1"
        },
        [
            new PassportHostedBackupManifestEntry
            {
                RelativePath = "records/hosted/capacity-1.json",
                Sha256 = new string('a', 64),
                ByteCount = 128
            },
            new PassportHostedBackupManifestEntry
            {
                RelativePath = "append-log/20260515.jsonl",
                Sha256 = new string('b', 64),
                ByteCount = 64
            }
        ]);

        Assert.True(result.Succeeded, result.Message);
        Assert.Equal("passport_hosted_storage_backup_manifest", result.Record!["record_type"]);
        Assert.Equal(false, result.Record["private_key_material_included"]);
        Assert.Equal(2, result.Record["manifest_file_count"]);
        Assert.Matches("^[0-9a-f]{64}$", result.Record["manifest_root_sha256"]?.ToString() ?? string.Empty);
        var inspection = PassportRegistryRecordInspector.Inspect(JsonSerializer.SerializeToUtf8Bytes(result.Record, JsonOptions));
        Assert.True(inspection.IsEnvelopeValid, string.Join("; ", inspection.ValidationFailures));

        var rejectedKeyMaterial = PassportHostedPolicy.CreateBackupManifestRecord(new PassportHostedBackupManifestRequest
        {
            ReleaseLane = "production-mvp",
            LedgerNamespace = "archrealms-passport-production-mvp",
            PolicyVersion = "passport-release-lanes-v1",
            StorageProvider = "managed-object-storage",
            BackupPolicyUri = "archrealms://runbooks/backup-policy-v1",
            RestoreRunbookUri = "archrealms://runbooks/restore-v1"
        },
        [
            new PassportHostedBackupManifestEntry
            {
                RelativePath = "keys/hosted-service-signing-key.pkcs8",
                Sha256 = new string('c', 64),
                ByteCount = 256
            }
        ]);

        Assert.False(rejectedKeyMaterial.Succeeded);
        Assert.Contains("no key material", rejectedKeyMaterial.Message, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public void IncidentReportIsMetadataOnlyAndRequiresResponseRunbook()
    {
        var result = PassportHostedPolicy.CreateIncidentReportRecord(new PassportHostedIncidentReportRequest
        {
            ReleaseLane = "production-mvp",
            LedgerNamespace = "archrealms-passport-production-mvp",
            PolicyVersion = "passport-release-lanes-v1",
            IncidentId = "incident-1",
            Severity = "high",
            IncidentType = "storage_delivery_failure",
            Summary = "Storage delivery failure detected for a production canary account.",
            DetectedUtc = DateTimeOffset.UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ"),
            IncidentResponseRunbookUri = "archrealms://runbooks/incident-response-v1",
            IncidentResponseOwner = "ops-duty-officer",
            TelemetryRetentionPolicyUri = "archrealms://policies/telemetry-retention-v1",
            RelatedRecordSha256 = [new string('d', 64)]
        });

        Assert.True(result.Succeeded, result.Message);
        Assert.Equal("passport_hosted_incident_report", result.Record!["record_type"]);
        Assert.Equal("high", result.Record["severity"]);
        Assert.Equal(false, result.Record["contains_raw_ai_prompts"]);
        var inspection = PassportRegistryRecordInspector.Inspect(JsonSerializer.SerializeToUtf8Bytes(result.Record, JsonOptions));
        Assert.True(inspection.IsEnvelopeValid, string.Join("; ", inspection.ValidationFailures));

        var rejectedRawPrompt = PassportHostedPolicy.CreateIncidentReportRecord(new PassportHostedIncidentReportRequest
        {
            ReleaseLane = "production-mvp",
            LedgerNamespace = "archrealms-passport-production-mvp",
            PolicyVersion = "passport-release-lanes-v1",
            Severity = "critical",
            IncidentType = "ai_privacy",
            Summary = "Raw prompt accidentally included.",
            DetectedUtc = DateTimeOffset.UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ"),
            IncidentResponseRunbookUri = "archrealms://runbooks/incident-response-v1",
            IncidentResponseOwner = "ops-duty-officer",
            TelemetryRetentionPolicyUri = "archrealms://policies/telemetry-retention-v1",
            ContainsRawAiPrompts = true
        });

        Assert.False(rejectedRawPrompt.Succeeded);
        Assert.Contains("metadata-only", rejectedRawPrompt.Message, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public void RecoveryControlValidatesSelfServiceDeviceSignature()
    {
        using var workspace = TemporaryDirectory.Create();
        using var device = RSA.Create(2048);
        var registry = new PassportHostedRegistryStore(workspace.Path);
        registry.SavePublicKey("device-1", device.ExportSubjectPublicKeyInfo());
        var request = CreateSignedRecoveryControlRequest(
            device,
            "passport_account_security_freeze",
            "passport_account_security_freeze_signature",
            "security_freeze_record_sha256",
            "device-1");

        var result = PassportHostedPolicy.ValidateRecoveryControl(request, registry);

        Assert.True(result.Succeeded, result.Message);
        Assert.Contains("Self-service recovery", result.Message, StringComparison.OrdinalIgnoreCase);
        Assert.Equal("passport_recovery_control_validation", result.Record!["record_type"]);
        Assert.Equal("self_service_device_signature", result.Record["validation_mode"]);
        var inspection = PassportRegistryRecordInspector.Inspect(JsonSerializer.SerializeToUtf8Bytes(result.Record, JsonOptions));
        Assert.True(inspection.IsEnvelopeValid, string.Join("; ", inspection.ValidationFailures));

        var aiApprovedRecord = JsonDocument.Parse(request.RecoveryControlRecord.GetRawText().Replace("\"ai_approved\": false", "\"ai_approved\": true")).RootElement.Clone();
        var rejectedAiApproval = PassportHostedPolicy.ValidateRecoveryControl(request with { RecoveryControlRecord = aiApprovedRecord }, registry);
        Assert.False(rejectedAiApproval.Succeeded);
        Assert.Contains("AI cannot approve", rejectedAiApproval.Message, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public void RecoveryControlValidatesSupportOverrideAdminAuthority()
    {
        using var workspace = TemporaryDirectory.Create();
        using var issuer = RSA.Create(2048);
        using var requester = RSA.Create(2048);
        using var approver = RSA.Create(2048);
        var registry = new PassportHostedRegistryStore(workspace.Path);
        registry.SavePublicKey("issuer-device", issuer.ExportSubjectPublicKeyInfo());
        registry.SavePublicKey("requester-device", requester.ExportSubjectPublicKeyInfo());
        registry.SavePublicKey("approver-device", approver.ExportSubjectPublicKeyInfo());
        AddRole(registry, issuer, "role-requester", "authority-identity", "requester-device", "recovery_override", "support_mediated_recovery");
        AddRole(registry, issuer, "role-approver", "authority-identity", "approver-device", "recovery_override", "support_mediated_recovery");
        var payloadHash = new string('b', 64);
        var adminAuthority = CreateSignedAdminRequest(
            requester,
            approver,
            "authority-identity",
            "requester-device",
            "approver-device",
            "recovery_override",
            "support_mediated_recovery",
            payloadHash: payloadHash);
        var request = CreateSupportRecoveryOverrideRequest(adminAuthority, payloadHash);

        var result = PassportHostedPolicy.ValidateRecoveryControl(request, registry);

        Assert.True(result.Succeeded, result.Message);
        Assert.Contains("Support-mediated recovery", result.Message, StringComparison.OrdinalIgnoreCase);
        Assert.Equal("passport_recovery_control_validation", result.Record!["record_type"]);
        Assert.Equal("support_mediated_dual_control", result.Record["validation_mode"]);
    }

    private static PassportAiSessionAuthorizationRequest CreateAiSessionRequest(RSA rsa, bool includeChallenge = true)
    {
        var record = new Dictionary<string, object?>
        {
            ["schema_version"] = 1,
            ["record_type"] = "passport_ai_session_request",
            ["record_id"] = "ai-request-1",
            ["created_utc"] = DateTimeOffset.UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ"),
            ["expires_utc"] = DateTimeOffset.UtcNow.AddMinutes(5).ToString("yyyy-MM-ddTHH:mm:ssZ"),
            ["release_lane"] = "production-mvp",
            ["ledger_namespace"] = "archrealms-passport-production-mvp",
            ["policy_version"] = "passport-release-lanes-v1",
            ["archrealms_identity_id"] = "identity-1",
            ["device_id"] = "device-1",
            ["gateway_url"] = "https://ai.archrealms.example",
            ["approved_knowledge_pack_id"] = "archrealms-mvp-approved-knowledge",
            ["privacy"] = new Dictionary<string, object?>
            {
                ["diagnostics_upload_opt_in"] = false,
                ["model_training_allowed"] = false,
                ["raw_prompt_retention_days"] = 30
            },
            ["authority_boundaries"] = new Dictionary<string, object?>
            {
                ["can_approve_recovery"] = false,
                ["can_issue_credits"] = false,
                ["can_release_escrow"] = false,
                ["can_mark_service_delivered"] = false,
                ["can_burn_credits"] = false,
                ["can_change_registry_authority"] = false,
                ["can_execute_wallet_operations"] = false,
                ["can_override_identity_status"] = false,
                ["can_approve_admin_authority"] = false
            },
            ["session_token_policy"] = new Dictionary<string, object?>
            {
                ["token_separate_from_wallet_keys"] = true,
                ["wallet_key_material_included"] = false,
                ["recovery_secret_material_included"] = false
            }
        };

        if (includeChallenge)
        {
            record["challenge"] = new Dictionary<string, object?>
            {
                ["challenge_id"] = "challenge-1",
                ["challenge_nonce"] = "nonce-1",
                ["audience"] = "archrealms-ai-gateway",
                ["expires_utc"] = DateTimeOffset.UtcNow.AddMinutes(5).ToString("yyyy-MM-ddTHH:mm:ssZ"),
                ["requested_scopes"] = new[] { "ai_guide" }
            };
        }

        var payload = JsonSerializer.SerializeToUtf8Bytes(record, JsonOptions);
        var signature = rsa.SignData(payload, HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1);
        record["signature"] = new Dictionary<string, object?>
        {
            ["signature_algorithm"] = "RSA_PKCS1_SHA256",
            ["signing_device_record_id"] = "device-1",
            ["signed_payload_sha256"] = ComputeSha256(payload)
        };
        var recordElement = JsonDocument.Parse(JsonSerializer.Serialize(record, JsonOptions)).RootElement.Clone();

        return new PassportAiSessionAuthorizationRequest
        {
            RequestRecord = recordElement,
            RequestRecordSha256 = ComputeJsonSha256(recordElement),
            SignedPayloadBase64 = Convert.ToBase64String(payload),
            SignatureBase64 = Convert.ToBase64String(signature),
            DevicePublicKeySpkiDerBase64 = Convert.ToBase64String(rsa.ExportSubjectPublicKeyInfo()),
            MessageQuota = 25,
            TokenQuota = 10000,
            TtlMinutes = 30
        };
    }

    private static PassportAdminAuthorityValidationRequest CreateSignedAdminRequest(
        RSA requester,
        RSA approver,
        string authorityIdentityId,
        string requesterDeviceId,
        string approverDeviceId,
        string actionType,
        string authorityScope,
        string? targetHash = null,
        string? payloadHash = null)
    {
        targetHash ??= new string('e', 64);
        payloadHash ??= new string('f', 64);
        var action = new Dictionary<string, object?>
        {
            ["schema_version"] = 1,
            ["record_type"] = "passport_admin_dual_control_action",
            ["record_id"] = "authority-1",
            ["created_utc"] = DateTimeOffset.UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ"),
            ["authority_identity_id"] = authorityIdentityId,
            ["action_type"] = actionType,
            ["authority_scope"] = authorityScope,
            ["reason_code"] = "test",
            ["target_record_sha256"] = targetHash,
            ["requested_payload_sha256"] = payloadHash,
            ["requester_device_id"] = requesterDeviceId,
            ["approver_device_id"] = approverDeviceId,
            ["required_approval_count"] = 2,
            ["approval_count"] = 2,
            ["ai_approved"] = false
        };
        var actionBytes = JsonSerializer.SerializeToUtf8Bytes(action, JsonOptions);
        var actionElement = JsonDocument.Parse(actionBytes).RootElement.Clone();
        return new PassportAdminAuthorityValidationRequest
        {
            ActionType = actionType,
            AuthorityScope = authorityScope,
            TargetRecordSha256 = targetHash,
            RequestedPayloadSha256 = payloadHash,
            AdminAuthorityRecord = actionElement,
            AdminAuthorityRecordPayloadBase64 = Convert.ToBase64String(actionBytes),
            RequesterSignatureRecord = CreateAdminSignatureRecord(
                requester,
                "passport_admin_dual_control_requester_signature",
                requesterDeviceId,
                actionBytes).RootElement.Clone(),
            ApproverSignatureRecord = CreateAdminSignatureRecord(
                approver,
                "passport_admin_dual_control_approver_signature",
                approverDeviceId,
                actionBytes).RootElement.Clone()
        };
    }

    private static PassportRecoveryControlValidationRequest CreateSignedRecoveryControlRequest(
        RSA authorizingDevice,
        string recordType,
        string signatureRecordType,
        string hashPropertyName,
        string authorizingDeviceId)
    {
        var record = new Dictionary<string, object?>
        {
            ["schema_version"] = 1,
            ["record_type"] = recordType,
            ["record_id"] = "recovery-control-1",
            ["created_utc"] = DateTimeOffset.UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ"),
            ["release_lane"] = "production-mvp",
            ["ledger_namespace"] = "archrealms-passport-production-mvp",
            ["policy_version"] = "passport-release-lanes-v1",
            ["archrealms_identity_id"] = "identity-1",
            ["authorizing_device_id"] = authorizingDeviceId,
            ["reason_code"] = "identity_compromise",
            ["freeze_wallet_operations"] = true,
            ["freeze_pending_escrow"] = true,
            ["revoke_ai_sessions"] = true,
            ["pause_storage_node_operations"] = true,
            ["ai_approved"] = false
        };
        var payload = JsonSerializer.SerializeToUtf8Bytes(record, JsonOptions);
        var payloadHash = ComputeSha256(payload);
        var signature = JsonDocument.Parse(JsonSerializer.Serialize(new Dictionary<string, object?>
        {
            ["schema_version"] = 1,
            ["record_type"] = signatureRecordType,
            ["record_id"] = "recovery-control-signature-1",
            ["authorizing_device_id"] = authorizingDeviceId,
            [hashPropertyName] = payloadHash,
            ["signature_algorithm"] = "RSA_PKCS1_SHA256",
            ["signature_base64"] = Convert.ToBase64String(authorizingDevice.SignData(payload, HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1))
        }, JsonOptions)).RootElement.Clone();

        return new PassportRecoveryControlValidationRequest
        {
            RecoveryControlRecord = JsonDocument.Parse(payload).RootElement.Clone(),
            RecoveryControlRecordPayloadBase64 = Convert.ToBase64String(payload),
            RecoveryControlRecordSha256 = payloadHash,
            RecoverySignatureRecord = signature
        };
    }

    private static PassportRecoveryControlValidationRequest CreateSupportRecoveryOverrideRequest(
        PassportAdminAuthorityValidationRequest adminAuthority,
        string requestedPayloadSha256)
    {
        var record = new Dictionary<string, object?>
        {
            ["schema_version"] = 1,
            ["record_type"] = "passport_support_mediated_recovery_override",
            ["record_id"] = "support-recovery-1",
            ["created_utc"] = DateTimeOffset.UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ"),
            ["release_lane"] = "production-mvp",
            ["ledger_namespace"] = "archrealms-passport-production-mvp",
            ["policy_version"] = "passport-release-lanes-v1",
            ["authority_identity_id"] = "authority-identity",
            ["target_identity_id"] = "identity-1",
            ["target_account_id"] = "account-1",
            ["reason_code"] = "identity_compromise",
            ["target_record_sha256"] = new string('e', 64),
            ["requested_payload_sha256"] = requestedPayloadSha256,
            ["requires_dual_control"] = true,
            ["ai_approved"] = false
        };
        var payload = JsonSerializer.SerializeToUtf8Bytes(record, JsonOptions);
        return new PassportRecoveryControlValidationRequest
        {
            RecoveryControlRecord = JsonDocument.Parse(payload).RootElement.Clone(),
            RecoveryControlRecordPayloadBase64 = Convert.ToBase64String(payload),
            RecoveryControlRecordSha256 = ComputeSha256(payload),
            AdminAuthority = adminAuthority
        };
    }

    private static JsonDocument CreateAdminSignatureRecord(RSA rsa, string recordType, string deviceId, byte[] actionBytes)
    {
        return JsonDocument.Parse(JsonSerializer.Serialize(new Dictionary<string, object?>
        {
            ["schema_version"] = 1,
            ["record_type"] = recordType,
            ["record_id"] = recordType + "-" + deviceId,
            ["device_id"] = deviceId,
            ["admin_action_record_sha256"] = ComputeSha256(actionBytes),
            ["signature_algorithm"] = "RSA_PKCS1_SHA256",
            ["signature_base64"] = Convert.ToBase64String(rsa.SignData(actionBytes, HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1))
        }, JsonOptions));
    }

    private static void AddRole(
        PassportHostedRegistryStore registry,
        RSA issuer,
        string roleId,
        string authorityIdentityId,
        string deviceId,
        string actionType,
        string authorityScope)
    {
        var role = new Dictionary<string, object?>
        {
            ["schema_version"] = 1,
            ["record_type"] = "passport_admin_authority_role_membership",
            ["record_id"] = roleId,
            ["created_utc"] = DateTimeOffset.UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ"),
            ["status"] = "active",
            ["authority_identity_id"] = authorityIdentityId,
            ["device_id"] = deviceId,
            ["role_name"] = "crown_admin",
            ["dual_control_eligible"] = true,
            ["authorized_action_types"] = new[] { actionType },
            ["authorized_authority_scopes"] = new[] { authorityScope },
            ["issued_by_device_id"] = "issuer-device",
            ["expires_utc"] = string.Empty,
            ["ai_approved"] = false
        };
        var roleBytes = JsonSerializer.SerializeToUtf8Bytes(role, JsonOptions);
        registry.SaveRoleMembership(
            roleId,
            roleBytes,
            "issuer-device",
            issuer.SignData(roleBytes, HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1));
    }

    private static object ReadNested(Dictionary<string, object?> record, string objectName, string propertyName)
    {
        var child = Assert.IsType<Dictionary<string, object?>>(record[objectName]);
        return child[propertyName]!;
    }

    private static string ComputeJsonSha256(JsonElement value)
    {
        return ComputeSha256(JsonSerializer.SerializeToUtf8Bytes(value, JsonOptions));
    }

    private static string ComputeSha256(byte[] value)
    {
        return Convert.ToHexString(SHA256.HashData(value)).ToLowerInvariant();
    }

    private sealed class TemporaryDirectory : IDisposable
    {
        private TemporaryDirectory(string path)
        {
            Path = path;
            Directory.CreateDirectory(path);
        }

        public string Path { get; }

        public static TemporaryDirectory Create()
        {
            return new TemporaryDirectory(System.IO.Path.Combine(System.IO.Path.GetTempPath(), "archrealms-hosted-policy-tests", Guid.NewGuid().ToString("N")));
        }

        public void Dispose()
        {
            try
            {
                if (Directory.Exists(Path))
                {
                    Directory.Delete(Path, true);
                }
            }
            catch
            {
            }
        }
    }
}
