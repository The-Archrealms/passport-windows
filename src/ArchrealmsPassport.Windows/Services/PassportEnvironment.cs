using System;
using System.Collections.Generic;
using System.IO;

namespace ArchrealmsPassport.Windows.Services
{
    public static class PassportEnvironment
    {
        public static PassportReleaseLane GetReleaseLane()
        {
            return PassportReleaseLane.Load();
        }

        public static string GetAppDataRoot()
        {
            var releaseLane = GetReleaseLane();
            var appDataRootOverride = Environment.GetEnvironmentVariable("ARCHREALMS_PASSPORT_APPDATA_ROOT");
            var appDataBaseRoot = string.IsNullOrWhiteSpace(appDataRootOverride)
                ? Path.Combine(
                    Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                    "Archrealms")
                : Path.GetFullPath(appDataRootOverride);

            var root = Path.Combine(
                appDataBaseRoot,
                releaseLane.AppDataFolderName);

            Directory.CreateDirectory(root);
            return root;
        }

        public static string GetDefaultWorkspaceRoot()
        {
            var root = Path.Combine(GetAppDataRoot(), "workspace");
            Directory.CreateDirectory(root);
            return root;
        }

        public static string GetDefaultIpfsRepoPath()
        {
            return Path.Combine(GetAppDataRoot(), "ipfs", "kubo");
        }

        public static string GetBundledIpfsRuntimeCacheRoot()
        {
            var root = Path.Combine(GetAppDataRoot(), "runtime", "ipfs", "bundled");
            Directory.CreateDirectory(root);
            return root;
        }

        public static string GetSettingsPath()
        {
            return Path.Combine(GetAppDataRoot(), "passport-settings.json");
        }

        public static string GetKeysRoot()
        {
            var root = Path.Combine(GetAppDataRoot(), "keys");
            Directory.CreateDirectory(root);
            return root;
        }

        public static string ResolveWorkspaceRoot(string workspaceRoot)
        {
            if (string.IsNullOrWhiteSpace(workspaceRoot))
            {
                return GetDefaultWorkspaceRoot();
            }

            var resolved = Path.GetFullPath(workspaceRoot);
            Directory.CreateDirectory(resolved);
            return resolved;
        }

        public static string FindToolRoot()
        {
            foreach (var seed in new[] { AppContext.BaseDirectory, Environment.CurrentDirectory })
            {
                var candidate = FindToolRootFrom(seed);
                if (!string.IsNullOrWhiteSpace(candidate))
                {
                    return candidate;
                }
            }

            return AppContext.BaseDirectory;
        }

        public static bool IsToolRoot(string root)
        {
            if (string.IsNullOrWhiteSpace(root) || !Directory.Exists(root))
            {
                return false;
            }

            return File.Exists(Path.Combine(root, "tools", "passport", "Publish-ArchrealmsRegistrySubmissionToIpfs.ps1"))
                && File.Exists(Path.Combine(root, "tools", "ipfs", "Initialize-ArchrealmsIpfsNode.ps1"))
                && File.Exists(Path.Combine(root, "registry", "templates", "passport-identity-record.template.json"));
        }

        public static string GetBundledIpfsRuntimeRoot(string toolRoot)
        {
            if (string.IsNullOrWhiteSpace(toolRoot))
            {
                return string.Empty;
            }

            return Path.Combine(toolRoot, "tools", "ipfs", "runtime");
        }

        public static string ResolveIpfsCliPath()
        {
            return ResolveIpfsCliPath(FindToolRoot(), string.Empty);
        }

        public static string ResolveIpfsCliPath(string toolRoot, string ipfsCliPathOverride)
        {
            foreach (var candidate in GetIpfsCliCandidates(toolRoot, ipfsCliPathOverride))
            {
                if (!string.IsNullOrWhiteSpace(candidate) && File.Exists(candidate))
                {
                    return Path.GetFullPath(candidate);
                }
            }

            return string.Empty;
        }

