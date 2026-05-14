using System.IO;
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
    }
}
