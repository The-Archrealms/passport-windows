using ArchrealmsPassport.Core.Protocol;
using Xunit;

namespace ArchrealmsPassport.Core.Tests;

public sealed class PassportMonetaryLedgerSemanticsTests
{
    [Fact]
    public void AppliesArchGenesisAndRejectsPostGenesisMintLikeEvents()
    {
        var genesis = PassportMonetaryLedgerSemantics.ApplyEvent(
            new PassportMonetaryBalanceState { AccountId = "account-1", AssetCode = "ARCH" },
            Event("event-1", "account-1", "ARCH", "arch_genesis_allocation", 100));

        Assert.True(genesis.Succeeded, string.Join("; ", genesis.Failures));
        Assert.Equal(100, genesis.Balance.AvailableBaseUnits);

        var unsupported = PassportMonetaryLedgerSemantics.ApplyEvent(
            genesis.Balance,
            Event("event-2", "account-1", "ARCH", "arch_mint", 25));

        Assert.False(unsupported.Succeeded);
        Assert.Contains("cannot be minted", unsupported.Failures.Single(), StringComparison.OrdinalIgnoreCase);
        Assert.Equal(100, unsupported.Balance.AvailableBaseUnits);
    }

    [Fact]
    public void AppliesCrownCreditEscrowBurnRefundAndRecreditSemantics()
    {
        var issued = PassportMonetaryLedgerSemantics.ApplyEvent(
            new PassportMonetaryBalanceState { AccountId = "account-1", AssetCode = "CC" },
            Event("event-1", "account-1", "CC", "cc_issue", 100));
        var escrowed = PassportMonetaryLedgerSemantics.ApplyEvent(
            issued.Balance,
            Event("event-2", "account-1", "CC", "cc_escrow", 70));
        var burned = PassportMonetaryLedgerSemantics.ApplyEvent(
            escrowed.Balance,
            Event("event-3", "account-1", "CC", "cc_burn", 25));
        var refunded = PassportMonetaryLedgerSemantics.ApplyEvent(
            burned.Balance,
            Event("event-4", "account-1", "CC", "cc_refund", 30));
        var recredited = PassportMonetaryLedgerSemantics.ApplyEvent(
            refunded.Balance,
            Event("event-5", "account-1", "CC", "cc_recredit", 5));

        Assert.True(recredited.Succeeded, string.Join("; ", recredited.Failures));
        Assert.Equal(65, recredited.Balance.AvailableBaseUnits);
        Assert.Equal(15, recredited.Balance.EscrowedBaseUnits);
        Assert.Equal(25, recredited.Balance.BurnedBaseUnits);
    }

    [Fact]
    public void ReportsOverspendFailuresWhilePreservingDeterministicReplay()
    {
        var result = PassportMonetaryLedgerSemantics.ApplyEvent(
            new PassportMonetaryBalanceState { AccountId = "account-1", AssetCode = "CC", AvailableBaseUnits = 10 },
            Event("event-1", "account-1", "CC", "cc_transfer_out", 25));

        Assert.False(result.Succeeded);
        Assert.Contains("exceeds available", result.Failures.Single(), StringComparison.OrdinalIgnoreCase);
        Assert.Equal(-15, result.Balance.AvailableBaseUnits);
    }

    private static PassportMonetaryLedgerEventState Event(
        string eventId,
        string accountId,
        string assetCode,
        string eventType,
        long amountBaseUnits)
    {
        return new PassportMonetaryLedgerEventState
        {
            EventId = eventId,
            AccountId = accountId,
            AssetCode = assetCode,
            EventType = eventType,
            AmountBaseUnits = amountBaseUnits
        };
    }
}
