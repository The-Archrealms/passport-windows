using Xunit;

namespace ArchrealmsPassport.HostedServices.Tests;

public sealed class PassportHostedStorageReadinessTests
{
    [Fact]
    public void StorageReadinessVerifiesWritableRootsAndBackupEnumeration()
    {
        using var workspace = TemporaryDirectory.Create();
        var store = new PassportHostedFileStore(workspace.Path);
        store.SaveRecord("capacity-1", new Dictionary<string, object?>
        {
            ["record_type"] = "passport_cc_capacity_report",
            ["record_id"] = "capacity-1"
        }, new string('a', 64));

        var readiness = PassportHostedStorageReadiness.FromFileStore(store);

        Assert.True(readiness.Ready, string.Join("; ", readiness.Missing));
        Assert.True(readiness.DataRootWritable);
        Assert.True(readiness.RecordsWritable);
        Assert.True(readiness.AppendLogWritable);
        Assert.True(readiness.BackupManifestEnumerable);
        Assert.True(readiness.BackupManifestEntryCount > 0);
        Assert.Empty(Directory.EnumerateFiles(workspace.Path, ".readiness-*.tmp", SearchOption.AllDirectories));
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
            return new TemporaryDirectory(System.IO.Path.Combine(System.IO.Path.GetTempPath(), "archrealms-hosted-storage-readiness-tests", Guid.NewGuid().ToString("N")));
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
