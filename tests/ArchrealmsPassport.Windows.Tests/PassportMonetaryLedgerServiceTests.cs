using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.Json;
using ArchrealmsPassport.Windows.Models;
using ArchrealmsPassport.Windows.Services;
using ArchrealmsPassport.Windows.Tests.Infrastructure;
using Xunit;

namespace ArchrealmsPassport.Windows.Tests;

public sealed class PassportMonetaryLedgerServiceTests
{
    [Fact]
    public void AppendsAndReplaysArchAndCrownCreditEventsFromTheCurrentReleaseLane()
    {
        using var workspace = PassportTestWorkspace.Create();
        var releaseLane = PassportReleaseLane.CreateDefault("staging");
        var service = new PassportMonetaryLedgerService(releaseLane);
        var accountId = "account-" + workspace.IdentityId;
        var walletKeyId = "wallet-key-test";

        AssertAppend(service.AppendEvent(
            workspace.Root,
            accountId,
            workspace.IdentityId,
            walletKeyId,
            PassportMonetaryLedgerService.EventArchGenesisAllocation,
            PassportMonetaryLedgerService.AssetArch,
            1_000,
            new Dictionary<string, string> { ["arch_genesis_hash"] = "genesis-test" }));
        AssertAppend(service.AppendEvent(
            workspace.Root,
            accountId,
            workspace.IdentityId,
            walletKeyId,
            PassportMonetaryLedgerService.EventCrownCreditIssue,
            PassportMonetaryLedgerService.AssetCrownCredit,
            500,
            new Dictionary<string, string> { ["issuance_policy"] = "mvp-capacity-test" }));
        AssertAppend(service.AppendEvent(
            workspace.Root,
            accountId,
            workspace.IdentityId,
            walletKeyId,
            PassportMonetaryLedgerService.EventCrownCreditEscrow,
            PassportMonetaryLedgerService.AssetCrownCredit,
            200,
            new Dictionary<string, string> { ["redemption_id"] = "storage-redemption-test" }));
        AssertAppend(service.AppendEvent(
            workspace.Root,
            accountId,
            workspace.IdentityId,
            walletKeyId,
            PassportMonetaryLedgerService.EventCrownCreditBurn,
            PassportMonetaryLedgerService.AssetCrownCredit,
            50,
            new Dictionary<string, string> { ["proof_epoch_id"] = "storage-epoch-test" }));
        AssertAppend(service.AppendEvent(
            workspace.Root,
            accountId,
            workspace.IdentityId,
            walletKeyId,
            PassportMonetaryLedgerService.EventCrownCreditRefund,
            PassportMonetaryLedgerService.AssetCrownCredit,
            150,
            new Dictionary<string, string> { ["refund_reason"] = "unused-escrow" }));

        var replay = service.Replay(workspace.Root);

        Assert.True(replay.Succeeded, string.Join("; ", replay.Failures));
        Assert.Equal(5, replay.EventCount);
        var arch = replay.Balances.Single(balance => balance.AssetCode == PassportMonetaryLedgerService.AssetArch);
        var cc = replay.Balances.Single(balance => balance.AssetCode == PassportMonetaryLedgerService.AssetCrownCredit);
        Assert.Equal(1_000, arch.AvailableBaseUnits);
        Assert.Equal(450, cc.AvailableBaseUnits);
        Assert.Equal(0, cc.EscrowedBaseUnits);
        Assert.Equal(50, cc.BurnedBaseUnits);
    }

    [Fact]
    public void ReplayRejectsEventsFromAnotherReleaseLane()
    {
        using var workspace = PassportTestWorkspace.Create();
        var stagingService = new PassportMonetaryLedgerService(PassportReleaseLane.CreateDefault("staging"));
        var productionService = new PassportMonetaryLedgerService(PassportReleaseLane.CreateDefault("production-mvp"));

        AssertAppend(stagingService.AppendEvent(
            workspace.Root,
            "account-test",
            workspace.IdentityId,
            "wallet-key-test",
            PassportMonetaryLedgerService.EventCrownCreditIssue,
            PassportMonetaryLedgerService.AssetCrownCredit,
            100));

        var replay = productionService.Replay(workspace.Root);

        Assert.False(replay.Succeeded);
        Assert.Contains(replay.Failures, failure => failure.Contains("belongs to release lane staging", System.StringComparison.Ordinal));
    }

