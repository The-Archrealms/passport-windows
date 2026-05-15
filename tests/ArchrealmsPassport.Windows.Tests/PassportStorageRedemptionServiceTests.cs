using System;
using System.Collections.Generic;
using System.IO;
using System.Security.Cryptography;
using System.Text.Json;
using ArchrealmsPassport.Windows.Models;
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

        var proof = CreateAcceptedStorageProof(workspace, "mvp_storage");
        var proofHash = PassportTestWorkspace.ComputeFileSha256(proof.RecordPath);
        var burn = service.BurnVerifiedEpoch(
            workspace.Root,
            accepted.RecordPath,
            burnCcBaseUnits: 1,
            verifiedGbDays: 1,
            proofRecordPath: proof.RecordPath,
            proofRecordSha256: proofHash,
            walletKeyReferencePath: wallet.WalletKeyReferencePath,
            walletPublicKeyPath: wallet.WalletPublicKeyPath);
        Assert.True(burn.Succeeded, burn.Message);

        var refund = service.RefundRemaining(
            workspace.Root,
            accepted.RecordPath,
            refundCcBaseUnits: 99,
            reasonCode: "unused_or_failed_epochs",
            walletKeyReferencePath: wallet.WalletKeyReferencePath,
            walletPublicKeyPath: wallet.WalletPublicKeyPath);
        Assert.True(refund.Succeeded, refund.Message);

        var replay = ledger.Replay(workspace.Root);
        Assert.True(replay.Succeeded, string.Join("; ", replay.Failures));
        Assert.Contains(replay.Balances, balance =>
            balance.AssetCode == PassportMonetaryLedgerService.AssetCrownCredit
            && balance.AvailableBaseUnits == 199
            && balance.EscrowedBaseUnits == 0
            && balance.BurnedBaseUnits == 1);

        var burnRecord = PassportTestWorkspace.ReadJson(burn.RecordPath);
        Assert.Equal("passport_storage_redemption_epoch_burn", PassportTestWorkspace.GetString(burnRecord, "record_type"));
        Assert.Equal(proofHash, PassportTestWorkspace.GetString(burnRecord, "proof_record_sha256"));
        Assert.Equal(1, PassportTestWorkspace.GetInt64(burnRecord, "verified_gb_days"));
        Assert.True(burnRecord.TryGetProperty("proof_acceptance", out var proofAcceptance));
        Assert.True(proofAcceptance.GetProperty("accepted").GetBoolean());
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

        var proof = CreateAcceptedStorageProof(workspace, "mvp_storage");
        var burn = service.BurnVerifiedEpoch(
            workspace.Root,
            accepted.RecordPath,
            101,
            1,
            proof.RecordPath,
            PassportTestWorkspace.ComputeFileSha256(proof.RecordPath),
            wallet.WalletKeyReferencePath,
            wallet.WalletPublicKeyPath);

        Assert.False(burn.Succeeded);
        Assert.Contains("exceeds remaining escrow", burn.Message, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public void StorageRedemptionRejectsBurnWhenProofPackageIsIncomplete()
    {
        using var workspace = PassportTestWorkspace.Create();
        var releaseLane = PassportReleaseLane.CreateDefault("production-mvp");
        var wallet = new PassportWalletKeyService(releaseLane).CreateAndBindWalletKey(
            workspace.Root,
            workspace.IdentityId,
            workspace.DeviceId,
            workspace.KeyReferencePath);
        Assert.True(wallet.Succeeded, wallet.Message);
        var accepted = CreateAcceptedRedemption(workspace, releaseLane, wallet, 200, 100);

        var proofPath = workspace.WriteProofSource("incomplete-storage-proof.json", "{\"proof\":\"ok\"}");
        var burn = new PassportStorageRedemptionService(releaseLane).BurnVerifiedEpoch(
            workspace.Root,
            accepted.RecordPath,
            1,
            1,
            proofPath,
            PassportTestWorkspace.ComputeFileSha256(proofPath),
            wallet.WalletKeyReferencePath,
            wallet.WalletPublicKeyPath);

        Assert.False(burn.Succeeded);
        Assert.Contains("proof package rejected", burn.Message, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public void StorageRedemptionRequiresBurnToMatchAcceptedQuoteFormula()
    {
        using var workspace = PassportTestWorkspace.Create();
        var releaseLane = PassportReleaseLane.CreateDefault("production-mvp");
        var wallet = new PassportWalletKeyService(releaseLane).CreateAndBindWalletKey(
            workspace.Root,
            workspace.IdentityId,
            workspace.DeviceId,
            workspace.KeyReferencePath);
        Assert.True(wallet.Succeeded, wallet.Message);
        var accepted = CreateAcceptedRedemption(workspace, releaseLane, wallet, 200, 100);
        var proof = CreateAcceptedStorageProof(workspace, "mvp_storage");

        var burn = new PassportStorageRedemptionService(releaseLane).BurnVerifiedEpoch(
            workspace.Root,
            accepted.RecordPath,
            2,
            1,
            proof.RecordPath,
            PassportTestWorkspace.ComputeFileSha256(proof.RecordPath),
            wallet.WalletKeyReferencePath,
            wallet.WalletPublicKeyPath);

        Assert.False(burn.Succeeded);
        Assert.Contains("accepted quote rate", burn.Message, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public void AdminEscrowReleaseWorksUnderSecurityFreezeWithDualControlAuthority()
    {
        using var workspace = PassportTestWorkspace.Create();
        var releaseLane = PassportReleaseLane.CreateDefault("production-mvp");
        var wallet = new PassportWalletKeyService(releaseLane).CreateAndBindWalletKey(
            workspace.Root,
            workspace.IdentityId,
            workspace.DeviceId,
            workspace.KeyReferencePath);
        Assert.True(wallet.Succeeded, wallet.Message);
        var accepted = CreateAcceptedRedemption(workspace, releaseLane, wallet, 200, 100);
        var acceptedHash = PassportTestWorkspace.ComputeFileSha256(accepted.RecordPath);
        var intentHash = PassportStorageRedemptionService.ComputeEscrowReleaseIntentHash(
            releaseLane,
            "account-test",
            workspace.IdentityId,
            wallet.WalletKeyId,
            40,
            "service_failure",
            acceptedHash);
        var adminEvidence = CreateAdminAuthorityEvidence(
            workspace,
            releaseLane,
            "escrow_release",
            "storage_redemption_admin_release",
            "service_failure",
            accepted.RecordId,
            acceptedHash,
            intentHash);

        var freeze = new PassportRecoveryService(releaseLane).CreateAccountSecurityFreeze(
            workspace.Root,
            workspace.IdentityId,
            workspace.DeviceId,
            workspace.KeyReferencePath,
            "escrow_freeze",
            freezeWalletOperations: true,
            freezePendingEscrow: true,
            revokeAiSessions: true,
            pauseStorageNodeOperations: true);
        Assert.True(freeze.Succeeded, freeze.Message);

        var release = new PassportStorageRedemptionService(releaseLane).ReleaseEscrowByAdmin(
            workspace.Root,
            accepted.RecordPath,
            40,
            "service_failure",
            adminEvidence);

        Assert.True(release.Succeeded, release.Message);
        var record = PassportTestWorkspace.ReadJson(release.RecordPath);
        Assert.Equal("passport_storage_redemption_admin_escrow_release", PassportTestWorkspace.GetString(record, "record_type"));
        Assert.True(record.GetProperty("requires_dual_control").GetBoolean());
        Assert.False(record.GetProperty("ai_approved").GetBoolean());

        var ledgerEvent = PassportTestWorkspace.ReadJson(release.LedgerEventPath);
        Assert.Equal("dual_control_admin_authorized", PassportTestWorkspace.GetString(ledgerEvent, "signature_status"));

        var replay = new PassportMonetaryLedgerService(releaseLane).Replay(workspace.Root);
        Assert.True(replay.Succeeded, string.Join("; ", replay.Failures));
        Assert.Contains(replay.Balances, balance =>
            balance.AssetCode == PassportMonetaryLedgerService.AssetCrownCredit
            && balance.AvailableBaseUnits == 140
            && balance.EscrowedBaseUnits == 60);
    }

    [Fact]
    public void AdminBurnOverrideRequiresDualControlAuthority()
    {
        using var workspace = PassportTestWorkspace.Create();
        var releaseLane = PassportReleaseLane.CreateDefault("production-mvp");
        var wallet = new PassportWalletKeyService(releaseLane).CreateAndBindWalletKey(
            workspace.Root,
            workspace.IdentityId,
            workspace.DeviceId,
            workspace.KeyReferencePath);
        Assert.True(wallet.Succeeded, wallet.Message);
        var accepted = CreateAcceptedRedemption(workspace, releaseLane, wallet, 200, 100);
        var acceptedHash = PassportTestWorkspace.ComputeFileSha256(accepted.RecordPath);
        var proof = CreateAcceptedStorageProof(workspace, "mvp_storage");
        var proofHash = PassportTestWorkspace.ComputeFileSha256(proof.RecordPath);
        var intentHash = PassportStorageRedemptionService.ComputeBurnOverrideIntentHash(
            releaseLane,
            "account-test",
            workspace.IdentityId,
            wallet.WalletKeyId,
            1,
            1,
            "verified_service_delivery",
            acceptedHash,
            proofHash);
        var adminEvidence = CreateAdminAuthorityEvidence(
            workspace,
            releaseLane,
            "burn_override",
            "storage_redemption_admin_burn",
            "verified_service_delivery",
            accepted.RecordId,
            acceptedHash,
            intentHash);

        var burn = new PassportStorageRedemptionService(releaseLane).OverrideBurnByAdmin(
            workspace.Root,
            accepted.RecordPath,
            1,
            1,
            "verified_service_delivery",
            proof.RecordPath,
            proofHash,
            adminEvidence);

        Assert.True(burn.Succeeded, burn.Message);
        var record = PassportTestWorkspace.ReadJson(burn.RecordPath);
        Assert.Equal("passport_storage_redemption_admin_burn_override", PassportTestWorkspace.GetString(record, "record_type"));

        var ledgerEvent = PassportTestWorkspace.ReadJson(burn.LedgerEventPath);
        Assert.Equal("dual_control_admin_authorized", PassportTestWorkspace.GetString(ledgerEvent, "signature_status"));

        var replay = new PassportMonetaryLedgerService(releaseLane).Replay(workspace.Root);
        Assert.True(replay.Succeeded, string.Join("; ", replay.Failures));
        Assert.Contains(replay.Balances, balance =>
            balance.AssetCode == PassportMonetaryLedgerService.AssetCrownCredit
            && balance.AvailableBaseUnits == 100
            && balance.EscrowedBaseUnits == 99
            && balance.BurnedBaseUnits == 1);
    }

    private static PassportMeteringRecordResult CreateAcceptedStorageProof(PassportTestWorkspace workspace, string serviceClass)
    {
        var proofSource = workspace.WriteProofSource("storage-proof-" + Guid.NewGuid().ToString("N") + ".bin", "storage proof source content");
        var manifestSha256 = PassportTestWorkspace.ComputeFileSha256(proofSource);
        var proof = new PassportRecordService().CreateStorageEpochProof(
            workspace.Root,
            workspace.IdentityId,
            workspace.DeviceId,
            workspace.KeyReferencePath,
            "node-test",
            "assignment-test",
            "bafytestcontent",
            manifestSha256,
            serviceClass,
            proofSource);
        Assert.True(proof.Succeeded, proof.Message);
        return proof;
    }

    private static PassportStorageRedemptionResult CreateAcceptedRedemption(
        PassportTestWorkspace workspace,
        PassportReleaseLane releaseLane,
        ArchrealmsPassport.Windows.Models.PassportWalletKeyBindingResult wallet,
        long fundingCcBaseUnits,
        long escrowCcBaseUnits)
    {
        var ledger = new PassportMonetaryLedgerService(releaseLane);
        var funding = ledger.AppendEvent(
            workspace.Root,
            "account-test",
            workspace.IdentityId,
            wallet.WalletKeyId,
            PassportMonetaryLedgerService.EventCrownCreditTransferIn,
            PassportMonetaryLedgerService.AssetCrownCredit,
            fundingCcBaseUnits,
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
            storageGb: escrowCcBaseUnits,
            serviceEpochCount: 1,
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
        return accepted;
    }

    private static Dictionary<string, string> CreateAdminAuthorityEvidence(
        PassportTestWorkspace workspace,
        PassportReleaseLane releaseLane,
        string actionType,
        string authorityScope,
        string reasonCode,
        string targetRecordId,
        string targetHash,
        string intentHash)
    {
        var secondDeviceId = AddSecondActiveDevice(workspace);
        var admin = new PassportAdminAuthorityService(releaseLane).CreateDualControlAction(
            workspace.Root,
            workspace.IdentityId,
            workspace.DeviceId,
            workspace.KeyReferencePath,
            secondDeviceId,
            workspace.KeyReferencePath,
            actionType,
            authorityScope,
            reasonCode,
            targetRecordId,
            targetHash,
            intentHash);
        Assert.True(admin.Succeeded, admin.Message);
        return new Dictionary<string, string>
        {
            ["admin_authority_record_path"] = admin.RecordPath,
            ["admin_authority_record_sha256"] = PassportAdminAuthorityService.ComputeFileSha256(admin.RecordPath),
            ["admin_authority_requester_signature_path"] = admin.RequesterSignaturePath,
            ["admin_authority_approver_signature_path"] = admin.ApproverSignaturePath
        };
    }

    private static string AddSecondActiveDevice(PassportTestWorkspace workspace)
    {
        var secondDeviceId = workspace.DeviceId + "-second-" + Guid.NewGuid().ToString("N")[..6];
        var timestamp = DateTime.UtcNow.ToString("yyyyMMddTHHmmssZ");
        var createdUtc = DateTime.UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ");
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
            ["public_key_sha256"] = Convert.ToHexString(SHA256.HashData(workspace.PublicKeyBytes)).ToLowerInvariant(),
            ["authorized_scopes"] = new[] { "authenticate", "submit_registry_record", "publish_archive" },
            ["authorization_mode"] = "test-fixture",
            ["authorization_package_path"] = string.Empty,
            ["authorization_record_path"] = string.Empty,
            ["authorizer_device_id"] = workspace.DeviceId,
            ["expires_utc"] = string.Empty,
            ["revocation_record_id"] = string.Empty,
            ["attestation_refs"] = Array.Empty<string>()
        };
        File.WriteAllText(recordPath, JsonSerializer.Serialize(record, new JsonSerializerOptions { WriteIndented = true }));
        return secondDeviceId;
    }
}
