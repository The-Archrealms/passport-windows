using System;
using System.Collections.Generic;
using System.IO;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using ArchrealmsPassport.Core.Protocol;
using ArchrealmsPassport.Windows.Models;

namespace ArchrealmsPassport.Windows.Services
{
    public sealed class PassportConversionQuoteService
    {
        private static readonly JsonSerializerOptions JsonOptions = new JsonSerializerOptions
        {
            WriteIndented = true
        };

        private readonly PassportReleaseLane releaseLane;

        public PassportConversionQuoteService(PassportReleaseLane? releaseLane = null)
        {
            this.releaseLane = releaseLane ?? PassportEnvironment.GetReleaseLane();
        }

        public PassportConversionQuoteResult CreateQuote(
            string workspaceRoot,
            string accountId,
            string identityId,
            string walletKeyId,
            string sourceAssetCode,
            string destinationAssetCode,
            long sourceAmountBaseUnits,
            long destinationAmountBaseUnits,
            string rateSource,
            string liquiditySource,
            string quoteMethod,
            string counterpartyClass,
            bool crownIsCounterparty,
            DateTime expiresUtc,
            int spreadBasisPoints,
            long feeBaseUnits,
            int maxSlippageBasisPoints,
            long liquidityLimitBaseUnits)
        {
            try
            {
                var resolvedWorkspaceRoot = PassportEnvironment.ResolveWorkspaceRoot(workspaceRoot);
                var normalizedSourceAsset = NormalizeAsset(sourceAssetCode);
                var normalizedDestinationAsset = NormalizeAsset(destinationAssetCode);
                if (string.Equals(normalizedSourceAsset, normalizedDestinationAsset, StringComparison.Ordinal))
                {
                    return Failed("A conversion quote requires two different assets.");
                }

                if (sourceAmountBaseUnits <= 0 || destinationAmountBaseUnits <= 0)
                {
                    return Failed("Conversion quote source and destination amounts must be greater than zero.");
                }

                if (spreadBasisPoints < 0 || feeBaseUnits < 0 || maxSlippageBasisPoints < 0 || liquidityLimitBaseUnits <= 0)
                {
                    return Failed("Conversion quote fees, slippage, and liquidity limit must be non-negative, and liquidity limit must be positive.");
                }

                if (expiresUtc.ToUniversalTime() <= DateTime.UtcNow)
                {
                    return Failed("Conversion quote expiration must be in the future.");
                }

                var normalizedRateSource = NormalizeRequired(rateSource, "rate source");
                var normalizedLiquiditySource = NormalizeRequired(liquiditySource, "liquidity source");
                var normalizedQuoteMethod = NormalizeRequired(quoteMethod, "quote method");
                var normalizedCounterpartyClass = NormalizeRequired(counterpartyClass, "counterparty class");
                var timestamp = DateTime.UtcNow.ToString("yyyyMMddTHHmmssZ");
                var createdUtc = DateTime.UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ");
                var quoteId = timestamp + "-" + normalizedSourceAsset.ToLowerInvariant() + "-to-" + normalizedDestinationAsset.ToLowerInvariant() + "-" + Guid.NewGuid().ToString("N")[..10];
                var quotesRoot = Path.Combine(resolvedWorkspaceRoot, "records", "passport", "monetary", "conversion-quotes");
                Directory.CreateDirectory(quotesRoot);
                var quotePath = Path.Combine(quotesRoot, quoteId + ".json");
                var quote = new Dictionary<string, object?>
                {
                    ["schema_version"] = 1,
                    ["record_type"] = "passport_arch_cc_conversion_quote",
                    ["record_id"] = quoteId,
                    ["quote_id"] = quoteId,
                    ["created_utc"] = createdUtc,
                    ["quote_time_utc"] = createdUtc,
                    ["expires_utc"] = expiresUtc.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ"),
                    ["release_lane"] = releaseLane.Lane,
                    ["ledger_namespace"] = releaseLane.LedgerNamespace,
                    ["policy_version"] = releaseLane.PolicyVersion,
                    ["account_id"] = NormalizeRequired(accountId, "account ID"),
                    ["archrealms_identity_id"] = NormalizeRequired(identityId, "identity ID"),
                    ["wallet_key_id"] = NormalizeRequired(walletKeyId, "wallet key ID"),
                    ["source_asset_code"] = normalizedSourceAsset,
                    ["destination_asset_code"] = normalizedDestinationAsset,
                    ["source_amount_base_units"] = sourceAmountBaseUnits,
                    ["destination_amount_base_units"] = destinationAmountBaseUnits,
                    ["rate_numerator_base_units"] = destinationAmountBaseUnits,
                    ["rate_denominator_base_units"] = sourceAmountBaseUnits,
                    ["rate_source"] = normalizedRateSource,
                    ["liquidity_source"] = normalizedLiquiditySource,
                    ["quote_method"] = normalizedQuoteMethod,
                    ["counterparty_class"] = normalizedCounterpartyClass,
                    ["crown_is_counterparty"] = crownIsCounterparty,
                    ["spread_basis_points"] = spreadBasisPoints,
                    ["fee_base_units"] = feeBaseUnits,
                    ["max_slippage_basis_points"] = maxSlippageBasisPoints,
                    ["liquidity_limit_base_units"] = liquidityLimitBaseUnits,
                    ["guaranteed_conversion"] = false,
                    ["fixed_parity"] = false,
                    ["minimum_arch_price_guaranteed"] = false,
                    ["unlimited_crown_convertibility"] = false,
                    ["stable_value_claim"] = false,
                    ["legal_tender_claim"] = false,
                    ["execution_status"] = "quote_only_not_executed",
                    ["summary"] = "Floating-rate ARCH/CC conversion quote. This is not a fixed conversion, parity promise, stable-value claim, or unlimited Crown convertibility."
                };
                File.WriteAllText(quotePath, JsonSerializer.Serialize(quote, JsonOptions), Encoding.UTF8);
                return new PassportConversionQuoteResult
                {
                    Succeeded = true,
                    Message = "Conversion quote created.",
                    QuoteId = quoteId,
                    QuotePath = quotePath,
                    QuoteSha256 = ComputeSha256(File.ReadAllBytes(quotePath))
                };
            }
            catch (Exception ex)
            {
                return Failed("Conversion quote creation failed: " + ex.Message);
            }
        }

