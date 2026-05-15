using System;
using System.IO;
using System.Runtime.ExceptionServices;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using ArchrealmsPassport.Windows.Models;
using ArchrealmsPassport.Windows.Services;
using ArchrealmsPassport.Windows.Tests.Infrastructure;
using ArchrealmsPassport.Windows.ViewModels;
using Xunit;

namespace ArchrealmsPassport.Windows.Tests;

public sealed class PassportMainViewModelHomeTests
{
    [Theory]
    [InlineData(false, false, false, true, false, false, false, "Create Passport")]
    [InlineData(false, true, false, true, false, false, false, "Request Access")]
    [InlineData(true, false, false, true, false, false, false, "Finish Setup")]
    [InlineData(true, false, true, false, false, false, false, "Prepare Registration")]
    [InlineData(true, false, true, true, false, false, false, "Enable Storage")]
    [InlineData(true, false, true, true, true, false, false, "Start Storage")]
    [InlineData(true, false, true, true, true, true, false, "Register Passport")]
    [InlineData(true, false, true, true, true, true, true, "Passport Ready")]
    public void PrimaryActionLabelSeparatesPreparedStorageFromRunningStorage(
        bool hasActivePassport,
        bool isJoiningExistingIdentity,
        bool hasActiveWallet,
        bool participatesInPublicRegistry,
        bool storageNodePrepared,
        bool storageNodeRunning,
        bool isRegistrationComplete,
        string expected)
    {
        var label = PassportMainViewModel.BuildPrimaryActionLabel(
            hasActivePassport,
            isJoiningExistingIdentity,
            hasActiveWallet,
            participatesInPublicRegistry,
            storageNodePrepared,
            storageNodeRunning,
            isRegistrationComplete);

        Assert.Equal(expected, label);
    }

    [Theory]
    [InlineData(true, false, true, "Running: 1 GB")]
    [InlineData(true, true, false, "Paused: 1 GB")]
    [InlineData(true, false, false, "Not enabled")]
    [InlineData(false, false, false, "Read-only")]
    public void StorageSummarySeparatesPreparedStorageFromRunningStorage(
        bool participatesInPublicRegistry,
        bool storageNodePrepared,
        bool storageNodeRunning,
        string expected)
    {
        var summary = PassportMainViewModel.BuildStorageSummaryText(
            participatesInPublicRegistry,
            storageNodePrepared,
            storageNodeRunning,
            "1 GB");

        Assert.Equal(expected, summary);
    }

    [Fact]
    public void HomeStorageOptInLabelShowsDefaultStorageLimit()
    {
        Assert.Equal("Contribute 1 GB storage", PassportMainViewModel.BuildHomeStorageOptInLabel("1 GB"));
    }

    [Fact]
    public void InitializeNodeReportsPreparedStorageWhenStartupFails()
    {
        RunOnStaThread(async delegate
        {
            var appDataRoot = Path.Combine(Path.GetTempPath(), "archrealms-passport-viewmodel-tests", Guid.NewGuid().ToString("N"));
            var oldAppDataRoot = Environment.GetEnvironmentVariable("ARCHREALMS_PASSPORT_APPDATA_ROOT");
            Environment.SetEnvironmentVariable("ARCHREALMS_PASSPORT_APPDATA_ROOT", appDataRoot);

            try
            {
                using var workspace = PassportTestWorkspace.Create();
                var localNodeService = new FakeLocalNodeService();
                using var viewModel = new PassportMainViewModel(
                    new PassportSettingsStore(),
                    new PassportStatusService(localNodeService),
                    localNodeService,
                    new PassportRecordService(),
                    new PassportCryptoService(),
                    new NetworkUsageService());

                viewModel.WorkspaceRoot = workspace.Root;
                viewModel.IpfsRepoPath = Path.Combine(workspace.Root, "ipfs");
                viewModel.StorageAllocationGb = 1;
                viewModel.NodeParticipationMode = "Read-only cache";
                viewModel.ParticipateInPublicRegistry = false;

                await viewModel.InitializeNodeAsync();

                Assert.Equal(1, localNodeService.InitializeCallCount);
                Assert.Equal(1, localNodeService.StartCallCount);
                Assert.True(viewModel.ParticipateInPublicRegistry);
                Assert.Equal("Public archive contributor", viewModel.NodeParticipationMode);
                Assert.Equal("Storage was prepared, but node startup failed: daemon blocked by test", viewModel.StorageActionStatusText);
                Assert.Equal("Paused: 1 GB", viewModel.StorageSummaryText);
                Assert.Equal("Paused", viewModel.LocalNodeSummaryText);
            }
            finally
            {
                Environment.SetEnvironmentVariable("ARCHREALMS_PASSPORT_APPDATA_ROOT", oldAppDataRoot);
                try
                {
                    if (Directory.Exists(appDataRoot))
                    {
                        Directory.Delete(appDataRoot, true);
                    }
                }
                catch
                {
                }
            }
        });
    }

