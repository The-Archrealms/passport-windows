using ArchrealmsPassport.Core.Protocol;
using Xunit;

namespace ArchrealmsPassport.Core.Tests;

public sealed class PassportMonetaryLedgerReplayVerifierTests
{
    [Fact]
    public void ReplaysBalancesAndAccountHashChain()
    {
        var result = PassportMonetaryLedgerReplayVerifier.Verify(
            new[]
            {
                Event(
                    "event-1",
                    PassportMonetaryProtocol.EventCrownCreditIssue,
                    PassportMonetaryProtocol.AssetCrownCredit,
                    100,
                    1,
                    1,
                    "",
                    "hash-1"),
                Event(
                    "event-2",
                    PassportMonetaryProtocol.EventCrownCreditEscrow,
                    PassportMonetaryProtocol.AssetCrownCredit,
                    40,
                    2,
                    2,
                    "hash-1",
                    "hash-2"),
                Event(
                    "event-3",
                    PassportMonetaryProtocol.EventCrownCreditBurn,
                    PassportMonetaryProtocol.AssetCrownCredit,
                    15,
                    3,
                    3,
                    "hash-2",
                    "hash-3")
            },
            Options());

        Assert.True(result.Succeeded, string.Join("; ", result.Failures));
        var balance = Assert.Single(result.Balances);
        Assert.Equal(60, balance.AvailableBaseUnits);
        Assert.Equal(25, balance.EscrowedBaseUnits);
        Assert.Equal(15, balance.BurnedBaseUnits);
    }

    [Fact]
    public void RejectsDuplicateIdsNoncesSequencesAndPriorHashes()
    {
        var result = PassportMonetaryLedgerReplayVerifier.Verify(
            new[]
            {
                Event("event-1", PassportMonetaryProtocol.EventCrownCreditIssue, PassportMonetaryProtocol.AssetCrownCredit, 100, 1, 1, "", "hash-1", nonce: "nonce-1"),
                Event("event-1", PassportMonetaryProtocol.EventCrownCreditIssue, PassportMonetaryProtocol.AssetCrownCredit, 50, 1, 1, "wrong", "hash-2", nonce: "nonce-1")
            },
            Options());

        Assert.False(result.Succeeded);
        Assert.Contains(result.Failures, failure => failure.Contains("Duplicate monetary ledger event ID: event-1", StringComparison.Ordinal));
        Assert.Contains(result.Failures, failure => failure.Contains("Duplicate monetary ledger anti-replay nonce: nonce-1", StringComparison.Ordinal));
        Assert.Contains(result.Failures, failure => failure.Contains("Monetary ledger global sequence is not strictly increasing", StringComparison.Ordinal));
        Assert.Contains(result.Failures, failure => failure.Contains("Duplicate account sequence 1", StringComparison.Ordinal));
        Assert.Contains(result.Failures, failure => failure.Contains("Invalid prior account event hash", StringComparison.Ordinal));
    }

    [Fact]
    public void EnforcesReleaseLaneAndProductionFlags()
    {
        var result = PassportMonetaryLedgerReplayVerifier.Verify(
            new[]
            {
                Event(
                    "event-1",
                    PassportMonetaryProtocol.EventCrownCreditIssue,
                    PassportMonetaryProtocol.AssetCrownCredit,
                    100,
                    1,
                    1,
                    "",
                    "hash-1") with
                {
                    ReleaseLane = "staging",
                    LedgerNamespace = "archrealms-passport-staging",
                    ProductionTokenRecord = true,
                    StagingRecord = true
                }
            },
            Options(expectedReleaseLane: "production-mvp", expectedLedgerNamespace: "archrealms-passport-production-mvp"));

        Assert.False(result.Succeeded);
        Assert.Contains(result.Failures, failure => failure.Contains("belongs to release lane staging", StringComparison.Ordinal));
        Assert.Contains(result.Failures, failure => failure.Contains("belongs to ledger namespace archrealms-passport-staging", StringComparison.Ordinal));
        Assert.Contains(result.Failures, failure => failure.Contains("Non-production ledger event event-1 cannot carry production token record status.", StringComparison.Ordinal));
        Assert.Contains(result.Failures, failure => failure.Contains("is marked as staging", StringComparison.Ordinal));
    }

    [Fact]
    public void EnforcesUniqueProductionArchGenesisAllocationIds()
    {
        var result = PassportMonetaryLedgerReplayVerifier.Verify(
            new[]
            {
                Event("event-1", PassportMonetaryProtocol.EventArchGenesisAllocation, PassportMonetaryProtocol.AssetArch, 100, 1, 1, "", "hash-1", allocationId: "allocation-1"),
                Event("event-2", PassportMonetaryProtocol.EventArchGenesisAllocation, PassportMonetaryProtocol.AssetArch, 50, 2, 1, "", "hash-2", accountId: "account-2", allocationId: "allocation-1")
            },
            Options(enforceUniqueArchGenesisAllocationIds: true));

        Assert.False(result.Succeeded);
        Assert.Contains(result.Failures, failure => failure.Contains("Duplicate ARCH genesis allocation ID: allocation-1.", StringComparison.Ordinal));
    }

    private static PassportMonetaryLedgerReplayEvent Event(
        string eventId,
        string eventType,
        string assetCode,
        long amount,
        long globalSequence,
        long accountSequence,
        string priorHash,
        string eventHash,
        string accountId = "account-1",
        string nonce = "",
        string allocationId = "")
    {
        return new PassportMonetaryLedgerReplayEvent
        {
            EventId = eventId,
            EventType = eventType,
            CreatedUtc = "2026-05-15T00:00:00Z",
            ReleaseLane = "staging",
            LedgerNamespace = "archrealms-passport-staging",
            AccountId = accountId,
            AssetCode = assetCode,
            AmountBaseUnits = amount,
            GlobalSequence = globalSequence,
            AccountSequence = accountSequence,
            PriorAccountEventHash = priorHash,
            EventHashSha256 = eventHash,
            AntiReplayNonce = string.IsNullOrWhiteSpace(nonce) ? "nonce-" + eventId : nonce,
            ArchGenesisAllocationId = allocationId
        };
    }

    private static PassportMonetaryLedgerReplayOptions Options(
        string expectedReleaseLane = "staging",
        string expectedLedgerNamespace = "archrealms-passport-staging",
        bool enforceUniqueArchGenesisAllocationIds = false)
    {
        return new PassportMonetaryLedgerReplayOptions
        {
            ExpectedReleaseLane = expectedReleaseLane,
            ExpectedLedgerNamespace = expectedLedgerNamespace,
            EnforceUniqueArchGenesisAllocationIds = enforceUniqueArchGenesisAllocationIds
        };
    }
}