        public PassportConversionQuoteResult ValidateQuoteForExecution(
            string workspaceRoot,
            string quotePath,
            string expectedQuoteSha256 = "")
        {
            try
            {
                var resolvedWorkspaceRoot = PassportEnvironment.ResolveWorkspaceRoot(workspaceRoot);
                var resolvedQuotePath = ResolveWorkspaceRelativePath(resolvedWorkspaceRoot, NormalizeRequired(quotePath, "quote path"));
                if (!File.Exists(resolvedQuotePath))
                {
                    return Failed("The conversion quote could not be found.");
                }

                var quoteBytes = File.ReadAllBytes(resolvedQuotePath);
                var quoteHash = ComputeSha256(quoteBytes);
                if (!string.IsNullOrWhiteSpace(expectedQuoteSha256)
                    && !string.Equals(quoteHash, expectedQuoteSha256.Trim(), StringComparison.OrdinalIgnoreCase))
                {
                    return Failed("The conversion quote hash does not match evidence.");
                }

                using var document = JsonDocument.Parse(File.ReadAllText(resolvedQuotePath));
                var root = document.RootElement;
                if (!Matches(root, "record_type", "passport_arch_cc_conversion_quote"))
                {
                    return Failed("The conversion evidence is not an ARCH/CC quote record.");
                }

                if (!Matches(root, "release_lane", releaseLane.Lane)
                    || !Matches(root, "ledger_namespace", releaseLane.LedgerNamespace))
                {
                    return Failed("The conversion quote belongs to a different release lane or ledger namespace.");
                }

                if (!IsArchOrCrownCredit(ReadString(root, "source_asset_code"))
                    || !IsArchOrCrownCredit(ReadString(root, "destination_asset_code"))
                    || string.Equals(ReadString(root, "source_asset_code"), ReadString(root, "destination_asset_code"), StringComparison.Ordinal))
                {
                    return Failed("The conversion quote must be between ARCH and CC.");
                }

                if (ReadInt64(root, "source_amount_base_units") <= 0
                    || ReadInt64(root, "destination_amount_base_units") <= 0
                    || ReadInt64(root, "rate_numerator_base_units") <= 0
                    || ReadInt64(root, "rate_denominator_base_units") <= 0)
                {
                    return Failed("The conversion quote amounts and rate must be greater than zero.");
                }

                if (string.IsNullOrWhiteSpace(ReadString(root, "rate_source"))
                    || string.IsNullOrWhiteSpace(ReadString(root, "liquidity_source"))
                    || string.IsNullOrWhiteSpace(ReadString(root, "quote_method"))
                    || string.IsNullOrWhiteSpace(ReadString(root, "counterparty_class")))
                {
                    return Failed("The conversion quote is missing rate, liquidity, method, or counterparty disclosure.");
                }

                if (ReadInt64(root, "spread_basis_points") < 0
                    || ReadInt64(root, "fee_base_units") < 0
                    || ReadInt64(root, "max_slippage_basis_points") < 0
                    || ReadInt64(root, "liquidity_limit_base_units") <= 0)
                {
                    return Failed("The conversion quote has invalid fee, slippage, or liquidity disclosure.");
                }

                if (ReadBool(root, "guaranteed_conversion")
                    || ReadBool(root, "fixed_parity")
                    || ReadBool(root, "minimum_arch_price_guaranteed")
                    || ReadBool(root, "unlimited_crown_convertibility")
                    || ReadBool(root, "stable_value_claim")
                    || ReadBool(root, "legal_tender_claim"))
                {
                    return Failed("The conversion quote contains a prohibited guarantee, parity, stable-value, legal-tender, or unlimited-convertibility claim.");
                }

                if (!DateTime.TryParse(ReadString(root, "expires_utc"), out var expiresUtc)
                    || expiresUtc.ToUniversalTime() <= DateTime.UtcNow)
                {
                    return Failed("The conversion quote is expired.");
                }

                return new PassportConversionQuoteResult
                {
                    Succeeded = true,
                    Message = "Conversion quote is valid for execution.",
                    QuoteId = ReadString(root, "quote_id"),
                    QuotePath = resolvedQuotePath,
                    QuoteSha256 = quoteHash
                };
            }
            catch (Exception ex)
            {
                return Failed("Conversion quote validation failed: " + ex.Message);
            }
        }

        private static string NormalizeAsset(string assetCode)
        {
            var normalized = PassportMonetaryProtocol.NormalizeAssetCode(NormalizeRequired(assetCode, "asset code"));

            if (!IsArchOrCrownCredit(normalized))
            {
                throw new InvalidOperationException("Conversion quotes are limited to ARCH and CC.");
            }

            return normalized;
        }

        private static bool IsArchOrCrownCredit(string assetCode)
        {
            return PassportMonetaryProtocol.IsSupportedAssetCode(assetCode);
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

        private static bool ReadBool(JsonElement root, string propertyName)
        {
            return root.TryGetProperty(propertyName, out var property) && property.ValueKind == JsonValueKind.True;
        }

        private static string ComputeSha256(byte[] value)
        {
            return Convert.ToHexString(SHA256.HashData(value)).ToLowerInvariant();
        }

        private static PassportConversionQuoteResult Failed(string message)
        {
            return new PassportConversionQuoteResult
            {
                Succeeded = false,
                Message = message
            };
        }
    }
}
