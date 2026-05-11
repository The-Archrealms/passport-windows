using System;
using System.IO;
using ArchrealmsPassport.Windows.Services;
using Xunit;

namespace ArchrealmsPassport.Windows.Tests;

public sealed class PassportEnvironmentTests
{
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
