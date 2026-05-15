using System.Windows;
using ArchrealmsPassport.Windows.Models;
using ArchrealmsPassport.Windows.Services;
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
}
