using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Security.Cryptography;
using System.Text.Json;
using ArchrealmsPassport.Core.Protocol;
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

        var genesisAppend = service.AppendEvent(
            workspace.Root,
            accountId,
            workspace.IdentityId,
            walletKeyId,
            PassportMonetaryLedgerService.EventArchGenesisAllocation,
            PassportMonetaryLedgerService.AssetArch,
            1_000,
            new Dictionary<string, string> { ["arch_genesis_hash"] = "genesis-test" });
        AssertAppend(genesisAppend);

        var inspection = PassportRegistryRecordInspector.Inspect(File.ReadAllBytes(genesisAppend.EventPath), genesisAppend.EventPath);
        Assert.True(inspection.IsEnvelopeValid, string.Join("; ", inspection.ValidationFailures));

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
    public void AccountExportContainsInclusionProofsKeyHistoryAndVerifierMaterial()
    {
        using var workspace = PassportTestWorkspace.Create();
        var releaseLane = PassportReleaseLane.CreateDefault("staging");
        var wallet = new PassportWalletKeyService(releaseLane).CreateAndBindWalletKey(
            workspace.Root,
            workspace.IdentityId,
            workspace.DeviceId,
            workspace.KeyReferencePath);
        Assert.True(wallet.Succeeded, wallet.Message);

        var service = new PassportMonetaryLedgerService(releaseLane);
        var accountId = "account-" + workspace.IdentityId;
        AssertAppend(service.AppendEvent(
            workspace.Root,
            accountId,
            workspace.IdentityId,
            wallet.WalletKeyId,
            PassportMonetaryLedgerService.EventCrownCreditIssue,
            PassportMonetaryLedgerService.AssetCrownCredit,
            300,
            walletKeyReferencePath: wallet.WalletKeyReferencePath,
            walletPublicKeyPath: wallet.WalletPublicKeyPath));
        AssertAppend(service.AppendEvent(
            workspace.Root,
            accountId,
            workspace.IdentityId,
            wallet.WalletKeyId,
            PassportMonetaryLedgerService.EventCrownCreditEscrow,
            PassportMonetaryLedgerService.AssetCrownCredit,
            50,
            walletKeyReferencePath: wallet.WalletKeyReferencePath,
            walletPublicKeyPath: wallet.WalletPublicKeyPath));

        var export = service.CreateAccountExport(workspace.Root, accountId);

        Assert.True(export.Succeeded, export.Message);
        var manifest = PassportTestWorkspace.ReadJson(export.ManifestPath);
        var firstEvent = manifest.GetProperty("events").EnumerateArray().First();
        var proof = firstEvent.GetProperty("inclusion_proof");
        Assert.Equal("merkle_sha256_v1", PassportTestWorkspace.GetString(proof, "root_algorithm"));
        Assert.Equal(PassportTestWorkspace.GetString(manifest, "transparency_root_sha256"), PassportTestWorkspace.GetString(proof, "epoch_root_sha256"));
        Assert.Equal("Archrealms.LedgerVerifier", PassportTestWorkspace.GetString(manifest.GetProperty("verifier"), "tool_name"));

        var keyHistory = manifest.GetProperty("key_history").EnumerateArray().ToArray();
        Assert.Contains(keyHistory, item => PassportTestWorkspace.GetString(item, "material_type") == "wallet_key_history");
        Assert.Contains(keyHistory, item => PassportTestWorkspace.GetString(item, "material_type") == "wallet_public_key");
        Assert.DoesNotContain(keyHistory, item => PassportTestWorkspace.GetString(item, "export_path").Contains("records/passport/wallet/keys/", System.StringComparison.OrdinalIgnoreCase));

        var verification = service.VerifyAccountExport(export.ExportRoot);

        Assert.True(verification.Succeeded, string.Join("; ", verification.Failures));
        Assert.Equal(2, verification.EventCount);
        Assert.False(string.IsNullOrWhiteSpace(verification.ExportRootSha256));
    }

    [Fact]
    public void AccountExportVerifierRejectsTamperedEventFiles()
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

        var export = service.CreateAccountExport(workspace.Root, accountId);
        Assert.True(export.Succeeded, export.Message);
        var manifest = PassportTestWorkspace.ReadJson(export.ManifestPath);
        var exportedEventPath = Path.Combine(
            export.ExportRoot,
            PassportTestWorkspace.GetString(manifest.GetProperty("events").EnumerateArray().First(), "export_path")
                .Replace('/', Path.DirectorySeparatorChar));
        File.WriteAllText(exportedEventPath, File.ReadAllText(exportedEventPath).Replace("\"amount_base_units\": 300", "\"amount_base_units\": 301"));

        var verification = service.VerifyAccountExport(export.ExportRoot);

        Assert.False(verification.Succeeded);
        Assert.Contains(verification.Failures, failure => failure.Contains("hash", System.StringComparison.OrdinalIgnoreCase));
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
    public void ProductionLedgerRejectsWalletSignedCcRecreditWithoutAdminAuthority()
    {
        using var workspace = PassportTestWorkspace.Create();
        var releaseLane = PassportReleaseLane.CreateDefault("production-mvp");
        var wallet = new PassportWalletKeyService(releaseLane).CreateAndBindWalletKey(
            workspace.Root,
            workspace.IdentityId,
            workspace.DeviceId,
            workspace.KeyReferencePath);
        Assert.True(wallet.Succeeded, wallet.Message);

        var service = new PassportMonetaryLedgerService(releaseLane);
        var result = service.AppendEvent(
            workspace.Root,
            "account-test",
            workspace.IdentityId,
            wallet.WalletKeyId,
            PassportMonetaryLedgerService.EventCrownCreditRecredit,
            PassportMonetaryLedgerService.AssetCrownCredit,
            10,
            new Dictionary<string, string> { ["recredit_reason"] = "failed_service_epoch" },
            walletKeyReferencePath: wallet.WalletKeyReferencePath,
            walletPublicKeyPath: wallet.WalletPublicKeyPath);

        Assert.False(result.Succeeded);
        Assert.Contains("dual-control admin authority", result.Message, System.StringComparison.OrdinalIgnoreCase);
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
        var capacityEvidence = CreateProductionCcIssueEvidence(workspace, releaseLane, "account-test", wallet.WalletKeyId, 100, 500);
        var append = ledgerService.AppendEvent(
            workspace.Root,
            "account-test",
            workspace.IdentityId,
            wallet.WalletKeyId,
            PassportMonetaryLedgerService.EventCrownCreditIssue,
            PassportMonetaryLedgerService.AssetCrownCredit,
            100,
            capacityEvidence,
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
        var capacityEvidence = CreateProductionCcIssueEvidence(workspace, releaseLane, "account-test", wallet.WalletKeyId, 100, 500);
        var append = ledgerService.AppendEvent(
            workspace.Root,
            "account-test",
            workspace.IdentityId,
            wallet.WalletKeyId,
            PassportMonetaryLedgerService.EventCrownCreditIssue,
            PassportMonetaryLedgerService.AssetCrownCredit,
            100,
            capacityEvidence,
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

    [Fact]
    public void ProductionLedgerRejectsCcIssueWithoutCapacityEvidence()
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

        var append = new PassportMonetaryLedgerService(releaseLane).AppendEvent(
            workspace.Root,
            "account-test",
            workspace.IdentityId,
            wallet.WalletKeyId,
            PassportMonetaryLedgerService.EventCrownCreditIssue,
            PassportMonetaryLedgerService.AssetCrownCredit,
            100,
            walletKeyReferencePath: wallet.WalletKeyReferencePath,
            walletPublicKeyPath: wallet.WalletPublicKeyPath);

        Assert.False(append.Succeeded);
        Assert.Contains("capacity_report_path", append.Message, System.StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public void ProductionLedgerAcceptsArchGenesisAllocationWithManifestEvidence()
    {
        using var workspace = PassportTestWorkspace.Create();
        var releaseLane = PassportReleaseLane.CreateDefault("production-mvp");
        var wallet = new PassportWalletKeyService(releaseLane).CreateAndBindWalletKey(
            workspace.Root,
            workspace.IdentityId,
            workspace.DeviceId,
            workspace.KeyReferencePath);
        Assert.True(wallet.Succeeded, wallet.Message);

        var accountId = "account-test";
        var evidence = CreateArchGenesisEvidence(workspace.Root, releaseLane, accountId, workspace.IdentityId, wallet.WalletKeyId, 1_000);
        var service = new PassportMonetaryLedgerService(releaseLane);
        var append = service.AppendEvent(
            workspace.Root,
            accountId,
            workspace.IdentityId,
            wallet.WalletKeyId,
            PassportMonetaryLedgerService.EventArchGenesisAllocation,
            PassportMonetaryLedgerService.AssetArch,
            1_000,
            evidence,
            walletKeyReferencePath: wallet.WalletKeyReferencePath,
            walletPublicKeyPath: wallet.WalletPublicKeyPath);
        AssertAppend(append);

        var replay = service.Replay(workspace.Root);

        Assert.True(replay.Succeeded, string.Join("; ", replay.Failures));
        var arch = replay.Balances.Single(balance => balance.AssetCode == PassportMonetaryLedgerService.AssetArch);
        Assert.Equal(1_000, arch.AvailableBaseUnits);
    }

    [Fact]
    public void ProductionLedgerRejectsArchGenesisAllocationWithoutManifestEvidence()
    {
        using var workspace = PassportTestWorkspace.Create();
        var releaseLane = PassportReleaseLane.CreateDefault("production-mvp");
        var wallet = new PassportWalletKeyService(releaseLane).CreateAndBindWalletKey(
            workspace.Root,
            workspace.IdentityId,
            workspace.DeviceId,
            workspace.KeyReferencePath);
        Assert.True(wallet.Succeeded, wallet.Message);

        var append = new PassportMonetaryLedgerService(releaseLane).AppendEvent(
            workspace.Root,
            "account-test",
            workspace.IdentityId,
            wallet.WalletKeyId,
            PassportMonetaryLedgerService.EventArchGenesisAllocation,
            PassportMonetaryLedgerService.AssetArch,
            1_000,
            new Dictionary<string, string>(),
            walletKeyReferencePath: wallet.WalletKeyReferencePath,
            walletPublicKeyPath: wallet.WalletPublicKeyPath);

        Assert.False(append.Succeeded);
        Assert.Contains("arch_genesis_manifest_path", append.Message, System.StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public void ProductionLedgerRejectsCcIssueWithoutIssuerAuthorityEvidence()
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

        var capacityEvidence = CreateCapacityEvidence(workspace.Root, releaseLane, 500);
        var append = new PassportMonetaryLedgerService(releaseLane).AppendEvent(
            workspace.Root,
            "account-test",
            workspace.IdentityId,
            wallet.WalletKeyId,
            PassportMonetaryLedgerService.EventCrownCreditIssue,
            PassportMonetaryLedgerService.AssetCrownCredit,
            100,
            capacityEvidence,
            walletKeyReferencePath: wallet.WalletKeyReferencePath,
            walletPublicKeyPath: wallet.WalletPublicKeyPath);

        Assert.False(append.Succeeded);
        Assert.Contains("admin_authority_record_path", append.Message, System.StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public void ProductionLedgerRejectsCcIssueAboveConservativeCapacityEvidence()
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

        var capacityEvidence = CreateCapacityEvidence(workspace.Root, releaseLane, 50);
        var append = new PassportMonetaryLedgerService(releaseLane).AppendEvent(
            workspace.Root,
            "account-test",
            workspace.IdentityId,
            wallet.WalletKeyId,
            PassportMonetaryLedgerService.EventCrownCreditIssue,
            PassportMonetaryLedgerService.AssetCrownCredit,
            100,
            capacityEvidence,
            walletKeyReferencePath: wallet.WalletKeyReferencePath,
            walletPublicKeyPath: wallet.WalletPublicKeyPath);

        Assert.False(append.Succeeded);
        Assert.Contains("exceeds", append.Message, System.StringComparison.OrdinalIgnoreCase);
    }

    private static void AssertAppend(PassportMonetaryLedgerAppendResult result)
    {
        Assert.True(result.Succeeded, result.Message);
        Assert.True(File.Exists(result.EventPath), result.EventPath);
        Assert.False(string.IsNullOrWhiteSpace(result.EventHashSha256));
    }

    private static Dictionary<string, string> CreateCapacityEvidence(string workspaceRoot, PassportReleaseLane releaseLane, long maxIssuanceBaseUnits)
    {
        var capacity = new PassportCrownCreditCapacityService(releaseLane).CreateCapacityReport(
            workspaceRoot,
            "storage",
            conservativeServiceLiabilityCapacityBaseUnits: 1_000,
            outstandingCrownCreditBeforeBaseUnits: 0,
            maxIssuanceBaseUnits: maxIssuanceBaseUnits,
            capacityHaircutBasisPoints: 6500,
            independentVolumeQualified: true,
            thinMarketIssuanceZero: false,
            continuityReserveExcluded: true,
            operationalReserveExcluded: true);
        Assert.True(capacity.Succeeded, capacity.Message);
        return new Dictionary<string, string>
        {
            ["capacity_report_path"] = capacity.ReportPath,
            ["capacity_report_sha256"] = capacity.ReportSha256
        };
    }

    private static Dictionary<string, string> CreateArchGenesisEvidence(
        string workspaceRoot,
        PassportReleaseLane releaseLane,
        string accountId,
        string identityId,
        string walletKeyId,
        long amountBaseUnits)
    {
        var allocationId = "arch-genesis-allocation-test";
        var manifest = new PassportArchGenesisService(releaseLane).CreateGenesisManifest(
            workspaceRoot,
            totalSupplyBaseUnits: amountBaseUnits,
            baseUnitPrecision: 18,
            new[]
            {
                new PassportArchGenesisAllocation
                {
                    AllocationId = allocationId,
                    AccountId = accountId,
                    IdentityId = identityId,
                    WalletKeyId = walletKeyId,
                    AmountBaseUnits = amountBaseUnits
                }
            });
        Assert.True(manifest.Succeeded, manifest.Message);
        return new Dictionary<string, string>
        {
            ["arch_genesis_manifest_path"] = manifest.ManifestPath,
            ["arch_genesis_manifest_sha256"] = manifest.ManifestSha256,
            ["arch_genesis_allocation_id"] = allocationId
        };
    }

    private static Dictionary<string, string> CreateProductionCcIssueEvidence(
        PassportTestWorkspace workspace,
        PassportReleaseLane releaseLane,
        string accountId,
        string walletKeyId,
        long amountBaseUnits,
        long maxIssuanceBaseUnits)
    {
        var evidence = CreateCapacityEvidence(workspace.Root, releaseLane, maxIssuanceBaseUnits);
        var secondDeviceId = AddSecondActiveDevice(workspace);
        if (releaseLane.ProductionLedger)
        {
            releaseLane.CrownAuthorityIdentityId = workspace.IdentityId;
        }

        var adminService = new PassportAdminAuthorityService(releaseLane);
        EnsureProductionAdminRoles(workspace, adminService, releaseLane, secondDeviceId, "cc_issue", "mvp_cc_issuance");
        var intentHash = PassportMonetaryLedgerService.ComputeCrownCreditIssueIntentHash(
            releaseLane,
            accountId,
            workspace.IdentityId,
            walletKeyId,
            amountBaseUnits,
            evidence);
        var adminAuthority = adminService.CreateDualControlAction(
            workspace.Root,
            workspace.IdentityId,
            workspace.DeviceId,
            workspace.KeyReferencePath,
            secondDeviceId,
            workspace.KeyReferencePath,
            "cc_issue",
            "mvp_cc_issuance",
            "capacity_authorized",
            "capacity-report",
            evidence["capacity_report_sha256"],
            intentHash);
        Assert.True(adminAuthority.Succeeded, adminAuthority.Message);

        evidence["admin_authority_record_path"] = adminAuthority.RecordPath;
        evidence["admin_authority_record_sha256"] = PassportAdminAuthorityService.ComputeFileSha256(adminAuthority.RecordPath);
        evidence["admin_authority_requester_signature_path"] = adminAuthority.RequesterSignaturePath;
        evidence["admin_authority_approver_signature_path"] = adminAuthority.ApproverSignaturePath;
        return evidence;
    }

    private static string AddSecondActiveDevice(PassportTestWorkspace workspace)
    {
        var secondDeviceId = workspace.DeviceId + "-second";
        var timestamp = System.DateTime.UtcNow.ToString("yyyyMMddTHHmmssZ");
        var createdUtc = System.DateTime.UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ");
        var secondPublicKeyPath = Path.Combine(workspace.Root, "records", "registry", "public-keys", secondDeviceId + ".spki.der");
        File.Copy(workspace.PublicKeyPath, secondPublicKeyPath, true);
        var recordPath = Path.Combine(workspace.Root, "records", "registry", "device-credentials", timestamp + "-" + secondDeviceId + ".json");
        var record = new Dictionary<string, object?>
        {
            ["schema_version"] = 1,
            ["record_type"] = "device_credential_record",
            ["record_id"] = timestamp + "-" + secondDeviceId,
            ["created_utc"] = createdUtc,
            ["effective_utc"] = createdUtc,
            ["status"] = "active",
            ["archrealms_identity_id"] = workspace.IdentityId,
            ["device_id"] = secondDeviceId,
            ["device_label"] = "Second Test Device",
            ["device_class"] = "desktop",
            ["client_platform"] = "windows",
            ["credential_origin"] = "test-fixture",
            ["public_key_algorithm"] = "RSA",
            ["public_key_format"] = "SPKI_DER",
            ["public_key_path"] = "records/registry/public-keys/" + secondDeviceId + ".spki.der",
            ["public_key_sha256"] = System.Convert.ToHexString(SHA256.HashData(workspace.PublicKeyBytes)).ToLowerInvariant(),
            ["authorized_scopes"] = new[] { "authenticate", "submit_registry_record", "publish_archive" },
            ["authorization_mode"] = "test-fixture",
            ["authorization_package_path"] = string.Empty,
            ["authorization_record_path"] = string.Empty,
            ["authorizer_device_id"] = workspace.DeviceId,
            ["expires_utc"] = string.Empty,
            ["revocation_record_id"] = string.Empty,
            ["attestation_refs"] = System.Array.Empty<string>()
        };
        File.WriteAllText(recordPath, JsonSerializer.Serialize(record, new JsonSerializerOptions { WriteIndented = true }));
        return secondDeviceId;
    }

    private static void EnsureProductionAdminRoles(
        PassportTestWorkspace workspace,
        PassportAdminAuthorityService service,
        PassportReleaseLane releaseLane,
        string secondDeviceId,
        string actionType,
        string authorityScope)
    {
        if (!releaseLane.ProductionLedger)
        {
            return;
        }

        var requesterRole = service.CreateRoleMembership(
            workspace.Root,
            workspace.IdentityId,
            workspace.DeviceId,
            workspace.KeyReferencePath,
            workspace.DeviceId,
            "crown_admin",
            new[] { actionType },
            new[] { authorityScope },
            "test_role_bootstrap");
        var approverRole = service.CreateRoleMembership(
            workspace.Root,
            workspace.IdentityId,
            workspace.DeviceId,
            workspace.KeyReferencePath,
            secondDeviceId,
            "crown_admin",
            new[] { actionType },
            new[] { authorityScope },
            "test_role_bootstrap");
        Assert.True(requesterRole.Succeeded, requesterRole.Message);
        Assert.True(approverRole.Succeeded, approverRole.Message);
    }
}
