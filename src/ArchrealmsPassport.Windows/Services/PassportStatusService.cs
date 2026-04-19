using System;
using System.IO;
using System.Linq;
using System.Text.Json;
using ArchrealmsPassport.Windows.Models;

namespace ArchrealmsPassport.Windows.Services
{
    public sealed class PassportStatusService
    {
        public ArchiveStatusSnapshot GetSnapshot(string workspaceRoot, string ipfsRepoPath)
        {
            var resolvedWorkspaceRoot = PassportEnvironment.ResolveWorkspaceRoot(workspaceRoot);
            var resolvedIpfsRepo = ResolveIpfsRepoPath(ipfsRepoPath);
            var latestSubmissionPath = FindLatestSubmissionPath(resolvedWorkspaceRoot);

            return new ArchiveStatusSnapshot
            {
                WorkspaceRoot = resolvedWorkspaceRoot,
                WorkspaceReady = Directory.Exists(resolvedWorkspaceRoot),
                IpfsCliDetected = !string.IsNullOrWhiteSpace(PassportEnvironment.ResolveIpfsCliPath()),
                IpfsRepoPath = resolvedIpfsRepo,
                IpfsNodePrepared = TryReadNodeRecord(resolvedWorkspaceRoot, out var peerId),
                NodePeerId = peerId,
                VerificationSummary = ReadVerificationSummary(latestSubmissionPath),
                LatestSubmissionPath = latestSubmissionPath,
                RegistrySubmissionCid = ReadLatestRegistrySubmissionCid(latestSubmissionPath)
            };
        }

        public string ResolveIpfsRepoPath(string ipfsRepoPath)
        {
            if (!string.IsNullOrWhiteSpace(ipfsRepoPath))
            {
                return Path.GetFullPath(ipfsRepoPath);
            }

            return PassportEnvironment.GetDefaultIpfsRepoPath();
        }

        private static bool TryReadNodeRecord(string workspaceRoot, out string peerId)
        {
            peerId = "Node not initialized";

            var nodePath = Path.Combine(workspaceRoot, "records", "passport", "ipfs-node.local.json");
            if (!File.Exists(nodePath))
            {
                return false;
            }

            using (var document = JsonDocument.Parse(File.ReadAllText(nodePath)))
            {
                if (document.RootElement.TryGetProperty("peer_id", out var peerIdElement))
                {
                    peerId = peerIdElement.GetString() ?? peerId;
                }
                else
                {
                    peerId = "Node record present";
                }
            }

            return true;
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
