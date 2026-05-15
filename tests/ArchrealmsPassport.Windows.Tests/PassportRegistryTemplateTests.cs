using System;
using System.IO;
using System.Text.Json;
using ArchrealmsPassport.Core.Protocol;
using Xunit;

namespace ArchrealmsPassport.Windows.Tests;

public sealed class PassportRegistryTemplateTests
{
    [Fact]
    public void RegistryTemplatesAreValidJson()
    {
        var templatesRoot = FindTemplatesRoot();

        foreach (var templatePath in Directory.EnumerateFiles(templatesRoot, "*.template.json"))
        {
            using var document = JsonDocument.Parse(File.ReadAllText(templatePath));
            Assert.True(document.RootElement.TryGetProperty("schema_version", out _), templatePath);
            Assert.True(document.RootElement.TryGetProperty("record_type", out _), templatePath);

            var inspection = PassportRegistryRecordInspector.Inspect(File.ReadAllBytes(templatePath), Path.GetFileName(templatePath));
            Assert.True(inspection.IsRecord, templatePath);
            Assert.False(string.IsNullOrWhiteSpace(inspection.SchemaVersion), templatePath);
        }
    }

    [Theory]
    [InlineData("monetary-ledger-event-record.template.json", "passport_monetary_ledger_event")]
    [InlineData("wallet-key-binding-record.template.json", "passport_wallet_key_binding")]
    [InlineData("admin-authority-record.template.json", "passport_admin_authority")]
    [InlineData("crown-credit-capacity-report-record.template.json", "passport_cc_capacity_report")]
    [InlineData("arch-cc-conversion-quote-record.template.json", "passport_arch_cc_conversion_quote")]
    [InlineData("arch-cc-conversion-execution-record.template.json", "passport_arch_cc_conversion_execution")]
    [InlineData("storage-redemption-record.template.json", "passport_storage_redemption")]
    [InlineData("ledger-correction-record.template.json", "passport_ledger_correction")]
    [InlineData("monetary-transparency-root-record.template.json", "passport_monetary_transparency_root")]
    [InlineData("monetary-account-export-record.template.json", "passport_monetary_account_export")]
    public void MonetaryTemplatesArePresentAndTyped(string fileName, string recordType)
    {
        var templatePath = Path.Combine(FindTemplatesRoot(), fileName);

        using var document = JsonDocument.Parse(File.ReadAllText(templatePath));

        Assert.Equal(recordType, document.RootElement.GetProperty("record_type").GetString());
        Assert.True(document.RootElement.TryGetProperty("release_lane", out _), fileName);
        Assert.True(document.RootElement.TryGetProperty("ledger_namespace", out _), fileName);
        Assert.True(document.RootElement.TryGetProperty("policy_version", out _), fileName);
    }

    private static string FindTemplatesRoot()
    {
        var current = new DirectoryInfo(AppContext.BaseDirectory);
        while (current != null)
        {
            var candidate = Path.Combine(current.FullName, "registry", "templates");
            if (Directory.Exists(candidate))
            {
                return candidate;
            }

            current = current.Parent;
        }

        throw new DirectoryNotFoundException("Could not locate registry/templates from " + AppContext.BaseDirectory);
    }
}
