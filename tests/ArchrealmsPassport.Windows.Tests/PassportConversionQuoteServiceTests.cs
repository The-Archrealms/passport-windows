using System;
using System.IO;
using System.Linq;
using ArchrealmsPassport.Windows.Services;
using ArchrealmsPassport.Windows.Tests.Infrastructure;
using Xunit;

namespace ArchrealmsPassport.Windows.Tests;

public sealed class PassportConversionQuoteServiceTests
{
    [Fact]
    public void CreateQuoteWritesDisclosureCompleteFloatingRateRecord()
    {
        using var workspace = PassportTestWorkspace.Create();
        var service = new PassportConversionQuoteService(PassportReleaseLane.CreateDefault("staging"));

        var quote = service.CreateQuote(
            workspace.Root,
            "account-test",
            workspace.IdentityId,
            "wallet-key-test",
            PassportMonetaryLedgerService.AssetArch,
            PassportMonetaryLedgerService.AssetCrownCredit,
            sourceAmountBaseUnits: 10,
            destinationAmountBaseUnits: 2_500,
            rateSource: "crown_reference_twap",
            liquiditySource: "qualified_internal_liquidity",
            quoteMethod: "floating_twap_quote",
            counterpartyClass: "crown_liquidity_facility",
            crownIsCounterparty: true,
            expiresUtc: DateTime.UtcNow.AddMinutes(5),
            spreadBasisPoints: 25,
            feeBaseUnits: 0,
            maxSlippageBasisPoints: 50,
            liquidityLimitBaseUnits: 10_000);

        Assert.True(quote.Succeeded, quote.Message);
        Assert.True(File.Exists(quote.QuotePath));
        Assert.False(string.IsNullOrWhiteSpace(quote.QuoteSha256));

        var record = PassportTestWorkspace.ReadJson(quote.QuotePath);
        Assert.Equal("passport_arch_cc_conversion_quote", PassportTestWorkspace.GetString(record, "record_type"));
        Assert.Equal(PassportMonetaryLedgerService.AssetArch, PassportTestWorkspace.GetString(record, "source_asset_code"));
        Assert.Equal(PassportMonetaryLedgerService.AssetCrownCredit, PassportTestWorkspace.GetString(record, "destination_asset_code"));
        Assert.Equal("crown_reference_twap", PassportTestWorkspace.GetString(record, "rate_source"));
        Assert.True(record.GetProperty("crown_is_counterparty").GetBoolean());
        Assert.False(record.GetProperty("guaranteed_conversion").GetBoolean());
        Assert.False(record.GetProperty("fixed_parity").GetBoolean());
        Assert.False(record.GetProperty("stable_value_claim").GetBoolean());

        var validation = service.ValidateQuoteForExecution(workspace.Root, quote.QuotePath, quote.QuoteSha256);
        Assert.True(validation.Succeeded, validation.Message);
    }

