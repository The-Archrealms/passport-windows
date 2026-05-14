using System;
using System.Collections.Generic;
using System.IO;
using ArchrealmsPassport.Windows.Services;
using ArchrealmsPassport.Windows.Tests.Infrastructure;
using Xunit;

namespace ArchrealmsPassport.Windows.Tests;

public sealed class PassportStorageRedemptionServiceTests
{
    [Fact]
    public void StorageRedemptionEscrowsBurnsAndRefundsCcAgainstProofEvidence()
    {
        using var workspace = PassportTestWorkspace.Create();
        var releaseLane = PassportReleaseLane.CreateDefault("production-mvp");
        var wallet = new PassportWalletKeyService(releaseLane).CreateAndBindWalletKey(
            workspace.Root,
            workspace.IdentityId,
            workspace.DeviceId,
            workspace.KeyReferencePath);
        Assert.True(wallet.Succeeded, wallet.Message);

        var ledger = new PassportMonetaryLedgerService(releaseLane);
        var funding = ledger.AppendEvent(
            workspace.Root,
            "account-test",
            workspace.IdentityId,
            wallet.WalletKeyId,
            PassportMonetaryLedgerService.EventCrownCreditTransferIn,
            PassportMonetaryLedgerService.AssetCrownCredit,
            200,
            new Dictionary<string, string> { ["funding_source"] = "test-existing-cc" },
            walletKeyReferencePath: wallet.WalletKeyReferencePath,
            walletPublicKeyPath: wallet.WalletPublicKeyPath);
        Assert.True(funding.Succeeded, funding.Message);

        var service = new PassportStorageRedemptionService(releaseLane);
        var quote = service.CreateQuote(
            workspace.Root,
            "account-test",
            workspace.IdentityId,
            wallet.WalletKeyId,
            storageGb: 10,
            serviceEpochCount: 10,
            ccPerGbEpochBaseUnits: 1,
            expiresUtc: DateTime.UtcNow.AddMinutes(5),
            serviceClass: "mvp_storage",
            quoteSource: "admin_set_mvp_storage_quote");
        Assert.True(quote.Succeeded, quote.Message);

        var accepted = service.AcceptQuote(
            workspace.Root,
            quote.RecordPath,
            quote.RecordSha256,
            wallet.WalletKeyReferencePath,
            wallet.WalletPublicKeyPath);
        Assert.True(accepted.Succeeded, accepted.Message);

        var proofPath = workspace.WriteProofSource("storage-proof.json", "{\"proof\":\"ok\"}");
        var proofHash = PassportTestWorkspace.ComputeFileSha256(proofPath);
        var burn = service.BurnVerifiedEpoch(
            workspace.Root,
            accepted.RecordPath,
            burnCcBaseUnits: 40,
            verifiedGbDays: 40,
            proofRecordPath: proofPath,
            proofRecordSha256: proofHash,
            walletKeyReferencePath: wallet.WalletKeyReferencePath,
            walletPublicKeyPath: wallet.WalletPublicKeyPath);
        Assert.True(burn.Succeeded, burn.Message);

        var refund = service.RefundRemaining(
            workspace.Root,
            accepted.RecordPath,
            refundCcBaseUnits: 60,
            reasonCode: "unused_or_failed_epochs",
            walletKeyReferencePath: wallet.WalletKeyReferencePath,
            walletPublicKeyPath: wallet.WalletPublicKeyPath);
        Assert.True(refund.Succeeded, refund.Message);

        var replay = ledger.Replay(workspace.Root);
        Assert.True(replay.Succeeded, string.Join("; ", replay.Failures));
        Assert.Contains(replay.Balances, balance =>
            balance.AssetCode == PassportMonetaryLedgerService.AssetCrownCredit
            && balance.AvailableBaseUnits == 160
            && balance.EscrowedBaseUnits == 0
            && balance.BurnedBaseUnits == 40);

        var burnRecord = PassportTestWorkspace.ReadJson(burn.RecordPath);
        Assert.Equal("passport_storage_redemption_epoch_burn", PassportTestWorkspace.GetString(burnRecord, "record_type"));
        Assert.Equal(proofHash, PassportTestWorkspace.GetString(burnRecord, "proof_record_sha256"));
        Assert.True(burnRecord.TryGetProperty("wallet_signature", out _));
    }

    [Fact]
    public void StorageRedemptionRejectsBurnsBeyondRemainingEscrow()
    {
        using var workspace = PassportTestWorkspace.Create();
        var releaseLane = PassportReleaseLane.CreateDefault("production-mvp");
        var wallet = new PassportWalletKeyService(releaseLane).CreateAndBindWalletKey(
            workspace.Root,
            workspace.IdentityId,
            workspace.DeviceId,
            workspace.KeyReferencePath);
        Assert.True(wallet.Succeeded, wallet.Message);

        var ledger = new PassportMonetaryLedgerService(releaseLane);
        var funding = ledger.AppendEvent(
            workspace.Root,
            "account-test",
            workspace.IdentityId,
            wallet.WalletKeyId,
            PassportMonetaryLedgerService.EventCrownCreditTransferIn,
            PassportMonetaryLedgerService.AssetCrownCredit,
            100,
            new Dictionary<string, string> { ["funding_source"] = "test-existing-cc" },
            walletKeyReferencePath: wallet.WalletKeyReferencePath,
            walletPublicKeyPath: wallet.WalletPublicKeyPath);
        Assert.True(funding.Succeeded, funding.Message);

        var service = new PassportStorageRedemptionService(releaseLane);
        var quote = service.CreateQuote(
            workspace.Root,
            "account-test",
            workspace.IdentityId,
            wallet.WalletKeyId,
            10,
            10,
            1,
            DateTime.UtcNow.AddMinutes(5),
            "mvp_storage",
            "admin_set_mvp_storage_quote");
        Assert.True(quote.Succeeded, quote.Message);
        var accepted = service.AcceptQuote(
            workspace.Root,
            quote.RecordPath,
            quote.RecordSha256,
            wallet.WalletKeyReferencePath,
            wallet.WalletPublicKeyPath);
        Assert.True(accepted.Succeeded, accepted.Message);

        var proofPath = workspace.WriteProofSource("storage-proof.json", "{\"proof\":\"ok\"}");
        var burn = service.BurnVerifiedEpoch(
            workspace.Root,
            accepted.RecordPath,
            101,
            101,
            proofPath,
            PassportTestWorkspace.ComputeFileSha256(proofPath),
            wallet.WalletKeyReferencePath,
            wallet.WalletPublicKeyPath);

        Assert.False(burn.Succeeded);
        Assert.Contains("exceeds remaining escrow", burn.Message, StringComparison.OrdinalIgnoreCase);
    }
}
