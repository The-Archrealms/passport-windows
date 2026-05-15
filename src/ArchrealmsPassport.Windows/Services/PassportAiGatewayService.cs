using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using ArchrealmsPassport.Windows.Models;

namespace ArchrealmsPassport.Windows.Services
{
    public sealed class PassportAiGatewayService
    {
        private static readonly JsonSerializerOptions JsonOptions = new JsonSerializerOptions
        {
            WriteIndented = true
        };

        private readonly PassportReleaseLane releaseLane;

        public PassportAiGatewayService(PassportReleaseLane? releaseLane = null)
        {
            this.releaseLane = releaseLane ?? PassportEnvironment.GetReleaseLane();
        }

        public PassportAiSessionResult CreateSessionRequest(
            string workspaceRoot,
            string identityId,
            string deviceId,
            string deviceKeyReferencePath,
            string gatewayUrl,
            string knowledgePackId,
            bool diagnosticsUploadOptIn)
        {
            try
            {
                var resolvedWorkspaceRoot = PassportEnvironment.ResolveWorkspaceRoot(workspaceRoot);
                if (string.IsNullOrWhiteSpace(identityId) || string.IsNullOrWhiteSpace(deviceId))
                {
                    return Failed("AI session request requires an active Passport identity and device.");
                }

                if (string.IsNullOrWhiteSpace(deviceKeyReferencePath) || !PassportDeviceKeyStore.ReferenceExists(deviceKeyReferencePath))
                {
                    return Failed("AI session request requires the active Passport device key.");
                }

                if (new PassportRecoveryService(releaseLane).AreAiSessionsRevoked(resolvedWorkspaceRoot, identityId))
                {
                    return Failed("AI sessions are revoked by the current account security freeze.");
                }

                var timestamp = DateTime.UtcNow.ToString("yyyyMMddTHHmmssZ");
                var createdUtc = DateTime.UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ");
                var expiresUtc = DateTime.UtcNow.AddMinutes(5).ToString("yyyy-MM-ddTHH:mm:ssZ");
                var requestId = timestamp + "-ai-session-request-" + Guid.NewGuid().ToString("N")[..10];
                var requestRoot = Path.Combine(resolvedWorkspaceRoot, "records", "passport", "ai", "session-requests", requestId);
                Directory.CreateDirectory(requestRoot);

                var payloadPath = Path.Combine(requestRoot, "ai-session-request.payload.json");
                var signaturePath = Path.Combine(requestRoot, "ai-session-request.sig");
                var recordPath = Path.Combine(requestRoot, "ai-session-request.json");
                var nonce = CreateToken();
                var normalizedGatewayUrl = string.IsNullOrWhiteSpace(gatewayUrl) ? "https://ai.archrealms.local" : gatewayUrl.Trim();
                var normalizedKnowledgePackId = string.IsNullOrWhiteSpace(knowledgePackId) ? "archrealms-mvp-approved-knowledge" : knowledgePackId.Trim();

                var record = new Dictionary<string, object?>
                {
                    ["schema_version"] = 1,
                    ["record_type"] = "passport_ai_session_request",
                    ["record_id"] = requestId,
                    ["created_utc"] = createdUtc,
                    ["expires_utc"] = expiresUtc,
                    ["status"] = "requested",
                    ["release_lane"] = releaseLane.Lane,
                    ["ledger_namespace"] = releaseLane.LedgerNamespace,
                    ["policy_version"] = releaseLane.PolicyVersion,
                    ["archrealms_identity_id"] = identityId.Trim(),
                    ["device_id"] = deviceId.Trim(),
                    ["gateway_url"] = normalizedGatewayUrl,
                    ["approved_knowledge_pack_id"] = normalizedKnowledgePackId,
                    ["challenge"] = new Dictionary<string, object?>
                    {
                        ["challenge_nonce"] = nonce,
                        ["audience"] = "archrealms-ai-gateway",
                        ["requested_scopes"] = new[] { "ai_guide" }
                    },
                    ["privacy"] = new Dictionary<string, object?>
                    {
                        ["diagnostics_upload_opt_in"] = diagnosticsUploadOptIn,
                        ["model_training_allowed"] = false,
                        ["raw_prompt_retention_days"] = 30,
                        ["private_passport_state_upload_allowed"] = diagnosticsUploadOptIn
                    },
                    ["authority_boundaries"] = CreateAuthorityBoundaries(),
                    ["session_token_policy"] = new Dictionary<string, object?>
                    {
                        ["token_separate_from_wallet_keys"] = true,
                        ["wallet_key_material_included"] = false,
                        ["recovery_secret_material_included"] = false
                    },
                    ["summary"] = "Passport-signed AI gateway session request. AI is an authenticated guide only and has no wallet, recovery, ledger, storage-delivery, registry-authority, or admin authority."
                };

                var payloadBytes = JsonSerializer.SerializeToUtf8Bytes(record, JsonOptions);
                var signatureBytes = PassportDeviceKeyStore.SignData(deviceKeyReferencePath, payloadBytes);
                File.WriteAllBytes(payloadPath, payloadBytes);
                File.WriteAllBytes(signaturePath, signatureBytes);
                record["signature"] = new Dictionary<string, object?>
                {
                    ["signature_algorithm"] = "RSA_PKCS1_SHA256",
                    ["signing_device_record_id"] = deviceId.Trim(),
                    ["signed_payload_path"] = ToWorkspaceRelativePath(resolvedWorkspaceRoot, payloadPath),
                    ["signature_path"] = ToWorkspaceRelativePath(resolvedWorkspaceRoot, signaturePath),
                    ["signed_payload_sha256"] = ComputeSha256(payloadBytes)
                };
                File.WriteAllText(recordPath, JsonSerializer.Serialize(record, JsonOptions), Encoding.UTF8);

                return new PassportAiSessionResult
                {
                    Succeeded = true,
                    Message = "Created Passport AI session request.",
                    RequestId = requestId,
                    RequestPath = recordPath,
                    RequestSha256 = ComputeSha256(File.ReadAllBytes(recordPath)),
                    SignaturePath = signaturePath,
                    ExpiresUtc = expiresUtc
                };
            }
            catch (Exception ex)
            {
                return Failed("AI session request failed: " + ex.Message);
            }
        }