    [Fact]
    public void ReplayRejectsArchPostGenesisMintEvents()
    {
        using var workspace = PassportTestWorkspace.Create();
        var releaseLane = PassportReleaseLane.CreateDefault("staging");
        var accountId = "account-test";
        var ledgerEvent = new PassportMonetaryLedgerEvent
        {
            EventId = "event-arch-mint-test",
            EventType = "arch_mint",
            CreatedUtc = "2026-05-13T00:00:00Z",
            ReleaseLane = releaseLane.Lane,
            TelemetryEnvironment = releaseLane.TelemetryEnvironment,
            LedgerNamespace = releaseLane.LedgerNamespace,
            ProductionTokenRecord = false,
            StagingRecord = true,
            AccountId = accountId,
            IdentityId = workspace.IdentityId,
            WalletKeyId = "wallet-key-test",
            AssetCode = PassportMonetaryLedgerService.AssetArch,
            AmountBaseUnits = 100,
            GlobalSequence = 1,
            AccountSequence = 1,
            ServerReceivedUtc = "2026-05-13T00:00:01Z",
            AntiReplayNonce = "nonce-arch-mint-test",
            DeviceSessionId = "device-session-test",
            PolicyVersion = releaseLane.PolicyVersion,
            SignatureStatus = "unsigned-local-ledger-foundation"
        };
        ledgerEvent.EventHashSha256 = PassportMonetaryLedgerService.ComputeEventHash(ledgerEvent);

        var eventPath = Path.Combine(
            workspace.Root,
            "records",
            "passport",
            "monetary",
            "events",
            "arch",
            accountId,
            "000000000001-" + ledgerEvent.EventId + ".json");
        Directory.CreateDirectory(Path.GetDirectoryName(eventPath) ?? string.Empty);
        File.WriteAllText(eventPath, JsonSerializer.Serialize(ledgerEvent, new JsonSerializerOptions { WriteIndented = true }));

        var replay = new PassportMonetaryLedgerService(releaseLane).Replay(workspace.Root);

        Assert.False(replay.Succeeded);
        Assert.Contains(replay.Failures, failure => failure.Contains("ARCH can be allocated from genesis or transferred", System.StringComparison.Ordinal));
    }

    [Fact]
    public void ReplayRejectsTamperedEventHashes()
    {
        using var workspace = PassportTestWorkspace.Create();
        var service = new PassportMonetaryLedgerService(PassportReleaseLane.CreateDefault("staging"));
        var append = service.AppendEvent(
            workspace.Root,
            "account-test",
            workspace.IdentityId,
            "wallet-key-test",
            PassportMonetaryLedgerService.EventCrownCreditIssue,
            PassportMonetaryLedgerService.AssetCrownCredit,
            100);
        AssertAppend(append);

        var json = File.ReadAllText(append.EventPath).Replace("\"amount_base_units\": 100", "\"amount_base_units\": 101");
        File.WriteAllText(append.EventPath, json);

        var replay = service.Replay(workspace.Root);

        Assert.False(replay.Succeeded);
        Assert.Contains(replay.Failures, failure => failure.Contains("Invalid monetary ledger event hash", System.StringComparison.Ordinal));
    }

    [Fact]
    public void AccountExportContainsReplayableEventsAndTransparencyRoot()
    {
        using var workspace = PassportTestWorkspace.Create();
        var releaseLane = PassportReleaseLane.CreateDefault("staging");
        var service = new PassportMonetaryLedgerService(releaseLane);
        var accountId = "account-test";

        AssertAppend(service.AppendEvent(
            workspace.Root,
            accountId,
            workspace.IdentityId,
            "wallet-key-test",
            PassportMonetaryLedgerService.EventCrownCreditIssue,
            PassportMonetaryLedgerService.AssetCrownCredit,
            300));
        AssertAppend(service.AppendEvent(
            workspace.Root,
            accountId,
            workspace.IdentityId,
            "wallet-key-test",
            PassportMonetaryLedgerService.EventCrownCreditEscrow,
            PassportMonetaryLedgerService.AssetCrownCredit,
            100));

        var export = service.CreateAccountExport(workspace.Root, accountId);

        Assert.True(export.Succeeded, export.Message);
        Assert.True(File.Exists(export.ManifestPath));
        Assert.True(File.Exists(export.TransparencyRootPath));
        Assert.Equal(2, export.EventCount);
        Assert.False(string.IsNullOrWhiteSpace(export.ExportRootSha256));

        var exportedReplay = service.Replay(export.ExportRoot);

        Assert.True(exportedReplay.Succeeded, string.Join("; ", exportedReplay.Failures));
        var cc = exportedReplay.Balances.Single(balance => balance.AssetCode == PassportMonetaryLedgerService.AssetCrownCredit);
        Assert.Equal(200, cc.AvailableBaseUnits);
        Assert.Equal(100, cc.EscrowedBaseUnits);
    }

