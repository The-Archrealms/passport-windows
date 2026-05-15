namespace ArchrealmsPassport.Core.Protocol;

public sealed record PassportMonetaryLedgerEventState
{
    public string EventId { get; init; } = string.Empty;

    public string AccountId { get; init; } = string.Empty;

    public string AssetCode { get; init; } = string.Empty;

    public string EventType { get; init; } = string.Empty;

    public long AmountBaseUnits { get; init; }
}

public sealed record PassportMonetaryBalanceState
{
    public string AccountId { get; init; } = string.Empty;

    public string AssetCode { get; init; } = string.Empty;

    public long AvailableBaseUnits { get; init; }

    public long EscrowedBaseUnits { get; init; }

    public long BurnedBaseUnits { get; init; }
}

public sealed record PassportMonetaryLedgerSemanticsResult(
    PassportMonetaryBalanceState Balance,
    IReadOnlyList<string> Failures)
{
    public bool Succeeded => Failures.Count == 0;
}

public static class PassportMonetaryLedgerSemantics
{
    public static PassportMonetaryLedgerSemanticsResult ApplyEvent(
        PassportMonetaryBalanceState balance,
        PassportMonetaryLedgerEventState ledgerEvent)
    {
        var failures = new List<string>();
        var assetCode = PassportMonetaryProtocol.NormalizeAssetCode(ledgerEvent.AssetCode);
        var eventType = PassportMonetaryProtocol.NormalizeEventType(ledgerEvent.EventType);
        var next = balance with
        {
            AccountId = string.IsNullOrWhiteSpace(balance.AccountId) ? ledgerEvent.AccountId : balance.AccountId,
            AssetCode = string.IsNullOrWhiteSpace(balance.AssetCode) ? assetCode : PassportMonetaryProtocol.NormalizeAssetCode(balance.AssetCode)
        };

        if (ledgerEvent.AmountBaseUnits <= 0)
        {
            failures.Add("A monetary ledger event amount must be greater than zero.");
            return new PassportMonetaryLedgerSemanticsResult(next, failures);
        }

        if (assetCode == PassportMonetaryProtocol.AssetArch)
        {
            next = ApplyArchEvent(next, ledgerEvent, eventType, failures);
            return new PassportMonetaryLedgerSemanticsResult(next, failures);
        }

        if (assetCode == PassportMonetaryProtocol.AssetCrownCredit)
        {
            next = ApplyCrownCreditEvent(next, ledgerEvent, eventType, failures);
            return new PassportMonetaryLedgerSemanticsResult(next, failures);
        }

        failures.Add("Unsupported monetary asset code " + ledgerEvent.AssetCode + " for event " + ledgerEvent.EventId + ".");
        return new PassportMonetaryLedgerSemanticsResult(next, failures);
    }

    private static PassportMonetaryBalanceState ApplyArchEvent(
        PassportMonetaryBalanceState balance,
        PassportMonetaryLedgerEventState ledgerEvent,
        string eventType,
        List<string> failures)
    {
        switch (eventType)
        {
            case PassportMonetaryProtocol.EventArchGenesisAllocation:
                if (balance.AvailableBaseUnits > 0)
                {
                    failures.Add("ARCH genesis allocation can appear only once for account " + ledgerEvent.AccountId + ".");
                }

                return balance with { AvailableBaseUnits = balance.AvailableBaseUnits + ledgerEvent.AmountBaseUnits };

            case PassportMonetaryProtocol.EventArchTransferIn:
                return balance with { AvailableBaseUnits = balance.AvailableBaseUnits + ledgerEvent.AmountBaseUnits };

            case PassportMonetaryProtocol.EventArchTransferOut:
                if (balance.AvailableBaseUnits < ledgerEvent.AmountBaseUnits)
                {
                    failures.Add("ARCH transfer out exceeds available balance for account " + ledgerEvent.AccountId + ".");
                }

                return balance with { AvailableBaseUnits = balance.AvailableBaseUnits - ledgerEvent.AmountBaseUnits };

            default:
                failures.Add("Unsupported ARCH event type " + ledgerEvent.EventType + ". ARCH can be allocated from genesis or transferred; it cannot be minted after genesis.");
                return balance;
        }
    }

    private static PassportMonetaryBalanceState ApplyCrownCreditEvent(
        PassportMonetaryBalanceState balance,
        PassportMonetaryLedgerEventState ledgerEvent,
        string eventType,
        List<string> failures)
    {
        switch (eventType)
        {
            case PassportMonetaryProtocol.EventCrownCreditIssue:
                return balance with { AvailableBaseUnits = balance.AvailableBaseUnits + ledgerEvent.AmountBaseUnits };

            case PassportMonetaryProtocol.EventCrownCreditEscrow:
                if (balance.AvailableBaseUnits < ledgerEvent.AmountBaseUnits)
                {
                    failures.Add("CC escrow exceeds available balance for account " + ledgerEvent.AccountId + ".");
                }

                return balance with
                {
                    AvailableBaseUnits = balance.AvailableBaseUnits - ledgerEvent.AmountBaseUnits,
                    EscrowedBaseUnits = balance.EscrowedBaseUnits + ledgerEvent.AmountBaseUnits
                };

            case PassportMonetaryProtocol.EventCrownCreditBurn:
                if (balance.EscrowedBaseUnits < ledgerEvent.AmountBaseUnits)
                {
                    failures.Add("CC burn exceeds escrowed balance for account " + ledgerEvent.AccountId + ".");
                }

                return balance with
                {
                    EscrowedBaseUnits = balance.EscrowedBaseUnits - ledgerEvent.AmountBaseUnits,
                    BurnedBaseUnits = balance.BurnedBaseUnits + ledgerEvent.AmountBaseUnits
                };

            case PassportMonetaryProtocol.EventCrownCreditRefund:
                if (balance.EscrowedBaseUnits < ledgerEvent.AmountBaseUnits)
                {
                    failures.Add("CC refund exceeds escrowed balance for account " + ledgerEvent.AccountId + ".");
                }

                return balance with
                {
                    EscrowedBaseUnits = balance.EscrowedBaseUnits - ledgerEvent.AmountBaseUnits,
                    AvailableBaseUnits = balance.AvailableBaseUnits + ledgerEvent.AmountBaseUnits
                };

            case PassportMonetaryProtocol.EventCrownCreditRecredit:
            case PassportMonetaryProtocol.EventCrownCreditTransferIn:
                return balance with { AvailableBaseUnits = balance.AvailableBaseUnits + ledgerEvent.AmountBaseUnits };

            case PassportMonetaryProtocol.EventCrownCreditTransferOut:
                if (balance.AvailableBaseUnits < ledgerEvent.AmountBaseUnits)
                {
                    failures.Add("CC transfer out exceeds available balance for account " + ledgerEvent.AccountId + ".");
                }

                return balance with { AvailableBaseUnits = balance.AvailableBaseUnits - ledgerEvent.AmountBaseUnits };

            default:
                failures.Add("Unsupported CC event type " + ledgerEvent.EventType + ". MVP CC events are issue, escrow, burn, refund, re-credit, transfer-in, and transfer-out only.");
                return balance;
        }
    }
}
