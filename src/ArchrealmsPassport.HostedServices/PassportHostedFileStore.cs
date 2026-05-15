using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using ArchrealmsPassport.HostedServices.Contracts;

namespace ArchrealmsPassport.HostedServices;

public sealed class PassportHostedFileStore : IPassportHostedStore
{
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        WriteIndented = true
    };

    private readonly string root;

    public PassportHostedFileStore(string root)
    {
        this.root = Path.GetFullPath(root);
        Directory.CreateDirectory(this.root);
        Directory.CreateDirectory(SessionRoot);
        Directory.CreateDirectory(RecordRoot);
        Directory.CreateDirectory(AppendLogRoot);
    }

    public string Root => root;

    private string SessionRoot => Path.Combine(root, "records", "ai", "sessions");

    private string RecordRoot => Path.Combine(root, "records", "hosted");

    private string AppendLogRoot => Path.Combine(root, "append-log");

    public static PassportHostedFileStore FromEnvironment()
    {
        var configuredRoot = Environment.GetEnvironmentVariable("ARCHREALMS_PASSPORT_HOSTED_DATA_ROOT");
        if (!string.IsNullOrWhiteSpace(configuredRoot))
        {
            return new PassportHostedFileStore(configuredRoot);
        }

        var appData = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
        if (string.IsNullOrWhiteSpace(appData))
        {
            appData = AppContext.BaseDirectory;
        }

        return new PassportHostedFileStore(Path.Combine(appData, "Archrealms", "PassportHostedServices"));
    }

    public void SaveAiSession(Dictionary<string, object?> sessionRecord)
    {
        var sessionId = ReadString(sessionRecord, "session_id");
        if (string.IsNullOrWhiteSpace(sessionId))
        {
            return;
        }

        var path = Path.Combine(SessionRoot, NormalizeFileName(sessionId) + ".json");
        WriteJson(path, sessionRecord);
        Append("ai_session", sessionId, ComputeFileSha256(path), path);
    }

    public bool TryGetAiSession(string sessionId, out PassportAiSessionAuthorizationResponse session)
    {
        var path = Path.Combine(SessionRoot, NormalizeFileName(sessionId) + ".json");
        if (!File.Exists(path))
        {
            session = default!;
            return false;
        }

        using var document = JsonDocument.Parse(File.ReadAllText(path));
        var root = document.RootElement;
        var sessionRecord = JsonSerializer.Deserialize<Dictionary<string, object?>>(root.GetRawText(), JsonOptions)
            ?? new Dictionary<string, object?>();
        session = new PassportAiSessionAuthorizationResponse
        {
            Succeeded = true,
            SessionId = ReadString(root, "session_id"),
            SessionTokenSha256 = ReadString(root, "session_token_sha256"),
            ExpiresUtc = ReadString(root, "expires_utc"),
            MessageQuota = ReadQuota(root, "message_limit"),
            TokenQuota = ReadQuota(root, "token_limit"),
            Session = sessionRecord
        };
        return true;
    }

    public void SaveRecord(string recordId, Dictionary<string, object?> record, string recordSha256)
    {
        if (string.IsNullOrWhiteSpace(recordId))
        {
            recordId = DateTime.UtcNow.ToString("yyyyMMddTHHmmssZ") + "-hosted-record";
        }

        var path = Path.Combine(RecordRoot, NormalizeFileName(recordId) + ".json");
        WriteJson(path, record);
        var hash = string.IsNullOrWhiteSpace(recordSha256) ? ComputeFileSha256(path) : recordSha256.Trim().ToLowerInvariant();
        File.WriteAllText(path + ".sha256", hash + Environment.NewLine, Encoding.UTF8);
        Append(ReadString(record, "record_type"), recordId, hash, path);
    }

    public bool TryGetRecord(string recordId, out StoredHostedRecord record)
    {
        var path = Path.Combine(RecordRoot, NormalizeFileName(recordId) + ".json");
        if (!File.Exists(path))
        {
            record = default!;
            return false;
        }

        var parsed = JsonSerializer.Deserialize<Dictionary<string, object?>>(File.ReadAllText(path), JsonOptions)
            ?? new Dictionary<string, object?>();
        var hashPath = path + ".sha256";
        var hash = File.Exists(hashPath) ? File.ReadAllText(hashPath).Trim() : ComputeFileSha256(path);
        record = new StoredHostedRecord(parsed, hash);
        return true;
    }

    private void Append(string recordType, string recordId, string recordSha256, string path)
    {
        var appendPath = Path.Combine(AppendLogRoot, DateTime.UtcNow.ToString("yyyyMMdd") + ".jsonl");
        var appendRecord = new Dictionary<string, object?>
        {
            ["schema_version"] = 1,
            ["record_type"] = "passport_hosted_append_log_entry",
            ["created_utc"] = DateTimeOffset.UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ"),
            ["hosted_record_type"] = string.IsNullOrWhiteSpace(recordType) ? "hosted_record" : recordType,
            ["hosted_record_id"] = recordId,
            ["hosted_record_sha256"] = recordSha256,
            ["hosted_record_path"] = ToStoreRelativePath(path)
        };
        File.AppendAllText(appendPath, JsonSerializer.Serialize(appendRecord) + Environment.NewLine, Encoding.UTF8);
    }

    private static void WriteJson(string path, object value)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(path) ?? string.Empty);
        File.WriteAllText(path, JsonSerializer.Serialize(value, JsonOptions), Encoding.UTF8);
    }

    private string ToStoreRelativePath(string path)
    {
        var fullRoot = Path.GetFullPath(root).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
        var fullPath = Path.GetFullPath(path);
        return fullPath.StartsWith(fullRoot, StringComparison.OrdinalIgnoreCase)
            ? fullPath[fullRoot.Length..].TrimStart(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar).Replace(Path.DirectorySeparatorChar, '/')
            : fullPath.Replace(Path.DirectorySeparatorChar, '/');
    }

    private static string ReadString(Dictionary<string, object?> record, string name)
    {
        return record.TryGetValue(name, out var value) ? value?.ToString() ?? string.Empty : string.Empty;
    }

    private static string ReadString(JsonElement root, string name)
    {
        return root.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.String ? value.GetString() ?? string.Empty : string.Empty;
    }

    private static int ReadQuota(JsonElement root, string quotaName)
    {
        if (!root.TryGetProperty("quota", out var quota)
            || !quota.TryGetProperty(quotaName, out var value)
            || !value.TryGetInt32(out var parsed))
        {
            return 0;
        }

        return parsed;
    }

    private static string NormalizeFileName(string value)
    {
        var normalized = new string((value ?? string.Empty)
            .Select(character => char.IsLetterOrDigit(character) || character is '-' or '_' or '.' ? character : '_')
            .ToArray());
        return string.IsNullOrWhiteSpace(normalized) ? "record" : normalized;
    }

    private static string ComputeFileSha256(string path)
    {
        return ComputeSha256(File.ReadAllBytes(path));
    }

    private static string ComputeSha256(byte[] value)
    {
        return Convert.ToHexString(SHA256.HashData(value)).ToLowerInvariant();
    }
}
