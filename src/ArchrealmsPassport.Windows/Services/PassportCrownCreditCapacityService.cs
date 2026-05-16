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
    public sealed class PassportCrownCreditCapacityService
    {
        private static readonly JsonSerializerOptions JsonOptions = new JsonSerializerOptions
        {
            WriteIndented = true
        };

        private readonly PassportReleaseLane releaseLane;

        public PassportCrownCreditCapacityService(PassportReleaseLane? releaseLane = null)
        {
            this.releaseLane = releaseLane ?? PassportEnvironment.GetReleaseLane();
        }

        public PassportCrownCreditCapacityReportResult CreateCapacityReport(
            string workspaceRoot,
            string serviceClass,
            long conservativeServiceLiabilityCapacityBaseUnits,
            long outstandingCrownCreditBeforeBaseUnits,
            long maxIssuanceBaseUnits,
            int capacityHaircutBasisPoints,
            bool independentVolumeQualified,
            bool thinMarketIssuanceZero,
            bool continuityReserveExcluded,
            bool operationalReserveExcluded,
            string capacityReportAuthorityRecordSha256 = "",
            string conservativeMethodologySha256 = "",
            string issuanceAuthorityRecordSha256 = "",
            string issuanceRecordSchemaSha256 = "",
            string noArchCreationValidationSha256 = "")
        {
            try
            {
                var resolvedWorkspaceRoot = PassportEnvironment.ResolveWorkspaceRoot(workspaceRoot);
                if (conservativeServiceLiabilityCapacityBaseUnits <= 0)
                {
                    return Failed("Conservative service liability capacity must be greater than zero.");
                }

                if (outstandingCrownCreditBeforeBaseUnits < 0)
                {
                    return Failed("Outstanding CC before issuance cannot be negative.");
                }

                if (maxIssuanceBaseUnits < 0)
                {
                    return Failed("Max issuance cannot be negative.");
                }

                if (thinMarketIssuanceZero && maxIssuanceBaseUnits != 0)
                {
                    return Failed("Thin-market capacity reports must set max issuance to zero.");
                }

                if (!independentVolumeQualified && maxIssuanceBaseUnits != 0)
                {
                    return Failed("Unqualified independent volume must set max issuance to zero.");
                }

                if (capacityHaircutBasisPoints < 0 || capacityHaircutBasisPoints > 10_000)
                {
                    return Failed("Capacity haircut must be between 0 and 10000 basis points.");
                }

                var evidenceHashes = NormalizeEvidenceHashes(
                    capacityReportAuthorityRecordSha256,
                    conservativeMethodologySha256,
                    issuanceAuthorityRecordSha256,
                    issuanceRecordSchemaSha256,
                    noArchCreationValidationSha256);
                if (evidenceHashes == null)
                {
                    return Failed("Production CC capacity report requires authority, conservative methodology, issuance authority, issuance schema, and no-ARCH-creation validation hash evidence.");
                }

                var now = DateTime.UtcNow;
                var timestamp = now.ToString("yyyyMMddTHHmmssZ");
                var createdUtc = now.ToString("yyyy-MM-ddTHH:mm:ssZ");
                var reportsRoot = Path.Combine(resolvedWorkspaceRoot, "records", "passport", "monetary", "capacity-reports", "cc");
                Directory.CreateDirectory(reportsRoot);
                var normalizedServiceClass = NormalizeServiceClass(serviceClass);
                var reportPath = Path.Combine(reportsRoot, timestamp + "-" + normalizedServiceClass + ".json");
                var report = new Dictionary<string, object?>
                {
                    ["schema_version"] = 1,
                    ["record_type"] = "passport_cc_capacity_report",
                    ["record_id"] = timestamp + "-" + normalizedServiceClass,
                    ["created_utc"] = createdUtc,
                    ["release_lane"] = releaseLane.Lane,
                    ["ledger_namespace"] = releaseLane.LedgerNamespace,
                    ["policy_version"] = releaseLane.PolicyVersion,
                    ["service_class"] = normalizedServiceClass,
                    ["reporting_period_start_utc"] = now.AddDays(-90).ToString("yyyy-MM-ddTHH:mm:ssZ"),
                    ["reporting_period_end_utc"] = createdUtc,
                    ["conservative_service_liability_capacity_base_units"] = conservativeServiceLiabilityCapacityBaseUnits,
                    ["outstanding_cc_before_base_units"] = outstandingCrownCreditBeforeBaseUnits,
                    ["max_issuance_base_units"] = maxIssuanceBaseUnits,
                    ["capacity_haircut_basis_points"] = capacityHaircutBasisPoints,
                    ["independent_volume_qualified"] = independentVolumeQualified,
                    ["thin_market_issuance_zero"] = thinMarketIssuanceZero,
                    ["continuity_reserve_excluded"] = continuityReserveExcluded,
                    ["operational_reserve_excluded"] = operationalReserveExcluded,
                    ["affiliate_trade_exclusion_applied"] = true,
                    ["proof_history_haircut"] = 0.0,
                    ["uptime_haircut"] = 0.0,
                    ["retrieval_haircut"] = 0.0,
                    ["repair_haircut"] = 0.0,
                    ["concentration_haircut"] = 0.0,
                    ["churn_haircut"] = 0.0,
                    ["audit_confidence_haircut"] = 0.0,
                    ["capacity_evidence_refs"] = new[] { "local_capacity_report:" + timestamp + ":" + normalizedServiceClass },
                    ["capacity_report_authority_record_sha256"] = evidenceHashes.Value.CapacityReportAuthorityRecordSha256,
                    ["conservative_methodology_sha256"] = evidenceHashes.Value.ConservativeMethodologySha256,
                    ["issuance_authority_record_sha256"] = evidenceHashes.Value.IssuanceAuthorityRecordSha256,
                    ["issuance_record_schema_sha256"] = evidenceHashes.Value.IssuanceRecordSchemaSha256,
                    ["no_arch_creation_validation_sha256"] = evidenceHashes.Value.NoArchCreationValidationSha256,
                    ["summary"] = "Conservative Crown Credit issuance-capacity report for Passport monetary ledger validation."
                };
                File.WriteAllText(reportPath, JsonSerializer.Serialize(report, JsonOptions), Encoding.UTF8);
                var hash = ComputeSha256(File.ReadAllBytes(reportPath));

                return new PassportCrownCreditCapacityReportResult
                {
                    Succeeded = true,
                    Message = "CC capacity report created.",
                    ReportPath = reportPath,
                    ReportSha256 = hash,
                    MaxIssuanceBaseUnits = maxIssuanceBaseUnits
                };
            }
            catch (Exception ex)
            {
                return Failed("CC capacity report creation failed: " + ex.Message);
            }
        }

        public PassportCrownCreditCapacityReportResult ValidateIssuance(
            string workspaceRoot,
            long issuanceAmountBaseUnits,
            IDictionary<string, string> evidenceReferences)
        {
            try
            {
                if (issuanceAmountBaseUnits <= 0)
                {
                    return Failed("CC issuance amount must be greater than zero.");
                }

                if (!evidenceReferences.TryGetValue("capacity_report_path", out var reportReference)
                    || string.IsNullOrWhiteSpace(reportReference))
                {
                    return Failed("Production CC issuance requires capacity_report_path evidence.");
                }

                var resolvedWorkspaceRoot = PassportEnvironment.ResolveWorkspaceRoot(workspaceRoot);
                var reportPath = ResolveWorkspaceRelativePath(resolvedWorkspaceRoot, reportReference);
                if (!File.Exists(reportPath))
                {
                    return Failed("The CC capacity report could not be found.");
                }

                var reportBytes = File.ReadAllBytes(reportPath);
                var actualHash = ComputeSha256(reportBytes);
                if (evidenceReferences.TryGetValue("capacity_report_sha256", out var expectedHash)
                    && !string.IsNullOrWhiteSpace(expectedHash)
                    && !string.Equals(actualHash, expectedHash.Trim(), StringComparison.OrdinalIgnoreCase))
                {
                    return Failed("The CC capacity report hash does not match evidence.");
                }

                using var document = JsonDocument.Parse(File.ReadAllText(reportPath));
                var root = document.RootElement;
                if (!Matches(root, "record_type", "passport_cc_capacity_report"))
                {
                    return Failed("The capacity evidence is not a CC capacity report.");
                }

                if (!Matches(root, "release_lane", releaseLane.Lane)
                    || !Matches(root, "ledger_namespace", releaseLane.LedgerNamespace))
                {
                    return Failed("The CC capacity report belongs to a different release lane or ledger namespace.");
                }

                var maxIssuance = ReadInt64(root, "max_issuance_base_units");
                if (ReadBool(root, "thin_market_issuance_zero"))
                {
                    return Failed("The CC capacity report applies a thin-market zero-issuance fallback.");
                }

                if (!ReadBool(root, "independent_volume_qualified"))
                {
                    return Failed("The CC capacity report lacks qualified independent volume.");
                }

                if (maxIssuance < issuanceAmountBaseUnits)
                {
                    return Failed("CC issuance exceeds the conservative capacity report limit.");
                }

                if (!ReadBool(root, "continuity_reserve_excluded") || !ReadBool(root, "operational_reserve_excluded"))
                {
                    return Failed("The CC capacity report must exclude continuity and operational reserves.");
                }

                if (ReadInt64(root, "conservative_service_liability_capacity_base_units") <= 0)
                {
                    return Failed("The CC capacity report has no conservative service-liability capacity.");
                }

                foreach (var hashField in new[]
                {
                    "capacity_report_authority_record_sha256",
                    "conservative_methodology_sha256",
                    "issuance_authority_record_sha256",
                    "issuance_record_schema_sha256",
                    "no_arch_creation_validation_sha256"
                })
                {
                    if (!LooksLikeSha256(ReadString(root, hashField)))
                    {
                        return Failed("The CC capacity report is missing required decision evidence: " + hashField + ".");
                    }
                }

                return new PassportCrownCreditCapacityReportResult
                {
                    Succeeded = true,
                    Message = "CC issuance capacity evidence is valid.",
                    ReportPath = reportPath,
                    ReportSha256 = actualHash,
                    MaxIssuanceBaseUnits = maxIssuance
                };
            }
            catch (Exception ex)
            {
                return Failed("CC issuance capacity validation failed: " + ex.Message);
            }
        }

        private static string NormalizeServiceClass(string serviceClass)
        {
            var normalized = (serviceClass ?? string.Empty).Trim().ToLowerInvariant().Replace(" ", "_").Replace("-", "_");
            return string.IsNullOrWhiteSpace(normalized) ? "aggregate" : normalized;
        }

        private (string CapacityReportAuthorityRecordSha256, string ConservativeMethodologySha256, string IssuanceAuthorityRecordSha256, string IssuanceRecordSchemaSha256, string NoArchCreationValidationSha256)? NormalizeEvidenceHashes(
            string capacityReportAuthorityRecordSha256,
            string conservativeMethodologySha256,
            string issuanceAuthorityRecordSha256,
            string issuanceRecordSchemaSha256,
            string noArchCreationValidationSha256)
        {
            var normalized = (
                NormalizeHashEvidence(capacityReportAuthorityRecordSha256, "local-cc-capacity-report-authority"),
                NormalizeHashEvidence(conservativeMethodologySha256, "local-cc-conservative-methodology"),
                NormalizeHashEvidence(issuanceAuthorityRecordSha256, "local-cc-issuance-authority"),
                NormalizeHashEvidence(issuanceRecordSchemaSha256, "local-cc-issuance-record-schema"),
                NormalizeHashEvidence(noArchCreationValidationSha256, "local-cc-no-arch-creation-validation"));

            if (releaseLane.ProductionLedger
                && (!LooksLikeSha256(capacityReportAuthorityRecordSha256)
                    || !LooksLikeSha256(conservativeMethodologySha256)
                    || !LooksLikeSha256(issuanceAuthorityRecordSha256)
                    || !LooksLikeSha256(issuanceRecordSchemaSha256)
                    || !LooksLikeSha256(noArchCreationValidationSha256)))
            {
                return null;
            }

            return normalized;
        }

        private static string NormalizeHashEvidence(string value, string fallbackLabel)
        {
            var normalized = (value ?? string.Empty).Trim();
            return LooksLikeSha256(normalized)
                ? normalized.ToLowerInvariant()
                : ComputeSha256(Encoding.UTF8.GetBytes(fallbackLabel));
        }

        private static string ResolveWorkspaceRelativePath(string workspaceRoot, string path)
        {
            var normalized = path.Replace('/', Path.DirectorySeparatorChar);
            return Path.IsPathRooted(normalized)
                ? Path.GetFullPath(normalized)
                : Path.GetFullPath(Path.Combine(workspaceRoot, normalized));
        }

        private static bool Matches(JsonElement root, string propertyName, string expected)
        {
            return root.TryGetProperty(propertyName, out var property)
                && property.ValueKind == JsonValueKind.String
                && string.Equals(property.GetString() ?? string.Empty, expected, StringComparison.Ordinal);
        }

        private static long ReadInt64(JsonElement root, string propertyName)
        {
            return root.TryGetProperty(propertyName, out var property) && property.TryGetInt64(out var value) ? value : 0;
        }

        private static bool ReadBool(JsonElement root, string propertyName)
        {
            return root.TryGetProperty(propertyName, out var property) && property.ValueKind == JsonValueKind.True;
        }

        private static string ReadString(JsonElement root, string propertyName)
        {
            return root.TryGetProperty(propertyName, out var property) && property.ValueKind == JsonValueKind.String
                ? property.GetString() ?? string.Empty
                : string.Empty;
        }

        private static bool LooksLikeSha256(string value)
        {
            var normalized = (value ?? string.Empty).Trim();
            return normalized.Length == 64 && normalized.All(Uri.IsHexDigit);
        }

        private static string ComputeSha256(byte[] value)
        {
            return Convert.ToHexString(SHA256.HashData(value)).ToLowerInvariant();
        }

        private static PassportCrownCreditCapacityReportResult Failed(string message)
        {
            return new PassportCrownCreditCapacityReportResult
            {
                Succeeded = false,
                Message = message
            };
        }
    }
}