        public static string DescribeIpfsCliSource(string resolvedPath, string toolRoot, string ipfsCliPathOverride)
        {
            if (string.IsNullOrWhiteSpace(resolvedPath))
            {
                return "No IPFS runtime detected";
            }

            var normalizedResolvedPath = Path.GetFullPath(resolvedPath);

            if (!string.IsNullOrWhiteSpace(ipfsCliPathOverride))
            {
                try
                {
                    if (PathsEqual(normalizedResolvedPath, Path.GetFullPath(ipfsCliPathOverride)))
                    {
                        return "Configured override";
                    }
                }
                catch
                {
                }
            }

            var environmentOverride = Environment.GetEnvironmentVariable("ARCHREALMS_IPFS_CLI");
            if (!string.IsNullOrWhiteSpace(environmentOverride))
            {
                try
                {
                    if (PathsEqual(normalizedResolvedPath, Path.GetFullPath(environmentOverride)))
                    {
                        return "Environment override";
                    }
                }
                catch
                {
                }
            }

            var bundledRuntimeRoot = GetBundledIpfsRuntimeRoot(toolRoot);
            var bundledRuntimeCacheRoot = GetBundledIpfsRuntimeCacheRoot();
            if (!string.IsNullOrWhiteSpace(bundledRuntimeCacheRoot)
                && normalizedResolvedPath.StartsWith(Path.GetFullPath(bundledRuntimeCacheRoot), StringComparison.OrdinalIgnoreCase))
            {
                return "Bundled runtime";
            }

            if (!string.IsNullOrWhiteSpace(bundledRuntimeRoot)
                && normalizedResolvedPath.StartsWith(Path.GetFullPath(bundledRuntimeRoot), StringComparison.OrdinalIgnoreCase))
            {
                return "Bundled runtime";
            }

            if (normalizedResolvedPath.IndexOf("IPFS Desktop", StringComparison.OrdinalIgnoreCase) >= 0)
            {
                return "IPFS Desktop runtime";
            }

            return "PATH runtime";
        }

        private static string FindToolRootFrom(string seed)
        {
            if (string.IsNullOrWhiteSpace(seed))
            {
                return string.Empty;
            }

            DirectoryInfo? current;
            try
            {
                current = new DirectoryInfo(seed);
            }
            catch
            {
                return string.Empty;
            }

            while (current != null)
            {
                if (IsToolRoot(current.FullName))
                {
                    return current.FullName;
                }

                current = current.Parent;
            }

            return string.Empty;
        }

        private static IEnumerable<string> GetIpfsCliCandidates(string toolRoot, string ipfsCliPathOverride)
        {
            var candidates = new List<string>();
            var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);

            void AddCandidate(string candidate)
            {
                if (string.IsNullOrWhiteSpace(candidate))
                {
                    return;
                }

                string normalizedCandidate;
                try
                {
                    normalizedCandidate = Path.GetFullPath(candidate);
                }
                catch
                {
                    return;
                }

                if (seen.Add(normalizedCandidate))
                {
                    candidates.Add(normalizedCandidate);
                }
            }

            AddCandidate(ipfsCliPathOverride);

            var environmentIpfsCli = Environment.GetEnvironmentVariable("ARCHREALMS_IPFS_CLI");
            if (!string.IsNullOrWhiteSpace(environmentIpfsCli))
            {
                AddCandidate(environmentIpfsCli);
            }

            var bundledRuntimeRoot = GetBundledIpfsRuntimeRoot(toolRoot);
            if (!string.IsNullOrWhiteSpace(bundledRuntimeRoot))
            {
                AddCandidate(MaterializeBundledIpfsRuntime(toolRoot));
                AddCandidate(Path.Combine(bundledRuntimeRoot, "ipfs.exe"));

                if (Directory.Exists(bundledRuntimeRoot))
                {
                    foreach (var bundledCandidate in Directory.EnumerateFiles(bundledRuntimeRoot, "ipfs.exe", SearchOption.AllDirectories))
                    {
                        AddCandidate(bundledCandidate);
                    }
                }
            }

            var path = Environment.GetEnvironmentVariable("PATH");

