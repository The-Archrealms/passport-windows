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
    public sealed class PassportStorageRedemptionService
    {
        private static readonly JsonSerializerOptions JsonOptions = new JsonSerializerOptions
        {
            WriteIndented = true
        };

        private readonly PassportReleaseLane releaseLane;

        public PassportStorageRedemptionService(PassportReleaseLane? releaseLane = null)
        {
            this.releaseLane = releaseLane ?? PassportEnvironment.GetReleaseLane();
        }

        public PassportStorageRedemptionResult CreateQuote(
            string workspaceRoot,
            string accountId,
            string identityId,
            string walletKeyId,
            long storageGb,
            int serviceEpochCount,
            long ccPerGbEpochBaseUnits,
            DateTime expiresUtc,
            string serviceClass,
            string quoteSource)
        {
            try
            {
                var resolvedWorkspaceRoot = PassportEnvironment.ResolveWorkspaceRoot(workspaceRoot);
                if (storageGb <= 0 || serviceEpochCount <= 0 || ccPerGbEpochBaseUnits <= 0)
                {
                    return Failed("Storage quote requires positive storage, epoch count, and CC rate.");
                }

                if (expiresUtc.ToUniversalTime() <= DateTime.UtcNow)
                {
                    return Failed("Storage quote expiration must be in the future.");
                }

                var quoteId = DateTime.UtcNow.ToString("yyyyMMddTHHmmssZ") + "-storage-quote-" + Guid.NewGuid().ToString("N")[..10];
                var root = Path.Combine(resolvedWorkspaceRoot, "records", "passport", "monetary", "storage-redemptions", "quotes");
                Directory.CreateDirectory(root);
                var path = Path.Combine(root, quoteId + ".json");
                var total = checked(storageGb * serviceEpochCount * ccPerGbEpochBaseUnits);
                var record = new Dictionary<string, object?>
                {
                    ["schema_version"] = 1,
                    ["record_type"] = "passport_storage_redemption_quote",
                    ["record_id"] = quoteId,
                    ["quote_id"] = quoteId,
                    ["created_utc"] = DateTime.UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ"),
                    ["expires_utc"] = expiresUtc.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ"),
                    ["release_lane"] = releaseLane.Lane,
                    ["ledger_namespace"] = releaseLane.LedgerNamespace,
                    ["policy_version"] = releaseLane.PolicyVersion,
                    ["account_id"] = NormalizeRequired(accountId, "account ID"),
                    ["archrealms_identity_id"] = NormalizeRequired(identityId, "identity ID"),
                    ["wallet_key_id"] = NormalizeRequired(walletKeyId, "wallet key ID"),
                    ["service_class"] = NormalizeRequired(serviceClass, "service class"),
                    ["storage_gb"] = storageGb,
                    ["service_epoch_count"] = serviceEpochCount,
                    ["cc_per_gb_epoch_base_units"] = ccPerGbEpochBaseUnits,
                    ["total_cc_base_units"] = total,
                    ["quote_source"] = NormalizeRequired(quoteSource, "quote source"),
                    ["capacity_or_liquidity_limited"] = true,
                    ["execution_status"] = "quote_only_not_accepted",
                    ["summary"] = "CC storage redemption quote. CC is escrowed on acceptance and burned only as verified service epochs complete."
                };
                File.WriteAllText(path, JsonSerializer.Serialize(record, JsonOptions), Encoding.UTF8);
                return Success("Storage redemption quote created.", quoteId, path, string.Empty, string.Empty);
            }
            catch (Exception ex)
            {
                return Failed("Storage redemption quote failed: " + ex.Message);
            }
        }

        public PassportStorageRedemptionResult AcceptQuote(
            string workspaceRoot,
            string quotePath,
            string quoteSha256,
            string walletKeyReferencePath,
            string walletPublicKeyPath)
        {
            try
            {
                var resolvedWorkspaceRoot = PassportEnvironment.ResolveWorkspaceRoot(workspaceRoot);
                var quote = ReadAndValidateQuote(resolvedWorkspaceRoot, quotePath, quoteSha256);
                if (!quote.Succeeded)
                {
                    return quote;
                }

                using var document = JsonDocument.Parse(File.ReadAllText(quote.RecordPath));
                var root = document.RootElement;
                var redemptionId = DateTime.UtcNow.ToString("yyyyMMddTHHmmssZ") + "-storage-redemption-" + Guid.NewGuid().ToString("N")[..10];
                var evidence = new Dictionary<string, string>
                {
                    ["storage_quote_id"] = ReadString(root, "quote_id"),
                    ["storage_quote_path"] = quote.RecordPath,
                    ["storage_quote_sha256"] = quote.RecordSha256,
                    ["storage_redemption_id"] = redemptionId
                };
                var ledger = new PassportMonetaryLedgerService(releaseLane);
                var escrow = ledger.AppendEvent(
                    resolvedWorkspaceRoot,
                    ReadString(root, "account_id"),
                    ReadString(root, "archrealms_identity_id"),
                    ReadString(root, "wallet_key_id"),
                    PassportMonetaryLedgerService.EventCrownCreditEscrow,
                    PassportMonetaryLedgerService.AssetCrownCredit,
                    ReadInt64(root, "total_cc_base_units"),
                    evidence,
                    walletKeyReferencePath: walletKeyReferencePath,
                    walletPublicKeyPath: walletPublicKeyPath);
                if (!escrow.Succeeded)
                {
                    return Failed("Storage redemption escrow failed: " + escrow.Message);
                }

                var recordPath = WriteSignedRecord(
                    resolvedWorkspaceRoot,
                    "accepted",
                    redemptionId,
                    root,
                    quote,
                    escrow,
                    walletKeyReferencePath,
                    walletPublicKeyPath,
                    new Dictionary<string, object?>
                    {
                        ["accepted_utc"] = DateTime.UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ"),
                        ["service_class"] = ReadString(root, "service_class"),
                        ["storage_gb"] = ReadInt64(root, "storage_gb"),
                        ["service_epoch_count"] = ReadInt64(root, "service_epoch_count"),
                        ["cc_per_gb_epoch_base_units"] = ReadInt64(root, "cc_per_gb_epoch_base_units"),
                        ["total_cc_base_units"] = ReadInt64(root, "total_cc_base_units"),
                        ["escrow_cc_base_units"] = ReadInt64(root, "total_cc_base_units"),
                        ["failed_epoch_remedy"] = "automatic_cc_recredit_or_service_extension"
                    });
                return Success("Storage redemption accepted and escrowed.", redemptionId, recordPath, escrow.EventPath, escrow.EventHashSha256);
            }
            catch (Exception ex)
            {
                return Failed("Storage redemption acceptance failed: " + ex.Message);
            }
        }

        public PassportStorageRedemptionResult BurnVerifiedEpoch(
            string workspaceRoot,
            string acceptedRedemptionPath,
            long burnCcBaseUnits,
            long verifiedGbDays,
            string proofRecordPath,
            string proofRecordSha256,
            string walletKeyReferencePath,
            string walletPublicKeyPath)
        {
            try
            {
                var resolvedWorkspaceRoot = PassportEnvironment.ResolveWorkspaceRoot(workspaceRoot);
                if (burnCcBaseUnits <= 0 || verifiedGbDays <= 0)
                {
                    return Failed("Storage epoch burn requires positive CC burn and verified GB-days.");
                }

                var acceptedPath = ResolveWorkspaceRelativePath(resolvedWorkspaceRoot, acceptedRedemptionPath);
                if (!File.Exists(acceptedPath))
                {
                    return Failed("Accepted storage redemption record could not be found.");
                }

                using var document = JsonDocument.Parse(File.ReadAllText(acceptedPath));
                var accepted = document.RootElement;
                if (!Matches(accepted, "record_type", "passport_storage_redemption_accepted"))
                {
                    return Failed("Storage burn requires an accepted redemption record.");
                }

                if (!HasVerifiedWalletSignature(accepted))
                {
                    return Failed("Storage burn requires a signed accepted redemption record.");
                }

                var quoteTerms = ReadAcceptedQuoteTerms(resolvedWorkspaceRoot, accepted);
                if (!quoteTerms.Succeeded)
                {
                    return Failed(quoteTerms.Message);
                }

                var proofPath = ResolveWorkspaceRelativePath(resolvedWorkspaceRoot, proofRecordPath);
                if (!File.Exists(proofPath))
                {
                    return Failed("Storage proof record could not be found.");
                }

                var actualProofHash = ComputeSha256(File.ReadAllBytes(proofPath));
                if (!string.Equals(actualProofHash, proofRecordSha256, StringComparison.OrdinalIgnoreCase))
                {
                    return Failed("Storage proof hash does not match burn evidence.");
                }

                var proofAcceptance = ValidateStorageProofForBurn(resolvedWorkspaceRoot, proofPath, accepted, quoteTerms, verifiedGbDays);
                if (!proofAcceptance.Succeeded)
                {
                    return Failed("Storage proof package rejected: " + proofAcceptance.Message);
                }

                var burnedSoFar = SumRecords(resolvedWorkspaceRoot, ReadString(accepted, "redemption_id"), "passport_storage_redemption_epoch_burn", "burn_cc_base_units");
                var refundedSoFar = SumRecords(resolvedWorkspaceRoot, ReadString(accepted, "redemption_id"), "passport_storage_redemption_refund", "refund_cc_base_units");
                var escrowTotal = ReadInt64(accepted, "escrow_cc_base_units");
                var remainingEscrow = escrowTotal - burnedSoFar - refundedSoFar;
                if (burnCcBaseUnits > remainingEscrow)
                {
                    return Failed("Storage burn exceeds remaining escrow.");
                }

                var expectedBurn = CalculateExpectedBurn(verifiedGbDays, quoteTerms.CcPerGbEpochBaseUnits, remainingEscrow);
                if (burnCcBaseUnits != expectedBurn)
                {
                    return Failed("Storage burn must equal verified GB-days multiplied by the accepted quote rate, capped by remaining escrow.");
                }

                var burnId = DateTime.UtcNow.ToString("yyyyMMddTHHmmssZ") + "-storage-burn-" + Guid.NewGuid().ToString("N")[..10];
                var evidence = new Dictionary<string, string>
                {
                    ["storage_redemption_id"] = ReadString(accepted, "redemption_id"),
                    ["storage_accepted_redemption_path"] = acceptedPath,
                    ["storage_proof_record_path"] = proofPath,
                    ["storage_proof_record_sha256"] = actualProofHash,
                    ["storage_burn_id"] = burnId,
                    ["storage_proof_acceptance_rule"] = "mvp_storage_epoch_burn_v1",
                    ["storage_verified_gb_days"] = verifiedGbDays.ToString(),
                    ["storage_quote_rate_cc_per_gb_epoch_base_units"] = quoteTerms.CcPerGbEpochBaseUnits.ToString()
                };
                var burn = new PassportMonetaryLedgerService(releaseLane).AppendEvent(
                    resolvedWorkspaceRoot,
                    ReadString(accepted, "account_id"),
                    ReadString(accepted, "archrealms_identity_id"),
                    ReadString(accepted, "wallet_key_id"),
                    PassportMonetaryLedgerService.EventCrownCreditBurn,
                    PassportMonetaryLedgerService.AssetCrownCredit,
                    burnCcBaseUnits,
                    evidence,
                    walletKeyReferencePath: walletKeyReferencePath,
                    walletPublicKeyPath: walletPublicKeyPath);
                if (!burn.Succeeded)
                {
                    return Failed("Storage burn ledger event failed: " + burn.Message);
                }

                var recordPath = WriteSignedRecord(
                    resolvedWorkspaceRoot,
                    "epoch-burn",
                    burnId,
                    accepted,
                    null,
                    burn,
                    walletKeyReferencePath,
                    walletPublicKeyPath,
                    new Dictionary<string, object?>
                    {
                        ["burn_cc_base_units"] = burnCcBaseUnits,
                        ["verified_gb_days"] = verifiedGbDays,
                        ["cc_per_gb_epoch_base_units"] = quoteTerms.CcPerGbEpochBaseUnits,
                        ["burn_formula"] = "burn_cc_base_units=verified_gb_days*cc_per_gb_epoch_base_units capped by remaining escrow",
                        ["proof_record_path"] = ToWorkspaceRelativePath(resolvedWorkspaceRoot, proofPath),
                        ["proof_record_sha256"] = actualProofHash,
                        ["proof_acceptance"] = proofAcceptance.ToRecord()
                    });
                return Success("Storage epoch burn recorded.", burnId, recordPath, burn.EventPath, burn.EventHashSha256);
            }
            catch (Exception ex)
            {
                return Failed("Storage epoch burn failed: " + ex.Message);
            }
        }

        public PassportStorageRedemptionResult RefundRemaining(
            string workspaceRoot,
            string acceptedRedemptionPath,
            long refundCcBaseUnits,
            string reasonCode,
            string walletKeyReferencePath,
            string walletPublicKeyPath)
        {
            try
            {
                var resolvedWorkspaceRoot = PassportEnvironment.ResolveWorkspaceRoot(workspaceRoot);
                if (refundCcBaseUnits <= 0)
                {
                    return Failed("Storage refund requires a positive CC amount.");
                }

                var acceptedPath = ResolveWorkspaceRelativePath(resolvedWorkspaceRoot, acceptedRedemptionPath);
                if (!File.Exists(acceptedPath))
                {
                    return Failed("Accepted storage redemption record could not be found.");
                }

                using var document = JsonDocument.Parse(File.ReadAllText(acceptedPath));
                var accepted = document.RootElement;
                var redemptionId = ReadString(accepted, "redemption_id");
                var burnedSoFar = SumRecords(resolvedWorkspaceRoot, redemptionId, "passport_storage_redemption_epoch_burn", "burn_cc_base_units");
                var refundedSoFar = SumRecords(resolvedWorkspaceRoot, redemptionId, "passport_storage_redemption_refund", "refund_cc_base_units");
                var escrowTotal = ReadInt64(accepted, "escrow_cc_base_units");
                if (burnedSoFar + refundedSoFar + refundCcBaseUnits > escrowTotal)
                {
                    return Failed("Storage refund exceeds remaining escrow.");
                }

                var refundId = DateTime.UtcNow.ToString("yyyyMMddTHHmmssZ") + "-storage-refund-" + Guid.NewGuid().ToString("N")[..10];
                var evidence = new Dictionary<string, string>
                {
                    ["storage_redemption_id"] = redemptionId,
                    ["storage_accepted_redemption_path"] = acceptedPath,
                    ["storage_refund_id"] = refundId,
                    ["storage_refund_reason_code"] = NormalizeReasonCode(reasonCode)
                };
                var refund = new PassportMonetaryLedgerService(releaseLane).AppendEvent(
                    resolvedWorkspaceRoot,
                    ReadString(accepted, "account_id"),
                    ReadString(accepted, "archrealms_identity_id"),
                    ReadString(accepted, "wallet_key_id"),
                    PassportMonetaryLedgerService.EventCrownCreditRefund,
                    PassportMonetaryLedgerService.AssetCrownCredit,
                    refundCcBaseUnits,
                    evidence,
                    walletKeyReferencePath: walletKeyReferencePath,
                    walletPublicKeyPath: walletPublicKeyPath);
                if (!refund.Succeeded)
                {
                    return Failed("Storage refund ledger event failed: " + refund.Message);
                }

                var recordPath = WriteSignedRecord(
                    resolvedWorkspaceRoot,
                    "refund",
                    refundId,
                    accepted,
                    null,
                    refund,
                    walletKeyReferencePath,
                    walletPublicKeyPath,
                    new Dictionary<string, object?>
                    {
                        ["refund_cc_base_units"] = refundCcBaseUnits,
                        ["reason_code"] = NormalizeReasonCode(reasonCode)
                    });
                return Success("Storage redemption refund recorded.", refundId, recordPath, refund.EventPath, refund.EventHashSha256);
            }
            catch (Exception ex)
            {
                return Failed("Storage redemption refund failed: " + ex.Message);
            }
        }

        public PassportStorageRedemptionResult RecreditFailedEpochByAdmin(
            string workspaceRoot,
            string acceptedRedemptionPath,
            long recreditCcBaseUnits,
            string reasonCode,
            string failureEvidencePath,
            string failureEvidenceSha256,
            IDictionary<string, string> adminAuthorityEvidence)
        {
            try
            {
                var resolvedWorkspaceRoot = PassportEnvironment.ResolveWorkspaceRoot(workspaceRoot);
                if (recreditCcBaseUnits <= 0)
                {
                    return Failed("Storage re-credit requires a positive CC amount.");
                }

                var acceptedPath = ResolveWorkspaceRelativePath(resolvedWorkspaceRoot, acceptedRedemptionPath);
                if (!File.Exists(acceptedPath))
                {
                    return Failed("Accepted storage redemption record could not be found.");
                }

                var evidencePath = ResolveWorkspaceRelativePath(resolvedWorkspaceRoot, failureEvidencePath);
                if (!File.Exists(evidencePath))
                {
                    return Failed("Storage failure evidence record could not be found.");
                }

                var actualFailureEvidenceHash = ComputeSha256(File.ReadAllBytes(evidencePath));
                if (!string.Equals(actualFailureEvidenceHash, failureEvidenceSha256, StringComparison.OrdinalIgnoreCase))
                {
                    return Failed("Storage failure evidence hash does not match re-credit evidence.");
                }

                using var document = JsonDocument.Parse(File.ReadAllText(acceptedPath));
                var accepted = document.RootElement;
                if (!Matches(accepted, "record_type", "passport_storage_redemption_accepted"))
                {
                    return Failed("Storage re-credit requires an accepted redemption record.");
                }

                if (!HasVerifiedWalletSignature(accepted))
                {
                    return Failed("Storage re-credit requires a signed accepted redemption record.");
                }

                var acceptedHash = ComputeSha256(File.ReadAllBytes(acceptedPath));
                var intentHash = ComputeStorageRecreditIntentHash(
                    releaseLane,
                    ReadString(accepted, "account_id"),
                    ReadString(accepted, "archrealms_identity_id"),
                    ReadString(accepted, "wallet_key_id"),
                    recreditCcBaseUnits,
                    reasonCode,
                    acceptedHash,
                    actualFailureEvidenceHash);
                var authority = new PassportAdminAuthorityService(releaseLane).ValidateDualControlActionEvidence(
                    resolvedWorkspaceRoot,
                    adminAuthorityEvidence,
                    "storage_recredit",
                    acceptedHash,
                    intentHash);
                if (!authority.Succeeded)
                {
                    return Failed(authority.Message);
                }

                var redemptionId = ReadString(accepted, "redemption_id");
                var burnedSoFar = SumRecords(resolvedWorkspaceRoot, redemptionId, "passport_storage_redemption_epoch_burn", "burn_cc_base_units")
                    + SumRecords(resolvedWorkspaceRoot, redemptionId, "passport_storage_redemption_admin_burn_override", "burn_cc_base_units");
                var recreditedSoFar = SumRecords(resolvedWorkspaceRoot, redemptionId, "passport_storage_redemption_recredit", "recredit_cc_base_units");
                if (recreditCcBaseUnits > burnedSoFar - recreditedSoFar)
                {
                    return Failed("Storage re-credit exceeds previously burned CC for this redemption.");
                }

                var recreditId = DateTime.UtcNow.ToString("yyyyMMddTHHmmssZ") + "-storage-recredit-" + Guid.NewGuid().ToString("N")[..10];
                var evidence = new Dictionary<string, string>(adminAuthorityEvidence, StringComparer.Ordinal)
                {
                    ["storage_redemption_id"] = redemptionId,
                    ["storage_accepted_redemption_path"] = acceptedPath,
                    ["storage_accepted_redemption_sha256"] = acceptedHash,
                    ["storage_failure_evidence_path"] = evidencePath,
                    ["storage_failure_evidence_sha256"] = actualFailureEvidenceHash,
                    ["storage_recredit_id"] = recreditId,
                    ["storage_recredit_reason_code"] = NormalizeReasonCode(reasonCode),
                    ["admin_authority_action_type"] = "storage_recredit",
                    ["admin_authority_target_record_sha256"] = acceptedHash,
                    ["admin_authority_requested_payload_sha256"] = intentHash
                };
                var recredit = new PassportMonetaryLedgerService(releaseLane).AppendEvent(
                    resolvedWorkspaceRoot,
                    ReadString(accepted, "account_id"),
                    ReadString(accepted, "archrealms_identity_id"),
                    ReadString(accepted, "wallet_key_id"),
                    PassportMonetaryLedgerService.EventCrownCreditRecredit,
                    PassportMonetaryLedgerService.AssetCrownCredit,
                    recreditCcBaseUnits,
                    evidence);
                if (!recredit.Succeeded)
                {
                    return Failed("Storage re-credit ledger event failed: " + recredit.Message);
                }

                var recordPath = WriteAdminRecord(
                    resolvedWorkspaceRoot,
                    "recredit",
                    recreditId,
                    "passport_storage_redemption_recredit",
                    accepted,
                    authority,
                    recredit,
                    new Dictionary<string, object?>
                    {
                        ["recredit_cc_base_units"] = recreditCcBaseUnits,
                        ["reason_code"] = NormalizeReasonCode(reasonCode),
                        ["accepted_redemption_sha256"] = acceptedHash,
                        ["failure_evidence_path"] = ToWorkspaceRelativePath(resolvedWorkspaceRoot, evidencePath),
                        ["failure_evidence_sha256"] = actualFailureEvidenceHash,
                        ["requested_payload_sha256"] = intentHash
                    });
                return Success("Storage failure re-credit recorded.", recreditId, recordPath, recredit.EventPath, recredit.EventHashSha256);
            }
            catch (Exception ex)
            {
                return Failed("Storage failure re-credit failed: " + ex.Message);
            }
        }

        public PassportStorageRedemptionResult ExtendServiceByAdmin(
            string workspaceRoot,
            string acceptedRedemptionPath,
            int extensionEpochCount,
            string reasonCode,
            string failureEvidencePath,
            string failureEvidenceSha256,
            IDictionary<string, string> adminAuthorityEvidence)
        {
            try
            {
                var resolvedWorkspaceRoot = PassportEnvironment.ResolveWorkspaceRoot(workspaceRoot);
                if (extensionEpochCount <= 0)
                {
                    return Failed("Storage service extension requires a positive epoch count.");
                }

                var acceptedPath = ResolveWorkspaceRelativePath(resolvedWorkspaceRoot, acceptedRedemptionPath);
                if (!File.Exists(acceptedPath))
                {
                    return Failed("Accepted storage redemption record could not be found.");
                }

                var evidencePath = ResolveWorkspaceRelativePath(resolvedWorkspaceRoot, failureEvidencePath);
                if (!File.Exists(evidencePath))
                {
                    return Failed("Storage failure evidence record could not be found.");
                }

                var actualFailureEvidenceHash = ComputeSha256(File.ReadAllBytes(evidencePath));
                if (!string.Equals(actualFailureEvidenceHash, failureEvidenceSha256, StringComparison.OrdinalIgnoreCase))
                {
                    return Failed("Storage failure evidence hash does not match service-extension evidence.");
                }

                using var document = JsonDocument.Parse(File.ReadAllText(acceptedPath));
                var accepted = document.RootElement;
                if (!Matches(accepted, "record_type", "passport_storage_redemption_accepted"))
                {
                    return Failed("Storage service extension requires an accepted redemption record.");
                }

                if (!HasVerifiedWalletSignature(accepted))
                {
                    return Failed("Storage service extension requires a signed accepted redemption record.");
                }

                var redemptionId = ReadString(accepted, "redemption_id");
                var extendedSoFar = SumRecords(resolvedWorkspaceRoot, redemptionId, "passport_storage_redemption_service_extension", "extension_epoch_count");
                var originalEpochCount = ReadInt64(accepted, "service_epoch_count");
                if (extensionEpochCount > originalEpochCount - extendedSoFar)
                {
                    return Failed("Storage service extension exceeds the original accepted epoch count.");
                }

                var acceptedHash = ComputeSha256(File.ReadAllBytes(acceptedPath));
                var intentHash = ComputeServiceExtensionIntentHash(
                    releaseLane,
                    ReadString(accepted, "account_id"),
                    ReadString(accepted, "archrealms_identity_id"),
                    ReadString(accepted, "wallet_key_id"),
                    extensionEpochCount,
                    reasonCode,
                    acceptedHash,
                    actualFailureEvidenceHash);
                var authority = new PassportAdminAuthorityService(releaseLane).ValidateDualControlActionEvidence(
                    resolvedWorkspaceRoot,
                    adminAuthorityEvidence,
                    "service_extension",
                    acceptedHash,
                    intentHash);
                if (!authority.Succeeded)
                {
                    return Failed(authority.Message);
                }

                var extensionId = DateTime.UtcNow.ToString("yyyyMMddTHHmmssZ") + "-service-extension-" + Guid.NewGuid().ToString("N")[..10];
                var recordPath = WriteAdminServiceExtensionRecord(
                    resolvedWorkspaceRoot,
                    extensionId,
                    accepted,
                    authority,
                    new Dictionary<string, object?>
                    {
                        ["extension_epoch_count"] = extensionEpochCount,
                        ["reason_code"] = NormalizeReasonCode(reasonCode),
                        ["accepted_redemption_sha256"] = acceptedHash,
                        ["failure_evidence_path"] = ToWorkspaceRelativePath(resolvedWorkspaceRoot, evidencePath),
                        ["failure_evidence_sha256"] = actualFailureEvidenceHash,
                        ["requested_payload_sha256"] = intentHash
                    });
                return Success("Storage service extension recorded.", extensionId, recordPath, string.Empty, string.Empty);
            }
            catch (Exception ex)
            {
                return Failed("Storage service extension failed: " + ex.Message);
            }
        }

        public PassportStorageRedemptionResult ReleaseEscrowByAdmin(
            string workspaceRoot,
            string acceptedRedemptionPath,
            long releaseCcBaseUnits,
            string reasonCode,
            IDictionary<string, string> adminAuthorityEvidence)
        {
            try
            {
                var resolvedWorkspaceRoot = PassportEnvironment.ResolveWorkspaceRoot(workspaceRoot);
                if (releaseCcBaseUnits <= 0)
                {
                    return Failed("Admin escrow release requires a positive CC amount.");
                }

                var acceptedPath = ResolveWorkspaceRelativePath(resolvedWorkspaceRoot, acceptedRedemptionPath);
                if (!File.Exists(acceptedPath))
                {
                    return Failed("Accepted storage redemption record could not be found.");
                }

                using var document = JsonDocument.Parse(File.ReadAllText(acceptedPath));
                var accepted = document.RootElement;
                if (!Matches(accepted, "record_type", "passport_storage_redemption_accepted"))
                {
                    return Failed("Admin escrow release requires an accepted redemption record.");
                }

                var acceptedHash = ComputeSha256(File.ReadAllBytes(acceptedPath));
                var intentHash = ComputeEscrowReleaseIntentHash(
                    releaseLane,
                    ReadString(accepted, "account_id"),
                    ReadString(accepted, "archrealms_identity_id"),
                    ReadString(accepted, "wallet_key_id"),
                    releaseCcBaseUnits,
                    reasonCode,
                    acceptedHash);
                var authority = new PassportAdminAuthorityService(releaseLane).ValidateDualControlActionEvidence(
                    resolvedWorkspaceRoot,
                    adminAuthorityEvidence,
                    "escrow_release",
                    acceptedHash,
                    intentHash);
                if (!authority.Succeeded)
                {
                    return Failed(authority.Message);
                }

                var redemptionId = ReadString(accepted, "redemption_id");
                var burnedSoFar = SumRecords(resolvedWorkspaceRoot, redemptionId, "passport_storage_redemption_epoch_burn", "burn_cc_base_units")
                    + SumRecords(resolvedWorkspaceRoot, redemptionId, "passport_storage_redemption_admin_burn_override", "burn_cc_base_units");
                var refundedSoFar = SumRecords(resolvedWorkspaceRoot, redemptionId, "passport_storage_redemption_refund", "refund_cc_base_units")
                    + SumRecords(resolvedWorkspaceRoot, redemptionId, "passport_storage_redemption_admin_escrow_release", "release_cc_base_units");
                var escrowTotal = ReadInt64(accepted, "escrow_cc_base_units");
                if (burnedSoFar + refundedSoFar + releaseCcBaseUnits > escrowTotal)
                {
                    return Failed("Admin escrow release exceeds remaining escrow.");
                }

                var releaseId = DateTime.UtcNow.ToString("yyyyMMddTHHmmssZ") + "-escrow-release-" + Guid.NewGuid().ToString("N")[..10];
                var evidence = new Dictionary<string, string>(adminAuthorityEvidence, StringComparer.Ordinal)
                {
                    ["storage_redemption_id"] = redemptionId,
                    ["storage_accepted_redemption_path"] = acceptedPath,
                    ["storage_accepted_redemption_sha256"] = acceptedHash,
                    ["storage_admin_release_id"] = releaseId,
                    ["storage_admin_release_reason_code"] = NormalizeReasonCode(reasonCode),
                    ["admin_authority_action_type"] = "escrow_release",
                    ["admin_authority_target_record_sha256"] = acceptedHash,
                    ["admin_authority_requested_payload_sha256"] = intentHash
                };
                var refund = new PassportMonetaryLedgerService(releaseLane).AppendEvent(
                    resolvedWorkspaceRoot,
                    ReadString(accepted, "account_id"),
                    ReadString(accepted, "archrealms_identity_id"),
                    ReadString(accepted, "wallet_key_id"),
                    PassportMonetaryLedgerService.EventCrownCreditRefund,
                    PassportMonetaryLedgerService.AssetCrownCredit,
                    releaseCcBaseUnits,
                    evidence);
                if (!refund.Succeeded)
                {
                    return Failed("Admin escrow release ledger event failed: " + refund.Message);
                }

                var recordPath = WriteAdminRecord(
                    resolvedWorkspaceRoot,
                    "admin-escrow-release",
                    releaseId,
                    "passport_storage_redemption_admin_escrow_release",
                    accepted,
                    authority,
                    refund,
                    new Dictionary<string, object?>
                    {
                        ["release_cc_base_units"] = releaseCcBaseUnits,
                        ["reason_code"] = NormalizeReasonCode(reasonCode),
                        ["accepted_redemption_sha256"] = acceptedHash,
                        ["requested_payload_sha256"] = intentHash
                    });
                return Success("Admin escrow release recorded.", releaseId, recordPath, refund.EventPath, refund.EventHashSha256);
            }
            catch (Exception ex)
            {
                return Failed("Admin escrow release failed: " + ex.Message);
            }
        }

        public PassportStorageRedemptionResult OverrideBurnByAdmin(
            string workspaceRoot,
            string acceptedRedemptionPath,
            long burnCcBaseUnits,
            long verifiedGbDays,
            string reasonCode,
            string proofRecordPath,
            string proofRecordSha256,
            IDictionary<string, string> adminAuthorityEvidence)
        {
            try
            {
                var resolvedWorkspaceRoot = PassportEnvironment.ResolveWorkspaceRoot(workspaceRoot);
                if (burnCcBaseUnits <= 0 || verifiedGbDays <= 0)
                {
                    return Failed("Admin burn override requires positive CC burn and verified GB-days.");
                }

                var acceptedPath = ResolveWorkspaceRelativePath(resolvedWorkspaceRoot, acceptedRedemptionPath);
                if (!File.Exists(acceptedPath))
                {
                    return Failed("Accepted storage redemption record could not be found.");
                }

                var proofPath = ResolveWorkspaceRelativePath(resolvedWorkspaceRoot, proofRecordPath);
                if (!File.Exists(proofPath))
                {
                    return Failed("Storage proof record could not be found.");
                }

                var actualProofHash = ComputeSha256(File.ReadAllBytes(proofPath));
                if (!string.Equals(actualProofHash, proofRecordSha256, StringComparison.OrdinalIgnoreCase))
                {
                    return Failed("Storage proof hash does not match burn override evidence.");
                }

                using var document = JsonDocument.Parse(File.ReadAllText(acceptedPath));
                var accepted = document.RootElement;
                if (!Matches(accepted, "record_type", "passport_storage_redemption_accepted"))
                {
                    return Failed("Admin burn override requires an accepted redemption record.");
                }

                if (!HasVerifiedWalletSignature(accepted))
                {
                    return Failed("Admin burn override requires a signed accepted redemption record.");
                }

                var quoteTerms = ReadAcceptedQuoteTerms(resolvedWorkspaceRoot, accepted);
                if (!quoteTerms.Succeeded)
                {
                    return Failed(quoteTerms.Message);
                }

                var proofAcceptance = ValidateStorageProofForBurn(resolvedWorkspaceRoot, proofPath, accepted, quoteTerms, verifiedGbDays);
                if (!proofAcceptance.Succeeded)
                {
                    return Failed("Storage proof package rejected: " + proofAcceptance.Message);
                }

                var acceptedHash = ComputeSha256(File.ReadAllBytes(acceptedPath));
                var intentHash = ComputeBurnOverrideIntentHash(
                    releaseLane,
                    ReadString(accepted, "account_id"),
                    ReadString(accepted, "archrealms_identity_id"),
                    ReadString(accepted, "wallet_key_id"),
                    burnCcBaseUnits,
                    verifiedGbDays,
                    reasonCode,
                    acceptedHash,
                    actualProofHash);
                var authority = new PassportAdminAuthorityService(releaseLane).ValidateDualControlActionEvidence(
                    resolvedWorkspaceRoot,
                    adminAuthorityEvidence,
                    "burn_override",
                    acceptedHash,
                    intentHash);
                if (!authority.Succeeded)
                {
                    return Failed(authority.Message);
                }

                var redemptionId = ReadString(accepted, "redemption_id");
                var burnedSoFar = SumRecords(resolvedWorkspaceRoot, redemptionId, "passport_storage_redemption_epoch_burn", "burn_cc_base_units")
                    + SumRecords(resolvedWorkspaceRoot, redemptionId, "passport_storage_redemption_admin_burn_override", "burn_cc_base_units");
                var refundedSoFar = SumRecords(resolvedWorkspaceRoot, redemptionId, "passport_storage_redemption_refund", "refund_cc_base_units")
                    + SumRecords(resolvedWorkspaceRoot, redemptionId, "passport_storage_redemption_admin_escrow_release", "release_cc_base_units");
                var escrowTotal = ReadInt64(accepted, "escrow_cc_base_units");
                var remainingEscrow = escrowTotal - burnedSoFar - refundedSoFar;
                if (burnCcBaseUnits > remainingEscrow)
                {
                    return Failed("Admin burn override exceeds remaining escrow.");
                }

                var expectedBurn = CalculateExpectedBurn(verifiedGbDays, quoteTerms.CcPerGbEpochBaseUnits, remainingEscrow);
                if (burnCcBaseUnits != expectedBurn)
                {
                    return Failed("Admin burn override must equal verified GB-days multiplied by the accepted quote rate, capped by remaining escrow.");
                }

                var burnId = DateTime.UtcNow.ToString("yyyyMMddTHHmmssZ") + "-burn-override-" + Guid.NewGuid().ToString("N")[..10];
                var evidence = new Dictionary<string, string>(adminAuthorityEvidence, StringComparer.Ordinal)
                {
                    ["storage_redemption_id"] = redemptionId,
                    ["storage_accepted_redemption_path"] = acceptedPath,
                    ["storage_accepted_redemption_sha256"] = acceptedHash,
                    ["storage_proof_record_path"] = proofPath,
                    ["storage_proof_record_sha256"] = actualProofHash,
                    ["storage_admin_burn_override_id"] = burnId,
                    ["storage_admin_burn_override_reason_code"] = NormalizeReasonCode(reasonCode),
                    ["storage_proof_acceptance_rule"] = "mvp_storage_epoch_burn_v1",
                    ["storage_verified_gb_days"] = verifiedGbDays.ToString(),
                    ["storage_quote_rate_cc_per_gb_epoch_base_units"] = quoteTerms.CcPerGbEpochBaseUnits.ToString(),
                    ["admin_authority_action_type"] = "burn_override",
                    ["admin_authority_target_record_sha256"] = acceptedHash,
                    ["admin_authority_requested_payload_sha256"] = intentHash
                };
                var burn = new PassportMonetaryLedgerService(releaseLane).AppendEvent(
                    resolvedWorkspaceRoot,
                    ReadString(accepted, "account_id"),
                    ReadString(accepted, "archrealms_identity_id"),
                    ReadString(accepted, "wallet_key_id"),
                    PassportMonetaryLedgerService.EventCrownCreditBurn,
                    PassportMonetaryLedgerService.AssetCrownCredit,
                    burnCcBaseUnits,
                    evidence);
                if (!burn.Succeeded)
                {
                    return Failed("Admin burn override ledger event failed: " + burn.Message);
                }

                var recordPath = WriteAdminRecord(
                    resolvedWorkspaceRoot,
                    "admin-burn-override",
                    burnId,
                    "passport_storage_redemption_admin_burn_override",
                    accepted,
                    authority,
                    burn,
                    new Dictionary<string, object?>
                    {
                        ["burn_cc_base_units"] = burnCcBaseUnits,
                        ["verified_gb_days"] = verifiedGbDays,
                        ["cc_per_gb_epoch_base_units"] = quoteTerms.CcPerGbEpochBaseUnits,
                        ["burn_formula"] = "burn_cc_base_units=verified_gb_days*cc_per_gb_epoch_base_units capped by remaining escrow",
                        ["reason_code"] = NormalizeReasonCode(reasonCode),
                        ["accepted_redemption_sha256"] = acceptedHash,
                        ["proof_record_path"] = ToWorkspaceRelativePath(resolvedWorkspaceRoot, proofPath),
                        ["proof_record_sha256"] = actualProofHash,
                        ["proof_acceptance"] = proofAcceptance.ToRecord(),
                        ["requested_payload_sha256"] = intentHash
                    });
                return Success("Admin burn override recorded.", burnId, recordPath, burn.EventPath, burn.EventHashSha256);
            }
            catch (Exception ex)
            {
                return Failed("Admin burn override failed: " + ex.Message);
            }
        }

        public static string ComputeEscrowReleaseIntentHash(
            PassportReleaseLane releaseLane,
            string accountId,
            string identityId,
            string walletKeyId,
            long releaseCcBaseUnits,
            string reasonCode,
            string acceptedRedemptionSha256)
        {
            var intent = new SortedDictionary<string, object?>(StringComparer.Ordinal)
            {
                ["release_lane"] = releaseLane.Lane,
                ["ledger_namespace"] = releaseLane.LedgerNamespace,
                ["action_type"] = "escrow_release",
                ["account_id"] = (accountId ?? string.Empty).Trim(),
                ["archrealms_identity_id"] = (identityId ?? string.Empty).Trim(),
                ["wallet_key_id"] = (walletKeyId ?? string.Empty).Trim(),
                ["release_cc_base_units"] = releaseCcBaseUnits,
                ["reason_code"] = NormalizeReasonCode(reasonCode),
                ["accepted_redemption_sha256"] = (acceptedRedemptionSha256 ?? string.Empty).Trim().ToLowerInvariant()
            };
            return ComputeSha256(Encoding.UTF8.GetBytes(JsonSerializer.Serialize(intent, JsonOptions)));
        }

        public static string ComputeBurnOverrideIntentHash(
            PassportReleaseLane releaseLane,
            string accountId,
            string identityId,
            string walletKeyId,
            long burnCcBaseUnits,
            long verifiedGbDays,
            string reasonCode,
            string acceptedRedemptionSha256,
            string proofRecordSha256)
        {
            var intent = new SortedDictionary<string, object?>(StringComparer.Ordinal)
            {
                ["release_lane"] = releaseLane.Lane,
                ["ledger_namespace"] = releaseLane.LedgerNamespace,
                ["action_type"] = "burn_override",
                ["account_id"] = (accountId ?? string.Empty).Trim(),
                ["archrealms_identity_id"] = (identityId ?? string.Empty).Trim(),
                ["wallet_key_id"] = (walletKeyId ?? string.Empty).Trim(),
                ["burn_cc_base_units"] = burnCcBaseUnits,
                ["verified_gb_days"] = verifiedGbDays,
                ["reason_code"] = NormalizeReasonCode(reasonCode),
                ["accepted_redemption_sha256"] = (acceptedRedemptionSha256 ?? string.Empty).Trim().ToLowerInvariant(),
                ["proof_record_sha256"] = (proofRecordSha256 ?? string.Empty).Trim().ToLowerInvariant()
            };
            return ComputeSha256(Encoding.UTF8.GetBytes(JsonSerializer.Serialize(intent, JsonOptions)));
        }

        public static string ComputeStorageRecreditIntentHash(
            PassportReleaseLane releaseLane,
            string accountId,
            string identityId,
            string walletKeyId,
            long recreditCcBaseUnits,
            string reasonCode,
            string acceptedRedemptionSha256,
            string failureEvidenceSha256)
        {
            var intent = new SortedDictionary<string, object?>(StringComparer.Ordinal)
            {
                ["release_lane"] = releaseLane.Lane,
                ["ledger_namespace"] = releaseLane.LedgerNamespace,
                ["action_type"] = "storage_recredit",
                ["account_id"] = (accountId ?? string.Empty).Trim(),
                ["archrealms_identity_id"] = (identityId ?? string.Empty).Trim(),
                ["wallet_key_id"] = (walletKeyId ?? string.Empty).Trim(),
                ["recredit_cc_base_units"] = recreditCcBaseUnits,
                ["reason_code"] = NormalizeReasonCode(reasonCode),
                ["accepted_redemption_sha256"] = (acceptedRedemptionSha256 ?? string.Empty).Trim().ToLowerInvariant(),
                ["failure_evidence_sha256"] = (failureEvidenceSha256 ?? string.Empty).Trim().ToLowerInvariant()
            };
            return ComputeSha256(Encoding.UTF8.GetBytes(JsonSerializer.Serialize(intent, JsonOptions)));
        }

        public static string ComputeServiceExtensionIntentHash(
            PassportReleaseLane releaseLane,
            string accountId,
            string identityId,
            string walletKeyId,
            int extensionEpochCount,
            string reasonCode,
            string acceptedRedemptionSha256,
            string failureEvidenceSha256)
        {
            var intent = new SortedDictionary<string, object?>(StringComparer.Ordinal)
            {
                ["release_lane"] = releaseLane.Lane,
                ["ledger_namespace"] = releaseLane.LedgerNamespace,
                ["action_type"] = "service_extension",
                ["account_id"] = (accountId ?? string.Empty).Trim(),
                ["archrealms_identity_id"] = (identityId ?? string.Empty).Trim(),
                ["wallet_key_id"] = (walletKeyId ?? string.Empty).Trim(),
                ["extension_epoch_count"] = extensionEpochCount,
                ["reason_code"] = NormalizeReasonCode(reasonCode),
                ["accepted_redemption_sha256"] = (acceptedRedemptionSha256 ?? string.Empty).Trim().ToLowerInvariant(),
                ["failure_evidence_sha256"] = (failureEvidenceSha256 ?? string.Empty).Trim().ToLowerInvariant()
            };
            return ComputeSha256(Encoding.UTF8.GetBytes(JsonSerializer.Serialize(intent, JsonOptions)));
        }

        private string WriteAdminRecord(
            string workspaceRoot,
            string kind,
            string recordId,
            string recordType,
            JsonElement sourceRecord,
            PassportAdminAuthorityResult authority,
            PassportMonetaryLedgerAppendResult ledgerEvent,
            Dictionary<string, object?> extra)
        {
            var root = Path.Combine(workspaceRoot, "records", "passport", "monetary", "storage-redemptions", kind);
            Directory.CreateDirectory(root);
            var path = Path.Combine(root, recordId + ".json");
            var record = new Dictionary<string, object?>
            {
                ["schema_version"] = 1,
                ["record_type"] = recordType,
                ["record_id"] = recordId,
                ["redemption_id"] = ReadString(sourceRecord, "redemption_id"),
                ["created_utc"] = DateTime.UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ"),
                ["release_lane"] = releaseLane.Lane,
                ["ledger_namespace"] = releaseLane.LedgerNamespace,
                ["policy_version"] = releaseLane.PolicyVersion,
                ["account_id"] = ReadString(sourceRecord, "account_id"),
                ["archrealms_identity_id"] = ReadString(sourceRecord, "archrealms_identity_id"),
                ["wallet_key_id"] = ReadString(sourceRecord, "wallet_key_id"),
                ["quote_id"] = ReadString(sourceRecord, "quote_id"),
                ["quote_path"] = ReadString(sourceRecord, "quote_path"),
                ["quote_sha256"] = ReadString(sourceRecord, "quote_sha256"),
                ["admin_authority_record_path"] = ToWorkspaceRelativePath(workspaceRoot, authority.RecordPath),
                ["admin_authority_requester_signature_path"] = ToWorkspaceRelativePath(workspaceRoot, authority.RequesterSignaturePath),
                ["admin_authority_approver_signature_path"] = ToWorkspaceRelativePath(workspaceRoot, authority.ApproverSignaturePath),
                ["ledger_event_id"] = ledgerEvent.EventId,
                ["ledger_event_path"] = ToWorkspaceRelativePath(workspaceRoot, ledgerEvent.EventPath),
                ["ledger_event_hash_sha256"] = ledgerEvent.EventHashSha256,
                ["requires_dual_control"] = true,
                ["ai_approved"] = false,
                ["summary"] = "Dual-control admin storage redemption operation linked to a CC ledger event. AI is not an approval authority."
            };
            foreach (var item in extra)
            {
                record[item.Key] = item.Value;
            }

            File.WriteAllText(path, JsonSerializer.Serialize(record, JsonOptions), Encoding.UTF8);
            return path;
        }

        private string WriteAdminServiceExtensionRecord(
            string workspaceRoot,
            string recordId,
            JsonElement sourceRecord,
            PassportAdminAuthorityResult authority,
            Dictionary<string, object?> extra)
        {
            var root = Path.Combine(workspaceRoot, "records", "passport", "monetary", "storage-redemptions", "service-extension");
            Directory.CreateDirectory(root);
            var path = Path.Combine(root, recordId + ".json");
            var record = new Dictionary<string, object?>
            {
                ["schema_version"] = 1,
                ["record_type"] = "passport_storage_redemption_service_extension",
                ["record_id"] = recordId,
                ["redemption_id"] = ReadString(sourceRecord, "redemption_id"),
                ["created_utc"] = DateTime.UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ"),
                ["release_lane"] = releaseLane.Lane,
                ["ledger_namespace"] = releaseLane.LedgerNamespace,
                ["policy_version"] = releaseLane.PolicyVersion,
                ["account_id"] = ReadString(sourceRecord, "account_id"),
                ["archrealms_identity_id"] = ReadString(sourceRecord, "archrealms_identity_id"),
                ["wallet_key_id"] = ReadString(sourceRecord, "wallet_key_id"),
                ["quote_id"] = ReadString(sourceRecord, "quote_id"),
                ["quote_path"] = ReadString(sourceRecord, "quote_path"),
                ["quote_sha256"] = ReadString(sourceRecord, "quote_sha256"),
                ["admin_authority_record_path"] = ToWorkspaceRelativePath(workspaceRoot, authority.RecordPath),
                ["admin_authority_requester_signature_path"] = ToWorkspaceRelativePath(workspaceRoot, authority.RequesterSignaturePath),
                ["admin_authority_approver_signature_path"] = ToWorkspaceRelativePath(workspaceRoot, authority.ApproverSignaturePath),
                ["requires_dual_control"] = true,
                ["ai_approved"] = false,
                ["ledger_event_id"] = string.Empty,
                ["summary"] = "Dual-control admin storage service extension record. AI is not an approval authority."
            };
            foreach (var item in extra)
            {
                record[item.Key] = item.Value;
            }

            File.WriteAllText(path, JsonSerializer.Serialize(record, JsonOptions), Encoding.UTF8);
            return path;
        }

        private string WriteSignedRecord(
            string workspaceRoot,
            string kind,
            string recordId,
            JsonElement sourceRecord,
            PassportStorageRedemptionResult? quote,
            PassportMonetaryLedgerAppendResult ledgerEvent,
            string walletKeyReferencePath,
            string walletPublicKeyPath,
            Dictionary<string, object?> extra)
        {
            var recordType = kind switch
            {
                "accepted" => "passport_storage_redemption_accepted",
                "epoch-burn" => "passport_storage_redemption_epoch_burn",
                "refund" => "passport_storage_redemption_refund",
                _ => "passport_storage_redemption_record"
            };
            var root = Path.Combine(workspaceRoot, "records", "passport", "monetary", "storage-redemptions", kind);
            Directory.CreateDirectory(root);
            var path = Path.Combine(root, recordId + ".json");
            var record = new Dictionary<string, object?>
            {
                ["schema_version"] = 1,
                ["record_type"] = recordType,
                ["record_id"] = recordId,
                ["redemption_id"] = kind == "accepted" ? recordId : ReadString(sourceRecord, "redemption_id"),
                ["created_utc"] = DateTime.UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ"),
                ["release_lane"] = releaseLane.Lane,
                ["ledger_namespace"] = releaseLane.LedgerNamespace,
                ["policy_version"] = releaseLane.PolicyVersion,
                ["account_id"] = ReadString(sourceRecord, "account_id"),
                ["archrealms_identity_id"] = ReadString(sourceRecord, "archrealms_identity_id"),
                ["wallet_key_id"] = ReadString(sourceRecord, "wallet_key_id"),
                ["quote_id"] = kind == "accepted" ? ReadString(sourceRecord, "quote_id") : ReadString(sourceRecord, "quote_id"),
                ["quote_path"] = kind == "accepted" && quote != null ? ToWorkspaceRelativePath(workspaceRoot, quote.RecordPath) : ReadString(sourceRecord, "quote_path"),
                ["quote_sha256"] = kind == "accepted" && quote != null ? quote.RecordSha256 : ReadString(sourceRecord, "quote_sha256"),
                ["ledger_event_id"] = ledgerEvent.EventId,
                ["ledger_event_path"] = ToWorkspaceRelativePath(workspaceRoot, ledgerEvent.EventPath),
                ["ledger_event_hash_sha256"] = ledgerEvent.EventHashSha256,
                ["burn_timing"] = "escrow_on_acceptance_burn_per_verified_epoch",
                ["summary"] = "Storage redemption record linked to CC escrow, proof-backed epoch burn, refund, or re-credit behavior."
            };
            foreach (var item in extra)
            {
                record[item.Key] = item.Value;
            }

            var unsignedPayload = JsonSerializer.Serialize(record, JsonOptions);
            var signature = new PassportWalletKeyService(releaseLane).SignWalletPayload(
                walletKeyReferencePath,
                walletPublicKeyPath,
                Encoding.UTF8.GetBytes(unsignedPayload));
            if (!signature.Succeeded)
            {
                throw new InvalidOperationException(signature.Message);
            }

            record["wallet_signature"] = new Dictionary<string, object?>
            {
                ["signature_algorithm"] = "RSA_PKCS1_SHA256",
                ["signature_base64"] = signature.SignatureBase64,
                ["signed_payload_sha256"] = signature.PayloadSha256,
                ["wallet_public_key_path"] = ToWorkspaceRelativePath(workspaceRoot, walletPublicKeyPath),
                ["verified_with_wallet_key"] = signature.VerifiedWithWalletKey
            };
            File.WriteAllText(path, JsonSerializer.Serialize(record, JsonOptions), Encoding.UTF8);
            return path;
        }

        private StorageQuoteTerms ReadAcceptedQuoteTerms(string workspaceRoot, JsonElement accepted)
        {
            var rate = ReadInt64(accepted, "cc_per_gb_epoch_base_units");
            var serviceClass = ReadString(accepted, "service_class");
            var total = ReadInt64(accepted, "total_cc_base_units");
            if (rate > 0 && !string.IsNullOrWhiteSpace(serviceClass))
            {
                return StorageQuoteTerms.Success(rate, serviceClass, total);
            }

            var quotePathValue = ReadString(accepted, "quote_path");
            if (string.IsNullOrWhiteSpace(quotePathValue))
            {
                return StorageQuoteTerms.Failed("Accepted storage redemption is missing quote terms.");
            }

            var quotePath = ResolveWorkspaceRelativePath(workspaceRoot, quotePathValue);
            if (!File.Exists(quotePath))
            {
                return StorageQuoteTerms.Failed("Accepted storage redemption quote record could not be found.");
            }

            var expectedQuoteSha256 = ReadString(accepted, "quote_sha256");
            var actualQuoteSha256 = ComputeSha256(File.ReadAllBytes(quotePath));
            if (!string.IsNullOrWhiteSpace(expectedQuoteSha256)
                && !string.Equals(actualQuoteSha256, expectedQuoteSha256, StringComparison.OrdinalIgnoreCase))
            {
                return StorageQuoteTerms.Failed("Accepted storage redemption quote hash does not match.");
            }

            using var quoteDocument = JsonDocument.Parse(File.ReadAllText(quotePath));
            var quote = quoteDocument.RootElement;
            if (!Matches(quote, "record_type", "passport_storage_redemption_quote"))
            {
                return StorageQuoteTerms.Failed("Accepted storage redemption quote evidence is not a quote record.");
            }

            if (!Matches(quote, "release_lane", releaseLane.Lane) || !Matches(quote, "ledger_namespace", releaseLane.LedgerNamespace))
            {
                return StorageQuoteTerms.Failed("Accepted storage redemption quote belongs to another release lane or ledger namespace.");
            }

            rate = ReadInt64(quote, "cc_per_gb_epoch_base_units");
            serviceClass = ReadString(quote, "service_class");
            total = ReadInt64(quote, "total_cc_base_units");
            if (rate <= 0 || string.IsNullOrWhiteSpace(serviceClass))
            {
                return StorageQuoteTerms.Failed("Accepted storage redemption quote is missing burn-rate terms.");
            }

            return StorageQuoteTerms.Success(rate, serviceClass, total);
        }

        private static StorageProofAcceptance ValidateStorageProofForBurn(
            string workspaceRoot,
            string proofPath,
            JsonElement accepted,
            StorageQuoteTerms quoteTerms,
            long requestedVerifiedGbDays)
        {
            using var proofDocument = JsonDocument.Parse(File.ReadAllText(proofPath));
            var envelope = proofDocument.RootElement;
            if (!envelope.TryGetProperty("signature", out var signature))
            {
                return StorageProofAcceptance.Failed("proof record is missing a device signature.");
            }

            var payloadPath = ResolveWorkspaceRelativePath(workspaceRoot, ReadString(signature, "signed_payload_path"));
            var signaturePath = ResolveWorkspaceRelativePath(workspaceRoot, ReadString(signature, "signature_path"));
            var expectedPayloadSha256 = ReadString(signature, "signed_payload_sha256");
            if (!File.Exists(payloadPath))
            {
                return StorageProofAcceptance.Failed("signed proof payload could not be found.");
            }

            if (!File.Exists(signaturePath))
            {
                return StorageProofAcceptance.Failed("proof signature file could not be found.");
            }

            var payloadBytes = File.ReadAllBytes(payloadPath);
            var actualPayloadSha256 = ComputeSha256(payloadBytes);
            if (!string.Equals(actualPayloadSha256, expectedPayloadSha256, StringComparison.OrdinalIgnoreCase))
            {
                return StorageProofAcceptance.Failed("signed proof payload hash does not match.");
            }

            using var payloadDocument = JsonDocument.Parse(payloadBytes);
            var proof = payloadDocument.RootElement;
            var deviceId = ReadString(proof, "device_id");
            var publicKeyPath = Path.Combine(workspaceRoot, "records", "registry", "public-keys", deviceId + ".spki.der");
            if (string.IsNullOrWhiteSpace(deviceId) || !File.Exists(publicKeyPath))
            {
                return StorageProofAcceptance.Failed("proof signing device public key could not be found.");
            }

            if (!VerifySignature(publicKeyPath, payloadBytes, File.ReadAllBytes(signaturePath)))
            {
                return StorageProofAcceptance.Failed("proof device signature verification failed.");
            }

            if (!Matches(proof, "record_type", "storage_epoch_proof_record"))
            {
                return StorageProofAcceptance.Failed("burn evidence must be a storage_epoch_proof_record.");
            }

            if (!Matches(proof, "status", "submitted") && !Matches(proof, "status", "accepted"))
            {
                return StorageProofAcceptance.Failed("proof status must be submitted or accepted.");
            }

            var recordId = ReadString(proof, "record_id");
            if (!string.Equals(ReadString(envelope, "record_id"), recordId, StringComparison.Ordinal))
            {
                return StorageProofAcceptance.Failed("proof envelope record ID does not match the signed payload.");
            }

            if (!Matches(proof, "archrealms_identity_id", ReadString(accepted, "archrealms_identity_id")))
            {
                return StorageProofAcceptance.Failed("proof identity does not match the accepted redemption.");
            }

            if (!Matches(proof, "service_class", quoteTerms.ServiceClass))
            {
                return StorageProofAcceptance.Failed("proof service class does not match the accepted quote.");
            }

            if (!proof.TryGetProperty("content_ref", out var contentRef)
                || string.IsNullOrWhiteSpace(ReadString(contentRef, "cid"))
                || string.IsNullOrWhiteSpace(ReadString(contentRef, "manifest_sha256")))
            {
                return StorageProofAcceptance.Failed("proof is missing content reference or manifest hash.");
            }

            if (!proof.TryGetProperty("object_manifest", out var objectManifest)
                || ReadInt64(objectManifest, "total_size_bytes") <= 0
                || ReadInt64(objectManifest, "redundancy_target") <= 0
                || string.IsNullOrWhiteSpace(ReadString(objectManifest, "privacy_preserving_object_id_sha256"))
                || !ObjectManifestHasChunkHashes(objectManifest))
            {
                return StorageProofAcceptance.Failed("proof is missing the encrypted object or chunk manifest fields required for burn.");
            }

            if (!proof.TryGetProperty("challenge", out var challenge)
                || string.IsNullOrWhiteSpace(ReadString(challenge, "challenge_seed_sha256"))
                || !HasNonEmptyArray(challenge, "segment_offsets"))
            {
                return StorageProofAcceptance.Failed("proof is missing the random possession challenge.");
            }

            if (!proof.TryGetProperty("proof_response", out var proofResponse)
                || ReadInt64(proofResponse, "proved_bytes") <= 0
                || string.IsNullOrWhiteSpace(ReadString(proofResponse, "response_sha256")))
            {
                return StorageProofAcceptance.Failed("proof is missing a successful possession response.");
            }

            if (!proof.TryGetProperty("retrieval_challenge", out var retrievalChallenge)
                || ReadInt64(retrievalChallenge, "latency_threshold_ms") <= 0
                || string.IsNullOrWhiteSpace(ReadString(retrievalChallenge, "verifier_id")))
            {
                return StorageProofAcceptance.Failed("proof is missing the sample retrieval challenge.");
            }

            if (!proof.TryGetProperty("retrieval_response", out var retrievalResponse)
                || !ReadBoolean(retrievalResponse, "succeeded")
                || ReadInt64(retrievalResponse, "retrieved_bytes") <= 0
                || !retrievalResponse.TryGetProperty("latency_ms", out _)
                || ReadInt64(retrievalResponse, "latency_ms") > ReadInt64(retrievalChallenge, "latency_threshold_ms")
                || string.IsNullOrWhiteSpace(ReadString(retrievalResponse, "verifier_signature")))
            {
                return StorageProofAcceptance.Failed("proof is missing a successful signed retrieval response within threshold.");
            }

            if (!proof.TryGetProperty("metering_claim", out var meteringClaim)
                || ReadInt64(meteringClaim, "claimed_storage_bytes") <= 0
                || ReadInt64(meteringClaim, "claimed_replicated_byte_seconds") <= 0)
            {
                return StorageProofAcceptance.Failed("proof is missing positive metering claim fields.");
            }

            if (!proof.TryGetProperty("delivery_metering", out var deliveryMetering)
                || ReadInt64(deliveryMetering, "verified_gb_days") < requestedVerifiedGbDays
                || string.IsNullOrWhiteSpace(ReadString(deliveryMetering, "metering_formula")))
            {
                return StorageProofAcceptance.Failed("proof metering does not cover the requested verified GB-days.");
            }

            if (!proof.TryGetProperty("repair_status", out var repairStatus)
                || string.IsNullOrWhiteSpace(ReadString(repairStatus, "redundancy_status"))
                || (ReadBoolean(repairStatus, "node_failed") && string.IsNullOrWhiteSpace(ReadString(repairStatus, "repair_action"))))
            {
                return StorageProofAcceptance.Failed("proof is missing repair or redundancy status.");
            }

            if (!proof.TryGetProperty("failure_remedy", out var failureRemedy)
                || string.IsNullOrWhiteSpace(ReadString(failureRemedy, "failed_epoch_remedy")))
            {
                return StorageProofAcceptance.Failed("proof is missing failure re-credit or service-extension rules.");
            }

            return StorageProofAcceptance.Success(
                recordId,
                deviceId,
                ReadString(proof, "assignment_id"),
                ReadNestedString(proof, "measurement_epoch", "epoch_id"),
                ReadString(contentRef, "manifest_sha256"),
                ReadInt64(meteringClaim, "claimed_storage_bytes"),
                ReadInt64(meteringClaim, "claimed_replicated_byte_seconds"),
                ReadInt64(proofResponse, "proved_bytes"),
                ReadString(proofResponse, "response_sha256"),
                ReadInt64(retrievalResponse, "retrieved_bytes"),
                ReadInt64(retrievalResponse, "latency_ms"),
                ReadInt64(deliveryMetering, "verified_gb_days"));
        }

        private static bool HasVerifiedWalletSignature(JsonElement record)
        {
            return record.TryGetProperty("wallet_signature", out var signature)
                && Matches(signature, "signature_algorithm", "RSA_PKCS1_SHA256")
                && !string.IsNullOrWhiteSpace(ReadString(signature, "signature_base64"))
                && !string.IsNullOrWhiteSpace(ReadString(signature, "signed_payload_sha256"))
                && ReadBoolean(signature, "verified_with_wallet_key");
        }

        private static long CalculateExpectedBurn(long verifiedGbDays, long ccPerGbEpochBaseUnits, long remainingEscrow)
        {
            var calculated = checked(verifiedGbDays * ccPerGbEpochBaseUnits);
            return calculated > remainingEscrow ? remainingEscrow : calculated;
        }

        private static bool VerifySignature(string publicKeyPath, byte[] data, byte[] signatureBytes)
        {
            using var rsa = RSA.Create();
            rsa.ImportSubjectPublicKeyInfo(File.ReadAllBytes(publicKeyPath), out _);
            return rsa.VerifyData(data, signatureBytes, HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1);
        }

        private static bool ObjectManifestHasChunkHashes(JsonElement objectManifest)
        {
            if (!objectManifest.TryGetProperty("chunks", out var chunks) || chunks.ValueKind != JsonValueKind.Array)
            {
                return false;
            }

            foreach (var chunk in chunks.EnumerateArray())
            {
                if (ReadInt64(chunk, "size_bytes") > 0 && !string.IsNullOrWhiteSpace(ReadString(chunk, "sha256")))
                {
                    return true;
                }
            }

            return false;
        }

        private static bool HasNonEmptyArray(JsonElement root, string propertyName)
        {
            return root.TryGetProperty(propertyName, out var value)
                && value.ValueKind == JsonValueKind.Array
                && value.GetArrayLength() > 0;
        }

        private static string ReadNestedString(JsonElement root, string objectName, string propertyName)
        {
            return root.TryGetProperty(objectName, out var nested) ? ReadString(nested, propertyName) : string.Empty;
        }

        private PassportStorageRedemptionResult ReadAndValidateQuote(string workspaceRoot, string quotePath, string expectedSha256)
        {
            var path = ResolveWorkspaceRelativePath(workspaceRoot, quotePath);
            if (!File.Exists(path))
            {
                return Failed("Storage redemption quote could not be found.");
            }

            var hash = ComputeSha256(File.ReadAllBytes(path));
            if (!string.IsNullOrWhiteSpace(expectedSha256) && !string.Equals(hash, expectedSha256, StringComparison.OrdinalIgnoreCase))
            {
                return Failed("Storage redemption quote hash does not match evidence.");
            }

            using var document = JsonDocument.Parse(File.ReadAllText(path));
            var root = document.RootElement;
            if (!Matches(root, "record_type", "passport_storage_redemption_quote"))
            {
                return Failed("Storage redemption evidence is not a quote record.");
            }

            if (!Matches(root, "release_lane", releaseLane.Lane) || !Matches(root, "ledger_namespace", releaseLane.LedgerNamespace))
            {
                return Failed("Storage redemption quote belongs to another release lane or ledger namespace.");
            }

            if (!DateTime.TryParse(ReadString(root, "expires_utc"), out var expiresUtc) || expiresUtc.ToUniversalTime() <= DateTime.UtcNow)
            {
                return Failed("Storage redemption quote is expired.");
            }

            return Success("Storage quote is valid.", ReadString(root, "quote_id"), path, string.Empty, string.Empty, hash);
        }

        private static long SumRecords(string workspaceRoot, string redemptionId, string recordType, string amountProperty)
        {
            var root = Path.Combine(workspaceRoot, "records", "passport", "monetary", "storage-redemptions");
            if (!Directory.Exists(root))
            {
                return 0;
            }

            return Directory.GetFiles(root, "*.json", SearchOption.AllDirectories)
                .Select(path =>
                {
                    using var document = JsonDocument.Parse(File.ReadAllText(path));
                    var element = document.RootElement.Clone();
                    return element;
                })
                .Where(record => Matches(record, "record_type", recordType) && Matches(record, "redemption_id", redemptionId))
                .Sum(record => ReadInt64(record, amountProperty));
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

        private static string NormalizeReasonCode(string reasonCode)
        {
            var normalized = NormalizeRequired(reasonCode, "reason code").Trim().ToLowerInvariant().Replace(" ", "_").Replace("-", "_");
            return normalized.Length > 64 ? normalized[..64] : normalized;
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

        private static long ReadInt64(JsonElement root, string propertyName)
        {
            if (!root.TryGetProperty(propertyName, out var property))
            {
                return 0;
            }

            if (property.ValueKind == JsonValueKind.Number && property.TryGetInt64(out var value))
            {
                return value;
            }

            return property.ValueKind == JsonValueKind.String && long.TryParse(property.GetString(), out var parsed) ? parsed : 0;
        }

        private static bool ReadBoolean(JsonElement root, string propertyName)
        {
            return root.TryGetProperty(propertyName, out var property)
                && (property.ValueKind == JsonValueKind.True
                    || (property.ValueKind == JsonValueKind.String && bool.TryParse(property.GetString(), out var value) && value));
        }

        private static string ResolveWorkspaceRelativePath(string workspaceRoot, string path)
        {
            var normalized = path.Replace('/', Path.DirectorySeparatorChar);
            return Path.IsPathRooted(normalized)
                ? Path.GetFullPath(normalized)
                : Path.GetFullPath(Path.Combine(workspaceRoot, normalized));
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

        private static string ComputeSha256(byte[] value)
        {
            return Convert.ToHexString(SHA256.HashData(value)).ToLowerInvariant();
        }

        private static PassportStorageRedemptionResult Success(
            string message,
            string recordId,
            string recordPath,
            string ledgerEventPath,
            string ledgerEventHash,
            string recordHash = "")
        {
            return new PassportStorageRedemptionResult
            {
                Succeeded = true,
                Message = message,
                RecordId = recordId,
                RecordPath = recordPath,
                RecordSha256 = string.IsNullOrWhiteSpace(recordHash) && File.Exists(recordPath) ? ComputeSha256(File.ReadAllBytes(recordPath)) : recordHash,
                LedgerEventPath = ledgerEventPath,
                LedgerEventHashSha256 = ledgerEventHash
            };
        }

        private static PassportStorageRedemptionResult Failed(string message)
        {
            return new PassportStorageRedemptionResult
            {
                Succeeded = false,
                Message = message
            };
        }

        private sealed class StorageQuoteTerms
        {
            public bool Succeeded { get; private init; }

            public string Message { get; private init; } = string.Empty;

            public long CcPerGbEpochBaseUnits { get; private init; }

            public string ServiceClass { get; private init; } = string.Empty;

            public long TotalCcBaseUnits { get; private init; }

            public static StorageQuoteTerms Success(long ccPerGbEpochBaseUnits, string serviceClass, long totalCcBaseUnits)
            {
                return new StorageQuoteTerms
                {
                    Succeeded = true,
                    CcPerGbEpochBaseUnits = ccPerGbEpochBaseUnits,
                    ServiceClass = serviceClass,
                    TotalCcBaseUnits = totalCcBaseUnits
                };
            }

            public static StorageQuoteTerms Failed(string message)
            {
                return new StorageQuoteTerms
                {
                    Succeeded = false,
                    Message = message
                };
            }
        }

        private sealed class StorageProofAcceptance
        {
            public bool Succeeded { get; private init; }

            public string Message { get; private init; } = string.Empty;

            public string RecordId { get; private init; } = string.Empty;

            public string DeviceId { get; private init; } = string.Empty;

            public string AssignmentId { get; private init; } = string.Empty;

            public string EpochId { get; private init; } = string.Empty;

            public string ManifestSha256 { get; private init; } = string.Empty;

            public long ClaimedStorageBytes { get; private init; }

            public long ClaimedReplicatedByteSeconds { get; private init; }

            public long ProvedBytes { get; private init; }

            public string PossessionResponseSha256 { get; private init; } = string.Empty;

            public long RetrievedBytes { get; private init; }

            public long RetrievalLatencyMs { get; private init; }

            public long VerifiedGbDays { get; private init; }

            public static StorageProofAcceptance Success(
                string recordId,
                string deviceId,
                string assignmentId,
                string epochId,
                string manifestSha256,
                long claimedStorageBytes,
                long claimedReplicatedByteSeconds,
                long provedBytes,
                string possessionResponseSha256,
                long retrievedBytes,
                long retrievalLatencyMs,
                long verifiedGbDays)
            {
                return new StorageProofAcceptance
                {
                    Succeeded = true,
                    RecordId = recordId,
                    DeviceId = deviceId,
                    AssignmentId = assignmentId,
                    EpochId = epochId,
                    ManifestSha256 = manifestSha256,
                    ClaimedStorageBytes = claimedStorageBytes,
                    ClaimedReplicatedByteSeconds = claimedReplicatedByteSeconds,
                    ProvedBytes = provedBytes,
                    PossessionResponseSha256 = possessionResponseSha256,
                    RetrievedBytes = retrievedBytes,
                    RetrievalLatencyMs = retrievalLatencyMs,
                    VerifiedGbDays = verifiedGbDays
                };
            }

            public static StorageProofAcceptance Failed(string message)
            {
                return new StorageProofAcceptance
                {
                    Succeeded = false,
                    Message = message
                };
            }

            public Dictionary<string, object?> ToRecord()
            {
                return new Dictionary<string, object?>
                {
                    ["accepted"] = true,
                    ["acceptance_rule"] = "mvp_storage_epoch_burn_v1",
                    ["proof_record_id"] = RecordId,
                    ["proof_device_id"] = DeviceId,
                    ["assignment_id"] = AssignmentId,
                    ["epoch_id"] = EpochId,
                    ["manifest_sha256"] = ManifestSha256,
                    ["claimed_storage_bytes"] = ClaimedStorageBytes,
                    ["claimed_replicated_byte_seconds"] = ClaimedReplicatedByteSeconds,
                    ["proved_bytes"] = ProvedBytes,
                    ["possession_response_sha256"] = PossessionResponseSha256,
                    ["retrieved_bytes"] = RetrievedBytes,
                    ["retrieval_latency_ms"] = RetrievalLatencyMs,
                    ["verified_gb_days"] = VerifiedGbDays,
                    ["checks"] = new[]
                    {
                        "accepted_redemption_signature_present",
                        "device_signature_verified",
                        "object_manifest_present",
                        "possession_challenge_present",
                        "retrieval_challenge_passed",
                        "metering_claim_positive",
                        "repair_status_present",
                        "failure_remedy_present"
                    }
                };
            }
        }
    }
}
