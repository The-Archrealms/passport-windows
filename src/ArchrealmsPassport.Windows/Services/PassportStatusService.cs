using System;
using System.IO;
using System.Linq;
using System.Text.Json;
using System.Threading.Tasks;
using ArchrealmsPassport.Windows.Models;

namespace ArchrealmsPassport.Windows.Services
{
    public sealed class PassportStatusService
    {
        private readonly ILocalNodeService _localNodeService;

        public PassportStatusService(ILocalNodeService localNodeService)
        {
            _localNodeService = localNodeService;
        }

        public async Task<ArchiveStatusSnapshot> GetSnapshotAsync(string workspaceRoot, string ipfsRepoPath, string toolRoot, string ipfsCliPathOverride)
        {
            var resolvedWorkspaceRoot = PassportEnvironment.ResolveWorkspaceRoot(workspaceRoot);
            var health = await _localNodeService.GetHealthAsync(resolvedWorkspaceRoot, ipfsRepoPath, toolRoot, ipfsCliPathOverride).ConfigureAwait(false);
            var latestSubmissionPath = FindLatestSubmissionPath(resolvedWorkspaceRoot);

            return new ArchiveStatusSnapshot
            {
                WorkspaceRoot = resolvedWorkspaceRoot,
                WorkspaceReady = Directory.Exists(resolvedWorkspaceRoot),
                IpfsCliDetected = health.IpfsCliDetected,
                IpfsCliPath = health.IpfsCliPath,
                IpfsCliSource = health.IpfsCliSource,
                IpfsRepoPath = health.IpfsRepoPath,
                IpfsNodePrepared = health.NodeRecordPresent || health.RepoInitialized,
                NodePeerId = health.PeerId,
                NodeHealthSummary = health.Summary,
                NodeApiEndpoint = health.ApiEndpoint,
                NodeApiReachable = health.ApiReachable,
                NodeIpfsVersion = string.IsNullOrWhiteSpace(health.ApiVersion) ? health.IpfsVersion : health.ApiVersion,
                NodeStorageMax = health.StorageMax,
                NodeStorageGcWatermark = health.StorageGcWatermark,
                NodeParticipationMode = health.ParticipationMode,
                NodeCachePolicy = health.CachePolicy,
                NodeProvideStrategy = health.ProvideStrategy,
                VerificationSummary = ReadVerificationSummary(latestSubmissionPath),
                LatestSubmissionPath = latestSubmissionPath,
                RegistrySubmissionCid = ReadLatestRegistrySubmissionCid(latestSubmissionPath)
            };
        }

        private static string FindLatestSubmissionPath(string workspaceRoot)
        {
            var submissionsRoot = Path.Combine(workspaceRoot, "records", "registry", "submissions");
            if (!Directory.Exists(submissionsRoot))
            {
                return string.Empty;
            }

            var latestSubmission = new DirectoryInfo(submissionsRoot)
                .GetDirectories()
                .OrderByDescending(directory => directory.Name)
                .Select(directory => Path.Combine(directory.FullName, "submission.json"))
                .FirstOrDefault(File.Exists);

            return latestSubmission ?? string.Empty;
        }

        private static string ReadVerificationSummary(string latestSubmissionPath)
        {
            if (string.IsNullOrWhiteSpace(latestSubmissionPath) || !File.Exists(latestSubmissionPath))
            {
                return "No submission package yet";
            }

            var verificationPath = Path.Combine(Path.GetDirectoryName(latestSubmissionPath) ?? string.Empty, "verification-report.json");
            if (!File.Exists(verificationPath))
            {
                return "Latest package prepared";
            }

            using (var document = JsonDocument.Parse(File.ReadAllText(verificationPath)))
            {
                var root = document.RootElement;
                if (root.TryGetProperty("verified", out var verifiedElement) && verifiedElement.GetBoolean())
                {
                    return "Latest package verified";
                }

                if (root.TryGetProperty("integrity_verified", out var integrityElement)
                    && integrityElement.GetBoolean()
                    && root.TryGetProperty("authorization_summary", out var authorizationSummaryElement))
                {
                    var authorizationSummary = authorizationSummaryElement.GetString() ?? string.Empty;
                    if (string.Equals(authorizationSummary, "delegated-unanchored", StringComparison.Ordinal))
                    {
                        return "Latest package integrity verified; authorization unanchored";
                    }

                    return "Latest package integrity verified; authorization failed";
                }

                if (root.TryGetProperty("verified", out _))
                {
                    return "Latest package verification failed";
                }
            }

            return "Verification report present";
        }

        private static string ReadLatestRegistrySubmissionCid(string latestSubmissionPath)
        {
            if (string.IsNullOrWhiteSpace(latestSubmissionPath) || !File.Exists(latestSubmissionPath))
            {
                return "Not published";
            }

            var publicationPath = Path.Combine(Path.GetDirectoryName(latestSubmissionPath) ?? string.Empty, "ipfs-publication.json");
            if (!File.Exists(publicationPath))
            {
                return "Not published";
            }

            using (var document = JsonDocument.Parse(File.ReadAllText(publicationPath)))
            {
                if (document.RootElement.TryGetProperty("root_cid", out var rootCidElement))
                {
                    return rootCidElement.GetString() ?? "Not published";
                }
            }

            return "Not published";
        }
    }
}