    [Fact]
    public void ValidateQuoteForExecutionRejectsExpiredQuotes()
    {
        using var workspace = PassportTestWorkspace.Create();
        var service = new PassportConversionQuoteService(PassportReleaseLane.CreateDefault("staging"));
        var quote = service.CreateQuote(
            workspace.Root,
            "account-test",
            workspace.IdentityId,
            "wallet-key-test",
            PassportMonetaryLedgerService.AssetArch,
            PassportMonetaryLedgerService.AssetCrownCredit,
            10,
            2_500,
            "crown_reference_twap",
            "qualified_internal_liquidity",
            "floating_twap_quote",
            "crown_liquidity_facility",
            true,
            DateTime.UtcNow.AddMinutes(5),
            25,
            0,
            50,
            10_000);
        Assert.True(quote.Succeeded, quote.Message);

        var json = File.ReadAllText(quote.QuotePath);
        json = json.Replace(
            DateTime.UtcNow.AddMinutes(5).ToString("yyyy-MM-ddTHH:mm:ssZ"),
            DateTime.UtcNow.AddMinutes(-1).ToString("yyyy-MM-ddTHH:mm:ssZ"));
        if (json.IndexOf(DateTime.UtcNow.AddMinutes(-1).ToString("yyyy-MM-ddTHH:mm:ssZ"), StringComparison.Ordinal) < 0)
        {
            var record = PassportTestWorkspace.ReadJson(quote.QuotePath);
            json = File.ReadAllText(quote.QuotePath).Replace(
                PassportTestWorkspace.GetString(record, "expires_utc"),
                DateTime.UtcNow.AddMinutes(-1).ToString("yyyy-MM-ddTHH:mm:ssZ"));
        }

        File.WriteAllText(quote.QuotePath, json);

        var validation = service.ValidateQuoteForExecution(workspace.Root, quote.QuotePath);

        Assert.False(validation.Succeeded);
        Assert.Contains("expired", validation.Message, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public void ValidateQuoteForExecutionRejectsGuaranteeClaims()
    {
        using var workspace = PassportTestWorkspace.Create();
        var service = new PassportConversionQuoteService(PassportReleaseLane.CreateDefault("staging"));
        var quote = service.CreateQuote(
            workspace.Root,
            "account-test",
            workspace.IdentityId,
            "wallet-key-test",
            PassportMonetaryLedgerService.AssetCrownCredit,
            PassportMonetaryLedgerService.AssetArch,
            2_500,
            10,
            "crown_reference_twap",
            "qualified_internal_liquidity",
            "floating_twap_quote",
            "crown_liquidity_facility",
            true,
            DateTime.UtcNow.AddMinutes(5),
            25,
            0,
            50,
            10_000);
        Assert.True(quote.Succeeded, quote.Message);

        var json = File.ReadAllText(quote.QuotePath).Replace("\"fixed_parity\": false", "\"fixed_parity\": true");
        File.WriteAllText(quote.QuotePath, json);

        var validation = service.ValidateQuoteForExecution(workspace.Root, quote.QuotePath);

        Assert.False(validation.Succeeded);
        Assert.Contains("prohibited", validation.Message, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public void ExecuteQuoteDebitsSourceAndCreditsDestinationLedgerBalances()
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
        var genesis = ledger.AppendEvent(
            workspace.Root,
            "account-test",
            workspace.IdentityId,
            wallet.WalletKeyId,
            PassportMonetaryLedgerService.EventArchGenesisAllocation,
            PassportMonetaryLedgerService.AssetArch,
            1_000,
            new System.Collections.Generic.Dictionary<string, string> { ["arch_genesis_hash"] = "genesis-test" },
            walletKeyReferencePath: wallet.WalletKeyReferencePath,
            walletPublicKeyPath: wallet.WalletPublicKeyPath);
        Assert.True(genesis.Succeeded, genesis.Message);

        var quote = new PassportConversionQuoteService(releaseLane).CreateQuote(
            workspace.Root,
            "account-test",
            workspace.IdentityId,
            wallet.WalletKeyId,
            PassportMonetaryLedgerService.AssetArch,
            PassportMonetaryLedgerService.AssetCrownCredit,
            100,
            2_500,
            "crown_reference_twap",
            "qualified_internal_liquidity",
            "floating_twap_quote",
            "crown_liquidity_facility",
            true,
            DateTime.UtcNow.AddMinutes(5),
            spreadBasisPoints: 25,
            feeBaseUnits: 0,
            maxSlippageBasisPoints: 50,
            liquidityLimitBaseUnits: 10_000);
        Assert.True(quote.Succeeded, quote.Message);

        var execution = new PassportConversionExecutionService(releaseLane).ExecuteQuote(
            workspace.Root,
            quote.QuotePath,
            quote.QuoteSha256,
            wallet.WalletKeyReferencePath,
            wallet.WalletPublicKeyPath);

        Assert.True(execution.Succeeded, execution.Message);
        Assert.True(File.Exists(execution.ExecutionRecordPath));
        Assert.True(File.Exists(execution.SourceLedgerEventPath));
        Assert.True(File.Exists(execution.DestinationLedgerEventPath));

        var replay = ledger.Replay(workspace.Root);
        Assert.True(replay.Succeeded, string.Join("; ", replay.Failures));
        var arch = replay.Balances.Single(balance => balance.AssetCode == PassportMonetaryLedgerService.AssetArch);
        var cc = replay.Balances.Single(balance => balance.AssetCode == PassportMonetaryLedgerService.AssetCrownCredit);
        Assert.Equal(900, arch.AvailableBaseUnits);
        Assert.Equal(2_500, cc.AvailableBaseUnits);

        var record = PassportTestWorkspace.ReadJson(execution.ExecutionRecordPath);
        Assert.Equal("passport_arch_cc_conversion_execution", PassportTestWorkspace.GetString(record, "record_type"));
        Assert.Equal("executed", PassportTestWorkspace.GetString(record, "execution_status"));
        Assert.True(record.TryGetProperty("wallet_signature", out _));
    }

    [Fact]
    public void ExecuteQuoteRejectsInsufficientSourceBalance()
    {
        using var workspace = PassportTestWorkspace.Create();
        var releaseLane = PassportReleaseLane.CreateDefault("production-mvp");
        var wallet = new PassportWalletKeyService(releaseLane).CreateAndBindWalletKey(
            workspace.Root,
            workspace.IdentityId,
            workspace.DeviceId,
            workspace.KeyReferencePath);
        Assert.True(wallet.Succeeded, wallet.Message);

        var quote = new PassportConversionQuoteService(releaseLane).CreateQuote(
            workspace.Root,
            "account-test",
            workspace.IdentityId,
            wallet.WalletKeyId,
            PassportMonetaryLedgerService.AssetArch,
            PassportMonetaryLedgerService.AssetCrownCredit,
            100,
            2_500,
            "crown_reference_twap",
            "qualified_internal_liquidity",
            "floating_twap_quote",
            "crown_liquidity_facility",
            true,
            DateTime.UtcNow.AddMinutes(5),
            25,
            0,
            50,
            10_000);
        Assert.True(quote.Succeeded, quote.Message);

        var execution = new PassportConversionExecutionService(releaseLane).ExecuteQuote(
            workspace.Root,
            quote.QuotePath,
            quote.QuoteSha256,
            wallet.WalletKeyReferencePath,
            wallet.WalletPublicKeyPath);

        Assert.False(execution.Succeeded);
        Assert.Contains("insufficient", execution.Message, StringComparison.OrdinalIgnoreCase);
    }
}