        public PassportAiSessionResult CreateLocalGatewaySession(
            string workspaceRoot,
            string requestPath,
            string requestSha256,
            int messageQuota,
            int tokenQuota,
            TimeSpan ttl)
        {
            try
            {
                var resolvedWorkspaceRoot = PassportEnvironment.ResolveWorkspaceRoot(workspaceRoot);
                var resolvedRequestPath = ResolveWorkspaceRelativePath(resolvedWorkspaceRoot, requestPath);
                if (!File.Exists(resolvedRequestPath))
                {
                    return Failed("AI session request record could not be found.");
                }

                var actualRequestSha256 = ComputeSha256(File.ReadAllBytes(resolvedRequestPath));
                if (!string.IsNullOrWhiteSpace(requestSha256)
                    && !string.Equals(actualRequestSha256, requestSha256, StringComparison.OrdinalIgnoreCase))
                {
                    return Failed("AI session request hash does not match.");
                }

                using var requestDocument = JsonDocument.Parse(File.ReadAllText(resolvedRequestPath));
                var request = requestDocument.RootElement;
                var validation = ValidateSessionRequest(resolvedWorkspaceRoot, request);
                if (!validation.Succeeded)
                {
                    return validation;
                }

                var identityId = ReadString(request, "archrealms_identity_id");
                if (new PassportRecoveryService(releaseLane).AreAiSessionsRevoked(resolvedWorkspaceRoot, identityId))
                {
                    return Failed("AI sessions are revoked by the current account security freeze.");
                }

                var sessionId = DateTime.UtcNow.ToString("yyyyMMddTHHmmssZ") + "-ai-session-" + Guid.NewGuid().ToString("N")[..10];
                var sessionRoot = Path.Combine(resolvedWorkspaceRoot, "records", "passport", "ai", "sessions");
                Directory.CreateDirectory(sessionRoot);
                var sessionPath = Path.Combine(sessionRoot, sessionId + ".json");
                var token = CreateToken();
                var expiresUtc = DateTime.UtcNow.Add(ttl <= TimeSpan.Zero ? TimeSpan.FromMinutes(30) : ttl).ToString("yyyy-MM-ddTHH:mm:ssZ");
                var tokenSha256 = ComputeSha256(Encoding.UTF8.GetBytes(token));
                var session = new Dictionary<string, object?>
                {
                    ["schema_version"] = 1,
                    ["record_type"] = "passport_ai_session_record",
                    ["record_id"] = sessionId,
                    ["session_id"] = sessionId,
                    ["created_utc"] = DateTime.UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ"),
                    ["expires_utc"] = expiresUtc,
                    ["status"] = "active",
                    ["release_lane"] = releaseLane.Lane,
                    ["ledger_namespace"] = releaseLane.LedgerNamespace,
                    ["policy_version"] = releaseLane.PolicyVersion,
                    ["archrealms_identity_id"] = identityId,
                    ["device_id"] = ReadString(request, "device_id"),
                    ["gateway_url"] = ReadString(request, "gateway_url"),
                    ["approved_knowledge_pack_id"] = ReadString(request, "approved_knowledge_pack_id"),
                    ["request_record_path"] = ToWorkspaceRelativePath(resolvedWorkspaceRoot, resolvedRequestPath),
                    ["request_record_sha256"] = actualRequestSha256,
                    ["session_token_sha256"] = tokenSha256,
                    ["quota"] = new Dictionary<string, object?>
                    {
                        ["message_limit"] = Math.Max(1, messageQuota),
                        ["token_limit"] = Math.Max(1, tokenQuota),
                        ["messages_used"] = 0,
                        ["tokens_used"] = 0
                    },
                    ["authority_boundaries"] = CreateAuthorityBoundaries(),
                    ["privacy"] = ReadPrivacy(request),
                    ["summary"] = "Local AI gateway session record for Passport integration. The bearer token is returned to the caller only; this record stores the token hash and grants no wallet, recovery, ledger, storage-delivery, registry-authority, or admin authority."
                };

                File.WriteAllText(sessionPath, JsonSerializer.Serialize(session, JsonOptions), Encoding.UTF8);

                return new PassportAiSessionResult
                {
                    Succeeded = true,
                    Message = "Created local Passport AI session.",
                    RequestId = ReadString(request, "record_id"),
                    RequestPath = resolvedRequestPath,
                    RequestSha256 = actualRequestSha256,
                    SessionId = sessionId,
                    SessionPath = sessionPath,
                    SessionToken = token,
                    SessionTokenSha256 = tokenSha256,
                    ExpiresUtc = expiresUtc,
                    MessageQuota = Math.Max(1, messageQuota),
                    TokenQuota = Math.Max(1, tokenQuota)
                };
            }
            catch (Exception ex)
            {
                return Failed("AI gateway session failed: " + ex.Message);
            }
        }

