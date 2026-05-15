using System.Linq;
using System.IO;
using ArchrealmsPassport.Core.Protocol;
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

        var fixtureFiles = Directory.EnumerateFiles(Path.Combine(workspace.Root, "records"), "*.json", SearchOption.AllDirectories).ToArray();
        Assert.NotEmpty(fixtureFiles);
        var firstInspection = PassportRegistryRecordInspector.Inspect(File.ReadAllBytes(fixtureFiles[0]), fixtureFiles[0]);
        Assert.True(firstInspection.IsRecord, fixtureFiles[0] + " " + string.Join(",", firstInspection.ValidationFailures));

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
        var proofSource = workspace.WriteProofSource("registry-proof-source.bin", "storage proof source content");
        var proof = new PassportRecordService().CreateStorageEpochProof(
            workspace.Root,
            workspace.IdentityId,
            workspace.DeviceId,
            workspace.KeyReferencePath,
            "node-test",
            "assignment-test",
            "bafyregistrycontent",
            PassportTestWorkspace.ComputeFileSha256(proofSource),
            "mvp_storage",
            proofSource);
        Assert.True(proof.Succeeded, proof.Message);

        var service = new PassportRegistryBrowserService();
        var proofRecords = service.ListRecords(workspace.Root, "storage_epoch_proof_record");
        var proofSummary = Assert.Single(proofRecords);

        Assert.Equal("bafyregistrycontent", proofSummary.Cid);
        Assert.False(string.IsNullOrWhiteSpace(proofSummary.SignaturePath));
        Assert.False(string.IsNullOrWhiteSpace(proofSummary.SignedPayloadPath));

        var formatted = service.FormatRecordDetail(proofSummary);

        Assert.Contains("cid:", formatted);
        Assert.Contains("schema:", formatted);
        Assert.Contains("signature:", formatted);
        Assert.Contains("signed payload:", formatted);
        Assert.Contains("sha256:", formatted);
        Assert.Contains("path:", formatted);
    }
}
