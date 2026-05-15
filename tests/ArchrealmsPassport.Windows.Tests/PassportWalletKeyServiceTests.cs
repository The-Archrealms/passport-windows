using System.IO;
using System.Text;
using ArchrealmsPassport.Windows.Services;
using ArchrealmsPassport.Windows.Tests.Infrastructure;
using Xunit;

namespace ArchrealmsPassport.Windows.Tests;

public sealed class PassportWalletKeyServiceTests
{
    [Fact]
    public void CreateAndBindWalletKeyWritesSignedIdentityAuthorization()
    {
        using var workspace = PassportTestWorkspace.Create();
        var service = new PassportWalletKeyService(PassportReleaseLane.CreateDefault("staging"));

        var result = service.CreateAndBindWalletKey(
            workspace.Root,
            workspace.IdentityId,
            workspace.DeviceId,
            workspace.KeyReferencePath);

        Assert.True(result.Succeeded, result.Message);
        Assert.NotEqual(workspace.DeviceId, result.WalletKeyId);
        Assert.True(result.VerifiedWithDeviceKey);
        Assert.True(File.Exists(result.WalletKeyReferencePath));
        Assert.True(File.Exists(result.WalletPublicKeyPath));
        Assert.True(File.Exists(result.BindingRecordPath));
        Assert.True(File.Exists(result.BindingSignaturePath));

        var binding = PassportTestWorkspace.ReadJson(result.BindingRecordPath);
        var signature = PassportTestWorkspace.ReadJson(result.BindingSignaturePath);

        Assert.Equal("passport_wallet_key_binding", PassportTestWorkspace.GetString(binding, "record_type"));
        Assert.Equal(workspace.IdentityId, PassportTestWorkspace.GetString(binding, "archrealms_identity_id"));
        Assert.Equal(result.WalletKeyId, PassportTestWorkspace.GetString(binding, "wallet_key_id"));
        Assert.Equal("passport_wallet_key_binding_signature", PassportTestWorkspace.GetString(signature, "record_type"));
        Assert.Equal("true", signature.GetProperty("verified_with_device_key").GetBoolean().ToString().ToLowerInvariant());
    }

    [Fact]
    public void WalletKeySignsPayloadWithoutUsingIdentityKey()
    {
        using var workspace = PassportTestWorkspace.Create();
        var service = new PassportWalletKeyService(PassportReleaseLane.CreateDefault("staging"));
        var binding = service.CreateAndBindWalletKey(
            workspace.Root,
            workspace.IdentityId,
            workspace.DeviceId,
            workspace.KeyReferencePath);
        Assert.True(binding.Succeeded, binding.Message);

        var signature = service.SignWalletPayload(
            binding.WalletKeyReferencePath,
            binding.WalletPublicKeyPath,
            Encoding.UTF8.GetBytes("wallet operation payload"));

        Assert.True(signature.Succeeded, signature.Message);
        Assert.True(signature.VerifiedWithWalletKey);
        Assert.False(string.IsNullOrWhiteSpace(signature.SignatureBase64));
        Assert.False(string.IsNullOrWhiteSpace(signature.PayloadSha256));
    }

    [Fact]
    public void RevokeWalletKeyWritesSignedRevocationAndMarksKeyInactive()
    {
        using var workspace = PassportTestWorkspace.Create();
        var service = new PassportWalletKeyService(PassportReleaseLane.CreateDefault("staging"));
        var binding = service.CreateAndBindWalletKey(
            workspace.Root,
            workspace.IdentityId,
            workspace.DeviceId,
            workspace.KeyReferencePath);
        Assert.True(binding.Succeeded, binding.Message);
        Assert.True(service.IsWalletKeyActive(workspace.Root, workspace.IdentityId, binding.WalletKeyId));

        var revocation = service.RevokeWalletKey(
            workspace.Root,
            workspace.IdentityId,
            workspace.DeviceId,
            workspace.KeyReferencePath,
            binding.WalletKeyId,
            "wallet_compromise",
            true);

        Assert.True(revocation.Succeeded, revocation.Message);
        Assert.True(revocation.VerifiedWithDeviceKey);
        Assert.True(File.Exists(revocation.RevocationRecordPath));
        Assert.True(File.Exists(revocation.RevocationSignaturePath));
        Assert.False(service.IsWalletKeyActive(workspace.Root, workspace.IdentityId, binding.WalletKeyId));

        var record = PassportTestWorkspace.ReadJson(revocation.RevocationRecordPath);
        Assert.Equal("passport_wallet_key_revocation", PassportTestWorkspace.GetString(record, "record_type"));
        Assert.Equal("wallet_compromise", PassportTestWorkspace.GetString(record, "reason_code"));
        Assert.True(record.GetProperty("freeze_pending_escrow").GetBoolean());
        Assert.False(record.GetProperty("ai_approved").GetBoolean());
    }

    [Fact]
    public void WalletBindingPolicyFailurePreventsActiveWalletUse()
    {
        using var workspace = PassportTestWorkspace.Create();
        var service = new PassportWalletKeyService(PassportReleaseLane.CreateDefault("staging"));
        var binding = service.CreateAndBindWalletKey(
            workspace.Root,
            workspace.IdentityId,
            workspace.DeviceId,
            workspace.KeyReferencePath);
        Assert.True(binding.Succeeded, binding.Message);

        var bindingJson = File.ReadAllText(binding.BindingRecordPath);
        File.WriteAllText(
            binding.BindingRecordPath,
            bindingJson.Replace("\"sign_cc_operations\"", "\"sign_cc_operations\", \"alter_identity\""),
            Encoding.UTF8);

        Assert.False(service.IsWalletKeyActive(workspace.Root, workspace.IdentityId, binding.WalletKeyId));
    }

    [Fact]
    public void RotateWalletKeyRevokesOldKeyAndBindsNewKey()
    {
        using var workspace = PassportTestWorkspace.Create();
        var service = new PassportWalletKeyService(PassportReleaseLane.CreateDefault("staging"));
        var binding = service.CreateAndBindWalletKey(
            workspace.Root,
            workspace.IdentityId,
            workspace.DeviceId,
            workspace.KeyReferencePath);
        Assert.True(binding.Succeeded, binding.Message);

        var rotation = service.RotateWalletKey(
            workspace.Root,
            workspace.IdentityId,
            workspace.DeviceId,
            workspace.KeyReferencePath,
            binding.WalletKeyId,
            true);

        Assert.True(rotation.Succeeded, rotation.Message);
        Assert.Equal(binding.WalletKeyId, rotation.Revocation.WalletKeyId);
        Assert.NotEqual(binding.WalletKeyId, rotation.Binding.WalletKeyId);
        Assert.False(service.IsWalletKeyActive(workspace.Root, workspace.IdentityId, binding.WalletKeyId));
        Assert.True(service.IsWalletKeyActive(workspace.Root, workspace.IdentityId, rotation.Binding.WalletKeyId));
    }
}
