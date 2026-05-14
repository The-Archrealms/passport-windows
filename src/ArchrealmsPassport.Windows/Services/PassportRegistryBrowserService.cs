using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Security.Cryptography;
using System.Text.Json;
using ArchrealmsPassport.Windows.Models;

namespace ArchrealmsPassport.Windows.Services
{
    public sealed class PassportRegistryBrowserService
    {
        public IReadOnlyList<PassportRegistryRecordSummary> ListRecords(string workspaceRoot, string filterText = "")
        {
            var resolvedWorkspaceRoot = PassportEnvironment.ResolveWorkspaceRoot(workspaceRoot);
            var recordsRoot = Path.Combine(resolvedWorkspaceRoot, "records");
            if (!Directory.Exists(recordsRoot))
            {
                return Array.Empty<PassportRegistryRecordSummary>();
            }

            var filter = (filterText ?? string.Empty).Trim();
            var records = new List<PassportRegistryRecordSummary>();
            foreach (var path in Directory.EnumerateFiles(recordsRoot, "*.json", SearchOption.AllDirectories))
            {
                var summary = TryReadRecordSummary(resolvedWorkspaceRoot, path);
                if (summary == null)
                {
                    continue;
                }

                if (!MatchesFilter(summary, filter))
                {
                    continue;
                }

                records.Add(summary);
            }

            return records
                .OrderByDescending(record => record.CreatedUtc, StringComparer.Ordinal)
                .ThenBy(record => record.RecordType, StringComparer.Ordinal)
                .ThenBy(record => record.RecordId, StringComparer.Ordinal)
                .ToArray();
        }

        public string FormatRecordList(IReadOnlyList<PassportRegistryRecordSummary> records)
        {
            if (records.Count == 0)
            {
                return "No registry records found.";
            }

            return string.Join(
                Environment.NewLine + Environment.NewLine,
                records.Select(record =>
                    record.RecordType
                    + " | "
                    + record.RecordId
                    + " | "
                    + record.Status
                    + Environment.NewLine
                    + "created: "
                    + record.CreatedUtc
                    + Environment.NewLine
                    + "sha256: "
                    + record.Sha256
                    + Environment.NewLine
                    + "path: "
                    + record.RelativePath));
        }

        private static PassportRegistryRecordSummary? TryReadRecordSummary(string workspaceRoot, string path)
        {
            try
            {
                using var document = JsonDocument.Parse(File.ReadAllText(path));
                var root = document.RootElement;
                if (!root.TryGetProperty("record_type", out var recordType) || recordType.ValueKind != JsonValueKind.String)
                {
                    return null;
                }

                return new PassportRegistryRecordSummary
                {
                    RecordType = recordType.GetString() ?? string.Empty,
                    RecordId = ReadString(root, "record_id", "event_id", "quote_id", "execution_id", "correction_id"),
                    CreatedUtc = ReadString(root, "created_utc"),
                    Status = ReadString(root, "status", "record_stage", "signature_status"),
                    RelativePath = ToWorkspaceRelativePath(workspaceRoot, path),
                    Sha256 = ComputeSha256(File.ReadAllBytes(path))
                };
            }
            catch
            {
                return null;
            }
        }

        private static bool MatchesFilter(PassportRegistryRecordSummary record, string filter)
        {
            if (string.IsNullOrWhiteSpace(filter))
            {
                return true;
            }

            return Contains(record.RecordType, filter)
                || Contains(record.RecordId, filter)
                || Contains(record.Status, filter)
                || Contains(record.RelativePath, filter)
                || Contains(record.Sha256, filter);
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

        private static bool Contains(string value, string filter)
        {
            return (value ?? string.Empty).IndexOf(filter, StringComparison.OrdinalIgnoreCase) >= 0;
        }

        private static string ToWorkspaceRelativePath(string workspaceRoot, string path)
        {
            return Path.GetRelativePath(workspaceRoot, path).Replace(Path.DirectorySeparatorChar, '/');
        }

        private static string ComputeSha256(byte[] value)
        {
            return Convert.ToHexString(SHA256.HashData(value)).ToLowerInvariant();
        }
    }
}
