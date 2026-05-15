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
    public sealed class PassportArchGenesisService
    {
        private static readonly JsonSerializerOptions JsonOptions = new JsonSerializerOptions
        {
            WriteIndented = true
        };

        private readonly PassportReleaseLane releaseLane;

        public PassportArchGenesisService(PassportReleaseLane? releaseLane = null)
        {
            this.releaseLane = releaseLane ?? PassportEnvironment.GetReleaseLane();
        }

        public PassportArchGenesisResult CreateGenesisManifest(
            string workspaceRoot,
            long totalSupplyBaseUnits,
            int baseUnitPrecision,
            IEnumerable<PassportArchGenesisAllocation> allocations)
        {
            try
            {
                var resolvedWorkspaceRoot = PassportEnvironment.ResolveWorkspaceRoot(workspaceRoot);
                if (totalSupplyBaseUnits <= 0)
                {
                    return Failed("ARCH genesis total supply must be greater than zero.");
                }

                if (baseUnitPrecision < 0 || baseUnitPrecision > 18)
                {
                    return Failed("ARCH base-unit precision must be between 0 and 18 decimals.");
                }

                var normalizedAllocations = NormalizeAllocations(allocations).ToArray();
                if (normalizedAllocations.Length == 0)
                {
                    return Failed("ARCH genesis manifest requires at least one allocation.");
                }

                var allocationTotal = normalizedAllocations.Sum(item => item.AmountBaseUnits);
                if (allocationTotal != totalSupplyBaseUnits)
                {
                    return Failed("ARCH genesis allocation total must equal fixed total supply.");
                }

                var duplicateAllocationIds = normalizedAllocations
                    .GroupBy(item => item.AllocationId, StringComparer.Ordinal)
                    .Where(group => group.Count() > 1)
                    .Select(group => group.Key)
                    .ToArray();
                if (duplicateAllocationIds.Length > 0)
                {
                    return Failed("ARCH genesis allocation IDs must be unique.");
                }

                var timestamp = DateTime.UtcNow.ToString("yyyyMMddTHHmmssZ");
                var createdUtc = DateTime.UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ");
                var manifestRoot = Path.Combine(resolvedWorkspaceRoot, "records", "passport", "monetary", "arch-genesis");
                Directory.CreateDirectory(manifestRoot);
                var recordId = timestamp + "-arch-genesis-" + releaseLane.Lane;
                var manifestPath = Path.Combine(manifestRoot, recordId + ".json");
                var manifest = new Dictionary<string, object?>
                {
                    ["schema_version"] = 1,
                    ["record_type"] = "passport_arch_genesis_manifest",
                    ["record_id"] = recordId,
                    ["created_utc"] = createdUtc,
                    ["release_lane"] = releaseLane.Lane,
                    ["ledger_namespace"] = releaseLane.LedgerNamespace,
                    ["policy_version"] = releaseLane.PolicyVersion,
                    ["asset_code"] = PassportMonetaryLedgerService.AssetArch,
                    ["total_supply_base_units"] = totalSupplyBaseUnits,
                    ["base_unit_precision"] = baseUnitPrecision,
                    ["allocation_total_base_units"] = allocationTotal,
                    ["post_genesis_minting_allowed"] = false,
                    ["sealed"] = true,
                    ["allocations"] = normalizedAllocations.Select(item => new Dictionary<string, object?>
                    {
                        ["allocation_id"] = item.AllocationId,
                        ["account_id"] = item.AccountId,
                        ["archrealms_identity_id"] = item.IdentityId,
                        ["wallet_key_id"] = item.WalletKeyId,
                        ["amount_base_units"] = item.AmountBaseUnits
                    }).ToArray(),
                    ["summary"] = "Fixed-genesis ARCH manifest. The allocation total equals total supply and post-genesis minting is disabled."
                };

                File.WriteAllText(manifestPath, JsonSerializer.Serialize(manifest, JsonOptions), Encoding.UTF8);
                return new PassportArchGenesisResult
                {
                    Succeeded = true,
                    Message = "ARCH genesis manifest created.",
                    ManifestPath = manifestPath,
                    ManifestSha256 = ComputeSha256(File.ReadAllBytes(manifestPath)),
                    TotalSupplyBaseUnits = totalSupplyBaseUnits
                };
            }
            catch (Exception ex)
            {
                return Failed("ARCH genesis manifest creation failed: " + ex.Message);
            }
        }

        public PassportArchGenesisResult ValidateAllocation(
            string workspaceRoot,
            string accountId,
            string identityId,
            string walletKeyId,
            long amountBaseUnits,
            IDictionary<string, string> evidenceReferences)
        {
            try
            {
                if (!evidenceReferences.TryGetValue("arch_genesis_manifest_path", out var manifestReference)
                    || string.IsNullOrWhiteSpace(manifestReference))
                {
                    return Failed("Production ARCH genesis allocation requires arch_genesis_manifest_path evidence.");
                }

                if (!evidenceReferences.TryGetValue("arch_genesis_manifest_sha256", out var expectedManifestSha256)
                    || string.IsNullOrWhiteSpace(expectedManifestSha256))
                {
                    return Failed("Production ARCH genesis allocation requires arch_genesis_manifest_sha256 evidence.");
                }

                if (!evidenceReferences.TryGetValue("arch_genesis_allocation_id", out var allocationId)
                    || string.IsNullOrWhiteSpace(allocationId))
                {
                    return Failed("Production ARCH genesis allocation requires arch_genesis_allocation_id evidence.");
                }

                var resolvedWorkspaceRoot = PassportEnvironment.ResolveWorkspaceRoot(workspaceRoot);
                var manifestPath = ResolveWorkspaceRelativePath(resolvedWorkspaceRoot, manifestReference);
                if (!File.Exists(manifestPath))
                {
                    return Failed("ARCH genesis manifest could not be found.");
                }

                var actualManifestSha256 = ComputeSha256(File.ReadAllBytes(manifestPath));
                if (!string.Equals(actualManifestSha256, expectedManifestSha256.Trim(), StringComparison.OrdinalIgnoreCase))
                {
                    return Failed("ARCH genesis manifest hash does not match evidence.");
                }

                using var document = JsonDocument.Parse(File.ReadAllText(manifestPath));
                var root = document.RootElement;
                if (!Matches(root, "record_type", "passport_arch_genesis_manifest"))
                {
                    return Failed("ARCH genesis evidence is not a genesis manifest.");
                }

                if (!Matches(root, "release_lane", releaseLane.Lane)
                    || !Matches(root, "ledger_namespace", releaseLane.LedgerNamespace))
                {
                    return Failed("ARCH genesis manifest belongs to another release lane or ledger namespace.");
                }

                if (!Matches(root, "asset_code", PassportMonetaryLedgerService.AssetArch))
                {
                    return Failed("ARCH genesis manifest has the wrong asset code.");
                }

                if (ReadBool(root, "post_genesis_minting_allowed"))
                {
                    return Failed("ARCH genesis manifest must disable post-genesis minting.");
                }

                if (!ReadBool(root, "sealed"))
                {
                    return Failed("ARCH genesis manifest must be sealed.");
                }

                var totalSupply = ReadInt64(root, "total_supply_base_units");
                var allocationTotal = ReadInt64(root, "allocation_total_base_units");
                if (totalSupply <= 0 || allocationTotal != totalSupply)
                {
                    return Failed("ARCH genesis manifest allocation total must equal fixed total supply.");
                }

                if (!root.TryGetProperty("allocations", out var allocations) || allocations.ValueKind != JsonValueKind.Array)
                {
                    return Failed("ARCH genesis manifest has no allocations.");
                }

                foreach (var allocation in allocations.EnumerateArray())
                {
                    if (!string.Equals(ReadString(allocation, "allocation_id"), allocationId.Trim(), StringComparison.Ordinal))
                    {
                        continue;
                    }

                    if (!string.Equals(ReadString(allocation, "account_id"), accountId.Trim(), StringComparison.Ordinal)
                        || !string.Equals(ReadString(allocation, "archrealms_identity_id"), identityId.Trim(), StringComparison.Ordinal)
                        || !string.Equals(ReadString(allocation, "wallet_key_id"), walletKeyId.Trim(), StringComparison.Ordinal)
                        || ReadInt64(allocation, "amount_base_units") != amountBaseUnits)
                    {
                        return Failed("ARCH genesis allocation evidence does not match the ledger event.");
                    }

                    return new PassportArchGenesisResult
                    {
                        Succeeded = true,
                        Message = "ARCH genesis allocation evidence is valid.",
                        ManifestPath = manifestPath,
                        ManifestSha256 = actualManifestSha256,
                        TotalSupplyBaseUnits = totalSupply,
                        AllocationAmountBaseUnits = amountBaseUnits
                    };
                }

                return Failed("ARCH genesis allocation ID was not found in the manifest.");
            }
            catch (Exception ex)
            {
                return Failed("ARCH genesis allocation validation failed: " + ex.Message);
            }
        }

        private static IEnumerable<PassportArchGenesisAllocation> NormalizeAllocations(IEnumerable<PassportArchGenesisAllocation> allocations)
        {
            foreach (var allocation in allocations ?? Array.Empty<PassportArchGenesisAllocation>())
            {
                var normalized = new PassportArchGenesisAllocation
                {
                    AllocationId = NormalizeRequired(allocation.AllocationId, "allocation ID"),
                    AccountId = NormalizeRequired(allocation.AccountId, "account ID"),
                    IdentityId = NormalizeRequired(allocation.IdentityId, "identity ID"),
                    WalletKeyId = NormalizeRequired(allocation.WalletKeyId, "wallet key ID"),
                    AmountBaseUnits = allocation.AmountBaseUnits
                };

                if (normalized.AmountBaseUnits <= 0)
                {
                    throw new InvalidOperationException("ARCH genesis allocation amount must be greater than zero.");
                }

                yield return normalized;
            }
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
            return string.Equals(ReadString(root, propertyName), expected, StringComparison.Ordinal);
        }

        private static string ReadString(JsonElement root, string propertyName)
        {
            return root.TryGetProperty(propertyName, out var property) && property.ValueKind == JsonValueKind.String
                ? property.GetString() ?? string.Empty
                : string.Empty;
        }

        private static long ReadInt64(JsonElement root, string propertyName)
        {
            return root.TryGetProperty(propertyName, out var property) && property.ValueKind == JsonValueKind.Number && property.TryGetInt64(out var value)
                ? value
                : 0;
        }

        private static bool ReadBool(JsonElement root, string propertyName)
        {
            return root.TryGetProperty(propertyName, out var property) && property.ValueKind == JsonValueKind.True;
        }

        private static string ComputeSha256(byte[] value)
        {
            return Convert.ToHexString(SHA256.HashData(value)).ToLowerInvariant();
        }

        private static PassportArchGenesisResult Failed(string message)
        {
            return new PassportArchGenesisResult
            {
                Succeeded = false,
                Message = message
            };
        }
    }
}
