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
                IpfsCliDetected = ResolveExecutableOnPath("ipfs.exe") != null,
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
                if (document.RootElement.TryGetProperty("verified", out var verifiedElement))
                {
                    return verifiedElement.GetBoolean()
                        ? "Latest package verified"
                        : "Latest package verification failed";
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

        private static string? ResolveExecutableOnPath(string executableName)
        {
            var path = Environment.GetEnvironmentVariable("PATH");
            if (string.IsNullOrWhiteSpace(path))
            {
                return null;
            }

            var segments = path.Split(new[] { Path.PathSeparator }, StringSplitOptions.RemoveEmptyEntries);
            foreach (var rawSegment in segments)
            {
                var segment = rawSegment.Trim();
                var candidate = Path.Combine(segment, executableName);
                if (File.Exists(candidate))
                {
                    return candidate;
                }
            }

            return null;
        }
    }
}
