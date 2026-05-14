using System.Linq;
using ArchrealmsPassport.Windows.Services;
using ArchrealmsPassport.Windows.Tests.Infrastructure;
using Xunit;

namespace ArchrealmsPassport.Windows.Tests;

public sealed class PassportRegistryBrowserServiceTests
{
    [Fact]
    public void RegistryBrowserIndexesLocalWorkspaceRecords()
    {
        using var workspace = PassportTestWorkspace.Create();

        var records = new PassportRegistryBrowserService().ListRecords(workspace.Root);

        Assert.Contains(records, record => record.RecordType == "passport_identity_record");
        Assert.Contains(records, record => record.RecordType == "device_credential_record");
        Assert.All(records, record => Assert.False(string.IsNullOrWhiteSpace(record.Sha256)));
    }

    [Fact]
    public void RegistryBrowserFiltersRecords()
    {
        using var workspace = PassportTestWorkspace.Create();

        var records = new PassportRegistryBrowserService().ListRecords(workspace.Root, "device_credential");

        Assert.NotEmpty(records);
        Assert.All(records, record => Assert.Contains("device_credential", record.RecordType));
        Assert.DoesNotContain(records, record => record.RecordType == "passport_identity_record");
    }

    [Fact]
    public void RegistryBrowserFormatsRecordDetails()
    {
        using var workspace = PassportTestWorkspace.Create();
        var service = new PassportRegistryBrowserService();

        var records = service.ListRecords(workspace.Root);
        var formatted = service.FormatRecordList(records.Take(1).ToArray());

        Assert.Contains("sha256:", formatted);
        Assert.Contains("path:", formatted);
    }
}
