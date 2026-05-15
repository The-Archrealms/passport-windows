using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using ArchrealmsPassport.Core.Protocol;
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
                if (Path.GetFileName(path).EndsWith(".payload.json", StringComparison.OrdinalIgnoreCase))
                {
                    continue;
                }

                var summary = TryReadRecordSummary(resolvedWorkspaceRoot, path);
                if (summary == null)
                {
                    continue;
                }

                if (!PassportRegistryRecordInspector.MatchesFilter(ToCoreSummary(summary), filter))
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
                    FormatRecordDetail(record)));
        }

        public string FormatRecordDetail(PassportRegistryRecordSummary record)
        {
            var lines = new List<string>
            {
                record.RecordType + " | " + record.RecordId + " | " + record.Status,
                "schema: " + record.SchemaVersion,
                "created: " + record.CreatedUtc,
                "sha256: " + record.Sha256,
                "path: " + record.RelativePath
            };

            if (record.ValidationFailures.Count > 0)
            {
                lines.Add("validation: " + string.Join(", ", record.ValidationFailures));
            }

            AddDetailLine(lines, "cid", record.Cid);
            AddDetailLine(lines, "signed payload", record.SignedPayloadPath);
            AddDetailLine(lines, "signed payload sha256", record.SignedPayloadSha256);
            AddDetailLine(lines, "signature", record.SignaturePath);
            AddDetailLine(lines, "wallet public key", record.WalletPublicKeyPath);
            AddDetailLine(lines, "wallet payload sha256", record.WalletSignedPayloadSha256);
            return string.Join(Environment.NewLine, lines);
        }

        private static PassportRegistryRecordSummary? TryReadRecordSummary(string workspaceRoot, string path)
        {
            try
            {
                var inspection = PassportRegistryRecordInspector.Inspect(
                    File.ReadAllBytes(path),
                    ToWorkspaceRelativePath(workspaceRoot, path));
                if (!inspection.IsRecord)
                {
                    return null;
                }

                return new PassportRegistryRecordSummary
                {
                    SchemaVersion = inspection.SchemaVersion,
                    RecordType = inspection.RecordType,
                    RecordId = inspection.RecordId,
                    CreatedUtc = inspection.CreatedUtc,
                    Status = inspection.Status,
                    RelativePath = inspection.RelativePath,
                    Sha256 = inspection.Sha256,
                    Cid = inspection.Cid,
                    SignedPayloadPath = inspection.SignedPayloadPath,
                    SignedPayloadSha256 = inspection.SignedPayloadSha256,
                    SignaturePath = inspection.SignaturePath,
                    WalletPublicKeyPath = inspection.WalletPublicKeyPath,
                    WalletSignedPayloadSha256 = inspection.WalletSignedPayloadSha256,
                    ValidationFailures = inspection.ValidationFailures
                };
            }
            catch
            {
                return null;
            }
        }

        private static void AddDetailLine(List<string> lines, string label, string value)
        {
            if (!string.IsNullOrWhiteSpace(value))
            {
                lines.Add(label + ": " + value);
            }
        }

        private static string ToWorkspaceRelativePath(string workspaceRoot, string path)
        {
            return Path.GetRelativePath(workspaceRoot, path).Replace(Path.DirectorySeparatorChar, '/');
        }

        private static PassportRegistryRecordInspection ToCoreSummary(PassportRegistryRecordSummary summary)
        {
            return new PassportRegistryRecordInspection
            {
                IsRecord = true,
                SchemaVersion = summary.SchemaVersion,
                RecordType = summary.RecordType,
                RecordId = summary.RecordId,
                CreatedUtc = summary.CreatedUtc,
                Status = summary.Status,
                RelativePath = summary.RelativePath,
                Sha256 = summary.Sha256,
                Cid = summary.Cid,
                SignedPayloadPath = summary.SignedPayloadPath,
                SignedPayloadSha256 = summary.SignedPayloadSha256,
                SignaturePath = summary.SignaturePath,
                WalletPublicKeyPath = summary.WalletPublicKeyPath,
                WalletSignedPayloadSha256 = summary.WalletSignedPayloadSha256,
                ValidationFailures = summary.ValidationFailures
            };
        }
    }
}
