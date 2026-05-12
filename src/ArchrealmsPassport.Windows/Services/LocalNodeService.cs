using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Net.Http;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;

namespace ArchrealmsPassport.Windows.Services
{
    public sealed class LocalNodeService
    {
        private static readonly TimeSpan HealthTimeout = TimeSpan.FromSeconds(2);
        private static readonly TimeSpan DaemonStartupTimeout = TimeSpan.FromSeconds(90);
        private static readonly TimeSpan DaemonShutdownTimeout = TimeSpan.FromSeconds(15);
        private static readonly JsonSerializerOptions JsonOptions = new JsonSerializerOptions { WriteIndented = true };
        private readonly PowerShellScriptRunner _scriptRunner;

        public LocalNodeService(PowerShellScriptRunner scriptRunner)
        {
            _scriptRunner = scriptRunner;
        }

        public string ResolveIpfsCliPath(string toolRoot, string ipfsCliPathOverride)
        {
            return PassportEnvironment.ResolveIpfsCliPath(toolRoot, ipfsCliPathOverride);
        }

        public async Task<LocalNodeOperationResult> InitializeAsync(
            string toolRoot,
            string workspaceRoot,
            string ipfsRepoPath,
            double storageAllocationGb,
            string participationMode,
            string cachePolicy,
            int storageGcWatermark,
            string provideStrategy,
            string ipfsCliPathOverride,
            CancellationToken cancellationToken = default(CancellationToken))
        {
            var arguments = new List<string>
            {
                "-WorkspaceRoot", workspaceRoot,
                "-IpfsRepoPath", ipfsRepoPath,
                "-StorageMax", string.Format(CultureInfo.InvariantCulture, "{0:0}GB", Math.Round(storageAllocationGb)),
                "-StorageGCWatermark", Math.Max(1, Math.Min(99, storageGcWatermark)).ToString(CultureInfo.InvariantCulture),
                "-ProvideStrategy", string.IsNullOrWhiteSpace(provideStrategy) ? "pinned" : provideStrategy,
                "-ParticipationMode", string.IsNullOrWhiteSpace(participationMode) ? "Public archive contributor" : participationMode,
                "-CachePolicy", string.IsNullOrWhiteSpace(cachePolicy) ? "Balanced pinned archive" : cachePolicy
            };

            var result = await RunScriptAsync(
                toolRoot,
                workspaceRoot,
                "tools\\ipfs\\Initialize-ArchrealmsIpfsNode.ps1",
                arguments,
                ipfsCliPathOverride,
                cancellationToken).ConfigureAwait(false);

            if (!result.Succeeded)
            {
                return result;
            }

            var recordPath = GetNodeRecordPath(PassportEnvironment.ResolveWorkspaceRoot(workspaceRoot));
            if (File.Exists(recordPath))
            {
                result.RecordPath = recordPath;
                using (var document = JsonDocument.Parse(File.ReadAllText(recordPath)))
                {
                    result.PeerId = TryReadString(document.RootElement, "peer_id");
                    result.ApiMultiaddr = TryReadString(document.RootElement, "api_multiaddr");
                }
            }

            return result;
        }