            if (!string.IsNullOrWhiteSpace(path))
            {
                var segments = path.Split(new[] { Path.PathSeparator }, StringSplitOptions.RemoveEmptyEntries);
                foreach (var rawSegment in segments)
                {
                    var segment = rawSegment.Trim();
                    if (!string.IsNullOrWhiteSpace(segment))
                    {
                        AddCandidate(Path.Combine(segment, "ipfs.exe"));
                    }
                }
            }

            var localAppData = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
            var programFiles = Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles);
            var programFilesX86 = Environment.GetFolderPath(Environment.SpecialFolder.ProgramFilesX86);

            if (!string.IsNullOrWhiteSpace(localAppData))
            {
                AddCandidate(Path.Combine(localAppData, "Programs", "IPFS Desktop", "resources", "app.asar.unpacked", "node_modules", "kubo", "kubo", "ipfs.exe"));
            }

            if (!string.IsNullOrWhiteSpace(programFiles))
            {
                AddCandidate(Path.Combine(programFiles, "IPFS Desktop", "resources", "app.asar.unpacked", "node_modules", "kubo", "kubo", "ipfs.exe"));
            }

            if (!string.IsNullOrWhiteSpace(programFilesX86))
            {
                AddCandidate(Path.Combine(programFilesX86, "IPFS Desktop", "resources", "app.asar.unpacked", "node_modules", "kubo", "kubo", "ipfs.exe"));
            }

            return candidates.ToArray();
        }

        private static string MaterializeBundledIpfsRuntime(string toolRoot)
        {
            var sourceRoot = GetBundledIpfsRuntimeRoot(toolRoot);
            if (string.IsNullOrWhiteSpace(sourceRoot) || !Directory.Exists(sourceRoot))
            {
                return string.Empty;
            }

            var sourceIpfs = Path.Combine(sourceRoot, "ipfs.exe");
            if (!File.Exists(sourceIpfs))
            {
                return string.Empty;
            }

            try
            {
                var destinationRoot = GetBundledIpfsRuntimeCacheRoot();
                CopyDirectory(sourceRoot, destinationRoot);
                var destinationIpfs = Path.Combine(destinationRoot, "ipfs.exe");
                return File.Exists(destinationIpfs) ? destinationIpfs : string.Empty;
            }
            catch
            {
                return string.Empty;
            }
        }

        private static void CopyDirectory(string sourceRoot, string destinationRoot)
        {
            Directory.CreateDirectory(destinationRoot);

            foreach (var sourceDirectory in Directory.EnumerateDirectories(sourceRoot, "*", SearchOption.AllDirectories))
            {
                var relativeDirectory = Path.GetRelativePath(sourceRoot, sourceDirectory);
                Directory.CreateDirectory(Path.Combine(destinationRoot, relativeDirectory));
            }

            foreach (var sourceFile in Directory.EnumerateFiles(sourceRoot, "*", SearchOption.AllDirectories))
            {
                var relativeFile = Path.GetRelativePath(sourceRoot, sourceFile);
                var destinationFile = Path.Combine(destinationRoot, relativeFile);
                var destinationDirectory = Path.GetDirectoryName(destinationFile);
                if (!string.IsNullOrWhiteSpace(destinationDirectory))
                {
                    Directory.CreateDirectory(destinationDirectory);
                }

                if (!ShouldCopyFile(sourceFile, destinationFile))
                {
                    continue;
                }

                File.Copy(sourceFile, destinationFile, true);
            }
        }

        private static bool ShouldCopyFile(string sourceFile, string destinationFile)
        {
            if (!File.Exists(destinationFile))
            {
                return true;
            }

            var sourceInfo = new FileInfo(sourceFile);
            var destinationInfo = new FileInfo(destinationFile);
            return sourceInfo.Length != destinationInfo.Length
                || sourceInfo.LastWriteTimeUtc > destinationInfo.LastWriteTimeUtc;
        }

        private static bool PathsEqual(string left, string right)
        {
            return string.Equals(
                Path.GetFullPath(left).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar),
                Path.GetFullPath(right).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar),
                StringComparison.OrdinalIgnoreCase);
        }
    }
}
