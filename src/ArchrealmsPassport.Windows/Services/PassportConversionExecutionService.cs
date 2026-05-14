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
    public sealed class PassportConversionExecutionService
    {
        private static readonly JsonSerializerOptions JsonOptions = new JsonSerializerOptions
        {
            WriteIndented = true
        };

        private readonly PassportReleaseLane releaseLane;

        public PassportConversionExecutionService(PassportReleaseLane? releaseLane = null)
        {
            this.releaseLane = releaseLane ?? PassportEnvironment.GetReleaseLane();
        }

        public PassportConversionExecutionResult ExecuteQuote(
            string workspaceRoot,
            string quotePath,
            string quoteSha256,
            string walletKeyReferencePath,
            string walletPublicKeyPath)
        {
            try
            {
                var resolvedWorkspaceRoot = PassportEnvironment.ResolveWorkspaceRoot(workspaceRoot);
                var quoteValidation = new PassportConversionQuoteService(releaseLane)
                    .ValidateQuoteForExecution(resolvedWorkspaceRoot, quotePath, quoteSha256);
                if (!quoteValidation.Succeeded)
                {
                    return Failed(quoteValidation.Message);
                }

                using var quoteDocument = JsonDocument.Parse(File.ReadAllText(quoteValidation.QuotePath));
                var quote = quoteDocument.RootElement;
                var accountId = ReadString(quote, "account_id");
                var identityId = ReadString(quote, "archrealms_identity_id");
                var walletKeyId = ReadString(quote, "wallet_key_id");
                var sourceAsset = ReadString(quote, "source_asset_code");
                var destinationAsset = ReadString(quote, "destination_asset_code");
                var sourceAmount = ReadInt64(quote, "source_amount_base_units");
                var destinationAmount = ReadInt64(quote, "destination_amount_base_units");
                var feeAmount = ReadInt64(quote, "fee_base_units");
                var totalSourceDebit = sourceAmount + feeAmount;
                var quoteId = ReadString(quote, "quote_id");
                var executionId = DateTime.UtcNow.ToString("yyyyMMddTHHmmssZ") + "-" + quoteId + "-execution";

                var replay = new PassportMonetaryLedgerService(releaseLane).Replay(resolvedWorkspaceRoot);
                if (!replay.Succeeded)
                {
                    return Failed("The monetary ledger must replay cleanly before conversion execution: " + string.Join("; ", replay.Failures));
                }

                var sourceBalance = replay.Balances.FirstOrDefault(balance =>
                    string.Equals(balance.AccountId, accountId, StringComparison.Ordinal)
                    && string.Equals(balance.AssetCode, sourceAsset, StringComparison.Ordinal));
                if (sourceBalance == null || sourceBalance.AvailableBaseUnits < totalSourceDebit)
                {
                    return Failed("The source asset balance is insufficient for the accepted conversion quote.");
                }

                var evidence = new Dictionary<string, string>
                {
                    ["conversion_quote_id"] = quoteId,
                    ["conversion_quote_path"] = quoteValidation.QuotePath,
                    ["conversion_quote_sha256"] = quoteValidation.QuoteSha256,
                    ["conversion_execution_id"] = executionId
                };

                var ledger = new PassportMonetaryLedgerService(releaseLane);
                var sourceEvent = ledger.AppendEvent(
                    resolvedWorkspaceRoot,
                    accountId,
                    identityId,
                    walletKeyId,
                    GetTransferOutEventType(sourceAsset),
                    sourceAsset,
                    totalSourceDebit,
                    evidence,
                    walletKeyReferencePath: walletKeyReferencePath,
                    walletPublicKeyPath: walletPublicKeyPath);
                if (!sourceEvent.Succeeded)
                {
                    return Failed("Conversion source debit failed: " + sourceEvent.Message);
                }

                var destinationEvent = ledger.AppendEvent(
                    resolvedWorkspaceRoot,
                    accountId,
                    identityId,
                    walletKeyId,
                    GetTransferInEventType(destinationAsset),
                    destinationAsset,
                    destinationAmount,
                    evidence,
                    walletKeyReferencePath: walletKeyReferencePath,
                    walletPublicKeyPath: walletPublicKeyPath);
                if (!destinationEvent.Succeeded)
                {
                    return Failed("Conversion destination credit failed after source debit; manual correction is required: " + destinationEvent.Message);
                }

                var executionRecordPath = WriteExecutionRecord(
                    resolvedWorkspaceRoot,
                    executionId,
                    quote,
                    quoteValidation,
                    sourceEvent,
                    destinationEvent,
                    totalSourceDebit,
                    walletKeyReferencePath,
                    walletPublicKeyPath);

                return new PassportConversionExecutionResult
                {
                    Succeeded = true,
                    Message = "Conversion quote executed.",
                    ExecutionId = executionId,
                    ExecutionRecordPath = executionRecordPath,
                    SourceLedgerEventPath = sourceEvent.EventPath,
                    DestinationLedgerEventPath = destinationEvent.EventPath
                };
            }
            catch (Exception ex)
            {
                return Failed("Conversion execution failed: " + ex.Message);
            }
        }

        private string WriteExecutionRecord(
            string workspaceRoot,
            string executionId,
            JsonElement quote,
            PassportConversionQuoteResult quoteValidation,
            PassportMonetaryLedgerAppendResult sourceEvent,
            PassportMonetaryLedgerAppendResult destinationEvent,
            long totalSourceDebit,
            string walletKeyReferencePath,
            string walletPublicKeyPath)
        {
            var createdUtc = DateTime.UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ");
            var executionRoot = Path.Combine(workspaceRoot, "records", "passport", "monetary", "conversion-executions");
            Directory.CreateDirectory(executionRoot);
            var executionRecordPath = Path.Combine(executionRoot, executionId + ".json");
            var unsignedRecord = new Dictionary<string, object?>
            {
                ["schema_version"] = 1,
                ["record_type"] = "passport_arch_cc_conversion_execution",
                ["record_id"] = executionId,
                ["execution_id"] = executionId,
                ["created_utc"] = createdUtc,
                ["release_lane"] = releaseLane.Lane,
                ["ledger_namespace"] = releaseLane.LedgerNamespace,
                ["policy_version"] = releaseLane.PolicyVersion,
                ["account_id"] = ReadString(quote, "account_id"),
                ["archrealms_identity_id"] = ReadString(quote, "archrealms_identity_id"),
                ["wallet_key_id"] = ReadString(quote, "wallet_key_id"),
                ["quote_id"] = quoteValidation.QuoteId,
                ["quote_path"] = ToWorkspaceRelativePath(workspaceRoot, quoteValidation.QuotePath),
                ["quote_sha256"] = quoteValidation.QuoteSha256,
                ["source_asset_code"] = ReadString(quote, "source_asset_code"),
                ["destination_asset_code"] = ReadString(quote, "destination_asset_code"),
                ["source_amount_base_units"] = ReadInt64(quote, "source_amount_base_units"),
                ["fee_base_units"] = ReadInt64(quote, "fee_base_units"),
                ["total_source_debit_base_units"] = totalSourceDebit,
                ["destination_amount_base_units"] = ReadInt64(quote, "destination_amount_base_units"),
                ["source_ledger_event_id"] = sourceEvent.EventId,
                ["source_ledger_event_path"] = ToWorkspaceRelativePath(workspaceRoot, sourceEvent.EventPath),
                ["source_ledger_event_hash_sha256"] = sourceEvent.EventHashSha256,
                ["destination_ledger_event_id"] = destinationEvent.EventId,
                ["destination_ledger_event_path"] = ToWorkspaceRelativePath(workspaceRoot, destinationEvent.EventPath),
                ["destination_ledger_event_hash_sha256"] = destinationEvent.EventHashSha256,
                ["execution_status"] = "executed",
                ["guaranteed_conversion"] = false,
                ["fixed_parity"] = false,
                ["stable_value_claim"] = false,
                ["summary"] = "Executed floating-rate ARCH/CC conversion linked to accepted quote and balance-changing ledger events."
            };
            var unsignedPayload = JsonSerializer.Serialize(unsignedRecord, JsonOptions);
            var unsignedPayloadBytes = Encoding.UTF8.GetBytes(unsignedPayload);
            var signature = new PassportWalletKeyService(releaseLane).SignWalletPayload(
                walletKeyReferencePath,
                walletPublicKeyPath,
                unsignedPayloadBytes);
            if (!signature.Succeeded)
            {
                throw new InvalidOperationException(signature.Message);
            }

            unsignedRecord["wallet_signature"] = new Dictionary<string, object?>
            {
                ["signature_algorithm"] = "RSA_PKCS1_SHA256",
                ["signature_base64"] = signature.SignatureBase64,
                ["signed_payload_sha256"] = signature.PayloadSha256,
                ["wallet_public_key_path"] = ToWorkspaceRelativePath(workspaceRoot, walletPublicKeyPath),
                ["verified_with_wallet_key"] = signature.VerifiedWithWalletKey
            };
            File.WriteAllText(executionRecordPath, JsonSerializer.Serialize(unsignedRecord, JsonOptions), Encoding.UTF8);
            return executionRecordPath;
        }

        private static string GetTransferOutEventType(string assetCode)
        {
            return assetCode == PassportMonetaryLedgerService.AssetArch
                ? PassportMonetaryLedgerService.EventArchTransferOut
                : PassportMonetaryLedgerService.EventCrownCreditTransferOut;
        }

        private static string GetTransferInEventType(string assetCode)
        {
            return assetCode == PassportMonetaryLedgerService.AssetArch
                ? PassportMonetaryLedgerService.EventArchTransferIn
                : PassportMonetaryLedgerService.EventCrownCreditTransferIn;
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

        private static PassportConversionExecutionResult Failed(string message)
        {
            return new PassportConversionExecutionResult
            {
                Succeeded = false,
                Message = message
            };
        }
    }
}