        public async Task<LocalNodeOperationResult> StartAsync(
            string toolRoot,
            string workspaceRoot,
            string ipfsRepoPath,
            string ipfsCliPathOverride,
            CancellationToken cancellationToken = default(CancellationToken))
        {
            var resolvedWorkspaceRoot = PassportEnvironment.ResolveWorkspaceRoot(workspaceRoot);
            var resolvedIpfsRepoPath = ResolveIpfsRepoPath(ipfsRepoPath);
            var resolvedIpfsCliPath = ResolveIpfsCliPath(toolRoot, ipfsCliPathOverride);

            if (string.IsNullOrWhiteSpace(resolvedIpfsCliPath))
            {
                return LocalNodeOperationResult.Failure("Cannot start local node because no IPFS runtime was found.");
            }

            if (!File.Exists(Path.Combine(resolvedIpfsRepoPath, "config")))
            {
                return LocalNodeOperationResult.Failure("Cannot start local node because the IPFS repo is not initialized. Run Initialize Local IPFS Node first.");
            }

            var existingHealth = await GetHealthAsync(resolvedWorkspaceRoot, resolvedIpfsRepoPath, toolRoot, ipfsCliPathOverride, cancellationToken).ConfigureAwait(false);
            if (existingHealth.ApiReachable)
            {
                return new LocalNodeOperationResult
                {
                    Succeeded = true,
                    Action = "start-local-node",
                    Message = "Local IPFS node is already running.",
                    ResolvedIpfsCliPath = resolvedIpfsCliPath,
                    PeerId = existingHealth.PeerId,
                    ApiMultiaddr = existingHealth.ApiMultiaddr,
                    ApiEndpoint = existingHealth.ApiEndpoint
                };
            }

            var processStartInfo = new ProcessStartInfo
            {
                FileName = resolvedIpfsCliPath,
                WorkingDirectory = resolvedWorkspaceRoot,
                UseShellExecute = false,
                CreateNoWindow = true
            };
            processStartInfo.ArgumentList.Add("daemon");
            processStartInfo.ArgumentList.Add("--enable-gc");
            processStartInfo.Environment["IPFS_PATH"] = resolvedIpfsRepoPath;
            processStartInfo.Environment["IPFS_TELEMETRY"] = "off";

            Process? process;
            try
            {
                process = Process.Start(processStartInfo);
            }
            catch (Exception ex)
            {
                return LocalNodeOperationResult.Failure("Failed to start local IPFS daemon: " + ex.Message);
            }

            if (process == null)
            {
                return LocalNodeOperationResult.Failure("Failed to start local IPFS daemon.");
            }

            try
            {
                var processId = process.Id;
                WriteDaemonRecord(resolvedWorkspaceRoot, new Dictionary<string, object?>
                {
                    ["state"] = "starting",
                    ["process_id"] = processId,
                    ["started_utc"] = DateTime.UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ", CultureInfo.InvariantCulture),
                    ["ipfs_cli_path"] = resolvedIpfsCliPath,
                    ["ipfs_repo_path"] = resolvedIpfsRepoPath
                });

                var deadline = DateTime.UtcNow + DaemonStartupTimeout;
                while (DateTime.UtcNow < deadline)
                {
                    cancellationToken.ThrowIfCancellationRequested();

                    if (process.HasExited)
                    {
                        return LocalNodeOperationResult.Failure("Local IPFS daemon exited during startup with code " + process.ExitCode.ToString(CultureInfo.InvariantCulture) + ".");
                    }

                    var health = await GetHealthAsync(resolvedWorkspaceRoot, resolvedIpfsRepoPath, toolRoot, ipfsCliPathOverride, cancellationToken).ConfigureAwait(false);
                    if (health.ApiReachable)
                    {
                        WriteDaemonRecord(resolvedWorkspaceRoot, new Dictionary<string, object?>
                        {
                            ["state"] = "running",
                            ["process_id"] = processId,
                            ["started_utc"] = DateTime.UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ", CultureInfo.InvariantCulture),
                            ["ipfs_cli_path"] = resolvedIpfsCliPath,
                            ["ipfs_repo_path"] = resolvedIpfsRepoPath,
                            ["api_endpoint"] = health.ApiEndpoint,
                            ["peer_id"] = health.PeerId
                        });

                        return new LocalNodeOperationResult
                        {
                            Succeeded = true,
                            Action = "start-local-node",
                            Message = "Started local IPFS node.",
                            ResolvedIpfsCliPath = resolvedIpfsCliPath,
                            PeerId = health.PeerId,
                            ApiMultiaddr = health.ApiMultiaddr,
                            ApiEndpoint = health.ApiEndpoint,
                            ProcessId = processId,
                            RecordPath = GetDaemonRecordPath(resolvedWorkspaceRoot)
                        };
                    }

                    await Task.Delay(500, cancellationToken).ConfigureAwait(false);
                }

                try
                {
                    if (!process.HasExited)
                    {
                        process.Kill(entireProcessTree: true);
                    }
                }
                catch (Exception)
                {
                }

                WriteDaemonRecord(resolvedWorkspaceRoot, new Dictionary<string, object?>
                {
                    ["state"] = "startup_timeout",
                    ["process_id"] = processId,
                    ["started_utc"] = DateTime.UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ", CultureInfo.InvariantCulture),
                    ["ipfs_cli_path"] = resolvedIpfsCliPath,
                    ["ipfs_repo_path"] = resolvedIpfsRepoPath
                });

                return new LocalNodeOperationResult
                {
                    Succeeded = false,
                    ExitCode = -1,
                    Action = "start-local-node",
                    Message = "Local IPFS daemon API was not reachable before the startup timeout.",
                    ResolvedIpfsCliPath = resolvedIpfsCliPath,
                    ProcessId = processId,
                    RecordPath = GetDaemonRecordPath(resolvedWorkspaceRoot)
                };
            }
            finally
            {
                process.Dispose();
            }
        }

        public async Task<LocalNodeOperationResult> RepairAsync(
            string toolRoot,
            string workspaceRoot,
            string ipfsRepoPath,
            double storageAllocationGb,
            string participationMode,
            string cachePolicy,
            int storageGcWatermark,
            string provideStrategy,
            string ipfsCliPathOverride,
            CancellationToken cancellationToken = default(CancellationToken))
        {
            var resolvedWorkspaceRoot = PassportEnvironment.ResolveWorkspaceRoot(workspaceRoot);
            var wasRunning = false;
            var initialHealth = await GetHealthAsync(resolvedWorkspaceRoot, ipfsRepoPath, toolRoot, ipfsCliPathOverride, cancellationToken).ConfigureAwait(false);
            if (initialHealth.ApiReachable)
            {
                wasRunning = true;
                var stopResult = await StopAsync(toolRoot, resolvedWorkspaceRoot, ipfsRepoPath, ipfsCliPathOverride, cancellationToken).ConfigureAwait(false);
                if (!stopResult.Succeeded)
                {
                    stopResult.Action = "repair-local-node";
                    stopResult.Message = "Cannot repair local node configuration because the daemon did not stop cleanly.";
                    return stopResult;
                }
            }

            var repairResult = await InitializeAsync(
                toolRoot,
                resolvedWorkspaceRoot,
                ipfsRepoPath,
                storageAllocationGb,
                participationMode,
                cachePolicy,
                storageGcWatermark,
                provideStrategy,
                ipfsCliPathOverride,
                cancellationToken).ConfigureAwait(false);

            repairResult.Action = "repair-local-node";
            if (!repairResult.Succeeded)
            {
                repairResult.Message = "Failed to repair local node configuration.";
                return repairResult;
            }

            repairResult.Message = "Repaired local node configuration and applied the current node settings.";

            if (wasRunning)
            {
                var startResult = await StartAsync(toolRoot, resolvedWorkspaceRoot, ipfsRepoPath, ipfsCliPathOverride, cancellationToken).ConfigureAwait(false);
                if (!startResult.Succeeded)
                {
                    startResult.Action = "repair-local-node";
                    startResult.Message = "Repaired local node configuration, but failed to restart the daemon.";
                    return startResult;
                }

                repairResult.Message = "Repaired local node configuration, applied the current node settings, and restarted the daemon.";
                repairResult.ApiEndpoint = startResult.ApiEndpoint;
                repairResult.ProcessId = startResult.ProcessId;
                if (!string.IsNullOrWhiteSpace(startResult.PeerId))
                {
                    repairResult.PeerId = startResult.PeerId;
                }
            }

            return repairResult;
        }

