namespace ArchrealmsPassport.Core.Protocol;

public sealed record PassportMonetaryLedgerReplayEvent
{
    public string EventId { get; init; } = string.Empty;

    public string EventType { get; init; } = string.Empty;

    public string CreatedUtc { get; init; } = string.Empty;

    public string ReleaseLane { get; init; } = string.Empty;

    public string LedgerNamespace { get; init; } = string.Empty;

    public bool ProductionTokenRecord { get; init; }

    public bool StagingRecord { get; init; }

    public string AccountId { get; init; } = string.Empty;

    public string AssetCode { get; init; } = string.Empty;

    public long AmountBaseUnits { get; init; }

    public long GlobalSequence { get; init; }

    public long AccountSequence { get; init; }

    public string PriorAccountEventHash { get; init; } = string.Empty;

    public string EventHashSha256 { get; init; } = string.Empty;

    public string AntiReplayNonce { get; init; } = string.Empty;

    public string ArchGenesisAllocationId { get; init; } = string.Empty;
}

public sealed record PassportMonetaryLedgerReplayOptions
{
    public string ExpectedReleaseLane { get; init; } = string.Empty;

    public string ExpectedLedgerNamespace { get; init; } = string.Empty;

    public bool ProductionLedger { get; init; }

    public bool AllowProductionTokenRecords { get; init; }

    public bool AllowStagingRecords { get; init; }

    public bool EnforceUniqueArchGenesisAllocationIds { get; init; }
}

public sealed record PassportMonetaryLedgerReplayVerificationResult
{
    public bool Succeeded => Failures.Count == 0;

    public int EventCount { get; init; }

    public IReadOnlyList<PassportMonetaryBalanceState> Balances { get; init; } = Array.Empty<PassportMonetaryBalanceState>();

    public IReadOnlyList<string> Failures { get; init; } = Array.Empty<string>();
}

public static class PassportMonetaryLedgerReplayVerifier
{
    public static PassportMonetaryLedgerReplayVerificationResult Verify(
        IEnumerable<PassportMonetaryLedgerReplayEvent> ledgerEvents,
        PassportMonetaryLedgerReplayOptions options)
    {
        var events = ledgerEvents.ToArray();
        var failures = new List<string>();
        ValidateDuplicateIds(events, options, failures);
        ValidateGlobalSequence(events, failures);

        var balances = new Dictionary<string, PassportMonetaryBalanceState>(StringComparer.Ordinal);
        foreach (var accountGroup in events
            .OrderBy(item => item.AccountId, StringComparer.Ordinal)
            .ThenBy(item => item.AccountSequence)
            .ThenBy(item => item.CreatedUtc, StringComparer.Ordinal)
            .ThenBy(item => item.EventId, StringComparer.Ordinal)
            .GroupBy(item => item.AccountId, StringComparer.Ordinal))
        {
            ValidateAndReplayAccount(accountGroup, options, balances, failures);
        }

        return new PassportMonetaryLedgerReplayVerificationResult
        {
            EventCount = events.Length,
            Balances = balances.Values
                .OrderBy(balance => balance.AccountId, StringComparer.Ordinal)
                .ThenBy(balance => balance.AssetCode, StringComparer.Ordinal)
                .ToArray(),
            Failures = failures.ToArray()
        };
    }

    private static void ValidateDuplicateIds(
        IReadOnlyList<PassportMonetaryLedgerReplayEvent> events,
        PassportMonetaryLedgerReplayOptions options,
        List<string> failures)
    {
        var duplicateEventIds = new HashSet<string>(StringComparer.Ordinal);
        var duplicateNonces = new HashSet<string>(StringComparer.Ordinal);
        var archGenesisAllocationIds = new HashSet<string>(StringComparer.Ordinal);

        foreach (var ledgerEvent in events)
        {
            if (!duplicateEventIds.Add(ledgerEvent.EventId))
            {
                failures.Add("Duplicate monetary ledger event ID: " + ledgerEvent.EventId);
            }

            if (!string.IsNullOrWhiteSpace(ledgerEvent.AntiReplayNonce)
                && !duplicateNonces.Add(ledgerEvent.AntiReplayNonce))
            {
                failures.Add("Duplicate monetary ledger anti-replay nonce: " + ledgerEvent.AntiReplayNonce);
            }

            if (options.EnforceUniqueArchGenesisAllocationIds
                && string.Equals(ledgerEvent.AssetCode, PassportMonetaryProtocol.AssetArch, StringComparison.Ordinal)
                && string.Equals(ledgerEvent.EventType, PassportMonetaryProtocol.EventArchGenesisAllocation, StringComparison.Ordinal)
                && !string.IsNullOrWhiteSpace(ledgerEvent.ArchGenesisAllocationId)
                && !archGenesisAllocationIds.Add(ledgerEvent.ArchGenesisAllocationId.Trim()))
            {
                failures.Add("Duplicate ARCH genesis allocation ID: " + ledgerEvent.ArchGenesisAllocationId.Trim() + ".");
            }
        }
    }

