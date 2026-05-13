using System;
using System.IO;
using System.Text.Json;
using ArchrealmsPassport.Windows.Services;
using Xunit;

namespace ArchrealmsPassport.Windows.Tests;

public sealed class PassportEnvironmentTests
{
    [Theory]
    [InlineData("dev", "PassportWindows-dev", false, false)]
    [InlineData("staging", "PassportWindows-staging", false, true)]
    [InlineData("canary-mvp", "PassportWindows-canary-mvp", true, false)]
    [InlineData("production-mvp", "PassportWindows", true, false)]
    public void ReleaseLaneDefaultsKeepProductionAndNonProductionRootsSeparate(
        string lane,
        string appDataFolderName,
        bool allowProductionTokenRecords,
        bool allowStagingRecords)
    {
        var releaseLane = PassportReleaseLane.CreateDefault(lane);

        Assert.Equal(PassportReleaseLane.NormalizeLane(lane), releaseLane.Lane);
        Assert.Equal(appDataFolderName, releaseLane.AppDataFolderName);
        Assert.Equal(allowProductionTokenRecords, releaseLane.AllowProductionTokenRecords);
        Assert.Equal(allowStagingRecords, releaseLane.AllowStagingRecords);
        Assert.StartsWith("archrealms-passport-", releaseLane.LedgerNamespace);
    }

    [Fact]
    public void ReleaseLaneManifestParsesStagingIsolationMetadata()
    {
        var json = "{" +
            "\"lane\":\"staging\"," +
            "\"lane_display_name\":\"Staging\"," +
            "\"package_channel\":\"sideload\"," +
            "\"package_identity\":\"TheArchrealms.PassportWindows.Staging.Sideload\"," +
            "\"ledger_namespace\":\"archrealms-passport-staging\"," +
            "\"telemetry_environment\":\"staging\"," +
            "\"issuer_key_scope\":\"passport-staging\"," +
            "\"allow_production_token_records\":false," +
            "\"allow_staging_records\":true," +
            "\"production_ledger\":false" +
            "}";

        using var document = JsonDocument.Parse(json);
        var releaseLane = PassportReleaseLane.FromJson(document.RootElement);

        Assert.Equal("staging", releaseLane.Lane);
        Assert.Equal("PassportWindows-staging", releaseLane.AppDataFolderName);
        Assert.Equal("archrealms-passport-staging", releaseLane.LedgerNamespace);
        Assert.False(releaseLane.AllowProductionTokenRecords);
        Assert.True(releaseLane.AllowStagingRecords);
        Assert.False(releaseLane.ProductionLedger);
    }

    [Fact]
    public void ResolveIpfsCliPathPrefersExplicitOverrideBeforeEnvironmentAndBundledRuntime()
    {
        var root = Path.Combine(Path.GetTempPath(), "passport-env-test-" + Guid.NewGuid().ToString("N"));
        var explicitRoot = Path.Combine(root, "explicit");
        var environmentRoot = Path.Combine(root, "environment");
        var bundledRoot = Path.Combine(root, "tools", "ipfs", "runtime");
        Directory.CreateDirectory(explicitRoot);
        Directory.CreateDirectory(environmentRoot);
        Directory.CreateDirectory(bundledRoot);

        var explicitIpfs = Path.Combine(explicitRoot, "ipfs.exe");
        var environmentIpfs = Path.Combine(environmentRoot, "ipfs.exe");
        var bundledIpfs = Path.Combine(bundledRoot, "ipfs.exe");
        File.WriteAllText(explicitIpfs, string.Empty);
        File.WriteAllText(environmentIpfs, string.Empty);
        File.WriteAllText(bundledIpfs, string.Empty);

        var oldEnvironment = Environment.GetEnvironmentVariable("ARCHREALMS_IPFS_CLI");
        try
        {
            Environment.SetEnvironmentVariable("ARCHREALMS_IPFS_CLI", environmentIpfs);

            var resolved = PassportEnvironment.ResolveIpfsCliPath(root, explicitIpfs);
            var source = PassportEnvironment.DescribeIpfsCliSource(resolved, root, explicitIpfs);

            Assert.Equal(Path.GetFullPath(explicitIpfs), resolved);
            Assert.Equal("Configured override", source);
        }
        finally
        {
            Environment.SetEnvironmentVariable("ARCHREALMS_IPFS_CLI", oldEnvironment);
            Directory.Delete(root, true);
        }
    }
}