        private PassportAiSessionResult ValidateSessionRequest(string workspaceRoot, JsonElement request)
        {
            if (!Matches(request, "record_type", "passport_ai_session_request"))
            {
                return Failed("AI gateway session requires a Passport AI session request record.");
            }

            if (!Matches(request, "release_lane", releaseLane.Lane) || !Matches(request, "ledger_namespace", releaseLane.LedgerNamespace))
            {
                return Failed("AI session request belongs to another release lane or ledger namespace.");
            }

            if (!DateTime.TryParse(ReadString(request, "expires_utc"), out var expiresUtc) || expiresUtc.ToUniversalTime() <= DateTime.UtcNow)
            {
                return Failed("AI session request is expired.");
            }

            if (!request.TryGetProperty("signature", out var signature))
            {
                return Failed("AI session request is missing a device signature.");
            }

            var payloadPath = ResolveWorkspaceRelativePath(workspaceRoot, ReadString(signature, "signed_payload_path"));
            var signaturePath = ResolveWorkspaceRelativePath(workspaceRoot, ReadString(signature, "signature_path"));
            if (!File.Exists(payloadPath) || !File.Exists(signaturePath))
            {
                return Failed("AI session request signature evidence is missing.");
            }

            var payloadBytes = File.ReadAllBytes(payloadPath);
            var expectedPayloadSha256 = ReadString(signature, "signed_payload_sha256");
            if (!string.Equals(ComputeSha256(payloadBytes), expectedPayloadSha256, StringComparison.OrdinalIgnoreCase))
            {
                return Failed("AI session request signed payload hash does not match.");
            }

            var deviceId = ReadString(request, "device_id");
            var publicKeyPath = Path.Combine(workspaceRoot, "records", "registry", "public-keys", deviceId + ".spki.der");
            if (!File.Exists(publicKeyPath) || !VerifySignature(publicKeyPath, payloadBytes, File.ReadAllBytes(signaturePath)))
            {
                return Failed("AI session request device signature verification failed.");
            }

            if (!request.TryGetProperty("session_token_policy", out var tokenPolicy)
                || !ReadBoolean(tokenPolicy, "token_separate_from_wallet_keys")
                || ReadBoolean(tokenPolicy, "wallet_key_material_included")
                || ReadBoolean(tokenPolicy, "recovery_secret_material_included"))
            {
                return Failed("AI session request violates token/key separation policy.");
            }

            if (!request.TryGetProperty("authority_boundaries", out var authority)
                || !AuthorityBoundaryIsNonAuthoritative(authority))
            {
                return Failed("AI session request must mark AI as non-authoritative.");
            }

            return new PassportAiSessionResult { Succeeded = true };
        }

