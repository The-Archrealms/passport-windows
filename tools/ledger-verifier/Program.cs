using System;
using System.Collections.Generic;
using System.IO;
using System.Text.Json;
using ArchrealmsPassport.Core.Protocol;

namespace Archrealms.LedgerVerifier;

internal static class Program
{
    private static readonly JsonSerializerOptions JsonOptions = new() { WriteIndented = true };

    private static int Main(string[] args)
    {
        try
        {
            if (args.Length < 1)
            {
                Console.Error.WriteLine("Usage: Archrealms.LedgerVerifier <account-export-root> [output-path] [release-lane]");
                return 1;
            }

            var exportRoot = Path.GetFullPath(args[0]);
            var outputPath = args.Length > 1 && !string.IsNullOrWhiteSpace(args[1])
                ? Path.GetFullPath(args[1])
                : Path.Combine(exportRoot, "verification-report.json");
            var manifestPath = Path.Combine(exportRoot, "manifest.json");
            if (!File.Exists(manifestPath))
            {
                throw new FileNotFoundException("The account export manifest was not found.", manifestPath);
            }

            var releaseLaneName = args.Length > 2 && !string.IsNullOrWhiteSpace(args[2])
                ? args[2]
                : ReadManifestString(manifestPath, "release_lane", "staging");
            var ledgerNamespace = ReadManifestString(manifestPath, "ledger_namespace", string.Empty);
            var verification = PassportMonetaryLedgerExportVerifier.Verify(
                exportRoot,
                new PassportMonetaryLedgerReplayOptions
                {
                    ExpectedReleaseLane = releaseLaneName,
                    ExpectedLedgerNamespace = ledgerNamespace
                });
            var report = new Dictionary<string, object?>
            {
                ["verified_utc"] = DateTime.UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ"),
                ["export_root"] = exportRoot,
                ["release_lane"] = verification.ReleaseLane,
                ["ledger_namespace"] = verification.LedgerNamespace,
                ["event_count"] = verification.EventCount,
                ["export_root_sha256"] = verification.ExportRootSha256,
                ["verified"] = verification.Succeeded,
                ["message"] = verification.Message,
                ["failures"] = verification.Failures
            };

            var outputDirectory = Path.GetDirectoryName(outputPath);
            if (!string.IsNullOrWhiteSpace(outputDirectory))
            {
                Directory.CreateDirectory(outputDirectory);
            }

            File.WriteAllText(outputPath, JsonSerializer.Serialize(report, JsonOptions) + Environment.NewLine);

            Console.WriteLine();
            Console.WriteLine("Archrealms monetary account export verification recorded:");
            Console.WriteLine("  Export   : " + exportRoot);
            Console.WriteLine("  Report   : " + outputPath);
            Console.WriteLine("  Verified : " + verification.Succeeded);
            if (!verification.Succeeded)
            {
                foreach (var failure in verification.Failures)
                {
                    Console.WriteLine("  Failure  : " + failure);
                }
            }

            return verification.Succeeded ? 0 : 2;
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine(ex.Message);
            return 1;
        }
    }

    private static string ReadManifestString(string manifestPath, string propertyName, string fallback)
    {
        using var document = JsonDocument.Parse(File.ReadAllText(manifestPath));
        return document.RootElement.TryGetProperty(propertyName, out var element)
            ? element.GetString() ?? fallback
            : fallback;
    }
}