    private static void ValidateGlobalSequence(
        IEnumerable<PassportMonetaryLedgerReplayEvent> events,
        List<string> failures)
    {
        var priorGlobalSequence = 0L;
        foreach (var ledgerEvent in events
            .OrderBy(item => item.GlobalSequence)
            .ThenBy(item => item.CreatedUtc, StringComparer.Ordinal)
            .ThenBy(item => item.EventId, StringComparer.Ordinal))
        {
            if (ledgerEvent.GlobalSequence <= priorGlobalSequence)
            {
                failures.Add("Monetary ledger global sequence is not strictly increasing at event " + ledgerEvent.EventId + ".");
            }

            priorGlobalSequence = ledgerEvent.GlobalSequence;
        }
    }

    private static void ValidateAndReplayAccount(
        IEnumerable<PassportMonetaryLedgerReplayEvent> accountEvents,
        PassportMonetaryLedgerReplayOptions options,
        Dictionary<string, PassportMonetaryBalanceState> balances,
        List<string> failures)
    {
        var expectedSequence = 1L;
        var priorHash = string.Empty;
        var sequenceIds = new HashSet<long>();

        foreach (var ledgerEvent in accountEvents)
        {
            if (!sequenceIds.Add(ledgerEvent.AccountSequence))
            {
                failures.Add("Duplicate account sequence " + ledgerEvent.AccountSequence + " for " + ledgerEvent.AccountId + ".");
            }

            if (ledgerEvent.AccountSequence != expectedSequence)
            {
                failures.Add("Expected account sequence " + expectedSequence + " for " + ledgerEvent.AccountId + " but found " + ledgerEvent.AccountSequence + ".");
            }

            if (!string.Equals(ledgerEvent.PriorAccountEventHash, priorHash, StringComparison.OrdinalIgnoreCase))
            {
                failures.Add("Invalid prior account event hash at sequence " + ledgerEvent.AccountSequence + " for " + ledgerEvent.AccountId + ".");
            }

            ValidateReleaseLane(ledgerEvent, options, failures);
            ApplyEventSemantics(balances, ledgerEvent, failures);
            priorHash = ledgerEvent.EventHashSha256;
            expectedSequence++;
        }
    }

    private static void ValidateReleaseLane(
        PassportMonetaryLedgerReplayEvent ledgerEvent,
        PassportMonetaryLedgerReplayOptions options,
        List<string> failures)
    {
        if (!string.IsNullOrWhiteSpace(options.ExpectedReleaseLane)
            && !string.Equals(ledgerEvent.ReleaseLane, options.ExpectedReleaseLane, StringComparison.Ordinal))
        {
            failures.Add("Event " + ledgerEvent.EventId + " belongs to release lane " + ledgerEvent.ReleaseLane + " but this ledger is " + options.ExpectedReleaseLane + ".");
        }

        if (!string.IsNullOrWhiteSpace(options.ExpectedLedgerNamespace)
            && !string.Equals(ledgerEvent.LedgerNamespace, options.ExpectedLedgerNamespace, StringComparison.Ordinal))
        {
            failures.Add("Event " + ledgerEvent.EventId + " belongs to ledger namespace " + ledgerEvent.LedgerNamespace + " but this ledger is " + options.ExpectedLedgerNamespace + ".");
        }

        if (options.ProductionLedger && !ledgerEvent.ProductionTokenRecord)
        {
            failures.Add("Production ledger event " + ledgerEvent.EventId + " is missing production token record status.");
        }

        if (!options.AllowProductionTokenRecords && ledgerEvent.ProductionTokenRecord)
        {
            failures.Add("Non-production ledger event " + ledgerEvent.EventId + " cannot carry production token record status.");
        }

        if (ledgerEvent.StagingRecord && !options.AllowStagingRecords)
        {
            failures.Add("Event " + ledgerEvent.EventId + " is marked as staging but this release lane does not allow staging records.");
        }
    }

    private static void ApplyEventSemantics(
        Dictionary<string, PassportMonetaryBalanceState> balances,
        PassportMonetaryLedgerReplayEvent ledgerEvent,
        List<string> failures)
    {
        var balance = GetBalance(balances, ledgerEvent.AccountId, ledgerEvent.AssetCode);
        var result = PassportMonetaryLedgerSemantics.ApplyEvent(
            balance,
            new PassportMonetaryLedgerEventState
            {
                EventId = ledgerEvent.EventId,
                AccountId = ledgerEvent.AccountId,
                AssetCode = ledgerEvent.AssetCode,
                EventType = ledgerEvent.EventType,
                AmountBaseUnits = ledgerEvent.AmountBaseUnits
            });

        foreach (var failure in result.Failures)
        {
            failures.Add(failure);
        }

        balances[GetBalanceKey(ledgerEvent.AccountId, ledgerEvent.AssetCode)] = result.Balance;
    }

    private static PassportMonetaryBalanceState GetBalance(
        Dictionary<string, PassportMonetaryBalanceState> balances,
        string accountId,
        string assetCode)
    {
        var key = GetBalanceKey(accountId, assetCode);
        if (!balances.TryGetValue(key, out var balance))
        {
            balance = new PassportMonetaryBalanceState
            {
                AccountId = accountId,
                AssetCode = assetCode
            };
            balances[key] = balance;
        }

        return balance;
    }

    private static string GetBalanceKey(string accountId, string assetCode)
    {
        return accountId + "|" + PassportMonetaryProtocol.NormalizeAssetCode(assetCode);
    }
}
