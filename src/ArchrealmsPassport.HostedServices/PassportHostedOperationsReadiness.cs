using System.Text.Json.Serialization;

namespace ArchrealmsPassport.HostedServices;

public sealed record PassportHostedOperationsReadiness
{
    [JsonPropertyName("schema")]
    public string Schema { get; init; } = "archrealms.passport.hosted_operations_readiness.v1";

    [JsonPropertyName("ready")]
    public bool Ready { get; init; }

    [JsonPropertyName("missing")]
    public string[] Missing { get; init; } = Array.Empty<string>();

    [JsonPropertyName("storage_provider")]
    public string StorageProvider { get; init; } = string.Empty;

    [JsonPropertyName("data_root_configured")]
    public bool DataRootConfigured { get; init; }

    [JsonPropertyName("backup_policy_uri_configured")]
    public bool BackupPolicyUriConfigured { get; init; }

    [JsonPropertyName("restore_runbook_uri_configured")]
    public bool RestoreRunbookUriConfigured { get; init; }

    [JsonPropertyName("signing_key_provider")]
    public string SigningKeyProvider { get; init; } = string.Empty;

    [JsonPropertyName("signing_key_id_configured")]
    public bool SigningKeyIdConfigured { get; init; }

    [JsonPropertyName("signing_key_custody")]
    public string SigningKeyCustody { get; init; } = string.Empty;

    [JsonPropertyName("local_signing_key_path_configured")]
    public bool LocalSigningKeyPathConfigured { get; init; }

    [JsonPropertyName("telemetry_destination_configured")]
    public bool TelemetryDestinationConfigured { get; init; }

    [JsonPropertyName("telemetry_retention_policy_uri_configured")]
    public bool TelemetryRetentionPolicyUriConfigured { get; init; }

    [JsonPropertyName("incident_response_runbook_uri_configured")]
    public bool IncidentResponseRunbookUriConfigured { get; init; }

    [JsonPropertyName("incident_response_owner_configured")]
    public bool IncidentResponseOwnerConfigured { get; init; }

    public static PassportHostedOperationsReadiness FromEnvironment()
    {
        return FromValues(
            Environment.GetEnvironmentVariable("ARCHREALMS_PASSPORT_HOSTED_DATA_ROOT"),
            Environment.GetEnvironmentVariable("ARCHREALMS_PASSPORT_HOSTED_STORAGE_PROVIDER"),
            Environment.GetEnvironmentVariable("ARCHREALMS_PASSPORT_HOSTED_STORAGE_BACKUP_POLICY_URI"),
            Environment.GetEnvironmentVariable("ARCHREALMS_PASSPORT_HOSTED_STORAGE_RESTORE_RUNBOOK_URI"),
            Environment.GetEnvironmentVariable("ARCHREALMS_PASSPORT_HOSTED_SIGNING_KEY_PROVIDER"),
            Environment.GetEnvironmentVariable("ARCHREALMS_PASSPORT_HOSTED_SIGNING_KEY_ID"),
            Environment.GetEnvironmentVariable("ARCHREALMS_PASSPORT_HOSTED_SIGNING_KEY_CUSTODY"),
            Environment.GetEnvironmentVariable("ARCHREALMS_PASSPORT_HOSTED_SIGNING_KEY_PATH"),
            Environment.GetEnvironmentVariable("ARCHREALMS_PASSPORT_TELEMETRY_DESTINATION"),
            Environment.GetEnvironmentVariable("ARCHREALMS_PASSPORT_TELEMETRY_RETENTION_POLICY_URI"),
            Environment.GetEnvironmentVariable("ARCHREALMS_PASSPORT_INCIDENT_RESPONSE_RUNBOOK_URI"),
            Environment.GetEnvironmentVariable("ARCHREALMS_PASSPORT_INCIDENT_RESPONSE_OWNER"));
    }