        private static Dictionary<string, object?> CreateAuthorityBoundaries()
        {
            return new Dictionary<string, object?>
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
            };
        }

        private static Dictionary<string, object?> ReadPrivacy(JsonElement request)
        {
            if (!request.TryGetProperty("privacy", out var privacy))
            {
                return new Dictionary<string, object?>();
            }

            return JsonSerializer.Deserialize<Dictionary<string, object?>>(privacy.GetRawText(), JsonOptions)
                ?? new Dictionary<string, object?>();
        }

        private static bool AuthorityBoundaryIsNonAuthoritative(JsonElement authority)
        {
            var forbidden = new[]
            {
                "can_approve_recovery",
                "can_issue_credits",
                "can_release_escrow",
                "can_mark_service_delivered",
                "can_burn_credits",
                "can_change_registry_authority",
                "can_execute_wallet_operations",
                "can_override_identity_status",
                "can_approve_admin_authority"
            };

            return forbidden.All(name => !ReadBoolean(authority, name));
        }

        private static string CreateToken()
        {
            var bytes = new byte[32];
            RandomNumberGenerator.Fill(bytes);
            return Convert.ToBase64String(bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_');
        }

        private static bool VerifySignature(string publicKeyPath, byte[] data, byte[] signatureBytes)
        {
            using var rsa = RSA.Create();
            rsa.ImportSubjectPublicKeyInfo(File.ReadAllBytes(publicKeyPath), out _);
            return rsa.VerifyData(data, signatureBytes, HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1);
        }

        private static bool Matches(JsonElement root, string propertyName, string expected)
        {
            return root.TryGetProperty(propertyName, out var property)
                && property.ValueKind == JsonValueKind.String
                && string.Equals(property.GetString() ?? string.Empty, expected, StringComparison.Ordinal);
        }

        private static string ReadString(JsonElement root, string propertyName)
        {
            return root.TryGetProperty(propertyName, out var property) && property.ValueKind == JsonValueKind.String
                ? property.GetString() ?? string.Empty
                : string.Empty;
        }

        private static bool ReadBoolean(JsonElement root, string propertyName)
        {
            return root.TryGetProperty(propertyName, out var property)
                && (property.ValueKind == JsonValueKind.True
                    || (property.ValueKind == JsonValueKind.String && bool.TryParse(property.GetString(), out var parsed) && parsed));
        }

        private static string ResolveWorkspaceRelativePath(string workspaceRoot, string path)
        {
            if (string.IsNullOrWhiteSpace(path))
            {
                return string.Empty;
            }

            var normalized = path.Replace('/', Path.DirectorySeparatorChar);
            return Path.IsPathRooted(normalized)
                ? Path.GetFullPath(normalized)
                : Path.GetFullPath(Path.Combine(workspaceRoot, normalized));
        }

        private static string ToWorkspaceRelativePath(string workspaceRoot, string path)
        {
            var root = Path.GetFullPath(workspaceRoot).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
            var fullPath = Path.GetFullPath(path);
            return fullPath.StartsWith(root, StringComparison.OrdinalIgnoreCase)
                ? fullPath[root.Length..].TrimStart(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar).Replace(Path.DirectorySeparatorChar, '/')
                : path.Replace(Path.DirectorySeparatorChar, '/');
        }

        private static string ComputeSha256(byte[] value)
        {
            return Convert.ToHexString(SHA256.HashData(value)).ToLowerInvariant();
        }

        private static PassportAiSessionResult Failed(string message)
        {
            return new PassportAiSessionResult
            {
                Succeeded = false,
                Message = message
            };
        }
    }
}
