using System.Text;
using System.Text.Json.Serialization;

namespace ArchrealmsPassport.HostedServices;

public sealed record PassportHostedStorageReadiness
{
    [JsonPropertyName("schema")]
    public string Schema { get; init; } = "archrealms.passport.hosted_storage_readiness.v1";

    [JsonPropertyName("ready")]
    public bool Ready { get; init; }

    [JsonPropertyName("missing")]
    public string[] Missing { get; init; } = Array.Empty<string>();

    [JsonPropertyName("data_root_configured")]
    public bool DataRootConfigured { get; init; }

    [JsonPropertyName("data_root_writable")]
    public bool DataRootWritable { get; init; }

    [JsonPropertyName("records_writable")]
    public bool RecordsWritable { get; init; }

    [JsonPropertyName("append_log_writable")]
    public bool AppendLogWritable { get; init; }

    [JsonPropertyName("backup_manifest_enumerable")]
    public bool BackupManifestEnumerable { get; init; }

    [JsonPropertyName("backup_manifest_entry_count")]
    public int BackupManifestEntryCount { get; init; }

    public static PassportHostedStorageReadiness FromFileStore(PassportHostedFileStore store)
    {
        var missing = new List<string>();
        var dataRootConfigured = !string.IsNullOrWhiteSpace(store.Root);
        var dataRootWritable = TryWriteDelete(Path.Combine(store.Root, ".readiness-" + Guid.NewGuid().ToString("N") + ".tmp"), missing, "hosted data root writable probe failed");
        var recordsRoot = Path.Combine(store.Root, "records", "hosted");
        var recordsWritable = TryWriteDelete(Path.Combine(recordsRoot, ".readiness-" + Guid.NewGuid().ToString("N") + ".tmp"), missing, "hosted records writable probe failed");
        var appendLogRoot = Path.Combine(store.Root, "append-log");
        var appendLogWritable = TryWriteDelete(Path.Combine(appendLogRoot, ".readiness-" + Guid.NewGuid().ToString("N") + ".tmp"), missing, "hosted append-log writable probe failed");

        var backupManifestEnumerable = false;
        var backupManifestEntryCount = 0;
        try
        {
            backupManifestEntryCount = store.CreateBackupManifestEntries().Length;
            backupManifestEnumerable = true;
        }
        catch (Exception exception)
        {
            missing.Add("hosted backup manifest enumeration failed: " + exception.Message);
        }

        if (!dataRootConfigured)
        {
            missing.Add("ARCHREALMS_PASSPORT_HOSTED_DATA_ROOT");
        }

        return new PassportHostedStorageReadiness
        {
            Ready = missing.Count == 0,
            Missing = missing.ToArray(),
            DataRootConfigured = dataRootConfigured,
            DataRootWritable = dataRootWritable,
            RecordsWritable = recordsWritable,
            AppendLogWritable = appendLogWritable,
            BackupManifestEnumerable = backupManifestEnumerable,
            BackupManifestEntryCount = backupManifestEntryCount
        };
    }

    private static bool TryWriteDelete(string path, List<string> missing, string failurePrefix)
    {
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(path) ?? string.Empty);
            File.WriteAllText(path, "archrealms-passport-hosted-storage-readiness", Encoding.UTF8);
            _ = File.ReadAllText(path, Encoding.UTF8);
            File.Delete(path);
            return true;
        }
        catch (Exception exception)
        {
            missing.Add(failurePrefix + ": " + exception.Message);
            return false;
        }
    }
}