    public static PassportHostedOperationsReadiness FromValues(
        string? dataRoot,
        string? storageProvider,
        string? backupPolicyUri,
        string? restoreRunbookUri,
        string? signingKeyProvider,
        string? signingKeyId,
        string? signingKeyCustody,
        string? localSigningKeyPath,
        string? telemetryDestination,
        string? telemetryRetentionPolicyUri,
        string? incidentResponseRunbookUri,
        string? incidentResponseOwner)
    {
        var missing = new List<string>();
        var normalizedStorageProvider = Normalize(storageProvider);
        var normalizedSigningKeyProvider = Normalize(signingKeyProvider);
        var normalizedSigningKeyCustody = Normalize(signingKeyCustody).ToLowerInvariant();

        AddIfMissing(missing, "ARCHREALMS_PASSPORT_HOSTED_DATA_ROOT", dataRoot);
        AddIfMissing(missing, "ARCHREALMS_PASSPORT_HOSTED_STORAGE_PROVIDER", normalizedStorageProvider);
        AddIfMissing(missing, "ARCHREALMS_PASSPORT_HOSTED_STORAGE_BACKUP_POLICY_URI", backupPolicyUri);
        AddIfMissing(missing, "ARCHREALMS_PASSPORT_HOSTED_STORAGE_RESTORE_RUNBOOK_URI", restoreRunbookUri);
        AddIfMissing(missing, "ARCHREALMS_PASSPORT_HOSTED_SIGNING_KEY_PROVIDER", normalizedSigningKeyProvider);
        AddIfMissing(missing, "ARCHREALMS_PASSPORT_HOSTED_SIGNING_KEY_ID", signingKeyId);
        AddIfMissing(missing, "ARCHREALMS_PASSPORT_HOSTED_SIGNING_KEY_CUSTODY", normalizedSigningKeyCustody);
        AddIfMissing(missing, "ARCHREALMS_PASSPORT_TELEMETRY_DESTINATION", telemetryDestination);
        AddIfMissing(missing, "ARCHREALMS_PASSPORT_TELEMETRY_RETENTION_POLICY_URI", telemetryRetentionPolicyUri);
        AddIfMissing(missing, "ARCHREALMS_PASSPORT_INCIDENT_RESPONSE_RUNBOOK_URI", incidentResponseRunbookUri);
        AddIfMissing(missing, "ARCHREALMS_PASSPORT_INCIDENT_RESPONSE_OWNER", incidentResponseOwner);

        if (!string.IsNullOrWhiteSpace(normalizedSigningKeyCustody)
            && normalizedSigningKeyCustody is not "managed" and not "kms" and not "hsm" and not "managed-hsm" and not "cloud-kms")
        {
            missing.Add("ARCHREALMS_PASSPORT_HOSTED_SIGNING_KEY_CUSTODY must be managed/kms/hsm");
        }

        if (!string.IsNullOrWhiteSpace(localSigningKeyPath))
        {
            missing.Add("ARCHREALMS_PASSPORT_HOSTED_SIGNING_KEY_PATH must not be used for production managed custody");
        }

        return new PassportHostedOperationsReadiness
        {
            Ready = missing.Count == 0,
            Missing = missing.ToArray(),
            StorageProvider = normalizedStorageProvider,
            DataRootConfigured = !string.IsNullOrWhiteSpace(dataRoot),
            BackupPolicyUriConfigured = !string.IsNullOrWhiteSpace(backupPolicyUri),
            RestoreRunbookUriConfigured = !string.IsNullOrWhiteSpace(restoreRunbookUri),
            SigningKeyProvider = normalizedSigningKeyProvider,
            SigningKeyIdConfigured = !string.IsNullOrWhiteSpace(signingKeyId),
            SigningKeyCustody = normalizedSigningKeyCustody,
            LocalSigningKeyPathConfigured = !string.IsNullOrWhiteSpace(localSigningKeyPath),
            TelemetryDestinationConfigured = !string.IsNullOrWhiteSpace(telemetryDestination),
            TelemetryRetentionPolicyUriConfigured = !string.IsNullOrWhiteSpace(telemetryRetentionPolicyUri),
            IncidentResponseRunbookUriConfigured = !string.IsNullOrWhiteSpace(incidentResponseRunbookUri),
            IncidentResponseOwnerConfigured = !string.IsNullOrWhiteSpace(incidentResponseOwner)
        };
    }

    private static void AddIfMissing(List<string> missing, string name, string? value)
    {
        if (string.IsNullOrWhiteSpace(value))
        {
            missing.Add(name);
        }
    }

    private static string Normalize(string? value)
    {
        return string.IsNullOrWhiteSpace(value) ? string.Empty : value.Trim();
    }
}
