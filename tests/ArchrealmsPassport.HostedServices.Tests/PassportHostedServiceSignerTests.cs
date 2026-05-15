using Xunit;

namespace ArchrealmsPassport.HostedServices.Tests;

public sealed class PassportHostedServiceSignerTests
{
    [Fact]
    public void ServiceSignerAddsVerifiableSignatureAndChangesRecordHash()
    {
        using var workspace = TemporaryDirectory.Create();
        var signer = new PassportHostedServiceSigner(System.IO.Path.Combine(workspace.Path, "keys", "service.pkcs8"));
        var response = new Contracts.PassportHostedRecordResponse
        {
            Succeeded = true,
            Message = "created",
            RecordId = "record-1",
            RecordSha256 = new string('a', 64),
            Record = new Dictionary<string, object?>
            {
                ["schema_version"] = 1,
                ["record_type"] = "passport_cc_capacity_report",
                ["record_id"] = "record-1"
            }
        };

        var signed = signer.Sign(response, "cc_capacity_report");

        Assert.NotEqual(response.RecordSha256, signed.RecordSha256);
        Assert.NotNull(signed.Record);
        Assert.True(signed.Record!.ContainsKey("service_signature"));
        Assert.True(PassportHostedServiceSigner.VerifySignedRecord(signed.Record));
        Assert.True(File.Exists(System.IO.Path.Combine(workspace.Path, "keys", "service.pkcs8")));
        Assert.True(File.Exists(System.IO.Path.Combine(workspace.Path, "keys", "service.spki.der")));
    }

    [Fact]
    public void ServiceSignerRejectsTamperedSignedRecords()
    {
        using var workspace = TemporaryDirectory.Create();
        var signer = new PassportHostedServiceSigner(System.IO.Path.Combine(workspace.Path, "keys", "service.pkcs8"));
        var signed = signer.Sign(new Contracts.PassportHostedRecordResponse
        {
            Succeeded = true,
            Message = "created",
            RecordId = "record-1",
            RecordSha256 = new string('a', 64),
            Record = new Dictionary<string, object?>
            {
                ["schema_version"] = 1,
                ["record_type"] = "passport_cc_capacity_report",
                ["record_id"] = "record-1"
            }
        }, "cc_capacity_report");

        signed.Record!["record_type"] = "tampered";

        Assert.False(PassportHostedServiceSigner.VerifySignedRecord(signed.Record));
    }

    private sealed class TemporaryDirectory : IDisposable
    {
        private TemporaryDirectory(string path)
        {
            Path = path;
            Directory.CreateDirectory(path);
        }

        public string Path { get; }

        public static TemporaryDirectory Create()
        {
            return new TemporaryDirectory(System.IO.Path.Combine(System.IO.Path.GetTempPath(), "archrealms-hosted-signer-tests", Guid.NewGuid().ToString("N")));
        }

        public void Dispose()
        {
            try
            {
                if (Directory.Exists(Path))
                {
                    Directory.Delete(Path, true);
                }
            }
            catch
            {
            }
        }
    }
}
