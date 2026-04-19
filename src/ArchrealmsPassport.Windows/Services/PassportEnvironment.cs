using System;
using System.IO;

namespace ArchrealmsPassport.Windows.Services
{
    public static class PassportEnvironment
    {
        public static string GetAppDataRoot()
        {
            var root = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "Archrealms",
                "PassportWindows");

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

        public static string ResolveIpfsCliPath()
        {
            foreach (var candidate in GetIpfsCliCandidates())
            {
                if (!string.IsNullOrWhiteSpace(candidate) && File.Exists(candidate))
                {
                    return candidate;
                }
            }

            return string.Empty;
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

        private static string[] GetIpfsCliCandidates()
        {
            var path = Environment.GetEnvironmentVariable("PATH");
            var candidates = new System.Collections.Generic.List<string>();

            if (!string.IsNullOrWhiteSpace(path))
            {
                var segments = path.Split(new[] { Path.PathSeparator }, StringSplitOptions.RemoveEmptyEntries);
                foreach (var rawSegment in segments)
                {
                    var segment = rawSegment.Trim();
                    if (!string.IsNullOrWhiteSpace(segment))
                    {
                        candidates.Add(Path.Combine(segment, "ipfs.exe"));
                    }
                }
            }

            var localAppData = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
            var programFiles = Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles);
            var programFilesX86 = Environment.GetFolderPath(Environment.SpecialFolder.ProgramFilesX86);

            if (!string.IsNullOrWhiteSpace(localAppData))
            {
                candidates.Add(Path.Combine(localAppData, "Programs", "IPFS Desktop", "resources", "app.asar.unpacked", "node_modules", "kubo", "kubo", "ipfs.exe"));
            }

            if (!string.IsNullOrWhiteSpace(programFiles))
            {
                candidates.Add(Path.Combine(programFiles, "IPFS Desktop", "resources", "app.asar.unpacked", "node_modules", "kubo", "kubo", "ipfs.exe"));
            }

            if (!string.IsNullOrWhiteSpace(programFilesX86))
            {
                candidates.Add(Path.Combine(programFilesX86, "IPFS Desktop", "resources", "app.asar.unpacked", "node_modules", "kubo", "kubo", "ipfs.exe"));
            }

            return candidates.ToArray();
        }
    }
}
