using System;
using System.Collections.Generic;
using System.IO;
using System.Security.Cryptography;
using System.Text.Json;
using ArchrealmsPassport.Windows.Services;
using ArchrealmsPassport.Windows.Tests.Infrastructure;
using Xunit;

namespace ArchrealmsPassport.Windows.Tests;

public sealed class PassportLedgerCorrectionServiceTests
{
    [Fact]
    public void ExecuteCorrectionAppendsNewBalancingLedgerEvent()
    {
        using var workspace = PassportTestWorkspace.Create();
        var releaseLane = PassportReleaseLane.CreateDefault("production-mvp");
        var wallet = new PassportWalletKeyService(releaseLane).CreateAndBindWalletKey(
            workspace.Root,
            workspace.IdentityId,
            workspace.DeviceId,
            workspace.KeyReferencePath);
        Assert.True(wallet.Succeeded, wallet.Message);

        var targetEventId = "target-event-test";
        var targetHash = new string('a', 64);
        var intentHash = PassportLedgerCorrectionService.ComputeCorrectionIntentHash(
            releaseLane,
            "account-test",
            workspace.IdentityId,
            wallet.WalletKeyId,
            PassportMonetaryLedgerService.AssetCrownCredit,
            25,
            "credit",
            "operator_error",
            targetEventId,
            targetHash);
        var admin = CreateAdminAuthorityEvidence(
            workspace,
            releaseLane,
            "ledger_correction",
            "mvp_ledger_correction",
            "operator_error",
            targetEventId,
            targetHash,
            intentHash);

        var correction = new PassportLedgerCorrectionService(releaseLane).ExecuteCorrection(
            workspace.Root,
            "account-test",
            workspace.IdentityId,
            wallet.WalletKeyId,
            PassportMonetaryLedgerService.AssetCrownCredit,
            25,
            "credit",
            "operator_error",
            targetEventId,
            targetHash,
            admin,
            wallet.WalletKeyReferencePath,
            wallet.WalletPublicKeyPath);

        Assert.True(correction.Succeeded, correction.Message);
        Assert.True(File.Exists(correction.CorrectionRecordPath));
        Assert.True(File.Exists(correction.LedgerEventPath));

        var replay = new PassportMonetaryLedgerService(releaseLane).Replay(workspace.Root);
        Assert.True(replay.Succeeded, string.Join("; ", replay.Failures));
        Assert.Contains(replay.Balances, balance =>
            balance.AssetCode == PassportMonetaryLedgerService.AssetCrownCredit
            && balance.AvailableBaseUnits == 25);

        var record = PassportTestWorkspace.ReadJson(correction.CorrectionRecordPath);
        Assert.Equal("passport_monetary_ledger_correction", PassportTestWorkspace.GetString(record, "record_type"));
        Assert.True(record.GetProperty("correction_is_new_event_only").GetBoolean());
        Assert.True(record.TryGetProperty("wallet_signature", out _));
    }

    [Fact]
    public void ExecuteCorrectionRequiresDualControlAuthorityEvidence()
    {
        using var workspace = PassportTestWorkspace.Create();
        var releaseLane = PassportReleaseLane.CreateDefault("production-mvp");
        var wallet = new PassportWalletKeyService(releaseLane).CreateAndBindWalletKey(
            workspace.Root,
            workspace.IdentityId,
            workspace.DeviceId,
            workspace.KeyReferencePath);
        Assert.True(wallet.Succeeded, wallet.Message);

        var correction = new PassportLedgerCorrectionService(releaseLane).ExecuteCorrection(
            workspace.Root,
            "account-test",
            workspace.IdentityId,
            wallet.WalletKeyId,
            PassportMonetaryLedgerService.AssetCrownCredit,
            25,
            "credit",
            "operator_error",
            "target-event-test",
            new string('a', 64),
            new Dictionary<string, string>(),
            wallet.WalletKeyReferencePath,
            wallet.WalletPublicKeyPath);

        Assert.False(correction.Succeeded);
        Assert.Contains("admin_authority_record_path", correction.Message, StringComparison.OrdinalIgnoreCase);
    }

    private static Dictionary<string, string> CreateAdminAuthorityEvidence(
        PassportTestWorkspace workspace,
        PassportReleaseLane releaseLane,
        string actionType,
        string authorityScope,
        string reasonCode,
        string targetRecordId,
        string targetRecordSha256,
        string requestedPayloadSha256)
    {
        var secondDeviceId = AddSecondActiveDevice(workspace);
        if (releaseLane.ProductionLedger)
        {
            releaseLane.CrownAuthorityIdentityId = workspace.IdentityId;
        }

        var service = new PassportAdminAuthorityService(releaseLane);
        EnsureProductionAdminRoles(workspace, service, releaseLane, secondDeviceId, actionType, authorityScope);
        var admin = service.CreateDualControlAction(
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
            targetRecordSha256,
            requestedPayloadSha256);
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
        var secondDeviceId = workspace.DeviceId + "-second";
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