    [Fact]
    public void ProductionLedgerAppendRequiresWalletSignature()
    {
        using var workspace = PassportTestWorkspace.Create();
        var service = new PassportMonetaryLedgerService(PassportReleaseLane.CreateDefault("production-mvp"));

        var result = service.AppendEvent(
            workspace.Root,
            "account-test",
            workspace.IdentityId,
            "wallet-key-test",
            PassportMonetaryLedgerService.EventCrownCreditIssue,
            PassportMonetaryLedgerService.AssetCrownCredit,
            100);

        Assert.False(result.Succeeded);
        Assert.Contains("require a wallet signature", result.Message);
    }

    [Fact]
    public void ProductionLedgerReplaysWalletSignedEvents()
    {
        using var workspace = PassportTestWorkspace.Create();
        var releaseLane = PassportReleaseLane.CreateDefault("production-mvp");
        var walletService = new PassportWalletKeyService(releaseLane);
        var wallet = walletService.CreateAndBindWalletKey(
            workspace.Root,
            workspace.IdentityId,
            workspace.DeviceId,
            workspace.KeyReferencePath);
        Assert.True(wallet.Succeeded, wallet.Message);

        var ledgerService = new PassportMonetaryLedgerService(releaseLane);
        var append = ledgerService.AppendEvent(
            workspace.Root,
            "account-test",
            workspace.IdentityId,
            wallet.WalletKeyId,
            PassportMonetaryLedgerService.EventCrownCreditIssue,
            PassportMonetaryLedgerService.AssetCrownCredit,
            100,
            walletKeyReferencePath: wallet.WalletKeyReferencePath,
            walletPublicKeyPath: wallet.WalletPublicKeyPath);
        AssertAppend(append);

        var replay = ledgerService.Replay(workspace.Root);

        Assert.True(replay.Succeeded, string.Join("; ", replay.Failures));
        var ledgerEvent = PassportTestWorkspace.ReadJson(append.EventPath);
        Assert.Equal("wallet_signed", PassportTestWorkspace.GetString(ledgerEvent, "signature_status"));
        Assert.False(string.IsNullOrWhiteSpace(PassportTestWorkspace.GetString(ledgerEvent, "wallet_signature_base64")));
        Assert.False(string.IsNullOrWhiteSpace(PassportTestWorkspace.GetString(ledgerEvent, "signed_event_hash_sha256")));
    }

    [Fact]
    public void ProductionLedgerBlocksNewEventsFromRevokedWalletKeys()
    {
        using var workspace = PassportTestWorkspace.Create();
        var releaseLane = PassportReleaseLane.CreateDefault("production-mvp");
        var walletService = new PassportWalletKeyService(releaseLane);
        var wallet = walletService.CreateAndBindWalletKey(
            workspace.Root,
            workspace.IdentityId,
            workspace.DeviceId,
            workspace.KeyReferencePath);
        Assert.True(wallet.Succeeded, wallet.Message);

        var ledgerService = new PassportMonetaryLedgerService(releaseLane);
        var append = ledgerService.AppendEvent(
            workspace.Root,
            "account-test",
            workspace.IdentityId,
            wallet.WalletKeyId,
            PassportMonetaryLedgerService.EventCrownCreditIssue,
            PassportMonetaryLedgerService.AssetCrownCredit,
            100,
            walletKeyReferencePath: wallet.WalletKeyReferencePath,
            walletPublicKeyPath: wallet.WalletPublicKeyPath);
        AssertAppend(append);

        var revocation = walletService.RevokeWalletKey(
            workspace.Root,
            workspace.IdentityId,
            workspace.DeviceId,
            workspace.KeyReferencePath,
            wallet.WalletKeyId,
            "wallet_compromise",
            true);
        Assert.True(revocation.Succeeded, revocation.Message);

        var blocked = ledgerService.AppendEvent(
            workspace.Root,
            "account-test",
            workspace.IdentityId,
            wallet.WalletKeyId,
            PassportMonetaryLedgerService.EventCrownCreditIssue,
            PassportMonetaryLedgerService.AssetCrownCredit,
            25,
            walletKeyReferencePath: wallet.WalletKeyReferencePath,
            walletPublicKeyPath: wallet.WalletPublicKeyPath);

        Assert.False(blocked.Succeeded);
        Assert.Contains("wallet key is not active", blocked.Message, System.StringComparison.OrdinalIgnoreCase);

        var replay = ledgerService.Replay(workspace.Root);
        Assert.True(replay.Succeeded, string.Join("; ", replay.Failures));
        Assert.Equal(1, replay.EventCount);
    }

    private static void AssertAppend(PassportMonetaryLedgerAppendResult result)
    {
        Assert.True(result.Succeeded, result.Message);
        Assert.True(File.Exists(result.EventPath), result.EventPath);
        Assert.False(string.IsNullOrWhiteSpace(result.EventHashSha256));
    }
}