        public async Task<LocalNodeOperationResult> StopAsync(
            string toolRoot,
            string workspaceRoot,
            string ipfsRepoPath,
            string ipfsCliPathOverride,
            CancellationToken cancellationToken = default(CancellationToken))
        {
            var resolvedWorkspaceRoot = PassportEnvironment.ResolveWorkspaceRoot(workspaceRoot);
            var resolvedIpfsRepoPath = ResolveIpfsRepoPath(ipfsRepoPath);
            var health = await GetHealthAsync(resolvedWorkspaceRoot, resolvedIpfsRepoPath, toolRoot, ipfsCliPathOverride, cancellationToken).ConfigureAwait(false);

            if (health.ApiReachable && !string.IsNullOrWhiteSpace(health.ApiEndpoint))
            {
                await TryShutdownApiAsync(health.ApiEndpoint, cancellationToken).ConfigureAwait(false);
            }

            var deadline = DateTime.UtcNow + DaemonShutdownTimeout;
            while (DateTime.UtcNow < deadline)
            {
                cancellationToken.ThrowIfCancellationRequested();
                health = await GetHealthAsync(resolvedWorkspaceRoot, resolvedIpfsRepoPath, toolRoot, ipfsCliPathOverride, cancellationToken).ConfigureAwait(false);
                if (!health.ApiReachable)
                {
                    WriteDaemonRecord(resolvedWorkspaceRoot, new Dictionary<string, object?>
                    {
                        ["state"] = "stopped",
                        ["stopped_utc"] = DateTime.UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ", CultureInfo.InvariantCulture),
                        ["ipfs_repo_path"] = resolvedIpfsRepoPath
                    });

                    return new LocalNodeOperationResult
                    {
                        Succeeded = true,
                        Action = "stop-local-node",
                        Message = "Stopped local IPFS node.",
                        RecordPath = GetDaemonRecordPath(resolvedWorkspaceRoot)
                    };
                }

                await Task.Delay(500, cancellationToken).ConfigureAwait(false);
            }

            var daemonRecord = ReadDaemonRecord(resolvedWorkspaceRoot);
            var processId = TryReadProcessId(daemonRecord);
            if (processId > 0 && TryKillProcess(processId, out var killMessage))
            {
                WriteDaemonRecord(resolvedWorkspaceRoot, new Dictionary<string, object?>
                {
                    ["state"] = "stopped",
                    ["stopped_utc"] = DateTime.UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ", CultureInfo.InvariantCulture),
                    ["process_id"] = processId,
                    ["stop_method"] = "process_kill",
                    ["ipfs_repo_path"] = resolvedIpfsRepoPath
                });

                return new LocalNodeOperationResult
                {
                    Succeeded = true,
                    Action = "stop-local-node",
                    Message = "Stopped local IPFS node by ending the recorded daemon process.",
                    ProcessId = processId,
                    RecordPath = GetDaemonRecordPath(resolvedWorkspaceRoot),
                    Stdout = killMessage
                };
            }

            if (!health.ApiReachable)
            {
                return new LocalNodeOperationResult
                {
                    Succeeded = true,
                    Action = "stop-local-node",
                    Message = "Local IPFS node is already stopped.",
                    RecordPath = GetDaemonRecordPath(resolvedWorkspaceRoot)
                };
            }

            return LocalNodeOperationResult.Failure("Local IPFS node did not stop before timeout.");
        }

        public async Task<LocalNodeOperationResult> RestartAsync(
            string toolRoot,
            string workspaceRoot,
            string ipfsRepoPath,
            string ipfsCliPathOverride,
            CancellationToken cancellationToken = default(CancellationToken))
        {
            var stopResult = await StopAsync(toolRoot, workspaceRoot, ipfsRepoPath, ipfsCliPathOverride, cancellationToken).ConfigureAwait(false);
            if (!stopResult.Succeeded)
            {
                return stopResult;
            }

            var startResult = await StartAsync(toolRoot, workspaceRoot, ipfsRepoPath, ipfsCliPathOverride, cancellationToken).ConfigureAwait(false);
            if (startResult.Succeeded)
            {
                startResult.Action = "restart-local-node";
                startResult.Message = "Restarted local IPFS node.";
            }

            return startResult;
        }

