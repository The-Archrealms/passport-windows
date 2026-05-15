using System.Text.Json;
using ArchrealmsPassport.HostedServices.Contracts;

namespace ArchrealmsPassport.HostedServices;

public sealed class PassportHostedKnowledgeStore
{
    private readonly string root;

    public PassportHostedKnowledgeStore(string root)
    {
        this.root = Path.GetFullPath(root);
        Directory.CreateDirectory(KnowledgeRoot);
    }

    private string KnowledgeRoot => Path.Combine(root, "records", "ai", "knowledge-packs");

    public static PassportHostedKnowledgeStore FromDataRoot(string dataRoot)
    {
        return new PassportHostedKnowledgeStore(dataRoot);
    }

    public PassportHostedKnowledgeChunk[] Retrieve(string knowledgePackId, string query, int maxChunks)
    {
        var chunksPath = Path.Combine(KnowledgeRoot, NormalizeFileName(knowledgePackId), "chunks.jsonl");
        if (!File.Exists(chunksPath))
        {
            return Array.Empty<PassportHostedKnowledgeChunk>();
        }

        var terms = Tokenize(query).ToArray();
        return File.ReadLines(chunksPath)
            .Where(line => !string.IsNullOrWhiteSpace(line))
            .Select(TryReadChunk)
            .Where(chunk => chunk != null)
            .Select(chunk => chunk!)
            .Where(chunk => chunk.Approved)
            .Select(chunk => (Chunk: chunk, Score: Score(chunk, terms)))
            .Where(item => item.Score > 0)
            .OrderByDescending(item => item.Score)
            .ThenBy(item => item.Chunk.Source.SourceId, StringComparer.Ordinal)
            .Take(Math.Clamp(maxChunks, 1, 10))
            .Select(item => item.Chunk)
            .ToArray();
    }

    private static PassportHostedKnowledgeChunk? TryReadChunk(string line)
    {
        try
        {
            using var document = JsonDocument.Parse(line);
            var root = document.RootElement;
            var status = ReadString(root, "approval_status", "status");
            return new PassportHostedKnowledgeChunk(
                new PassportAiSourceRef
                {
                    SourceId = ReadString(root, "source_id"),
                    Title = ReadString(root, "title"),
                    SourcePath = ReadString(root, "source_path"),
                    SourceSha256 = ReadString(root, "source_sha256"),
                    ChunkSha256 = ReadString(root, "chunk_sha256")
                },
                ReadString(root, "text", "chunk_text"),
                string.Equals(status, "approved", StringComparison.OrdinalIgnoreCase)
                    || string.Equals(status, "active", StringComparison.OrdinalIgnoreCase));
        }
        catch
        {
            return null;
        }
    }

    private static int Score(PassportHostedKnowledgeChunk chunk, string[] terms)
    {
        if (terms.Length == 0)
        {
            return 1;
        }

        var haystack = (chunk.Source.Title + " " + chunk.Source.SourcePath + " " + chunk.Text).ToLowerInvariant();
        return terms.Count(term => haystack.Contains(term, StringComparison.Ordinal));
    }

    private static IEnumerable<string> Tokenize(string query)
    {
        var current = new List<char>();
        foreach (var character in (query ?? string.Empty).ToLowerInvariant())
        {
            if (char.IsLetterOrDigit(character))
            {
                current.Add(character);
                continue;
            }

            if (current.Count >= 3)
            {
                yield return new string(current.ToArray());
            }

            current.Clear();
        }

        if (current.Count >= 3)
        {
            yield return new string(current.ToArray());
        }
    }

    private static string ReadString(JsonElement root, params string[] propertyNames)
    {
        foreach (var propertyName in propertyNames)
        {
            if (root.TryGetProperty(propertyName, out var value) && value.ValueKind == JsonValueKind.String)
            {
                return value.GetString() ?? string.Empty;
            }
        }

        return string.Empty;
    }

    private static string NormalizeFileName(string value)
    {
        var normalized = new string((value ?? string.Empty)
            .Select(character => char.IsLetterOrDigit(character) || character is '-' or '_' or '.' ? character : '_')
            .ToArray());
        return string.IsNullOrWhiteSpace(normalized) ? "archrealms-mvp-approved-knowledge" : normalized;
    }
}

public sealed record PassportHostedKnowledgeChunk(PassportAiSourceRef Source, string Text, bool Approved);
