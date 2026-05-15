using System.Text.Json;
using Xunit;

namespace ArchrealmsPassport.HostedServices.Tests;

public sealed class PassportHostedFileStoreTests
{
    [Fact]
    public void FileStorePersistsAiSessionsAndAppendLogWithoutBearerToken()
    {
        using var workspace = TemporaryDirectory.Create();
        var store = new PassportHostedFileStore(workspace.Path);
        var sessionRecord = new Dictionary<string, object?>
        {
            ["schema_version"] = 1,
            ["record_type"] = "passport_ai_session_record",
            ["record_id"] = "session-1",
            ["session_id"] = "session-1",
            ["expires_utc"] = DateTimeOffset.UtcNow.AddMinutes(30).ToString("yyyy-MM-ddTHH:mm:ssZ"),
            ["session_token_sha256"] = new string('a', 64),
            ["quota"] = new Dictionary<string, object?>
            {
                ["message_limit"] = 25,
                ["token_limit"] = 10000,
                ["messages_used"] = 0,
                ["tokens_used"] = 0
            }
        };

        store.SaveAiSession(sessionRecord);

        Assert.True(store.TryGetAiSession("session-1", out var session));
        Assert.Equal("session-1", session.SessionId);
        Assert.Equal(25, session.MessageQuota);
        Assert.Equal(10000, session.TokenQuota);
        Assert.DoesNotContain(Directory.EnumerateFiles(workspace.Path, "*", SearchOption.AllDirectories),
            path => File.ReadAllText(path).Contains("bearer", StringComparison.OrdinalIgnoreCase));
        Assert.NotEmpty(Directory.EnumerateFiles(System.IO.Path.Combine(workspace.Path, "append-log"), "*.jsonl"));
    }

    [Fact]
    public void FileStorePersistsHostedRecordsWithHashSidecar()
    {
        using var workspace = TemporaryDirectory.Create();
        var store = new PassportHostedFileStore(workspace.Path);
        var record = new Dictionary<string, object?>
        {
            ["schema_version"] = 1,
            ["record_type"] = "passport_cc_capacity_report",
            ["record_id"] = "capacity-1",
            ["max_issuance_base_units"] = 100
        };
        var hash = new string('b', 64);

        store.SaveRecord("capacity-1", record, hash);

        Assert.True(store.TryGetRecord("capacity-1", out var stored));
        Assert.Equal(hash, stored.RecordSha256);
        Assert.Equal("passport_cc_capacity_report", stored.Record["record_type"]?.ToString());
        var recordFile = Directory.EnumerateFiles(System.IO.Path.Combine(workspace.Path, "records", "hosted"), "capacity-1.json").Single();
        Assert.True(File.Exists(recordFile + ".sha256"));
        using var appendEntry = JsonDocument.Parse(File.ReadLines(Directory.EnumerateFiles(System.IO.Path.Combine(workspace.Path, "append-log"), "*.jsonl").Single()).Single());
        Assert.Equal("passport_hosted_append_log_entry", appendEntry.RootElement.GetProperty("record_type").GetString());
    }

    [Fact]
    public void FileStoreReadsRedactedAppendLogTelemetry()
    {
        using var workspace = TemporaryDirectory.Create();
        var store = new PassportHostedFileStore(workspace.Path);
        var record = new Dictionary<string, object?>
        {
            ["schema_version"] = 1,
            ["record_type"] = "passport_storage_delivery_acceptance",
            ["record_id"] = "storage-delivery-1"
        };

        store.SaveRecord("storage-delivery-1", record, new string('c', 64));

        var entries = store.ReadAppendLogTelemetry(
            DateTimeOffset.UtcNow.AddMinutes(-5),
            DateTimeOffset.UtcNow.AddMinutes(5),
            10);

        var entry = Assert.Single(entries);
        Assert.Equal("passport_storage_delivery_acceptance", entry.HostedRecordType);
        Assert.Equal("storage-delivery-1", entry.HostedRecordId);
        Assert.Equal(new string('c', 64), entry.HostedRecordSha256);
        Assert.DoesNotContain("hosted_record_path", JsonSerializer.Serialize(entries), StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public void FileStoreCreatesBackupManifestEntriesForRecordsAndAppendLogOnly()
    {
        using var workspace = TemporaryDirectory.Create();
        var store = new PassportHostedFileStore(workspace.Path);
        store.SaveRecord("capacity-1", new Dictionary<string, object?>
        {
            ["schema_version"] = 1,
            ["record_type"] = "passport_cc_capacity_report",
            ["record_id"] = "capacity-1"
        }, new string('d', 64));
        store.SaveAiSession(new Dictionary<string, object?>
        {
            ["schema_version"] = 1,
            ["record_type"] = "passport_ai_session_record",
            ["record_id"] = "session-1",
            ["session_id"] = "session-1",
            ["expires_utc"] = DateTimeOffset.UtcNow.AddMinutes(30).ToString("yyyy-MM-ddTHH:mm:ssZ")
        });
        Directory.CreateDirectory(System.IO.Path.Combine(workspace.Path, "keys"));
        File.WriteAllText(System.IO.Path.Combine(workspace.Path, "keys", "hosted-service-signing-key.pkcs8"), "private-key");

        var entries = store.CreateBackupManifestEntries();

        Assert.Contains(entries, entry => entry.RelativePath == "records/hosted/capacity-1.json");
        Assert.Contains(entries, entry => entry.RelativePath.StartsWith("records/ai/sessions/", StringComparison.Ordinal));
        Assert.Contains(entries, entry => entry.RelativePath.StartsWith("append-log/", StringComparison.Ordinal));
        Assert.DoesNotContain(entries, entry => entry.RelativePath.StartsWith("keys/", StringComparison.Ordinal));
        Assert.All(entries, entry => Assert.Matches("^[0-9a-f]{64}$", entry.Sha256));
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
            return new TemporaryDirectory(System.IO.Path.Combine(System.IO.Path.GetTempPath(), "archrealms-hosted-tests", Guid.NewGuid().ToString("N")));
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