        public async Task<LocalNodeOperationResult> WriteDiagnosticsAsync(
            string toolRoot,
            string workspaceRoot,
            string ipfsRepoPath,
            string ipfsCliPathOverride,
            CancellationToken cancellationToken = default(CancellationToken))
        {
            var resolvedWorkspaceRoot = PassportEnvironment.ResolveWorkspaceRoot(workspaceRoot);
            var health = await GetHealthAsync(resolvedWorkspaceRoot, ipfsRepoPath, toolRoot, ipfsCliPathOverride, cancellationToken).ConfigureAwait(false);
            var daemonRecord = ReadDaemonRecord(resolvedWorkspaceRoot);
            var latestSubmissionPath = FindLatestFile(Path.Combine(resolvedWorkspaceRoot, "records", "registry", "submissions"), "submission.json");
            var latestPublicationPath = string.IsNullOrWhiteSpace(latestSubmissionPath)
                ? string.Empty
                : Path.Combine(Path.GetDirectoryName(latestSubmissionPath) ?? string.Empty, "ipfs-publication.json");
            if (!File.Exists(latestPublicationPath))
            {
                latestPublicationPath = string.Empty;
            }

            var diagnosticsRoot = Path.Combine(resolvedWorkspaceRoot, "records", "passport", "node-diagnostics");
            var carExportsRoot = Path.Combine(resolvedWorkspaceRoot, "records", "ipfs-car-exports");
            var readOnlyRoot = Path.Combine(resolvedWorkspaceRoot, "records", "ipfs-readonly");
            Directory.CreateDirectory(diagnosticsRoot);

            var reportPath = Path.Combine(
                diagnosticsRoot,
                DateTime.UtcNow.ToString("yyyyMMddTHHmmssZ", CultureInfo.InvariantCulture) + "-local-node-diagnostics.json");

            var report = new Dictionary<string, object?>
            {
                ["record_type"] = "local_node_diagnostics",
                ["created_utc"] = DateTime.UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ", CultureInfo.InvariantCulture),
                ["workspace_root"] = health.WorkspaceRoot,
                ["ipfs_repo_path"] = health.IpfsRepoPath,
                ["ipfs_cli_detected"] = health.IpfsCliDetected,
                ["ipfs_cli_path"] = health.IpfsCliPath,
                ["ipfs_cli_source"] = health.IpfsCliSource,
                ["repo_initialized"] = health.RepoInitialized,
                ["node_record_present"] = health.NodeRecordPresent,
                ["node_record_path"] = health.NodeRecordPath,
                ["peer_id"] = health.PeerId,
                ["api_multiaddr"] = health.ApiMultiaddr,
                ["gateway_multiaddr"] = health.GatewayMultiaddr,
                ["storage_max"] = health.StorageMax,
                ["storage_gc_watermark"] = health.StorageGcWatermark,
                ["participation_mode"] = health.ParticipationMode,
                ["cache_policy"] = health.CachePolicy,
                ["provide_strategy"] = health.ProvideStrategy,
                ["ipfs_version"] = health.IpfsVersion,
                ["api_endpoint"] = health.ApiEndpoint,
                ["api_reachable"] = health.ApiReachable,
                ["api_status"] = health.ApiStatus,
                ["api_version"] = health.ApiVersion,
                ["workspace_size_bytes"] = TryGetDirectorySize(resolvedWorkspaceRoot),
                ["ipfs_repo_size_bytes"] = TryGetDirectorySize(health.IpfsRepoPath),
                ["latest_registry_submission_path"] = latestSubmissionPath,
                ["latest_publication_path"] = latestPublicationPath,
                ["latest_car_export_record_path"] = FindLatestFile(carExportsRoot, "*.json"),
                ["latest_node_diagnostics_path"] = FindLatestFile(diagnosticsRoot, "*.json"),
                ["workspace_paths"] = new Dictionary<string, object?>
                {
                    ["workspace_root"] = resolvedWorkspaceRoot,
                    ["records_root"] = Path.Combine(resolvedWorkspaceRoot, "records"),
                    ["ipfs_repo_path"] = health.IpfsRepoPath,
                    ["node_diagnostics_root"] = diagnosticsRoot,
                    ["car_exports_root"] = carExportsRoot,
                    ["read_only_ipfs_root"] = readOnlyRoot
                },
                ["recommended_recovery_actions"] = BuildRecoveryActions(health),
                ["summary"] = health.Summary,
                ["daemon_record"] = daemonRecord
            };

            File.WriteAllText(reportPath, JsonSerializer.Serialize(report, JsonOptions));

            return new LocalNodeOperationResult
            {
                Succeeded = true,
                Action = "write-local-node-diagnostics",
                Message = "Wrote local node diagnostics.",
                RecordPath = reportPath,
                PeerId = health.PeerId,
                ApiEndpoint = health.ApiEndpoint
            };
        }

        public async Task<LocalNodeOperationResult> ExportCarAsync(
            string toolRoot,
            string workspaceRoot,
            string cid,
            string ipfsRepoPath,
            string ipfsCliPathOverride,
            CancellationToken cancellationToken = default(CancellationToken))
        {
            if (string.IsNullOrWhiteSpace(cid))
            {
                return LocalNodeOperationResult.Failure("A CID is required for CAR export.");
            }

            var resolvedWorkspaceRoot = PassportEnvironment.ResolveWorkspaceRoot(workspaceRoot);
            var exportRoot = Path.Combine(resolvedWorkspaceRoot, "records", "ipfs-car-exports");
            Directory.CreateDirectory(exportRoot);

            var safeCid = SanitizePathSegment(cid.Trim());
            var timestamp = DateTime.UtcNow.ToString("yyyyMMddTHHmmssZ", CultureInfo.InvariantCulture);
            var carPath = Path.Combine(exportRoot, timestamp + "-" + safeCid + ".car");
            var recordPath = Path.Combine(exportRoot, timestamp + "-" + safeCid + ".car-export.json");

            var arguments = new List<string>
            {
                "-Cid", cid.Trim(),
                "-WorkspaceRoot", resolvedWorkspaceRoot,
                "-CarPath", carPath,
                "-RecordPath", recordPath,
                "-IpfsRepoPath", ipfsRepoPath
            };

            var result = await RunScriptAsync(
                toolRoot,
                resolvedWorkspaceRoot,
                "tools\\ipfs\\Export-ArchrealmsIpfsCar.ps1",
                arguments,
                ipfsCliPathOverride,
                cancellationToken).ConfigureAwait(false);

            if (!result.Succeeded)
            {
                return result;
            }

            result.Action = "export-ipfs-car";
            result.RecordPath = recordPath;
            result.CarPath = carPath;

            if (File.Exists(recordPath))
            {
                using (var document = JsonDocument.Parse(File.ReadAllText(recordPath)))
                {
                    result.CarPath = TryReadString(document.RootElement, "car_path", result.CarPath);
                    result.Sha256 = TryReadString(document.RootElement, "car_sha256");
                    result.ByteCount = TryReadInt64(document.RootElement, "car_size_bytes");
                    result.RootCid = TryReadString(document.RootElement, "cid", cid.Trim());
                }
            }

            return result;
        }

