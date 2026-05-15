using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace ArchrealmsPassport.Core.Protocol;

public sealed record PassportMonetaryLedgerExportVerifierResult
{
    public bool Succeeded { get; init; }

    public string Message { get; init; } = string.Empty;

    public string ExportRootSha256 { get; init; } = string.Empty;

    public string ReleaseLane { get; init; } = string.Empty;

    public string LedgerNamespace { get; init; } = string.Empty;

    public int EventCount { get; init; }

    public IReadOnlyList<string> Failures { get; init; } = Array.Empty<string>();
}

public static class PassportMonetaryLedgerExportVerifier
{
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        WriteIndented = true
    };

    public static PassportMonetaryLedgerExportVerifierResult Verify(
        string exportRoot,
        PassportMonetaryLedgerReplayOptions? replayOptions = null)
    {
        var failures = new List<string>();
        var eventCount = 0;
        var releaseLane = string.Empty;
        var ledgerNamespace = string.Empty;
        var exportRootSha256 = string.Empty;

        try
        {
            var resolvedExportRoot = Path.GetFullPath(NormalizeRequired(exportRoot, "export root"));
            var manifestPath = Path.Combine(resolvedExportRoot, "manifest.json");
            if (!File.Exists(manifestPath))
            {
                failures.Add("Missing account export manifest.");
                return BuildResult(failures, eventCount, exportRootSha256, releaseLane, ledgerNamespace);
            }

            using var manifestDocument = JsonDocument.Parse(File.ReadAllText(manifestPath));
            var manifest = manifestDocument.RootElement;
            releaseLane = ReadString(manifest, "release_lane");
            ledgerNamespace = ReadString(manifest, "ledger_namespace");
            if (!Matches(manifest, "record_type", "passport_monetary_account_export"))
            {
                failures.Add("Invalid account export manifest record type.");
            }

            var options = replayOptions ?? new PassportMonetaryLedgerReplayOptions
            {
                ExpectedReleaseLane = releaseLane,
                ExpectedLedgerNamespace = ledgerNamespace
            };

            if (!string.IsNullOrWhiteSpace(options.ExpectedReleaseLane)
                && !Matches(manifest, "release_lane", options.ExpectedReleaseLane))
            {
                failures.Add("Export release lane does not match verifier release lane.");
            }

            if (!string.IsNullOrWhiteSpace(options.ExpectedLedgerNamespace)
                && !Matches(manifest, "ledger_namespace", options.ExpectedLedgerNamespace))
            {
                failures.Add("Export ledger namespace does not match verifier ledger namespace.");
            }

            var transparencyRootPath = ResolveRelativePath(
                resolvedExportRoot,
                ReadString(manifest, "transparency_root_export_path"));
            if (!File.Exists(transparencyRootPath))
            {
                failures.Add("Missing exported transparency root.");
            }
            else
            {
                VerifyTransparencyRoot(transparencyRootPath, ReadString(manifest, "transparency_root_sha256"), failures);
            }

            if (manifest.TryGetProperty("events", out var events) && events.ValueKind == JsonValueKind.Array)
            {
                foreach (var eventRow in events.EnumerateArray())
                {
                    eventCount++;
                    VerifyExportedEvent(resolvedExportRoot, manifest, eventRow, failures);
                }
            }
            else
            {
                failures.Add("Manifest does not contain an events array.");
            }

            VerifyManifestAccountHashChain(manifest, failures);

            if (manifest.TryGetProperty("key_history", out var keyHistory) && keyHistory.ValueKind == JsonValueKind.Array)
            {
                VerifyKeyHistory(resolvedExportRoot, keyHistory, failures);
            }

            var exportedEvents = ReadExportedEvents(resolvedExportRoot).ToArray();
            var replay = PassportMonetaryLedgerReplayVerifier.Verify(
                exportedEvents.Select(ToReplayEvent),
                options);
            if (!replay.Succeeded)
            {
                failures.AddRange(replay.Failures.Select(failure => "Replay failed: " + failure));
            }
            else
            {
                VerifyManifestBalances(manifest, replay.Balances, failures);
            }

            exportRootSha256 = ComputeDirectoryHash(resolvedExportRoot);
        }
        catch (Exception ex)
        {
            failures.Add("Monetary ledger account export verification failed: " + ex.Message);
        }

        return BuildResult(failures, eventCount, exportRootSha256, releaseLane, ledgerNamespace);
    }

    public static string ComputeEventHash(PassportMonetaryLedgerRecord ledgerEvent)
    {
        var originalHash = ledgerEvent.EventHashSha256;
        ledgerEvent.EventHashSha256 = string.Empty;

        try
        {
            var payload = JsonSerializer.Serialize(ledgerEvent, JsonOptions);
            return ComputeSha256(Encoding.UTF8.GetBytes(payload));
        }
        finally
        {
            ledgerEvent.EventHashSha256 = originalHash;
        }
    }

    public static string ComputeTransparencyLeafHash(PassportMonetaryLedgerRecord ledgerEvent)
    {
        var material = string.Join(
            "\n",
            "passport-monetary-ledger-leaf-v1",
            ledgerEvent.GlobalSequence.ToString(),
            ledgerEvent.EventId,
            ledgerEvent.EventHashSha256);
        return ComputeSha256(Encoding.UTF8.GetBytes(material));
    }

    public static string ComputeMerkleRoot(IReadOnlyList<string> leafHashes)
    {
        if (leafHashes.Count == 0)
        {
            return ComputeSha256(Encoding.UTF8.GetBytes("passport-monetary-ledger-empty-root-v1"));
        }

        var level = leafHashes.Select(NormalizeHash).ToList();
        while (level.Count > 1)
        {
            var next = new List<string>();
            for (var i = 0; i < level.Count; i += 2)
            {
                var left = level[i];
                var right = i + 1 < level.Count ? level[i + 1] : left;
                next.Add(ComputeMerkleParent(left, right));
            }

            level = next;
        }

        return level[0];
    }

    private static void VerifyExportedEvent(
        string exportRoot,
        JsonElement manifest,
        JsonElement eventRow,
        List<string> failures)
    {
        var eventId = ReadString(eventRow, "event_id");
        var relativePath = ReadString(eventRow, "export_path");
        var eventPath = ResolveRelativePath(exportRoot, relativePath);
        if (!File.Exists(eventPath))
        {
            failures.Add("Missing exported event file for event " + eventId + ".");
            return;
        }

        var expectedFileHash = ReadString(eventRow, "event_file_sha256");
        if (!string.IsNullOrWhiteSpace(expectedFileHash))
        {
            var actualFileHash = ComputeSha256(File.ReadAllBytes(eventPath));
            if (!string.Equals(actualFileHash, expectedFileHash, StringComparison.OrdinalIgnoreCase))
            {
                failures.Add("Exported event file hash mismatch for event " + eventId + ".");
            }
        }

        var ledgerEvent = JsonSerializer.Deserialize<PassportMonetaryLedgerRecord>(File.ReadAllText(eventPath));
        if (ledgerEvent == null)
        {
            failures.Add("Unable to parse exported event " + eventId + ".");
            return;
        }

        if (!string.Equals(ledgerEvent.EventId, eventId, StringComparison.Ordinal))
        {
            failures.Add("Exported event ID mismatch for " + eventId + ".");
        }

        if (!string.Equals(ledgerEvent.EventHashSha256, ReadString(eventRow, "event_hash_sha256"), StringComparison.OrdinalIgnoreCase))
        {
            failures.Add("Export manifest event hash mismatch for " + eventId + ".");
        }

        var computedEventHash = ComputeEventHash(ledgerEvent);
        if (!string.Equals(computedEventHash, ledgerEvent.EventHashSha256, StringComparison.OrdinalIgnoreCase))
        {
            failures.Add("Exported event hash is invalid for event " + eventId + ".");
        }

        if (eventRow.TryGetProperty("inclusion_proof", out var proof))
        {
            var leafHash = ComputeTransparencyLeafHash(ledgerEvent);
            if (!string.Equals(leafHash, ReadString(proof, "leaf_hash_sha256"), StringComparison.OrdinalIgnoreCase))
            {
                failures.Add("Inclusion proof leaf hash does not match event " + eventId + ".");
            }

            VerifyMerkleProof(proof, ReadString(manifest, "transparency_root_sha256"), failures);
        }
        else
        {
            failures.Add("Exported event is missing an inclusion proof: " + eventId + ".");
        }
    }

    private static void VerifyTransparencyRoot(string transparencyRootPath, string expectedRootSha256, List<string> failures)
    {
        using var document = JsonDocument.Parse(File.ReadAllText(transparencyRootPath));
        var root = document.RootElement;
        if (!Matches(root, "record_type", "passport_monetary_transparency_root"))
        {
            failures.Add("Invalid transparency root record type.");
            return;
        }

        if (!Matches(root, "root_algorithm", "merkle_sha256_v1"))
        {
            failures.Add("Unsupported transparency root algorithm.");
            return;
        }

        if (!string.Equals(ReadString(root, "epoch_root_sha256"), expectedRootSha256, StringComparison.OrdinalIgnoreCase))
        {
            failures.Add("Transparency root hash does not match manifest.");
        }

        if (!root.TryGetProperty("event_leaves", out var eventLeaves) || eventLeaves.ValueKind != JsonValueKind.Array)
        {
            failures.Add("Transparency root is missing event leaves.");
            return;
        }

        var leafHashes = eventLeaves
            .EnumerateArray()
            .Select(item => ReadString(item, "leaf_hash_sha256"))
            .ToArray();
        var computedRoot = ComputeMerkleRoot(leafHashes);
        if (!string.Equals(computedRoot, expectedRootSha256, StringComparison.OrdinalIgnoreCase))
        {
            failures.Add("Transparency root cannot be recomputed from event leaves.");
        }
    }

    private static bool VerifyMerkleProof(JsonElement proof, string expectedRootSha256, List<string> failures)
    {
        var eventId = ReadString(proof, "event_id");
        var computed = ReadString(proof, "leaf_hash_sha256");
        if (string.IsNullOrWhiteSpace(computed))
        {
            failures.Add("Inclusion proof is missing a leaf hash for event " + eventId + ".");
            return false;
        }

        if (proof.TryGetProperty("siblings", out var siblings) && siblings.ValueKind == JsonValueKind.Array)
        {
            foreach (var sibling in siblings.EnumerateArray())
            {
                var siblingHash = ReadString(sibling, "hash_sha256");
                var position = ReadString(sibling, "position");
                if (string.Equals(position, "left", StringComparison.Ordinal))
                {
                    computed = ComputeMerkleParent(siblingHash, computed);
                }
                else if (string.Equals(position, "right", StringComparison.Ordinal))
                {
                    computed = ComputeMerkleParent(computed, siblingHash);
                }
                else
                {
                    failures.Add("Inclusion proof has an invalid sibling position for event " + eventId + ".");
                    return false;
                }
            }
        }

        var expected = NormalizeHash(expectedRootSha256);
        var proofRoot = NormalizeHash(ReadString(proof, "epoch_root_sha256"));
        if (!string.Equals(proofRoot, expected, StringComparison.Ordinal))
        {
            failures.Add("Inclusion proof root does not match export transparency root for event " + eventId + ".");
            return false;
        }

        if (!string.Equals(NormalizeHash(computed), expected, StringComparison.Ordinal))
        {
            failures.Add("Inclusion proof does not resolve to the transparency root for event " + eventId + ".");
            return false;
        }

        return true;
    }

    public static string ComputeMerkleParent(string leftHash, string rightHash)
    {
        var material = string.Join(
            "\n",
            "passport-monetary-ledger-node-v1",
            NormalizeHash(leftHash),
            NormalizeHash(rightHash));
        return ComputeSha256(Encoding.UTF8.GetBytes(material));
    }

    private static void VerifyKeyHistory(string exportRoot, JsonElement keyHistory, List<string> failures)
    {
        foreach (var item in keyHistory.EnumerateArray())
        {
            var exportPath = ResolveRelativePath(exportRoot, ReadString(item, "export_path"));
            if (!File.Exists(exportPath))
            {
                failures.Add("Missing key-history export material: " + ReadString(item, "export_path") + ".");
                continue;
            }

            var expectedHash = ReadString(item, "sha256");
            var actualHash = ComputeSha256(File.ReadAllBytes(exportPath));
            if (!string.Equals(actualHash, expectedHash, StringComparison.OrdinalIgnoreCase))
            {
                failures.Add("Key-history export material hash mismatch: " + ReadString(item, "export_path") + ".");
            }

            if (ReadString(item, "export_path").Contains("records/passport/wallet/keys/", StringComparison.OrdinalIgnoreCase))
            {
                failures.Add("Account export must not include protected wallet private key material.");
            }
        }
    }

    private static void VerifyManifestBalances(
        JsonElement manifest,
        IReadOnlyList<PassportMonetaryBalanceState> replayBalances,
        List<string> failures)
    {
        if (!manifest.TryGetProperty("balances", out var balances) || balances.ValueKind != JsonValueKind.Array)
        {
            failures.Add("Manifest does not contain replay balances.");
            return;
        }

        foreach (var manifestBalance in balances.EnumerateArray())
        {
            var accountId = ReadString(manifestBalance, "account_id");
            var assetCode = ReadString(manifestBalance, "asset_code");
            var replayBalance = replayBalances.FirstOrDefault(balance =>
                string.Equals(balance.AccountId, accountId, StringComparison.Ordinal)
                && string.Equals(balance.AssetCode, assetCode, StringComparison.Ordinal));
            if (replayBalance == null)
            {
                failures.Add("Replay does not contain manifest balance for " + accountId + " " + assetCode + ".");
                continue;
            }

            if (replayBalance.AvailableBaseUnits != ReadInt64(manifestBalance, "available_base_units")
                || replayBalance.EscrowedBaseUnits != ReadInt64(manifestBalance, "escrowed_base_units")
                || replayBalance.BurnedBaseUnits != ReadInt64(manifestBalance, "burned_base_units"))
            {
                failures.Add("Replay balance does not match manifest for " + accountId + " " + assetCode + ".");
            }
        }
    }

    private static void VerifyManifestAccountHashChain(JsonElement manifest, List<string> failures)
    {
        if (!manifest.TryGetProperty("events", out var events) || events.ValueKind != JsonValueKind.Array)
        {
            return;
        }

        if (!manifest.TryGetProperty("account_hash_chain", out var chain) || chain.ValueKind != JsonValueKind.Array)
        {
            failures.Add("Manifest does not contain an account hash chain.");
            return;
        }

        var eventRows = events
            .EnumerateArray()
            .ToDictionary(
                item => ReadString(item, "event_id"),
                item => item.Clone(),
                StringComparer.Ordinal);
        var expectedSequence = 1L;
        var expectedPriorHash = string.Empty;
        foreach (var chainItem in chain.EnumerateArray().OrderBy(item => ReadInt64(item, "account_sequence")))
        {
            var eventId = ReadString(chainItem, "event_id");
            if (!eventRows.TryGetValue(eventId, out var eventRow))
            {
                failures.Add("Account hash chain references an event missing from the export manifest: " + eventId + ".");
                continue;
            }

            var sequence = ReadInt64(chainItem, "account_sequence");
            if (sequence != expectedSequence)
            {
                failures.Add("Account hash chain expected sequence " + expectedSequence + " but found " + sequence + ".");
            }

            if (!string.Equals(ReadString(chainItem, "prior_account_event_hash"), expectedPriorHash, StringComparison.OrdinalIgnoreCase))
            {
                failures.Add("Account hash chain prior hash mismatch at sequence " + sequence + ".");
            }

            if (!string.Equals(ReadString(chainItem, "event_hash_sha256"), ReadString(eventRow, "event_hash_sha256"), StringComparison.OrdinalIgnoreCase))
            {
                failures.Add("Account hash chain event hash mismatch for event " + eventId + ".");
            }

            expectedPriorHash = ReadString(chainItem, "event_hash_sha256");
            expectedSequence++;
        }

        if (chain.GetArrayLength() != eventRows.Count)
        {
            failures.Add("Account hash chain length does not match exported event count.");
        }
    }

    private static IEnumerable<PassportMonetaryLedgerRecord> ReadExportedEvents(string exportRoot)
    {
        var eventsRoot = Path.Combine(exportRoot, "records", "passport", "monetary", "events");
        if (!Directory.Exists(eventsRoot))
        {
            return Array.Empty<PassportMonetaryLedgerRecord>();
        }

        return Directory
            .EnumerateFiles(eventsRoot, "*.json", SearchOption.AllDirectories)
            .OrderBy(path => path, StringComparer.OrdinalIgnoreCase)
            .Select(path =>
            {
                var ledgerEvent = JsonSerializer.Deserialize<PassportMonetaryLedgerRecord>(File.ReadAllText(path));
                if (ledgerEvent == null)
                {
                    throw new InvalidOperationException("Unable to parse monetary ledger event: " + path);
                }

                return ledgerEvent;
            })
            .ToArray();
    }

    private static PassportMonetaryLedgerReplayEvent ToReplayEvent(PassportMonetaryLedgerRecord ledgerEvent)
    {
        return new PassportMonetaryLedgerReplayEvent
        {
            EventId = ledgerEvent.EventId,
            EventType = ledgerEvent.EventType,
            CreatedUtc = ledgerEvent.CreatedUtc,
            ReleaseLane = ledgerEvent.ReleaseLane,
            LedgerNamespace = ledgerEvent.LedgerNamespace,
            ProductionTokenRecord = ledgerEvent.ProductionTokenRecord,
            StagingRecord = ledgerEvent.StagingRecord,
            AccountId = ledgerEvent.AccountId,
            AssetCode = ledgerEvent.AssetCode,
            AmountBaseUnits = ledgerEvent.AmountBaseUnits,
            GlobalSequence = ledgerEvent.GlobalSequence,
            AccountSequence = ledgerEvent.AccountSequence,
            PriorAccountEventHash = ledgerEvent.PriorAccountEventHash,
            EventHashSha256 = ledgerEvent.EventHashSha256,
            AntiReplayNonce = ledgerEvent.AntiReplayNonce,
            ArchGenesisAllocationId = ledgerEvent.EvidenceReferences.TryGetValue("arch_genesis_allocation_id", out var allocationId)
                ? allocationId.Trim()
                : string.Empty
        };
    }

    private static PassportMonetaryLedgerExportVerifierResult BuildResult(
        IReadOnlyList<string> failures,
        int eventCount,
        string exportRootSha256,
        string releaseLane,
        string ledgerNamespace)
    {
        var succeeded = failures.Count == 0;
        return new PassportMonetaryLedgerExportVerifierResult
        {
            Succeeded = succeeded,
            Message = succeeded
                ? "Monetary ledger account export verification succeeded."
                : "Monetary ledger account export verification failed.",
            EventCount = eventCount,
            ExportRootSha256 = exportRootSha256,
            ReleaseLane = releaseLane,
            LedgerNamespace = ledgerNamespace,
            Failures = failures.ToArray()
        };
    }

    private static string ResolveRelativePath(string root, string path)
    {
        var normalized = path.Replace('/', Path.DirectorySeparatorChar);
        return Path.IsPathRooted(normalized)
            ? Path.GetFullPath(normalized)
            : Path.GetFullPath(Path.Combine(root, normalized));
    }

    private static bool Matches(JsonElement root, string propertyName, string expectedValue)
    {
        return string.Equals(ReadString(root, propertyName), expectedValue, StringComparison.Ordinal);
    }

    private static string ReadString(JsonElement root, string propertyName)
    {
        return root.TryGetProperty(propertyName, out var value) ? value.GetString() ?? string.Empty : string.Empty;
    }

    private static long ReadInt64(JsonElement root, string propertyName)
    {
        if (!root.TryGetProperty(propertyName, out var value))
        {
            return 0;
        }

        if (value.ValueKind == JsonValueKind.Number && value.TryGetInt64(out var number))
        {
            return number;
        }

        return value.ValueKind == JsonValueKind.String && long.TryParse(value.GetString(), out var parsed) ? parsed : 0;
    }

    private static string NormalizeRequired(string value, string label)
    {
        var normalized = (value ?? string.Empty).Trim();
        if (string.IsNullOrWhiteSpace(normalized))
        {
            throw new InvalidOperationException("A " + label + " is required.");
        }

        return normalized;
    }

    private static string NormalizeHash(string hash)
    {
        return (hash ?? string.Empty).Trim().ToLowerInvariant();
    }

    private static string ComputeDirectoryHash(string root)
    {
        var builder = new StringBuilder();
        foreach (var file in Directory.EnumerateFiles(root, "*", SearchOption.AllDirectories).OrderBy(path => path, StringComparer.OrdinalIgnoreCase))
        {
            var relativePath = ToRootRelativePath(root, file);
            builder.Append(relativePath).Append('\n');
            builder.Append(ComputeSha256(File.ReadAllBytes(file))).Append('\n');
        }

        return ComputeSha256(Encoding.UTF8.GetBytes(builder.ToString()));
    }

    private static string ToRootRelativePath(string root, string path)
    {
        var normalizedRoot = Path.GetFullPath(root).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
        var normalizedPath = Path.GetFullPath(path);
        if (!normalizedPath.StartsWith(normalizedRoot, StringComparison.OrdinalIgnoreCase))
        {
            return path.Replace(Path.DirectorySeparatorChar, '/');
        }

        var relative = normalizedPath.Substring(normalizedRoot.Length).TrimStart(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
        return relative.Replace(Path.DirectorySeparatorChar, '/');
    }

    private static string ComputeSha256(byte[] value)
    {
        return Convert.ToHexString(SHA256.HashData(value)).ToLowerInvariant();
    }
}
