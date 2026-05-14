using System;
using System.Collections.Generic;
using System.IO;
using System.Security.Cryptography;
using System.Text.Json;
using ArchrealmsPassport.Windows.Services;
using ArchrealmsPassport.Windows.Tests.Infrastructure;
using Xunit;

namespace ArchrealmsPassport.Windows.Tests;

public sealed class PassportAdminAuthorityServiceTests
{
    [Fact]
    public void DualControlAdminActionWritesTwoVerifiedSignatures()
    {
        using var workspace = PassportTestWorkspace.Create();
        var secondDeviceId = AddSecondActiveDevice(workspace);
        var service = new PassportAdminAuthorityService(PassportReleaseLane.CreateDefault("staging"));

        var result = service.CreateDualControlAction(
            workspace.Root,
            workspace.IdentityId,
            workspace.DeviceId,
            workspace.KeyReferencePath,
            secondDeviceId,
            workspace.KeyReferencePath,
            "cc_issue",
            "mvp_cc_issuance",
            "capacity_authorized",
            "capacity-record-test",
            new string('a', 64),
            new string('b', 64));

        Assert.True(result.Succeeded, result.Message);
        Assert.True(result.RequesterSignatureVerified);
        Assert.True(result.ApproverSignatureVerified);
        Assert.True(File.Exists(result.RecordPath));
        Assert.True(File.Exists(result.RequesterSignaturePath));
        Assert.True(File.Exists(result.ApproverSignaturePath));

        var record = PassportTestWorkspace.ReadJson(result.RecordPath);
        Assert.Equal("passport_admin_dual_control_action", PassportTestWorkspace.GetString(record, "record_type"));
        Assert.Equal("cc_issue", PassportTestWorkspace.GetString(record, "action_type"));
        Assert.Equal("capacity_authorized", PassportTestWorkspace.GetString(record, "reason_code"));
        Assert.Equal(2, PassportTestWorkspace.GetInt64(record, "approval_count"));
        Assert.False(record.GetProperty("ai_approved").GetBoolean());
    }

    [Fact]
    public void DualControlAdminActionRequiresDistinctDevices()
    {
        using var workspace = PassportTestWorkspace.Create();
        var service = new PassportAdminAuthorityService(PassportReleaseLane.CreateDefault("staging"));

        var result = service.CreateDualControlAction(
            workspace.Root,
            workspace.IdentityId,
            workspace.DeviceId,
            workspace.KeyReferencePath,
            workspace.DeviceId,
            workspace.KeyReferencePath,
            "ledger_correction",
            "mvp_ledger_correction",
            "operator_error",
            "ledger-event-test",
            new string('c', 64),
            new string('d', 64));

        Assert.False(result.Succeeded);
        Assert.Contains("two distinct", result.Message, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public void ValidateDualControlAdminActionEvidenceVerifiesRecordAndSignatures()
    {
        using var workspace = PassportTestWorkspace.Create();
        var secondDeviceId = AddSecondActiveDevice(workspace);
        var service = new PassportAdminAuthorityService(PassportReleaseLane.CreateDefault("staging"));
        var targetHash = new string('e', 64);
        var payloadHash = new string('f', 64);
        var created = service.CreateDualControlAction(
            workspace.Root,
            workspace.IdentityId,
            workspace.DeviceId,
            workspace.KeyReferencePath,
            secondDeviceId,
            workspace.KeyReferencePath,
            "cc_issue",
            "mvp_cc_issuance",
            "capacity_authorized",
            "capacity-record-test",
            targetHash,
            payloadHash);
        Assert.True(created.Succeeded, created.Message);

        var validation = service.ValidateDualControlActionEvidence(
            workspace.Root,
            new Dictionary<string, string>
            {
                ["admin_authority_record_path"] = created.RecordPath,
                ["admin_authority_record_sha256"] = PassportAdminAuthorityService.ComputeFileSha256(created.RecordPath),
                ["admin_authority_requester_signature_path"] = created.RequesterSignaturePath,
                ["admin_authority_approver_signature_path"] = created.ApproverSignaturePath
            },
            "cc_issue",
            targetHash,
            payloadHash);

        Assert.True(validation.Succeeded, validation.Message);
        Assert.True(validation.RequesterSignatureVerified);
        Assert.True(validation.ApproverSignatureVerified);
    }

    [Fact]
    public void ValidateDualControlAdminActionEvidenceRejectsMismatchedTarget()
    {
        using var workspace = PassportTestWorkspace.Create();
        var secondDeviceId = AddSecondActiveDevice(workspace);
        var service = new PassportAdminAuthorityService(PassportReleaseLane.CreateDefault("staging"));
        var created = service.CreateDualControlAction(
            workspace.Root,
            workspace.IdentityId,
            workspace.DeviceId,
            workspace.KeyReferencePath,
            secondDeviceId,
            workspace.KeyReferencePath,
            "cc_issue",
            "mvp_cc_issuance",
            "capacity_authorized",
            "capacity-record-test",
            new string('e', 64),
            new string('f', 64));
        Assert.True(created.Succeeded, created.Message);

        var validation = service.ValidateDualControlActionEvidence(
            workspace.Root,
            new Dictionary<string, string>
            {
                ["admin_authority_record_path"] = created.RecordPath,
                ["admin_authority_record_sha256"] = PassportAdminAuthorityService.ComputeFileSha256(created.RecordPath),
                ["admin_authority_requester_signature_path"] = created.RequesterSignaturePath,
                ["admin_authority_approver_signature_path"] = created.ApproverSignaturePath
            },
            "cc_issue",
            new string('0', 64),
            new string('f', 64));

        Assert.False(validation.Succeeded);
        Assert.Contains("target record hash", validation.Message, StringComparison.OrdinalIgnoreCase);
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