        public async Task<LocalNodeOperationResult> PublishRegistrySubmissionAsync(
            string toolRoot,
            string workspaceRoot,
            string submissionPath,
            string ipfsRepoPath,
            string ipfsCliPathOverride,
            bool exportCar,
            CancellationToken cancellationToken = default(CancellationToken))
        {
            var arguments = new List<string>
            {
                "-SubmissionPath", submissionPath,
                "-WorkspaceRoot", workspaceRoot,
                "-IpfsRepoPath", ipfsRepoPath
            };

            if (exportCar)
            {
                arguments.Add("-ExportCar");
            }

            var result = await RunScriptAsync(
                toolRoot,
                workspaceRoot,
                "tools\\passport\\Publish-ArchrealmsRegistrySubmissionToIpfs.ps1",
                arguments,
                ipfsCliPathOverride,
                cancellationToken).ConfigureAwait(false);

            if (!result.Succeeded)
            {
                return result;
            }

            var publicationPath = FindPublicationPath(submissionPath);
            if (File.Exists(publicationPath))
            {
                result.RecordPath = publicationPath;
                using (var document = JsonDocument.Parse(File.ReadAllText(publicationPath)))
                {
                    result.RootCid = TryReadString(document.RootElement, "root_cid");
                    result.CarPath = TryReadString(document.RootElement, "car_path");
                }
            }

            return result;
        }

        public async Task<LocalNodeOperationResult> PreviewReadOnlyIpfsFileAsync(
            string toolRoot,
            string workspaceRoot,
            string cid,
            string relativePath,
            string ipfsRepoPath,
            string ipfsCliPathOverride,
            CancellationToken cancellationToken = default(CancellationToken))
        {
            var arguments = new List<string>
            {
                "-Cid", cid.Trim(),
                "-IpfsRepoPath", ipfsRepoPath
            };

            if (!string.IsNullOrWhiteSpace(relativePath))
            {
                arguments.Add("-RelativePath");
                arguments.Add(relativePath.Trim());
            }

            var result = await RunScriptAsync(
                toolRoot,
                workspaceRoot,
                "tools\\passport\\Read-ArchrealmsIpfsText.ps1",
                arguments,
                ipfsCliPathOverride,
                cancellationToken).ConfigureAwait(false);

            if (!result.Succeeded)
            {
                return result;
            }

            try
            {
                using (var document = JsonDocument.Parse(result.Stdout))
                {
                    var root = document.RootElement;
                    result.PreviewText = TryReadString(root, "preview_text", result.Stdout);
                    result.IpfsPath = TryReadString(root, "ipfs_path");
                    result.Sha256 = TryReadString(root, "sha256");
                    result.ByteCount = TryReadInt64(root, "byte_count");
                    result.Truncated = TryReadBoolean(root, "truncated");
                }
            }
            catch (JsonException)
            {
                result.PreviewText = result.Stdout;
            }

            return result;
        }

        public async Task<LocalNodeOperationResult> FetchReadOnlyIpfsFileAsync(
            string toolRoot,
            string workspaceRoot,
            string cid,
            string relativePath,
            string ipfsRepoPath,
            string ipfsCliPathOverride,
            CancellationToken cancellationToken = default(CancellationToken))
        {
            var arguments = new List<string>
            {
                "-Cid", cid.Trim(),
                "-WorkspaceRoot", workspaceRoot,
                "-IpfsRepoPath", ipfsRepoPath
            };

            if (!string.IsNullOrWhiteSpace(relativePath))
            {
                arguments.Add("-RelativePath");
                arguments.Add(relativePath.Trim());
            }

            var result = await RunScriptAsync(
                toolRoot,
                workspaceRoot,
                "tools\\passport\\Save-ArchrealmsIpfsFileReadOnly.ps1",
                arguments,
                ipfsCliPathOverride,
                cancellationToken).ConfigureAwait(false);

            if (!result.Succeeded)
            {
                return result;
            }

            try
            {
                using (var document = JsonDocument.Parse(result.Stdout))
                {
                    var root = document.RootElement;
                    result.DestinationPath = TryReadString(root, "destination_path");
                    result.MetadataPath = TryReadString(root, "metadata_path");
                    result.IpfsPath = TryReadString(root, "ipfs_path");
                    result.Sha256 = TryReadString(root, "sha256");
                    result.ByteCount = TryReadInt64(root, "byte_count");
                }
            }
            catch (JsonException)
            {
            }

            return result;
        }

