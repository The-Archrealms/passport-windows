using System;
using System.IO;
using ArchrealmsPassport.Windows.Services;
using ArchrealmsPassport.Windows.Tests.Infrastructure;
using Xunit;

namespace ArchrealmsPassport.Windows.Tests;

public sealed class PassportCryptoServiceTests
{
    [Fact]
    public void SignChallengeWritesVerifiedSignatureRecord()
    {
        using var workspace = PassportTestWorkspace.Create();
        var service = new PassportCryptoService();

        var result = service.SignChallenge(
            workspace.Root,
            workspace.IdentityId,
            workspace.DeviceId,
            workspace.KeyReferencePath,
            "test-challenge");

        Assert.True(result.Succeeded, result.Message);
        Assert.True(result.VerifiedWithPublicKey);
        Assert.True(File.Exists(result.SignatureRecordPath));

        var record = PassportTestWorkspace.ReadJson(result.SignatureRecordPath);
        Assert.Equal("passport_challenge_signature", PassportTestWorkspace.GetString(record, "record_type"));
        Assert.Equal("test-challenge", PassportTestWorkspace.GetString(record, "challenge"));
    }

    [Fact]
    public void SignChallengeRejectsEmptyChallenge()
    {
        using var workspace = PassportTestWorkspace.Create();
        var service = new PassportCryptoService();

        var result = service.SignChallenge(
            workspace.Root,
            workspace.IdentityId,
            workspace.DeviceId,
            workspace.KeyReferencePath,
            string.Empty);

        Assert.False(result.Succeeded);
        Assert.Contains("challenge is required", result.Message, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public void CreateRegistrySubmissionIncludesManifestSignatureAndPackageDocuments()
    {
        using var workspace = PassportTestWorkspace.Create();
        var service = new PassportCryptoService();

        var result = service.CreateRegistrySubmission(
            workspace.Root,
            workspace.IdentityId,
            workspace.DeviceId,
            workspace.KeyReferencePath);

        Assert.True(result.Succeeded, result.Message);
        Assert.True(result.VerifiedWithPublicKey);
        Assert.True(File.Exists(result.SubmissionPath));
        Assert.True(File.Exists(result.ManifestPath));
        Assert.True(File.Exists(result.SignaturePath));

        var submission = PassportTestWorkspace.ReadJson(result.SubmissionPath);
        var manifest = PassportTestWorkspace.ReadJson(result.ManifestPath);
        var signature = PassportTestWorkspace.ReadJson(result.SignaturePath);

        Assert.Equal("registry_submission_package", PassportTestWorkspace.GetString(submission, "record_type"));
        Assert.True(PassportTestWorkspace.GetInt64(submission, "document_count") >= 3);
        Assert.Equal(workspace.IdentityId, PassportTestWorkspace.GetString(manifest, "archrealms_identity_id"));
        Assert.Equal("manifest_signature_record", PassportTestWorkspace.GetString(signature, "record_type"));
    }
}
