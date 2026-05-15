using System.IO;
using System;
using System.Collections.Generic;
using System.Security.Cryptography;
using System.Text.Json;
using ArchrealmsPassport.Windows.Services;
using ArchrealmsPassport.Windows.Tests.Infrastructure;
using Xunit;

namespace ArchrealmsPassport.Windows.Tests;

public sealed class PassportRecoveryServiceTests
{
    [Fact]
    public void DeviceDeauthorizationWritesSignedRecordAndBlocksFutureWalletBinding()
    {
        using var workspace = PassportTestWorkspace.Create();
        var releaseLane = PassportReleaseLane.CreateDefault("staging");
        var recovery = new PassportRecoveryService(releaseLane);

        var deauthorization = recovery.CreateDeviceDeauthorization(
            workspace.Root,
            workspace.IdentityId,
            workspace.DeviceId,
            workspace.KeyReferencePath,
            workspace.DeviceId,
            "device_loss");

        Assert.True(deauthorization.Succeeded, deauthorization.Message);
        Assert.Equal("passport_device_deauthorization", deauthorization.RecordType);
        Assert.True(deauthorization.VerifiedWithDeviceKey);
        Assert.True(File.Exists(deauthorization.RecordPath));
        Assert.True(File.Exists(deauthorization.SignaturePath));
        Assert.True(recovery.IsDeviceDeauthorized(workspace.Root, workspace.IdentityId, workspace.DeviceId));

        var record = PassportTestWorkspace.ReadJson(deauthorization.RecordPath);
        Assert.Equal("device_loss", PassportTestWorkspace.GetString(record, "reason_code"));
        Assert.False(record.GetProperty("ai_approved").GetBoolean());

        var wallet = new PassportWalletKeyService(releaseLane).CreateAndBindWalletKey(
            workspace.Root,
            workspace.IdentityId,
            workspace.DeviceId,
            workspace.KeyReferencePath);

        Assert.False(wallet.Succeeded);
        Assert.Contains("deauthorized", wallet.Message, System.StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public void AccountSecurityFreezeRecordsRecoveryAndEscrowFreezeScope()
    {
        using var workspace = PassportTestWorkspace.Create();
        var recovery = new PassportRecoveryService(PassportReleaseLane.CreateDefault("staging"));

        var freeze = recovery.CreateAccountSecurityFreeze(
            workspace.Root,
            workspace.IdentityId,
            workspace.DeviceId,
            workspace.KeyReferencePath,
            "identity_compromise",
            freezeWalletOperations: true,
            freezePendingEscrow: true,
            revokeAiSessions: true,
            pauseStorageNodeOperations: true);

        Assert.True(freeze.Succeeded, freeze.Message);
        Assert.Equal("passport_account_security_freeze", freeze.RecordType);
        Assert.True(freeze.VerifiedWithDeviceKey);
        Assert.True(File.Exists(freeze.RecordPath));
        Assert.True(File.Exists(freeze.SignaturePath));

        var record = PassportTestWorkspace.ReadJson(freeze.RecordPath);
        Assert.Equal("identity_compromise", PassportTestWorkspace.GetString(record, "reason_code"));
        Assert.True(record.GetProperty("freeze_wallet_operations").GetBoolean());
        Assert.True(record.GetProperty("freeze_pending_escrow").GetBoolean());
        Assert.True(record.GetProperty("revoke_ai_sessions").GetBoolean());
        Assert.True(record.GetProperty("pause_storage_node_operations").GetBoolean());
        Assert.False(record.GetProperty("ai_approved").GetBoolean());
        Assert.True(recovery.IsWalletOperationsFrozen(workspace.Root, workspace.IdentityId));
        Assert.True(recovery.IsPendingEscrowFrozen(workspace.Root, workspace.IdentityId));
        Assert.True(recovery.AreAiSessionsRevoked(workspace.Root, workspace.IdentityId));
        Assert.True(recovery.AreStorageNodeOperationsPaused(workspace.Root, workspace.IdentityId));
    }

    [Fact]
    public void RecoveryGuidanceExportDefinesBackupAndAuthorityBoundaries()
    {
        using var workspace = PassportTestWorkspace.Create();
        var recovery = new PassportRecoveryService(PassportReleaseLane.CreateDefault("staging"));

        var guidance = recovery.CreateRecoveryGuidanceExport(workspace.Root, workspace.IdentityId);

        Assert.True(guidance.Succeeded, guidance.Message);
        Assert.Equal("passport_recovery_guidance_export", guidance.RecordType);
        Assert.True(File.Exists(guidance.RecordPath));

        var record = PassportTestWorkspace.ReadJson(guidance.RecordPath);
        Assert.Equal("passport_recovery_guidance_export", PassportTestWorkspace.GetString(record, "record_type"));
        Assert.Contains("cannot approve recovery", PassportTestWorkspace.GetString(record, "ai_authority"), StringComparison.OrdinalIgnoreCase);
        Assert.Contains("separate records", PassportTestWorkspace.GetString(record, "citizenship_asset_boundary"), StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public void SupportMediatedRecoveryOverrideRequiresDualControlAuthority()
    {
        using var workspace = PassportTestWorkspace.Create();
        var releaseLane = PassportReleaseLane.CreateDefault("staging");
        var secondDeviceId = AddSecondActiveDevice(workspace);
        var targetHash = new string('a', 64);
        var payloadHash = new string('b', 64);
        var admin = new PassportAdminAuthorityService(releaseLane).CreateDualControlAction(
            workspace.Root,
            workspace.IdentityId,
            workspace.DeviceId,
            workspace.KeyReferencePath,
            secondDeviceId,
            workspace.KeyReferencePath,
            "recovery_override",
            "support_mediated_recovery",
            "identity_compromise",
            "recovery-target-test",
            targetHash,
            payloadHash);
        Assert.True(admin.Succeeded, admin.Message);

        var recovery = new PassportRecoveryService(releaseLane).CreateSupportMediatedRecoveryOverride(
            workspace.Root,
            workspace.IdentityId,
            workspace.IdentityId,
            "account-test",
            "identity_compromise",
            "recovery-target-test",
            targetHash,
            payloadHash,
            new Dictionary<string, string>
            {
                ["admin_authority_record_path"] = admin.RecordPath,
                ["admin_authority_record_sha256"] = PassportAdminAuthorityService.ComputeFileSha256(admin.RecordPath),
                ["admin_authority_requester_signature_path"] = admin.RequesterSignaturePath,
                ["admin_authority_approver_signature_path"] = admin.ApproverSignaturePath
            });

        Assert.True(recovery.Succeeded, recovery.Message);
        Assert.Equal("passport_support_mediated_recovery_override", recovery.RecordType);
        var record = PassportTestWorkspace.ReadJson(recovery.RecordPath);
        Assert.True(record.GetProperty("requires_dual_control").GetBoolean());
        Assert.False(record.GetProperty("ai_approved").GetBoolean());
    }

    [Fact]
    public void AccountSecurityFreezeBlocksWalletSignedLedgerOperations()
    {
        using var workspace = PassportTestWorkspace.Create();
        var releaseLane = PassportReleaseLane.CreateDefault("production-mvp");
        var wallet = new PassportWalletKeyService(releaseLane).CreateAndBindWalletKey(
            workspace.Root,
            workspace.IdentityId,
            workspace.DeviceId,
            workspace.KeyReferencePath);
        Assert.True(wallet.Succeeded, wallet.Message);

        var freeze = new PassportRecoveryService(releaseLane).CreateAccountSecurityFreeze(
            workspace.Root,
            workspace.IdentityId,
            workspace.DeviceId,
            workspace.KeyReferencePath,
            "identity_compromise",
            freezeWalletOperations: true,
            freezePendingEscrow: true,
            revokeAiSessions: true,
            pauseStorageNodeOperations: true);
        Assert.True(freeze.Succeeded, freeze.Message);

        var append = new PassportMonetaryLedgerService(releaseLane).AppendEvent(
            workspace.Root,
            "account-test",
            workspace.IdentityId,
            wallet.WalletKeyId,
            PassportMonetaryLedgerService.EventCrownCreditTransferIn,
            PassportMonetaryLedgerService.AssetCrownCredit,
            100,
            new Dictionary<string, string> { ["funding_source"] = "blocked-after-freeze" },
            walletKeyReferencePath: wallet.WalletKeyReferencePath,
            walletPublicKeyPath: wallet.WalletPublicKeyPath);

        Assert.False(append.Succeeded);
        Assert.Contains("frozen", append.Message, StringComparison.OrdinalIgnoreCase);
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
}