        public async Task<LocalNodeHealthSnapshot> GetHealthAsync(
            string workspaceRoot,
            string ipfsRepoPath,
            string toolRoot,
            string ipfsCliPathOverride,
            CancellationToken cancellationToken = default(CancellationToken))
        {
            var resolvedWorkspaceRoot = PassportEnvironment.ResolveWorkspaceRoot(workspaceRoot);
            var resolvedIpfsRepoPath = ResolveIpfsRepoPath(ipfsRepoPath);
            var resolvedIpfsCliPath = ResolveIpfsCliPath(toolRoot, ipfsCliPathOverride);

            var snapshot = new LocalNodeHealthSnapshot
            {
                WorkspaceRoot = resolvedWorkspaceRoot,
                IpfsRepoPath = resolvedIpfsRepoPath,
                IpfsCliDetected = !string.IsNullOrWhiteSpace(resolvedIpfsCliPath),
                IpfsCliPath = resolvedIpfsCliPath,
                IpfsCliSource = PassportEnvironment.DescribeIpfsCliSource(resolvedIpfsCliPath, toolRoot, ipfsCliPathOverride),
                RepoInitialized = File.Exists(Path.Combine(resolvedIpfsRepoPath, "config")),
                NodeRecordPath = GetNodeRecordPath(resolvedWorkspaceRoot)
            };

            if (File.Exists(snapshot.NodeRecordPath))
            {
                snapshot.NodeRecordPresent = true;
                using (var document = JsonDocument.Parse(File.ReadAllText(snapshot.NodeRecordPath)))
                {
                    var root = document.RootElement;
                    snapshot.PeerId = TryReadString(root, "peer_id");
                    snapshot.ApiMultiaddr = TryReadString(root, "api_multiaddr");
                    snapshot.GatewayMultiaddr = TryReadString(root, "gateway_multiaddr");
                    snapshot.StorageMax = TryReadString(root, "storage_max");
                    snapshot.StorageGcWatermark = TryReadString(root, "storage_gc_watermark");
                    snapshot.ParticipationMode = TryReadString(root, "participation_mode");
                    snapshot.CachePolicy = TryReadString(root, "cache_policy");
                    snapshot.ProvideStrategy = TryReadString(root, "provide_strategy");
                    snapshot.IpfsVersion = TryReadString(root, "ipfs_version");
                }
            }

            snapshot.ApiEndpoint = TryBuildApiEndpoint(snapshot.ApiMultiaddr);
            if (!string.IsNullOrWhiteSpace(snapshot.ApiEndpoint))
            {
                await ProbeApiAsync(snapshot, cancellationToken).ConfigureAwait(false);
            }

            snapshot.Summary = BuildHealthSummary(snapshot);
            return snapshot;
        }

        private async Task<LocalNodeOperationResult> RunScriptAsync(
            string toolRoot,
            string workspaceRoot,
            string scriptRelativePath,
            IReadOnlyList<string> arguments,
            string ipfsCliPathOverride,
            CancellationToken cancellationToken)
        {
            if (!Directory.Exists(PassportEnvironment.ResolveWorkspaceRoot(workspaceRoot))
                || !PassportEnvironment.IsToolRoot(toolRoot))
            {
                return LocalNodeOperationResult.Failure("Cannot run local-node action because the Passport workspace or local tooling is not ready.");
            }

            var resolvedIpfsCliPath = ResolveIpfsCliPath(toolRoot, ipfsCliPathOverride);
            var scriptResult = await _scriptRunner.RunAsync(
                toolRoot,
                workspaceRoot,
                scriptRelativePath,
                arguments,
                resolvedIpfsCliPath,
                cancellationToken).ConfigureAwait(false);

            return LocalNodeOperationResult.FromScript(scriptResult, scriptRelativePath, resolvedIpfsCliPath);
        }

        private static async Task ProbeApiAsync(LocalNodeHealthSnapshot snapshot, CancellationToken cancellationToken)
        {
            using (var timeoutSource = new CancellationTokenSource(HealthTimeout))
            using (var linkedSource = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken, timeoutSource.Token))
            using (var httpClient = new HttpClient { Timeout = HealthTimeout })
            {
                httpClient.DefaultRequestHeaders.UserAgent.ParseAdd("ArchrealmsPassport.Windows/0.1");
                try
                {
                    using (var response = await httpClient.PostAsync(snapshot.ApiEndpoint + "/api/v0/version", null, linkedSource.Token).ConfigureAwait(false))
                    {
                        snapshot.ApiReachable = response.IsSuccessStatusCode;
                        snapshot.ApiStatus = ((int)response.StatusCode).ToString(CultureInfo.InvariantCulture);

                        var body = await response.Content.ReadAsStringAsync().ConfigureAwait(false);
                        if (!string.IsNullOrWhiteSpace(body))
                        {
                            using (var document = JsonDocument.Parse(body))
                            {
                                snapshot.ApiVersion = TryReadString(document.RootElement, "Version");
                            }
                        }
                    }
                }
                catch (Exception ex)
                {
                    snapshot.ApiReachable = false;
                    snapshot.ApiStatus = ex.Message;
                }
            }
        }

