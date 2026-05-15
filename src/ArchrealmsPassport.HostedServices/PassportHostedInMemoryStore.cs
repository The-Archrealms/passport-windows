using ArchrealmsPassport.HostedServices.Contracts;

namespace ArchrealmsPassport.HostedServices;

public sealed class PassportHostedInMemoryStore : IPassportHostedStore
{
    private readonly Dictionary<string, PassportAiSessionAuthorizationResponse> aiSessions = new(StringComparer.Ordinal);
    private readonly Dictionary<string, StoredHostedRecord> records = new(StringComparer.Ordinal);

    public void SaveAiSession(Dictionary<string, object?> sessionRecord)
    {
        var sessionId = ReadString(sessionRecord, "session_id");
        var tokenSha256 = ReadString(sessionRecord, "session_token_sha256");
        if (string.IsNullOrWhiteSpace(sessionId) || string.IsNullOrWhiteSpace(tokenSha256))
        {
            return;
        }

        aiSessions[sessionId] = new PassportAiSessionAuthorizationResponse
        {
            Succeeded = true,
            SessionId = sessionId,
            SessionTokenSha256 = tokenSha256,
            ExpiresUtc = ReadString(sessionRecord, "expires_utc"),
            MessageQuota = ReadQuota(sessionRecord, "message_limit"),
            TokenQuota = ReadQuota(sessionRecord, "token_limit"),
            Session = sessionRecord
        };
    }

    public bool TryGetAiSession(string sessionId, out PassportAiSessionAuthorizationResponse session)
    {
        return aiSessions.TryGetValue(sessionId, out session!);
    }

    public void SaveRecord(string recordId, Dictionary<string, object?> record, string recordSha256)
    {
        records[recordId] = new StoredHostedRecord(record, recordSha256);
    }

    public bool TryGetRecord(string recordId, out StoredHostedRecord record)
    {
        return records.TryGetValue(recordId, out record!);
    }

    private static string ReadString(Dictionary<string, object?> record, string name)
    {
        return record.TryGetValue(name, out var value) ? value?.ToString() ?? string.Empty : string.Empty;
    }

    private static int ReadQuota(Dictionary<string, object?> sessionRecord, string name)
    {
        if (!sessionRecord.TryGetValue("quota", out var quotaValue)
            || quotaValue is not Dictionary<string, object?> quota
            || !quota.TryGetValue(name, out var value))
        {
            return 0;
        }

        return value is int intValue ? intValue : Convert.ToInt32(value);
    }
}

public interface IPassportHostedSessionStore
{
    void SaveAiSession(Dictionary<string, object?> sessionRecord);

    bool TryGetAiSession(string sessionId, out PassportAiSessionAuthorizationResponse session);
}

public interface IPassportHostedStore : IPassportHostedSessionStore
{
    void SaveRecord(string recordId, Dictionary<string, object?> record, string recordSha256);

    bool TryGetRecord(string recordId, out StoredHostedRecord record);
}

public sealed record StoredHostedRecord(Dictionary<string, object?> Record, string RecordSha256);