    [Fact]
    public void PrimaryActionOnlyHidesAfterRegistrationWhenStorageIsRunning()
    {
        Assert.Equal(Visibility.Visible, PassportMainViewModel.BuildPrimaryActionVisibility(false, true, true, true, true));
        Assert.Equal(Visibility.Visible, PassportMainViewModel.BuildPrimaryActionVisibility(true, true, false, true, true));
        Assert.Equal(Visibility.Visible, PassportMainViewModel.BuildPrimaryActionVisibility(true, true, true, false, true));
        Assert.Equal(Visibility.Collapsed, PassportMainViewModel.BuildPrimaryActionVisibility(true, true, true, true, true));
        Assert.Equal(Visibility.Collapsed, PassportMainViewModel.BuildPrimaryActionVisibility(true, false, false, false, true));
    }

    [Fact]
    public void MonetarySummaryRequiresWalletBeforeLedgerRecords()
    {
        var replay = new PassportMonetaryLedgerReplayResult();

        var summary = PassportMainViewModel.BuildMonetaryLedgerSummary(
            hasActivePassport: true,
            hasActiveWallet: false,
            replay,
            "passport-test");

        Assert.Equal("Bind a wallet key before ARCH/CC records can be signed.", summary);
    }

    [Fact]
    public void MonetarySummaryShowsReplayDerivedArchAndCcBalances()
    {
        var replay = new PassportMonetaryLedgerReplayResult
        {
            EventCount = 3
        };
        replay.Balances.Add(new PassportMonetaryBalance
        {
            AccountId = "passport-test",
            AssetCode = PassportMonetaryLedgerService.AssetArch,
            AvailableBaseUnits = 125
        });
        replay.Balances.Add(new PassportMonetaryBalance
        {
            AccountId = "passport-test",
            AssetCode = PassportMonetaryLedgerService.AssetCrownCredit,
            AvailableBaseUnits = 40,
            EscrowedBaseUnits = 10,
            BurnedBaseUnits = 5
        });

        var summary = PassportMainViewModel.BuildMonetaryLedgerSummary(
            hasActivePassport: true,
            hasActiveWallet: true,
            replay,
            "passport-test");

        Assert.Equal("ARCH available 125; CC available 40, escrowed 10, burned 5", summary);
    }

    [Fact]
    public void AdminAuthorityEvidenceTextUsesServiceEvidenceKeys()
    {
        var result = new PassportAdminAuthorityResult
        {
            RecordPath = "records/passport/admin-authority/ledger_correction/action.json",
            RequesterSignaturePath = "records/passport/admin-authority/ledger_correction/requester.json",
            ApproverSignaturePath = "records/passport/admin-authority/ledger_correction/approver.json"
        };

        var evidence = PassportMainViewModel.BuildAdminAuthorityEvidenceText(result, new string('a', 64));

        Assert.Contains("admin_authority_record_path=", evidence);
        Assert.Contains("admin_authority_record_sha256=", evidence);
        Assert.Contains("admin_authority_requester_signature_path=", evidence);
        Assert.Contains("admin_authority_approver_signature_path=", evidence);
    }

    private static void RunOnStaThread(Func<Task> action)
    {
        Exception? threadException = null;
        var completed = new ManualResetEventSlim(false);

        var thread = new Thread(() =>
        {
            try
            {
                action().GetAwaiter().GetResult();
            }
            catch (Exception ex)
            {
                threadException = ex;
            }
            finally
            {
                completed.Set();
            }
        });

        thread.SetApartmentState(ApartmentState.STA);
        thread.Start();

        Assert.True(completed.Wait(TimeSpan.FromSeconds(15)), "The WPF view-model test did not complete.");
        if (threadException != null)
        {
            ExceptionDispatchInfo.Capture(threadException).Throw();
        }
    }

    private sealed class FakeLocalNodeService : ILocalNodeService
    {
        public int InitializeCallCount { get; private set; }

        public int StartCallCount { get; private set; }

        private bool _prepared;

        public Task<LocalNodeOperationResult> InitializeAsync(
            string toolRoot,
            string workspaceRoot,
            string ipfsRepoPath,
            double storageAllocationGb,
            string participationMode,
            string cachePolicy,
            int storageGcWatermark,
            string provideStrategy,
            string ipfsCliPathOverride,
            CancellationToken cancellationToken = default)
        {
            InitializeCallCount++;
            _prepared = true;
            return Task.FromResult(new LocalNodeOperationResult
            {
                Succeeded = true,
                Action = "initialize-local-node",
                Message = "Prepared test storage node.",
                RecordPath = Path.Combine(workspaceRoot, "records", "node", "local-node.json"),
                PeerId = "peer-test"
            });
        }