        private static async Task TryShutdownApiAsync(string apiEndpoint, CancellationToken cancellationToken)
        {
            using (var timeoutSource = new CancellationTokenSource(HealthTimeout))
            using (var linkedSource = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken, timeoutSource.Token))
            using (var httpClient = new HttpClient { Timeout = HealthTimeout })
            {
                httpClient.DefaultRequestHeaders.UserAgent.ParseAdd("ArchrealmsPassport.Windows/0.1");
                try
                {
                    using (await httpClient.PostAsync(apiEndpoint + "/api/v0/shutdown", null, linkedSource.Token).ConfigureAwait(false))
                    {
                    }
                }
                catch
                {
                }
            }
        }

        private static bool TryKillProcess(int processId, out string message)
        {
            message = string.Empty;

            try
            {
                using (var process = Process.GetProcessById(processId))
                {
                    if (process.HasExited)
                    {
                        message = "Recorded daemon process had already exited.";
                        return true;
                    }

                    process.Kill(entireProcessTree: true);
                    process.WaitForExit(3000);
                    message = "Ended process " + processId.ToString(CultureInfo.InvariantCulture) + ".";
                    return true;
                }
            }
            catch (ArgumentException)
            {
                message = "Recorded daemon process was not running.";
                return true;
            }
            catch (Exception ex)
            {
                message = ex.Message;
                return false;
            }
        }

        private static Dictionary<string, object?> ReadDaemonRecord(string workspaceRoot)
        {
            var path = GetDaemonRecordPath(workspaceRoot);
            if (!File.Exists(path))
            {
                return new Dictionary<string, object?>();
            }

            using (var document = JsonDocument.Parse(File.ReadAllText(path)))
            {
                return JsonSerializer.Deserialize<Dictionary<string, object?>>(document.RootElement.GetRawText()) ?? new Dictionary<string, object?>();
            }
        }

        private static void WriteDaemonRecord(string workspaceRoot, Dictionary<string, object?> record)
        {
            var path = GetDaemonRecordPath(workspaceRoot);
            var directory = Path.GetDirectoryName(path);
            if (!string.IsNullOrWhiteSpace(directory))
            {
                Directory.CreateDirectory(directory);
            }

            record["record_type"] = "local_ipfs_daemon_state";
            record["updated_utc"] = DateTime.UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ", CultureInfo.InvariantCulture);
            File.WriteAllText(path, JsonSerializer.Serialize(record, JsonOptions));
        }

        private static int TryReadProcessId(Dictionary<string, object?> record)
        {
            if (!record.TryGetValue("process_id", out var value) || value == null)
            {
                return 0;
            }

            if (value is JsonElement element)
            {
                if (element.ValueKind == JsonValueKind.Number && element.TryGetInt32(out var number))
                {
                    return number;
                }

                if (element.ValueKind == JsonValueKind.String
                    && int.TryParse(element.GetString(), NumberStyles.Integer, CultureInfo.InvariantCulture, out var parsed))
                {
                    return parsed;
                }
            }

            if (value is int intValue)
            {
                return intValue;
            }

            return int.TryParse(value.ToString(), NumberStyles.Integer, CultureInfo.InvariantCulture, out var fallback)
                ? fallback
                : 0;
        }

        private static string BuildHealthSummary(LocalNodeHealthSnapshot snapshot)
        {
            if (!snapshot.IpfsCliDetected)
            {
                return "No IPFS runtime detected";
            }

            if (!snapshot.NodeRecordPresent && !snapshot.RepoInitialized)
            {
                return "Node not initialized";
            }

            var peer = string.IsNullOrWhiteSpace(snapshot.PeerId)
                ? "peer unknown"
                : snapshot.PeerId;

            if (snapshot.ApiReachable)
            {
                return peer + "; daemon reachable";
            }

            if (!string.IsNullOrWhiteSpace(snapshot.ApiEndpoint))
            {
                return peer + "; daemon not reachable";
            }

            return peer + "; repo initialized";
        }

        private static string ResolveIpfsRepoPath(string ipfsRepoPath)
        {
            if (!string.IsNullOrWhiteSpace(ipfsRepoPath))
            {
                return Path.GetFullPath(ipfsRepoPath);
            }

            return PassportEnvironment.GetDefaultIpfsRepoPath();
        }

        private static string GetNodeRecordPath(string workspaceRoot)
        {
            return Path.Combine(workspaceRoot, "records", "passport", "ipfs-node.local.json");
        }

        private static string GetDaemonRecordPath(string workspaceRoot)
        {
            return Path.Combine(workspaceRoot, "records", "passport", "ipfs-node.daemon.json");
        }

        private static string FindPublicationPath(string submissionPath)
        {
            if (string.IsNullOrWhiteSpace(submissionPath))
            {
                return string.Empty;
            }

            var resolvedSubmissionPath = Path.GetFullPath(submissionPath);
            var packageRoot = Directory.Exists(resolvedSubmissionPath)
                ? resolvedSubmissionPath
                : Path.GetDirectoryName(resolvedSubmissionPath) ?? string.Empty;

            return string.IsNullOrWhiteSpace(packageRoot)
                ? string.Empty
                : Path.Combine(packageRoot, "ipfs-publication.json");
        }

        private static string FindLatestFile(string root, string searchPattern)
        {
            if (string.IsNullOrWhiteSpace(root) || !Directory.Exists(root))
            {
                return string.Empty;
            }

            try
            {
                return Directory.EnumerateFiles(root, searchPattern, SearchOption.AllDirectories)
                    .OrderByDescending(File.GetLastWriteTimeUtc)
                    .FirstOrDefault() ?? string.Empty;
            }
            catch
            {
                return string.Empty;
            }
        }

        private static long TryGetDirectorySize(string root)
        {
            if (string.IsNullOrWhiteSpace(root) || !Directory.Exists(root))
            {
                return 0;
            }

            try
            {
                long total = 0;
                foreach (var file in Directory.EnumerateFiles(root, "*", SearchOption.AllDirectories))
                {
                    try
                    {
                        total += new FileInfo(file).Length;
                    }
                    catch
                    {
                    }
                }

                return total;
            }
            catch
            {
                return 0;
            }
        }

        private static IReadOnlyList<string> BuildRecoveryActions(LocalNodeHealthSnapshot health)
        {
            var actions = new List<string>();
            if (!health.IpfsCliDetected)
            {
                actions.Add("Install or bundle the IPFS runtime, then retry node initialization.");
                return actions;
            }

            if (!health.RepoInitialized && !health.NodeRecordPresent)
            {
                actions.Add("Run Initialize Local IPFS Node.");
            }

            if (health.RepoInitialized && !health.ApiReachable)
            {
                actions.Add("Start the storage node, then refresh status.");
                actions.Add("If start fails, run Repair Node Config and write diagnostics again.");
            }

            if (health.ApiReachable)
            {
                actions.Add("Node API is reachable; retry the failed publish, read, or CAR export action.");
            }

            return actions;
        }

        private static string SanitizePathSegment(string value)
        {
            var sanitized = new string((value ?? string.Empty)
                .Select(character => char.IsLetterOrDigit(character) || character == '.' || character == '_' || character == '-'
                    ? character
                    : '-')
                .ToArray()).Trim('-', '.', '_');

            return string.IsNullOrWhiteSpace(sanitized)
                ? "cid"
                : sanitized;
        }

        private static string TryBuildApiEndpoint(string apiMultiaddr)
        {
            if (string.IsNullOrWhiteSpace(apiMultiaddr))
            {
                return string.Empty;
            }

            var parts = apiMultiaddr.Trim('/').Split(new[] { '/' }, StringSplitOptions.RemoveEmptyEntries);
            string host = string.Empty;
            string port = string.Empty;

            for (var index = 0; index < parts.Length - 1; index++)
            {
                if (string.Equals(parts[index], "ip4", StringComparison.OrdinalIgnoreCase)
                    || string.Equals(parts[index], "dns", StringComparison.OrdinalIgnoreCase)
                    || string.Equals(parts[index], "dns4", StringComparison.OrdinalIgnoreCase)
                    || string.Equals(parts[index], "dns6", StringComparison.OrdinalIgnoreCase))
                {
                    host = parts[index + 1];
                }

                if (string.Equals(parts[index], "ip6", StringComparison.OrdinalIgnoreCase))
                {
                    host = "[" + parts[index + 1] + "]";
                }

                if (string.Equals(parts[index], "tcp", StringComparison.OrdinalIgnoreCase))
                {
                    port = parts[index + 1];
                }
            }

            if (string.IsNullOrWhiteSpace(host) || string.IsNullOrWhiteSpace(port))
            {
                return string.Empty;
            }

            return "http://" + host + ":" + port;
        }

        private static string TryReadString(JsonElement element, string propertyName, string fallback = "")
        {
            if (element.TryGetProperty(propertyName, out var property)
                && property.ValueKind != JsonValueKind.Null
                && property.ValueKind != JsonValueKind.Undefined)
            {
                return property.ToString();
            }

            return fallback;
        }

        private static long TryReadInt64(JsonElement element, string propertyName)
        {
            if (element.TryGetProperty(propertyName, out var property)
                && property.ValueKind == JsonValueKind.Number
                && property.TryGetInt64(out var value))
            {
                return value;
            }

            return 0;
        }

        private static bool TryReadBoolean(JsonElement element, string propertyName)
        {
            return element.TryGetProperty(propertyName, out var property)
                && property.ValueKind == JsonValueKind.True;
        }
    }

    public sealed class LocalNodeOperationResult
    {
        public bool Succeeded { get; set; }
        public int ExitCode { get; set; }
        public string Action { get; set; } = string.Empty;
        public string Message { get; set; } = string.Empty;
        public string Stdout { get; set; } = string.Empty;
        public string Stderr { get; set; } = string.Empty;
        public string ResolvedIpfsCliPath { get; set; } = string.Empty;
        public string RecordPath { get; set; } = string.Empty;
        public string PeerId { get; set; } = string.Empty;
        public string ApiMultiaddr { get; set; } = string.Empty;
        public string ApiEndpoint { get; set; } = string.Empty;
        public string RootCid { get; set; } = string.Empty;
        public string CarPath { get; set; } = string.Empty;
        public string PreviewText { get; set; } = string.Empty;
        public string IpfsPath { get; set; } = string.Empty;
        public string Sha256 { get; set; } = string.Empty;
        public long ByteCount { get; set; }
        public bool Truncated { get; set; }
        public string DestinationPath { get; set; } = string.Empty;
        public string MetadataPath { get; set; } = string.Empty;
        public int ProcessId { get; set; }

        public static LocalNodeOperationResult Failure(string message)
        {
            return new LocalNodeOperationResult
            {
                Succeeded = false,
                ExitCode = -1,
                Message = message,
                Stderr = message
            };
        }

        public static LocalNodeOperationResult FromScript(ScriptRunResult result, string action, string resolvedIpfsCliPath)
        {
            var message = result.Succeeded
                ? "Local-node action completed: " + action
                : "Local-node action failed: " + action;

            return new LocalNodeOperationResult
            {
                Succeeded = result.Succeeded,
                ExitCode = result.ExitCode,
                Action = action,
                Message = message,
                Stdout = result.Stdout,
                Stderr = result.Stderr,
                ResolvedIpfsCliPath = resolvedIpfsCliPath
            };
        }
    }

    public sealed class LocalNodeHealthSnapshot
    {
        public string WorkspaceRoot { get; set; } = string.Empty;
        public string IpfsRepoPath { get; set; } = string.Empty;
        public bool IpfsCliDetected { get; set; }
        public string IpfsCliPath { get; set; } = string.Empty;
        public string IpfsCliSource { get; set; } = string.Empty;
        public bool RepoInitialized { get; set; }
        public bool NodeRecordPresent { get; set; }
        public string NodeRecordPath { get; set; } = string.Empty;
        public string PeerId { get; set; } = string.Empty;
        public string ApiMultiaddr { get; set; } = string.Empty;
        public string GatewayMultiaddr { get; set; } = string.Empty;
        public string StorageMax { get; set; } = string.Empty;
        public string StorageGcWatermark { get; set; } = string.Empty;
        public string ParticipationMode { get; set; } = string.Empty;
        public string CachePolicy { get; set; } = string.Empty;
        public string ProvideStrategy { get; set; } = string.Empty;
        public string IpfsVersion { get; set; } = string.Empty;
        public string ApiEndpoint { get; set; } = string.Empty;
        public bool ApiReachable { get; set; }
        public string ApiStatus { get; set; } = string.Empty;
        public string ApiVersion { get; set; } = string.Empty;
        public string Summary { get; set; } = string.Empty;
    }
}
