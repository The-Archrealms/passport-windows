using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace ArchrealmsPassport.Core.Protocol;

public sealed record PassportRegistryRecordInspection
{
    public bool IsRecord { get; init; }

    public string SchemaVersion { get; init; } = string.Empty;

    public string RecordType { get; init; } = string.Empty;

    public string RecordId { get; init; } = string.Empty;

    public string CreatedUtc { get; init; } = string.Empty;

    public string Status { get; init; } = string.Empty;

    public string RelativePath { get; init; } = string.Empty;

    public string Sha256 { get; init; } = string.Empty;

    public string Cid { get; init; } = string.Empty;

    public string SignedPayloadPath { get; init; } = string.Empty;

    public string SignedPayloadSha256 { get; init; } = string.Empty;

    public string SignaturePath { get; init; } = string.Empty;

    public string WalletPublicKeyPath { get; init; } = string.Empty;

    public string WalletSignedPayloadSha256 { get; init; } = string.Empty;

    public IReadOnlyList<string> ValidationFailures { get; init; } = Array.Empty<string>();

    public bool IsEnvelopeValid => IsRecord && ValidationFailures.Count == 0;
}

public static class PassportRegistryRecordInspector
{
    public static PassportRegistryRecordInspection Inspect(byte[] recordJson, string relativePath = "")
    {
        var sha256 = ComputeSha256(recordJson);
        try
        {
            using var document = JsonDocument.Parse(DecodeJson(recordJson));
            var root = document.RootElement;
            if (root.ValueKind != JsonValueKind.Object)
            {
                return NotRecord(relativePath, sha256, "root_must_be_object");
            }

            var validationFailures = new List<string>();
            var schemaVersion = ReadSchemaVersion(root);
            if (string.IsNullOrWhiteSpace(schemaVersion))
            {
                validationFailures.Add("schema_version_required");
            }

            var recordType = ReadString(root, "record_type");
            if (string.IsNullOrWhiteSpace(recordType))
            {
                validationFailures.Add("record_type_required");
                return NotRecord(relativePath, sha256, validationFailures);
            }

            var recordId = ReadString(root, "record_id", "event_id", "quote_id", "execution_id", "correction_id");
            if (string.IsNullOrWhiteSpace(recordId))
            {
                validationFailures.Add("record_identifier_required");
            }

            var createdUtc = ReadString(root, "created_utc");
            if (string.IsNullOrWhiteSpace(createdUtc))
            {
                validationFailures.Add("created_utc_required");
            }
            else if (!DateTimeOffset.TryParse(createdUtc, out _))
            {
                validationFailures.Add("created_utc_invalid");
            }

            var inspection = new PassportRegistryRecordInspection
            {
                IsRecord = true,
                SchemaVersion = schemaVersion,
                RecordType = recordType,
                RecordId = recordId,
                CreatedUtc = createdUtc,
                Status = ReadString(root, "status", "record_stage", "signature_status"),
                RelativePath = relativePath,
                Sha256 = sha256,
                Cid = ReadCid(root),
                ValidationFailures = validationFailures.ToArray()
            };

            if (root.TryGetProperty("signature", out var signature))
            {
                if (signature.ValueKind == JsonValueKind.Object)
                {
                    inspection = inspection with
                    {
                        SignedPayloadPath = ReadString(signature, "signed_payload_path"),
                        SignedPayloadSha256 = ReadString(signature, "signed_payload_sha256"),
                        SignaturePath = ReadString(signature, "signature_path")
                    };
                }
                else
                {
                    inspection = inspection with
                    {
                        ValidationFailures = inspection.ValidationFailures.Append("signature_must_be_object").ToArray()
                    };
                }
            }

            if (root.TryGetProperty("wallet_signature", out var walletSignature))
            {
                if (walletSignature.ValueKind == JsonValueKind.Object)
                {
                    inspection = inspection with
                    {
                        WalletPublicKeyPath = ReadString(walletSignature, "wallet_public_key_path"),
                        WalletSignedPayloadSha256 = ReadString(walletSignature, "signed_payload_sha256")
                    };
                }
                else
                {
                    inspection = inspection with
                    {
                        ValidationFailures = inspection.ValidationFailures.Append("wallet_signature_must_be_object").ToArray()
                    };
                }
            }

            return inspection;
        }
        catch
        {
            return NotRecord(relativePath, sha256, "invalid_json");
        }
    }

    public static bool MatchesFilter(PassportRegistryRecordInspection record, string filter)
    {
        if (!record.IsRecord)
        {
            return false;
        }

        if (string.IsNullOrWhiteSpace(filter))
        {
            return true;
        }

        return Contains(record.SchemaVersion, filter)
            || Contains(record.RecordType, filter)
            || Contains(record.RecordId, filter)
            || Contains(record.Status, filter)
            || Contains(record.RelativePath, filter)
            || Contains(record.Sha256, filter)
            || Contains(record.Cid, filter)
            || Contains(record.SignaturePath, filter)
            || Contains(record.SignedPayloadPath, filter)
            || Contains(record.SignedPayloadSha256, filter)
            || Contains(record.WalletPublicKeyPath, filter)
            || Contains(record.WalletSignedPayloadSha256, filter)
            || record.ValidationFailures.Any(failure => Contains(failure, filter));
    }

    private static string ReadCid(JsonElement root)
    {
        var direct = ReadString(root, "cid", "root_cid", "content_cid", "registry_submission_cid");
        if (!string.IsNullOrWhiteSpace(direct))
        {
            return direct;
        }

        if (root.TryGetProperty("content_ref", out var contentRef))
        {
            return ReadString(contentRef, "cid");
        }

        if (root.TryGetProperty("source", out var source))
        {
            return ReadString(source, "cid", "root_cid");
        }

        return string.Empty;
    }

    private static string ReadString(JsonElement root, params string[] propertyNames)
    {
        foreach (var propertyName in propertyNames)
        {
            if (root.TryGetProperty(propertyName, out var property) && property.ValueKind == JsonValueKind.String)
            {
                return property.GetString() ?? string.Empty;
            }
        }

        return string.Empty;
    }

    private static string ReadSchemaVersion(JsonElement root)
    {
        if (!root.TryGetProperty("schema_version", out var property))
        {
            return string.Empty;
        }

        return property.ValueKind switch
        {
            JsonValueKind.String => property.GetString() ?? string.Empty,
            JsonValueKind.Number => property.GetRawText(),
            _ => string.Empty
        };
    }

    private static bool Contains(string value, string filter)
    {
        return (value ?? string.Empty).IndexOf(filter, StringComparison.OrdinalIgnoreCase) >= 0;
    }

    private static string ComputeSha256(byte[] value)
    {
        return Convert.ToHexString(SHA256.HashData(value)).ToLowerInvariant();
    }

    private static string DecodeJson(byte[] value)
    {
        return Encoding.UTF8.GetString(value).TrimStart('\uFEFF');
    }

    private static PassportRegistryRecordInspection NotRecord(
        string relativePath,
        string sha256,
        params string[] validationFailures)
    {
        return new PassportRegistryRecordInspection
        {
            IsRecord = false,
            RelativePath = relativePath,
            Sha256 = sha256,
            ValidationFailures = validationFailures
        };
    }

    private static PassportRegistryRecordInspection NotRecord(
        string relativePath,
        string sha256,
        IReadOnlyList<string> validationFailures)
    {
        return new PassportRegistryRecordInspection
        {
            IsRecord = false,
            RelativePath = relativePath,
            Sha256 = sha256,
            ValidationFailures = validationFailures
        };
    }
}
