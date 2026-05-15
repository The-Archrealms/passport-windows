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
    public sealed class PassportAdminAuthorityService
    {
        private static readonly JsonSerializerOptions JsonOptions = new JsonSerializerOptions
        {
            WriteIndented = true
        };

        private readonly PassportReleaseLane releaseLane;

        public PassportAdminAuthorityService(PassportReleaseLane? releaseLane = null)
        {
            this.releaseLane = releaseLane ?? PassportEnvironment.GetReleaseLane();
        }

        public PassportAdminRoleMembershipResult CreateRoleMembership(
            string workspaceRoot,
            string authorityIdentityId,
            string issuerDeviceId,
            string issuerDeviceKeyReferencePath,
            string subjectDeviceId,
            string roleName,
            IEnumerable<string> authorizedActionTypes,
            IEnumerable<string> authorizedAuthorityScopes,
            string reasonCode)
        {
            try
            {
                var resolvedWorkspaceRoot = PassportEnvironment.ResolveWorkspaceRoot(workspaceRoot);
                var normalizedIdentityId = NormalizeRequired(authorityIdentityId, "authority identity ID");
                var normalizedIssuerDeviceId = NormalizeRequired(issuerDeviceId, "issuer device ID");
                var normalizedSubjectDeviceId = NormalizeRequired(subjectDeviceId, "subject device ID");
                var normalizedRoleName = NormalizeRequired(roleName, "role name").Trim().ToLowerInvariant().Replace(" ", "_").Replace("-", "_");
                var normalizedReasonCode = NormalizeReasonCode(reasonCode);
                var actionTypes = NormalizeAuthorizationList(authorizedActionTypes, NormalizeActionAuthorization);
                var authorityScopes = NormalizeAuthorizationList(authorizedAuthorityScopes, NormalizeScopeAuthorization);

                var identityGate = ValidateCrownAuthorityIdentity(normalizedIdentityId);
                if (!identityGate.Succeeded)
                {
                    return FailedRoleMembership(identityGate.Message);
                }

                var issuerDevice = FindLatestDeviceRecord(resolvedWorkspaceRoot, normalizedIdentityId, normalizedIssuerDeviceId, "active");
                var subjectDevice = FindLatestDeviceRecord(resolvedWorkspaceRoot, normalizedIdentityId, normalizedSubjectDeviceId, "active");
                if (issuerDevice == null)
                {
                    return FailedRoleMembership("The admin role issuer device credential record could not be found.");
                }

                if (subjectDevice == null)
                {
                    return FailedRoleMembership("The admin role subject device credential record could not be found.");
                }

                var recovery = new PassportRecoveryService(releaseLane);
                if (recovery.IsDeviceDeauthorized(resolvedWorkspaceRoot, normalizedIdentityId, normalizedIssuerDeviceId)
                    || recovery.IsDeviceDeauthorized(resolvedWorkspaceRoot, normalizedIdentityId, normalizedSubjectDeviceId))
                {
                    return FailedRoleMembership("Admin role membership cannot be issued by or assigned to deauthorized devices.");
                }

                var issuerPublicKeyPath = ResolvePublicKeyPath(resolvedWorkspaceRoot, issuerDevice.Value.RootElement);
                if (string.IsNullOrWhiteSpace(issuerPublicKeyPath) || !File.Exists(issuerPublicKeyPath))
                {
                    return FailedRoleMembership("The admin role issuer public key could not be resolved.");
                }

                var timestamp = DateTime.UtcNow.ToString("yyyyMMddTHHmmssZ");
                var createdUtc = DateTime.UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ");
                var root = Path.Combine(resolvedWorkspaceRoot, "records", "passport", "admin-authority", "roles");
                Directory.CreateDirectory(root);
                var recordId = timestamp + "-" + normalizedSubjectDeviceId + "-" + normalizedRoleName + "-" + Guid.NewGuid().ToString("N")[..10];
                var recordPath = Path.Combine(root, recordId + ".json");
                var record = new Dictionary<string, object?>
                {
                    ["schema_version"] = 1,
                    ["record_type"] = "passport_admin_authority_role_membership",
                    ["record_id"] = recordId,
                    ["created_utc"] = createdUtc,
                    ["effective_utc"] = createdUtc,
                    ["release_lane"] = releaseLane.Lane,
                    ["ledger_namespace"] = releaseLane.LedgerNamespace,
                    ["policy_version"] = releaseLane.PolicyVersion,
                    ["status"] = "active",
                    ["authority_identity_id"] = normalizedIdentityId,
                    ["device_id"] = normalizedSubjectDeviceId,
                    ["role_name"] = normalizedRoleName,
                    ["dual_control_eligible"] = true,
                    ["authorized_action_types"] = actionTypes,
                    ["authorized_authority_scopes"] = authorityScopes,
                    ["reason_code"] = normalizedReasonCode,
                    ["issued_by_identity_id"] = normalizedIdentityId,
                    ["issued_by_device_id"] = normalizedIssuerDeviceId,
                    ["expires_utc"] = string.Empty,
                    ["ai_approved"] = false,
                    ["summary"] = "Passport admin role membership for dual-control authority. AI is not an approval authority."
                };
                File.WriteAllText(recordPath, JsonSerializer.Serialize(record, JsonOptions), Encoding.UTF8);

                var recordBytes = File.ReadAllBytes(recordPath);
                var signature = WriteRoleMembershipSignature(
                    root,
                    recordId + ".signature.json",
                    resolvedWorkspaceRoot,
                    recordPath,
                    recordBytes,
                    normalizedIdentityId,
                    normalizedIssuerDeviceId,
                    issuerDeviceKeyReferencePath,
                    issuerPublicKeyPath);

                return new PassportAdminRoleMembershipResult
                {
                    Succeeded = signature.Verified,
                    Message = signature.Verified
                        ? "Admin authority role membership created."
                        : "Admin authority role membership signature verification failed.",
                    RecordPath = recordPath,
                    SignaturePath = signature.Path,
                    SignatureVerified = signature.Verified
                };
            }
            catch (Exception ex)
            {
                return FailedRoleMembership("Admin authority role membership failed: " + ex.Message);
            }
        }

        public PassportAdminAuthorityResult CreateDualControlAction(
            string workspaceRoot,
            string authorityIdentityId,
            string requesterDeviceId,
            string requesterDeviceKeyReferencePath,
            string approverDeviceId,
            string approverDeviceKeyReferencePath,
            string actionType,
            string authorityScope,
            string reasonCode,
            string targetRecordId,
            string targetRecordSha256,
            string requestedPayloadSha256)
        {
            try
            {
                var resolvedWorkspaceRoot = PassportEnvironment.ResolveWorkspaceRoot(workspaceRoot);
                var normalizedIdentityId = NormalizeRequired(authorityIdentityId, "authority identity ID");
                var normalizedRequesterDeviceId = NormalizeRequired(requesterDeviceId, "requester device ID");
                var normalizedApproverDeviceId = NormalizeRequired(approverDeviceId, "approver device ID");
                if (string.Equals(normalizedRequesterDeviceId, normalizedApproverDeviceId, StringComparison.Ordinal))
                {
                    return Failed("Dual-control admin actions require two distinct authorizing devices.");
                }

                var normalizedActionType = NormalizeActionType(actionType);
                var normalizedReasonCode = NormalizeReasonCode(reasonCode);
                var requesterDevice = FindLatestDeviceRecord(resolvedWorkspaceRoot, normalizedIdentityId, normalizedRequesterDeviceId, "active");
                var approverDevice = FindLatestDeviceRecord(resolvedWorkspaceRoot, normalizedIdentityId, normalizedApproverDeviceId, "active");
                if (requesterDevice == null)
                {
                    return Failed("The requester device credential record could not be found.");
                }

                if (approverDevice == null)
                {
                    return Failed("The approver device credential record could not be found.");
                }

                var recovery = new PassportRecoveryService(releaseLane);
                if (recovery.IsDeviceDeauthorized(resolvedWorkspaceRoot, normalizedIdentityId, normalizedRequesterDeviceId)
                    || recovery.IsDeviceDeauthorized(resolvedWorkspaceRoot, normalizedIdentityId, normalizedApproverDeviceId))
                {
                    return Failed("Dual-control admin actions cannot be authorized by deauthorized devices.");
                }

                var requesterPublicKeyPath = ResolvePublicKeyPath(resolvedWorkspaceRoot, requesterDevice.Value.RootElement);
                var approverPublicKeyPath = ResolvePublicKeyPath(resolvedWorkspaceRoot, approverDevice.Value.RootElement);
                if (string.IsNullOrWhiteSpace(requesterPublicKeyPath) || !File.Exists(requesterPublicKeyPath))
                {
                    return Failed("The requester public key could not be resolved.");
                }

                if (string.IsNullOrWhiteSpace(approverPublicKeyPath) || !File.Exists(approverPublicKeyPath))
                {
                    return Failed("The approver public key could not be resolved.");
                }

                var authorityPolicy = ValidateProductionAuthorityPolicy(
                    resolvedWorkspaceRoot,
                    normalizedIdentityId,
                    normalizedRequesterDeviceId,
                    normalizedApproverDeviceId,
                    normalizedActionType,
                    NormalizeRequired(authorityScope, "authority scope"));
                if (!authorityPolicy.Succeeded)
                {
                    return authorityPolicy;
                }

                var timestamp = DateTime.UtcNow.ToString("yyyyMMddTHHmmssZ");
                var createdUtc = DateTime.UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ");
                var root = Path.Combine(resolvedWorkspaceRoot, "records", "passport", "admin-authority", normalizedActionType);
                Directory.CreateDirectory(root);
                var recordPath = Path.Combine(root, timestamp + "-" + normalizedActionType + ".json");
                var record = new Dictionary<string, object?>
                {
                    ["schema_version"] = 1,
                    ["record_type"] = "passport_admin_dual_control_action",
                    ["record_id"] = timestamp + "-" + normalizedActionType,
                    ["created_utc"] = createdUtc,
                    ["release_lane"] = releaseLane.Lane,
                    ["ledger_namespace"] = releaseLane.LedgerNamespace,
                    ["policy_version"] = releaseLane.PolicyVersion,
                    ["authority_identity_id"] = normalizedIdentityId,
                    ["action_type"] = normalizedActionType,
                    ["authority_scope"] = NormalizeRequired(authorityScope, "authority scope"),
                    ["reason_code"] = normalizedReasonCode,
                    ["target_record_id"] = (targetRecordId ?? string.Empty).Trim(),
                    ["target_record_sha256"] = (targetRecordSha256 ?? string.Empty).Trim().ToLowerInvariant(),
                    ["requested_payload_sha256"] = (requestedPayloadSha256 ?? string.Empty).Trim().ToLowerInvariant(),
                    ["requester_device_id"] = normalizedRequesterDeviceId,
                    ["approver_device_id"] = normalizedApproverDeviceId,
                    ["required_approval_count"] = 2,
                    ["approval_count"] = 2,
                    ["ai_approved"] = false,
                    ["summary"] = "Dual-control Passport admin authority record. AI is not an approval authority."
                };
                File.WriteAllText(recordPath, JsonSerializer.Serialize(record, JsonOptions), Encoding.UTF8);

                var recordBytes = File.ReadAllBytes(recordPath);
                var requesterSignature = WriteSignature(
                    root,
                    timestamp + "-" + normalizedActionType + ".requester-signature.json",
                    "passport_admin_dual_control_requester_signature",
                    resolvedWorkspaceRoot,
                    recordPath,
                    recordBytes,
                    normalizedIdentityId,
                    normalizedRequesterDeviceId,
                    requesterDeviceKeyReferencePath,
                    requesterPublicKeyPath);
                var approverSignature = WriteSignature(
                    root,
                    timestamp + "-" + normalizedActionType + ".approver-signature.json",
                    "passport_admin_dual_control_approver_signature",
                    resolvedWorkspaceRoot,
                    recordPath,
                    recordBytes,
                    normalizedIdentityId,
                    normalizedApproverDeviceId,
                    approverDeviceKeyReferencePath,
                    approverPublicKeyPath);

                return new PassportAdminAuthorityResult
                {
                    Succeeded = requesterSignature.Verified && approverSignature.Verified,
                    Message = requesterSignature.Verified && approverSignature.Verified
                        ? "Dual-control admin authority record created."
                        : "Dual-control admin authority signature verification failed.",
                    RecordPath = recordPath,
                    RequesterSignaturePath = requesterSignature.Path,
                    ApproverSignaturePath = approverSignature.Path,
                    RequesterSignatureVerified = requesterSignature.Verified,
                    ApproverSignatureVerified = approverSignature.Verified
                };
            }
            catch (Exception ex)
            {
                return Failed("Dual-control admin authority failed: " + ex.Message);
            }
        }

        public PassportAdminAuthorityResult ValidateDualControlActionEvidence(
            string workspaceRoot,
            IDictionary<string, string> evidenceReferences,
            string expectedActionType,
            string expectedTargetRecordSha256,
            string expectedRequestedPayloadSha256)
        {
            try
            {
                if (!evidenceReferences.TryGetValue("admin_authority_record_path", out var actionRecordReference)
                    || string.IsNullOrWhiteSpace(actionRecordReference))
                {
                    return Failed("Production issuer validation requires admin_authority_record_path evidence.");
                }

                var resolvedWorkspaceRoot = PassportEnvironment.ResolveWorkspaceRoot(workspaceRoot);
                var actionRecordPath = ResolveWorkspaceRelativePath(resolvedWorkspaceRoot, actionRecordReference);
                if (!File.Exists(actionRecordPath))
                {
                    return Failed("The admin authority record could not be found.");
                }

                var actionRecordBytes = File.ReadAllBytes(actionRecordPath);
                var actionRecordHash = ComputeSha256(actionRecordBytes);
                if (evidenceReferences.TryGetValue("admin_authority_record_sha256", out var expectedActionRecordHash)
                    && !string.IsNullOrWhiteSpace(expectedActionRecordHash)
                    && !string.Equals(actionRecordHash, expectedActionRecordHash.Trim(), StringComparison.OrdinalIgnoreCase))
                {
                    return Failed("The admin authority record hash does not match evidence.");
                }

                using var document = JsonDocument.Parse(File.ReadAllText(actionRecordPath));
                var root = document.RootElement;
                if (!Matches(root, "record_type", "passport_admin_dual_control_action"))
                {
                    return Failed("The authority evidence is not a dual-control admin authority record.");
                }

                var normalizedExpectedActionType = NormalizeActionType(expectedActionType);
                if (!Matches(root, "release_lane", releaseLane.Lane)
                    || !Matches(root, "ledger_namespace", releaseLane.LedgerNamespace))
                {
                    return Failed("The admin authority record belongs to a different release lane or ledger namespace.");
                }

                if (!Matches(root, "action_type", normalizedExpectedActionType))
                {
                    return Failed("The admin authority record action type does not match the requested operation.");
                }

                if (ReadBool(root, "ai_approved"))
                {
                    return Failed("AI cannot approve admin authority records.");
                }

                if (ReadInt64(root, "required_approval_count") < 2 || ReadInt64(root, "approval_count") < 2)
                {
                    return Failed("The admin authority record does not contain dual-control approval.");
                }

                var requesterDeviceId = ReadString(root, "requester_device_id");
                var approverDeviceId = ReadString(root, "approver_device_id");
                var authorityIdentityId = ReadString(root, "authority_identity_id");
                if (string.IsNullOrWhiteSpace(requesterDeviceId)
                    || string.IsNullOrWhiteSpace(approverDeviceId)
                    || string.Equals(requesterDeviceId, approverDeviceId, StringComparison.Ordinal))
                {
                    return Failed("The admin authority record must contain two distinct authorizing devices.");
                }

                if (!string.Equals(ReadString(root, "target_record_sha256"), (expectedTargetRecordSha256 ?? string.Empty).Trim(), StringComparison.OrdinalIgnoreCase))
                {
                    return Failed("The admin authority target record hash does not match the requested operation.");
                }

                if (!string.Equals(ReadString(root, "requested_payload_sha256"), (expectedRequestedPayloadSha256 ?? string.Empty).Trim(), StringComparison.OrdinalIgnoreCase))
                {
                    return Failed("The admin authority requested payload hash does not match the requested operation.");
                }

                var recovery = new PassportRecoveryService(releaseLane);
                if (recovery.IsDeviceDeauthorized(resolvedWorkspaceRoot, authorityIdentityId, requesterDeviceId)
                    || recovery.IsDeviceDeauthorized(resolvedWorkspaceRoot, authorityIdentityId, approverDeviceId))
                {
                    return Failed("The admin authority record includes a deauthorized device.");
                }

                var authorityPolicy = ValidateProductionAuthorityPolicy(
                    resolvedWorkspaceRoot,
                    authorityIdentityId,
                    requesterDeviceId,
                    approverDeviceId,
                    normalizedExpectedActionType,
                    ReadString(root, "authority_scope"));
                if (!authorityPolicy.Succeeded)
                {
                    return authorityPolicy;
                }

                var requesterSignaturePath = ResolveEvidenceSignaturePath(
                    resolvedWorkspaceRoot,
                    actionRecordPath,
                    evidenceReferences,
                    "admin_authority_requester_signature_path",
                    "passport_admin_dual_control_requester_signature");
                var approverSignaturePath = ResolveEvidenceSignaturePath(
                    resolvedWorkspaceRoot,
                    actionRecordPath,
                    evidenceReferences,
                    "admin_authority_approver_signature_path",
                    "passport_admin_dual_control_approver_signature");
                var requesterVerified = ValidateSignatureRecord(
                    resolvedWorkspaceRoot,
                    requesterSignaturePath,
                    "passport_admin_dual_control_requester_signature",
                    actionRecordHash,
                    actionRecordBytes,
                    requesterDeviceId);
                var approverVerified = ValidateSignatureRecord(
                    resolvedWorkspaceRoot,
                    approverSignaturePath,
                    "passport_admin_dual_control_approver_signature",
                    actionRecordHash,
                    actionRecordBytes,
                    approverDeviceId);

                if (!requesterVerified.Succeeded)
                {
                    return requesterVerified;
                }

                if (!approverVerified.Succeeded)
                {
                    return approverVerified;
                }

                return new PassportAdminAuthorityResult
                {
                    Succeeded = true,
                    Message = "Dual-control admin authority evidence is valid.",
                    RecordPath = actionRecordPath,
                    RequesterSignaturePath = requesterSignaturePath,
                    ApproverSignaturePath = approverSignaturePath,
                    RequesterSignatureVerified = true,
                    ApproverSignatureVerified = true
                };
            }
            catch (Exception ex)
            {
                return Failed("Dual-control admin authority validation failed: " + ex.Message);
            }
        }

        public static string ComputeFileSha256(string path)
        {
            return ComputeSha256(File.ReadAllBytes(path));
        }

        private static (string Path, bool Verified) WriteSignature(
            string outputRoot,
            string fileName,
            string recordType,
            string workspaceRoot,
            string actionRecordPath,
            byte[] actionRecordBytes,
            string identityId,
            string deviceId,
            string deviceKeyReferencePath,
            string devicePublicKeyPath)
        {
            var timestamp = DateTime.UtcNow.ToString("yyyyMMddTHHmmssZ");
            var createdUtc = DateTime.UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ");
            var signatureBytes = PassportDeviceKeyStore.SignData(deviceKeyReferencePath, actionRecordBytes);
            var verified = VerifySignature(devicePublicKeyPath, actionRecordBytes, signatureBytes);
            var signaturePath = Path.Combine(outputRoot, fileName);
            var signatureRecord = new Dictionary<string, object?>
            {
                ["schema_version"] = 1,
                ["record_type"] = recordType,
                ["record_id"] = timestamp + "-" + recordType,
                ["created_utc"] = createdUtc,
                ["archrealms_identity_id"] = identityId,
                ["device_id"] = deviceId,
                ["admin_action_record_path"] = ToWorkspaceRelativePath(workspaceRoot, actionRecordPath),
                ["admin_action_record_sha256"] = ComputeSha256(actionRecordBytes),
                ["signature_algorithm"] = "RSA_PKCS1_SHA256",
                ["signature_base64"] = Convert.ToBase64String(signatureBytes),
                ["device_public_key_path"] = ToWorkspaceRelativePath(workspaceRoot, devicePublicKeyPath),
                ["verified_with_device_key"] = verified,
                ["summary"] = "Signature for a dual-control Passport admin authority record."
            };
            File.WriteAllText(signaturePath, JsonSerializer.Serialize(signatureRecord, JsonOptions), Encoding.UTF8);
            return (signaturePath, verified);
        }

        private static (string Path, bool Verified) WriteRoleMembershipSignature(
            string outputRoot,
            string fileName,
            string workspaceRoot,
            string roleMembershipRecordPath,
            byte[] roleMembershipRecordBytes,
            string identityId,
            string issuerDeviceId,
            string issuerDeviceKeyReferencePath,
            string issuerDevicePublicKeyPath)
        {
            var timestamp = DateTime.UtcNow.ToString("yyyyMMddTHHmmssZ");
            var createdUtc = DateTime.UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ");
            var signatureBytes = PassportDeviceKeyStore.SignData(issuerDeviceKeyReferencePath, roleMembershipRecordBytes);
            var verified = VerifySignature(issuerDevicePublicKeyPath, roleMembershipRecordBytes, signatureBytes);
            var signaturePath = Path.Combine(outputRoot, fileName);
            var signatureRecord = new Dictionary<string, object?>
            {
                ["schema_version"] = 1,
                ["record_type"] = "passport_admin_authority_role_membership_signature",
                ["record_id"] = timestamp + "-passport_admin_authority_role_membership_signature",
                ["created_utc"] = createdUtc,
                ["archrealms_identity_id"] = identityId,
                ["issuer_device_id"] = issuerDeviceId,
                ["role_membership_record_path"] = ToWorkspaceRelativePath(workspaceRoot, roleMembershipRecordPath),
                ["role_membership_record_sha256"] = ComputeSha256(roleMembershipRecordBytes),
                ["signature_algorithm"] = "RSA_PKCS1_SHA256",
                ["signature_base64"] = Convert.ToBase64String(signatureBytes),
                ["issuer_device_public_key_path"] = ToWorkspaceRelativePath(workspaceRoot, issuerDevicePublicKeyPath),
                ["verified_with_device_key"] = verified,
                ["summary"] = "Signature for a Passport admin authority role membership record."
            };
            File.WriteAllText(signaturePath, JsonSerializer.Serialize(signatureRecord, JsonOptions), Encoding.UTF8);
            return (signaturePath, verified);
        }

        private PassportAdminAuthorityResult ValidateProductionAuthorityPolicy(
            string workspaceRoot,
            string authorityIdentityId,
            string requesterDeviceId,
            string approverDeviceId,
            string actionType,
            string authorityScope)
        {
            if (!releaseLane.ProductionLedger)
            {
                return new PassportAdminAuthorityResult
                {
                    Succeeded = true,
                    Message = "Non-production admin role policy is advisory."
                };
            }

            var identityGate = ValidateCrownAuthorityIdentity(authorityIdentityId);
            if (!identityGate.Succeeded)
            {
                return identityGate;
            }

            var requesterRole = FindActiveAdminRoleMembership(
                workspaceRoot,
                authorityIdentityId,
                requesterDeviceId,
                actionType,
                authorityScope);
            if (!requesterRole.Succeeded)
            {
                return Failed("Requester device is not assigned an active admin authority role for this action: " + requesterRole.Message);
            }

            var approverRole = FindActiveAdminRoleMembership(
                workspaceRoot,
                authorityIdentityId,
                approverDeviceId,
                actionType,
                authorityScope);
            if (!approverRole.Succeeded)
            {
                return Failed("Approver device is not assigned an active admin authority role for this action: " + approverRole.Message);
            }

            return new PassportAdminAuthorityResult
            {
                Succeeded = true,
                Message = "Production admin authority role policy is valid."
            };
        }

        private PassportAdminAuthorityResult ValidateCrownAuthorityIdentity(string authorityIdentityId)
        {
            if (!releaseLane.ProductionLedger)
            {
                return new PassportAdminAuthorityResult
                {
                    Succeeded = true,
                    Message = "Non-production Crown authority identity policy is advisory."
                };
            }

            if (string.IsNullOrWhiteSpace(releaseLane.CrownAuthorityIdentityId))
            {
                return Failed("Production admin authority requires crown_authority_identity_id in the release-lane manifest.");
            }

            if (!string.Equals(
                (authorityIdentityId ?? string.Empty).Trim(),
                releaseLane.CrownAuthorityIdentityId.Trim(),
                StringComparison.Ordinal))
            {
                return Failed("Production admin authority must be issued by the configured Crown authority identity.");
            }

            return new PassportAdminAuthorityResult
            {
                Succeeded = true,
                Message = "Crown authority identity policy is valid."
            };
        }

        private PassportAdminAuthorityResult FindActiveAdminRoleMembership(
            string workspaceRoot,
            string authorityIdentityId,
            string deviceId,
            string actionType,
            string authorityScope)
        {
            var roleRoot = Path.Combine(workspaceRoot, "records", "passport", "admin-authority", "roles");
            if (!Directory.Exists(roleRoot))
            {
                return Failed("No admin role membership records were found.");
            }

            foreach (var candidate in Directory.GetFiles(roleRoot, "*.json").OrderByDescending(Path.GetFileName))
            {
                using var document = JsonDocument.Parse(File.ReadAllText(candidate));
                var root = document.RootElement.Clone();
                if (!Matches(root, "record_type", "passport_admin_authority_role_membership")
                    || !Matches(root, "status", "active")
                    || !Matches(root, "release_lane", releaseLane.Lane)
                    || !Matches(root, "ledger_namespace", releaseLane.LedgerNamespace)
                    || !Matches(root, "authority_identity_id", authorityIdentityId)
                    || !Matches(root, "device_id", deviceId)
                    || !ReadBool(root, "dual_control_eligible")
                    || ReadBool(root, "ai_approved")
                    || IsExpired(root)
                    || !AuthorizedArrayContains(root, "authorized_action_types", NormalizeActionAuthorization(actionType))
                    || !AuthorizedArrayContains(root, "authorized_authority_scopes", NormalizeScopeAuthorization(authorityScope)))
                {
                    continue;
                }

                var signature = ValidateRoleMembershipSignature(workspaceRoot, candidate, File.ReadAllBytes(candidate), ReadString(root, "issued_by_device_id"));
                if (!signature.Succeeded)
                {
                    return signature;
                }

                return new PassportAdminAuthorityResult
                {
                    Succeeded = true,
                    Message = "Admin role membership is active."
                };
            }

            return Failed("No active role membership permits " + actionType + " for " + authorityScope + ".");
        }

        private PassportAdminAuthorityResult ValidateRoleMembershipSignature(
            string workspaceRoot,
            string roleMembershipRecordPath,
            byte[] roleMembershipRecordBytes,
            string expectedIssuerDeviceId)
        {
            var roleMembershipHash = ComputeSha256(roleMembershipRecordBytes);
            var signatureRoot = Path.GetDirectoryName(roleMembershipRecordPath) ?? workspaceRoot;
            foreach (var candidate in Directory.GetFiles(signatureRoot, "*.json").OrderBy(path => path, StringComparer.OrdinalIgnoreCase))
            {
                if (string.Equals(candidate, roleMembershipRecordPath, StringComparison.OrdinalIgnoreCase))
                {
                    continue;
                }

                using var document = JsonDocument.Parse(File.ReadAllText(candidate));
                var root = document.RootElement.Clone();
                if (!Matches(root, "record_type", "passport_admin_authority_role_membership_signature")
                    || !Matches(root, "issuer_device_id", expectedIssuerDeviceId)
                    || !string.Equals(ReadString(root, "role_membership_record_sha256"), roleMembershipHash, StringComparison.OrdinalIgnoreCase))
                {
                    continue;
                }

                var publicKeyPath = ResolveWorkspaceRelativePath(workspaceRoot, ReadString(root, "issuer_device_public_key_path"));
                if (!File.Exists(publicKeyPath))
                {
                    return Failed("The admin role membership issuer public key could not be found.");
                }

                var signatureBase64 = ReadString(root, "signature_base64");
                if (string.IsNullOrWhiteSpace(signatureBase64))
                {
                    return Failed("The admin role membership signature is missing.");
                }

                var signatureBytes = Convert.FromBase64String(signatureBase64);
                if (!VerifySignature(publicKeyPath, roleMembershipRecordBytes, signatureBytes))
                {
                    return Failed("The admin role membership signature verification failed.");
                }

                return new PassportAdminAuthorityResult
                {
                    Succeeded = true,
                    Message = "Admin role membership signature verified."
                };
            }

            return Failed("An admin role membership signature could not be found.");
        }

        private static string ResolveEvidenceSignaturePath(
            string workspaceRoot,
            string actionRecordPath,
            IDictionary<string, string> evidenceReferences,
            string evidenceKey,
            string recordType)
        {
            if (evidenceReferences.TryGetValue(evidenceKey, out var signatureReference)
                && !string.IsNullOrWhiteSpace(signatureReference))
            {
                return ResolveWorkspaceRelativePath(workspaceRoot, signatureReference);
            }

            var signatureRoot = Path.GetDirectoryName(actionRecordPath) ?? workspaceRoot;
            foreach (var candidate in Directory.GetFiles(signatureRoot, "*.json").OrderBy(path => path, StringComparer.OrdinalIgnoreCase))
            {
                if (string.Equals(candidate, actionRecordPath, StringComparison.OrdinalIgnoreCase))
                {
                    continue;
                }

                using var document = JsonDocument.Parse(File.ReadAllText(candidate));
                if (Matches(document.RootElement, "record_type", recordType))
                {
                    return candidate;
                }
            }

            return string.Empty;
        }

        private static PassportAdminAuthorityResult ValidateSignatureRecord(
            string workspaceRoot,
            string signaturePath,
            string expectedRecordType,
            string expectedActionRecordHash,
            byte[] actionRecordBytes,
            string expectedDeviceId)
        {
            if (string.IsNullOrWhiteSpace(signaturePath) || !File.Exists(signaturePath))
            {
                return Failed("A required admin authority signature record could not be found.");
            }

            using var document = JsonDocument.Parse(File.ReadAllText(signaturePath));
            var root = document.RootElement;
            if (!Matches(root, "record_type", expectedRecordType))
            {
                return Failed("The admin authority signature record type is invalid.");
            }

            if (!Matches(root, "device_id", expectedDeviceId))
            {
                return Failed("The admin authority signature was made by an unexpected device.");
            }

            if (!string.Equals(ReadString(root, "admin_action_record_sha256"), expectedActionRecordHash, StringComparison.OrdinalIgnoreCase))
            {
                return Failed("The admin authority signature does not reference the expected action record hash.");
            }

            var publicKeyPath = ResolveWorkspaceRelativePath(workspaceRoot, ReadString(root, "device_public_key_path"));
            if (!File.Exists(publicKeyPath))
            {
                return Failed("The admin authority signature public key could not be found.");
            }

            var signatureBase64 = ReadString(root, "signature_base64");
            if (string.IsNullOrWhiteSpace(signatureBase64))
            {
                return Failed("The admin authority signature is missing.");
            }

            var signatureBytes = Convert.FromBase64String(signatureBase64);
            if (!VerifySignature(publicKeyPath, actionRecordBytes, signatureBytes))
            {
                return Failed("The admin authority signature verification failed.");
            }

            return new PassportAdminAuthorityResult
            {
                Succeeded = true,
                Message = "Admin authority signature verified."
            };
        }

        private static (string RecordPath, JsonElement RootElement)? FindLatestDeviceRecord(
            string workspaceRoot,
            string identityId,
            string deviceId,
            string requiredStatus)
        {
            var deviceRoot = Path.Combine(workspaceRoot, "records", "registry", "device-credentials");
            if (!Directory.Exists(deviceRoot))
            {
                return null;
            }

            foreach (var file in Directory.GetFiles(deviceRoot, "*.json").OrderByDescending(Path.GetFileName))
            {
                using var document = JsonDocument.Parse(File.ReadAllText(file));
                var root = document.RootElement.Clone();
                if (Matches(root, "record_type", "device_credential_record")
                    && Matches(root, "status", requiredStatus)
                    && Matches(root, "archrealms_identity_id", identityId)
                    && Matches(root, "device_id", deviceId))
                {
                    return (file, root);
                }
            }

            return null;
        }

        private static string ResolvePublicKeyPath(string workspaceRoot, JsonElement deviceRecord)
        {
            if (!TryGetString(deviceRecord, "public_key_path", out var publicKeyRelative))
            {
                return string.Empty;
            }

            return Path.Combine(workspaceRoot, publicKeyRelative.Replace('/', Path.DirectorySeparatorChar));
        }

        private static bool VerifySignature(string publicKeyPath, byte[] data, byte[] signatureBytes)
        {
            using var rsa = RSA.Create();
            rsa.ImportSubjectPublicKeyInfo(File.ReadAllBytes(publicKeyPath), out _);
            return rsa.VerifyData(data, signatureBytes, HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1);
        }

        private static bool Matches(JsonElement root, string propertyName, string expected)
        {
            return TryGetString(root, propertyName, out var actual)
                && string.Equals(actual, expected, StringComparison.Ordinal);
        }

        private static bool TryGetString(JsonElement root, string propertyName, out string value)
        {
            if (root.TryGetProperty(propertyName, out var element))
            {
                value = element.GetString() ?? string.Empty;
                return true;
            }

            value = string.Empty;
            return false;
        }

        private static string ReadString(JsonElement root, string propertyName)
        {
            return TryGetString(root, propertyName, out var value) ? value : string.Empty;
        }

        private static long ReadInt64(JsonElement root, string propertyName)
        {
            return root.TryGetProperty(propertyName, out var property) && property.TryGetInt64(out var value) ? value : 0;
        }

        private static bool ReadBool(JsonElement root, string propertyName)
        {
            return root.TryGetProperty(propertyName, out var property) && property.ValueKind == JsonValueKind.True;
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

        private static string NormalizeActionType(string actionType)
        {
            var normalized = NormalizeRequired(actionType, "action type").Trim().ToLowerInvariant().Replace(" ", "_").Replace("-", "_");
            return normalized switch
            {
                "cc_issue" => normalized,
                "ledger_correction" => normalized,
                "wallet_revocation" => normalized,
                "device_revocation" => normalized,
                "recovery_override" => normalized,
                "escrow_release" => normalized,
                "burn_override" => normalized,
                "storage_recredit" => normalized,
                "service_extension" => normalized,
                "telemetry_access" => normalized,
                _ => throw new InvalidOperationException("Unsupported admin action type: " + actionType)
            };
        }

        private static string[] NormalizeAuthorizationList(
            IEnumerable<string> values,
            Func<string, string> normalize)
        {
            var normalized = (values ?? Array.Empty<string>())
                .Select(normalize)
                .Where(value => !string.IsNullOrWhiteSpace(value))
                .Distinct(StringComparer.Ordinal)
                .ToArray();

            if (normalized.Length == 0)
            {
                throw new InvalidOperationException("At least one admin role authorization value is required.");
            }

            return normalized;
        }

        private static string NormalizeActionAuthorization(string actionType)
        {
            var normalized = (actionType ?? string.Empty).Trim();
            return string.Equals(normalized, "*", StringComparison.Ordinal)
                ? "*"
                : NormalizeActionType(normalized);
        }

        private static string NormalizeScopeAuthorization(string authorityScope)
        {
            var normalized = NormalizeRequired(authorityScope, "authority scope").Trim().ToLowerInvariant().Replace(" ", "_").Replace("-", "_");
            return normalized.Length > 96 ? normalized[..96] : normalized;
        }

        private static string NormalizeReasonCode(string reasonCode)
        {
            var normalized = NormalizeRequired(reasonCode, "reason code").Trim().ToLowerInvariant().Replace(" ", "_").Replace("-", "_");
            return normalized.Length > 64 ? normalized[..64] : normalized;
        }

        private static bool AuthorizedArrayContains(JsonElement root, string propertyName, string expected)
        {
            if (!root.TryGetProperty(propertyName, out var property) || property.ValueKind != JsonValueKind.Array)
            {
                return false;
            }

            foreach (var item in property.EnumerateArray())
            {
                if (item.ValueKind != JsonValueKind.String)
                {
                    continue;
                }

                var value = item.GetString() ?? string.Empty;
                if (string.Equals(value, "*", StringComparison.Ordinal)
                    || string.Equals(value, expected, StringComparison.Ordinal))
                {
                    return true;
                }
            }

            return false;
        }

        private static bool IsExpired(JsonElement root)
        {
            var expiresUtc = ReadString(root, "expires_utc");
            if (string.IsNullOrWhiteSpace(expiresUtc))
            {
                return false;
            }

            return DateTime.TryParse(expiresUtc, out var expires)
                && expires.ToUniversalTime() <= DateTime.UtcNow;
        }

        private static string ToWorkspaceRelativePath(string workspaceRoot, string path)
        {
            var normalizedRoot = Path.GetFullPath(workspaceRoot).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
            var normalizedPath = Path.GetFullPath(path);
            if (!normalizedPath.StartsWith(normalizedRoot, StringComparison.OrdinalIgnoreCase))
            {
                return path.Replace(Path.DirectorySeparatorChar, '/');
            }

            var relative = normalizedPath.Substring(normalizedRoot.Length).TrimStart(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
            return relative.Replace(Path.DirectorySeparatorChar, '/');
        }

        private static string ResolveWorkspaceRelativePath(string workspaceRoot, string path)
        {
            var normalized = path.Replace('/', Path.DirectorySeparatorChar);
            return Path.IsPathRooted(normalized)
                ? Path.GetFullPath(normalized)
                : Path.GetFullPath(Path.Combine(workspaceRoot, normalized));
        }

        private static string ComputeSha256(byte[] value)
        {
            return Convert.ToHexString(SHA256.HashData(value)).ToLowerInvariant();
        }

        private static PassportAdminAuthorityResult Failed(string message)
        {
            return new PassportAdminAuthorityResult
            {
                Succeeded = false,
                Message = message
            };
        }

        private static PassportAdminRoleMembershipResult FailedRoleMembership(string message)
        {
            return new PassportAdminRoleMembershipResult
            {
                Succeeded = false,
                Message = message
            };
        }
    }
}
