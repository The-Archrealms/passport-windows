using System.Text.Json;
using ArchrealmsPassport.Core.Protocol;
using Xunit;

namespace ArchrealmsPassport.Core.Tests;

public sealed class PassportMonetaryLedgerExportVerifierTests
{
    private static readonly JsonSerializerOptions JsonOptions = new() { WriteIndented = true };

    [Fact]
    public void VerifiesEmptyPortableAccountExportPackage()
    {
        using var export = TestExport.Create();
        export.WriteEmptyExport();

        var result = PassportMonetaryLedgerExportVerifier.Verify(
            export.Root,
            new PassportMonetaryLedgerReplayOptions
            {
                ExpectedReleaseLane = "staging",
                ExpectedLedgerNamespace = "archrealms-passport-staging"
            });

        Assert.True(result.Succeeded, string.Join("; ", result.Failures));
        Assert.Equal(0, result.EventCount);
        Assert.False(string.IsNullOrWhiteSpace(result.ExportRootSha256));
    }

    [Fact]
    public void ReportsMissingManifest()
    {
        using var export = TestExport.Create();

        var result = PassportMonetaryLedgerExportVerifier.Verify(export.Root);

        Assert.False(result.Succeeded);
        Assert.Contains("Missing account export manifest.", result.Failures);
    }

    [Fact]
    public void ReportsTransparencyRootMismatch()
    {
        using var export = TestExport.Create();
        export.WriteEmptyExport(manifestRootHash: new string('a', 64));

        var result = PassportMonetaryLedgerExportVerifier.Verify(export.Root);

        Assert.False(result.Succeeded);
        Assert.Contains(result.Failures, failure => failure.Contains("Transparency root hash does not match manifest.", StringComparison.Ordinal));
    }

    private sealed class TestExport : IDisposable
    {
        private TestExport(string root)
        {
            Root = root;
        }

        public string Root { get; }

        public static TestExport Create()
        {
            var root = Path.Combine(Path.GetTempPath(), "archrealms-core-export-tests", Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(root);
            return new TestExport(root);
        }

        public void WriteEmptyExport(string? manifestRootHash = null)
        {
            var emptyRoot = PassportMonetaryLedgerExportVerifier.ComputeMerkleRoot(Array.Empty<string>());
            var manifestHash = manifestRootHash ?? emptyRoot;
            WriteJson(
                Path.Combine(Root, "transparency-root.json"),
                new Dictionary<string, object?>
                {
                    ["schema_version"] = 1,
                    ["record_type"] = "passport_monetary_transparency_root",
                    ["record_id"] = "empty-root",
                    ["created_utc"] = "2026-05-15T00:00:00Z",
                    ["release_lane"] = "staging",
                    ["ledger_namespace"] = "archrealms-passport-staging",
                    ["root_algorithm"] = "merkle_sha256_v1",
                    ["event_leaves"] = Array.Empty<object>(),
                    ["epoch_root_sha256"] = emptyRoot
                });
            WriteJson(
                Path.Combine(Root, "manifest.json"),
                new Dictionary<string, object?>
                {
                    ["schema_version"] = 1,
                    ["record_type"] = "passport_monetary_account_export",
                    ["record_id"] = "empty-export",
                    ["created_utc"] = "2026-05-15T00:00:00Z",
                    ["release_lane"] = "staging",
                    ["ledger_namespace"] = "archrealms-passport-staging",
                    ["events"] = Array.Empty<object>(),
                    ["balances"] = Array.Empty<object>(),
                    ["account_hash_chain"] = Array.Empty<object>(),
                    ["key_history"] = Array.Empty<object>(),
                    ["transparency_root_sha256"] = manifestHash,
                    ["transparency_root_export_path"] = "transparency-root.json"
                });
        }

        public void Dispose()
        {
            try
            {
                if (Directory.Exists(Root))
                {
                    Directory.Delete(Root, true);
                }
            }
            catch
            {
            }
        }

        private static void WriteJson(string path, object value)
        {
            Directory.CreateDirectory(Path.GetDirectoryName(path) ?? string.Empty);
            File.WriteAllText(path, JsonSerializer.Serialize(value, JsonOptions));
        }
    }
}
