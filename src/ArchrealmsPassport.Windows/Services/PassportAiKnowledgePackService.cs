using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Security.Cryptography;
using System.Text.RegularExpressions;
using ArchrealmsPassport.Windows.Models;

namespace ArchrealmsPassport.Windows.Services
{
    public sealed class PassportAiKnowledgePackService
    {
        private static readonly HashSet<string> StopWords = new HashSet<string>(StringComparer.OrdinalIgnoreCase)
        {
            "a",
            "an",
            "and",
            "are",
            "as",
            "be",
            "by",
            "can",
            "for",
            "from",
            "how",
            "in",
            "is",
            "it",
            "of",
            "on",
            "or",
            "the",
            "to",
            "what",
            "when",
            "where",
            "why",
            "with"
        };

        public PassportAiKnowledgePackRetrievalResult Retrieve(
            string toolRoot,
            string knowledgePackId,
            string question,
            int maxChunks = 3)
        {
            var result = new PassportAiKnowledgePackRetrievalResult
            {
                KnowledgePackId = NormalizeKnowledgePackId(knowledgePackId)
            };

            var packRoot = ResolveKnowledgePackRoot(toolRoot, result.KnowledgePackId);
            if (string.IsNullOrWhiteSpace(packRoot) || !Directory.Exists(packRoot))
            {
                result.Message = "Approved knowledge pack was not found: " + result.KnowledgePackId;
                return result;
            }

            result.KnowledgePackRoot = packRoot;
            var chunks = LoadChunks(packRoot);
            if (chunks.Count == 0)
            {
                result.Message = "Approved knowledge pack has no readable source chunks: " + result.KnowledgePackId;
                return result;
            }

            var queryTerms = Tokenize(question).ToArray();
            foreach (var chunk in chunks)
            {
                chunk.Score = ScoreChunk(chunk, queryTerms);
            }

            var selected = chunks
                .OrderByDescending(chunk => chunk.Score)
                .ThenBy(chunk => chunk.SourcePath, StringComparer.OrdinalIgnoreCase)
                .ThenBy(chunk => chunk.ChunkIndex)
                .Take(Math.Max(1, maxChunks))
                .ToArray();

            result.Chunks.AddRange(selected);
            result.Message = selected.Any(chunk => chunk.Score > 0)
                ? "Retrieved approved knowledge-pack context."
                : "No strong source match was found; returning the closest approved context.";
            return result;
        }

        private static string ResolveKnowledgePackRoot(string toolRoot, string knowledgePackId)
        {
            foreach (var root in new[]
            {
                Path.Combine(toolRoot ?? string.Empty, "knowledge-packs", knowledgePackId),
                Path.Combine(AppContext.BaseDirectory, "knowledge-packs", knowledgePackId)
            })
            {
                if (!string.IsNullOrWhiteSpace(root) && Directory.Exists(root))
                {
                    return Path.GetFullPath(root);
                }
            }

            return string.Empty;
        }

        private static List<PassportAiKnowledgeChunk> LoadChunks(string packRoot)
        {
            var chunks = new List<PassportAiKnowledgeChunk>();
            var files = Directory
                .EnumerateFiles(packRoot, "*.*", SearchOption.AllDirectories)
                .Where(path => path.EndsWith(".md", StringComparison.OrdinalIgnoreCase)
                    || path.EndsWith(".txt", StringComparison.OrdinalIgnoreCase))
                .OrderBy(path => path, StringComparer.OrdinalIgnoreCase);

            foreach (var file in files)
            {
                var text = File.ReadAllText(file);
                var sourceSha256 = ComputeSha256(File.ReadAllBytes(file));
                var sourcePath = Path.GetRelativePath(packRoot, file).Replace(Path.DirectorySeparatorChar, '/');
                var sections = SplitSections(text);
                for (var index = 0; index < sections.Count; index++)
                {
                    var section = sections[index];
                    var chunkText = section.Text.Trim();
                    if (string.IsNullOrWhiteSpace(chunkText))
                    {
                        continue;
                    }

                    chunks.Add(new PassportAiKnowledgeChunk
                    {
                        SourceId = sourcePath + "#" + (index + 1).ToString("000"),
                        SourcePath = sourcePath,
                        SourceSha256 = sourceSha256,
                        Title = section.Title,
                        ChunkIndex = index,
                        Text = chunkText,
                        ChunkSha256 = ComputeSha256(System.Text.Encoding.UTF8.GetBytes(chunkText))
                    });
                }
            }

            return chunks;
        }

        private static List<KnowledgeSection> SplitSections(string text)
        {
            var sections = new List<KnowledgeSection>();
            var matches = Regex.Matches(text, @"(?m)^(#{1,3})\s+(.+)$");
            if (matches.Count == 0)
            {
                sections.Add(new KnowledgeSection { Title = "Approved knowledge", Text = text });
                return sections;
            }

            for (var i = 0; i < matches.Count; i++)
            {
                var start = matches[i].Index;
                var end = i + 1 < matches.Count ? matches[i + 1].Index : text.Length;
                var title = matches[i].Groups[2].Value.Trim();
                var sectionText = text.Substring(start, end - start);
                sections.Add(new KnowledgeSection { Title = title, Text = sectionText });
            }

            return sections;
        }

        private static int ScoreChunk(PassportAiKnowledgeChunk chunk, string[] queryTerms)
        {
            if (queryTerms.Length == 0)
            {
                return 0;
            }

            var title = chunk.Title.ToLowerInvariant();
            var text = chunk.Text.ToLowerInvariant();
            var score = 0;
            foreach (var term in queryTerms)
            {
                if (title.Contains(term, StringComparison.Ordinal))
                {
                    score += 5;
                }

                score += Regex.Matches(text, Regex.Escape(term), RegexOptions.IgnoreCase).Count;
            }

            return score;
        }

        internal static IEnumerable<string> Tokenize(string value)
        {
            foreach (Match match in Regex.Matches(value ?? string.Empty, "[A-Za-z0-9][A-Za-z0-9_-]{2,}"))
            {
                var token = match.Value.ToLowerInvariant();
                if (!StopWords.Contains(token))
                {
                    yield return token;
                }
            }
        }

        private static string NormalizeKnowledgePackId(string value)
        {
            var normalized = string.IsNullOrWhiteSpace(value) ? "archrealms-mvp-approved-knowledge" : value.Trim();
            return Regex.IsMatch(normalized, "^[A-Za-z0-9_.-]+$")
                ? normalized
                : "archrealms-mvp-approved-knowledge";
        }

        private static string ComputeSha256(byte[] value)
        {
            return Convert.ToHexString(SHA256.HashData(value)).ToLowerInvariant();
        }

        private sealed class KnowledgeSection
        {
            public string Title { get; set; } = string.Empty;

            public string Text { get; set; } = string.Empty;
        }
    }

    public sealed class PassportAiKnowledgePackRetrievalResult
    {
        public string KnowledgePackId { get; set; } = string.Empty;

        public string KnowledgePackRoot { get; set; } = string.Empty;

        public string Message { get; set; } = string.Empty;

        public List<PassportAiKnowledgeChunk> Chunks { get; } = new List<PassportAiKnowledgeChunk>();
    }

    public sealed class PassportAiKnowledgeChunk : PassportAiSourceReference
    {
        public int ChunkIndex { get; set; }

        public int Score { get; set; }

        public string Text { get; set; } = string.Empty;
    }
}