        public Task<LocalNodeOperationResult> StartAsync(
            string toolRoot,
            string workspaceRoot,
            string ipfsRepoPath,
            string ipfsCliPathOverride,
            CancellationToken cancellationToken = default)
        {
            StartCallCount++;
            return Task.FromResult(LocalNodeOperationResult.Failure("daemon blocked by test"));
        }

        public Task<LocalNodeOperationResult> RepairAsync(
            string toolRoot,
            string workspaceRoot,
            string ipfsRepoPath,
            double storageAllocationGb,
            string participationMode,
            string cachePolicy,
            int storageGcWatermark,
            string provideStrategy,
            string ipfsCliPathOverride,
            CancellationToken cancellationToken = default)
        {
            return Task.FromResult(LocalNodeOperationResult.Failure("not implemented in fake"));
        }

        public Task<LocalNodeOperationResult> StopAsync(
            string toolRoot,
            string workspaceRoot,
            string ipfsRepoPath,
            string ipfsCliPathOverride,
            CancellationToken cancellationToken = default)
        {
            return Task.FromResult(new LocalNodeOperationResult
            {
                Succeeded = true,
                Action = "stop-local-node",
                Message = "Stopped fake node."
            });
        }

        public Task<LocalNodeOperationResult> RestartAsync(
            string toolRoot,
            string workspaceRoot,
            string ipfsRepoPath,
            string ipfsCliPathOverride,
            CancellationToken cancellationToken = default)
        {
            return Task.FromResult(LocalNodeOperationResult.Failure("not implemented in fake"));
        }

        public Task<LocalNodeOperationResult> WriteDiagnosticsAsync(
            string toolRoot,
            string workspaceRoot,
            string ipfsRepoPath,
            string ipfsCliPathOverride,
            CancellationToken cancellationToken = default)
        {
            return Task.FromResult(LocalNodeOperationResult.Failure("not implemented in fake"));
        }

        public Task<LocalNodeOperationResult> ExportCarAsync(
            string toolRoot,
            string workspaceRoot,
            string cid,
            string ipfsRepoPath,
            string ipfsCliPathOverride,
            CancellationToken cancellationToken = default)
        {
            return Task.FromResult(LocalNodeOperationResult.Failure("not implemented in fake"));
        }

        public Task<LocalNodeOperationResult> PublishRegistrySubmissionAsync(
            string toolRoot,
            string workspaceRoot,
            string submissionPath,
            string ipfsRepoPath,
            string ipfsCliPathOverride,
            bool exportCar,
            CancellationToken cancellationToken = default)
        {
            return Task.FromResult(LocalNodeOperationResult.Failure("not implemented in fake"));
        }

        public Task<LocalNodeOperationResult> PreviewReadOnlyIpfsFileAsync(
            string toolRoot,
            string workspaceRoot,
            string cid,
            string relativePath,
            string ipfsRepoPath,
            string ipfsCliPathOverride,
            CancellationToken cancellationToken = default)
        {
            return Task.FromResult(LocalNodeOperationResult.Failure("not implemented in fake"));
        }

        public Task<LocalNodeOperationResult> FetchReadOnlyIpfsFileAsync(
            string toolRoot,
            string workspaceRoot,
            string cid,
            string relativePath,
            string ipfsRepoPath,
            string ipfsCliPathOverride,
            CancellationToken cancellationToken = default)
        {
            return Task.FromResult(LocalNodeOperationResult.Failure("not implemented in fake"));
        }

        public Task<LocalNodeHealthSnapshot> GetHealthAsync(
            string workspaceRoot,
            string ipfsRepoPath,
            string toolRoot,
            string ipfsCliPathOverride,
            CancellationToken cancellationToken = default)
        {
            return Task.FromResult(new LocalNodeHealthSnapshot
            {
                WorkspaceRoot = workspaceRoot,
                IpfsRepoPath = ipfsRepoPath,
                IpfsCliDetected = true,
                IpfsCliPath = "fake-ipfs.exe",
                IpfsCliSource = "Test runtime",
                RepoInitialized = _prepared,
                NodeRecordPresent = _prepared,
                PeerId = _prepared ? "peer-test" : string.Empty,
                StorageMax = _prepared ? "1GB" : string.Empty,
                ParticipationMode = _prepared ? "Public archive contributor" : string.Empty,
                CachePolicy = _prepared ? "Balanced pinned archive" : string.Empty,
                ApiReachable = false,
                Summary = _prepared ? "Local storage prepared; daemon offline" : "Node not initialized"
            });
        }
    }
}
