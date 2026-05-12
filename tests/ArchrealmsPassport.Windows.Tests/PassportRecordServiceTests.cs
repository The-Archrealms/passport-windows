using System;
using System.IO;
using ArchrealmsPassport.Windows.Services;
using ArchrealmsPassport.Windows.Tests.Infrastructure;
using Xunit;

namespace ArchrealmsPassport.Windows.Tests;

public sealed class PassportRecordServiceTests
{
    [Fact]
    public void CreateNewIdentityUsesSimplePassportAndDeviceIds()
    {
        var root = Path.Combine(Path.GetTempPath(), "archrealms-passport-tests", Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);

        try
        {
            var service = new PassportRecordService();
            var result = service.CreateNewIdentity(root, "Dan", "named", string.Empty, false);

            Assert.True(result.Succeeded, result.Message);
            Assert.Matches("^passport-[0-9a-f]{10}$", result.IdentityId);
            Assert.Matches("^device-[0-9a-f]{10}$", result.DeviceId);

            var identityRecord = PassportTestWorkspace.ReadJson(result.IdentityRecordPath);
            Assert.Equal("Dan", PassportTestWorkspace.GetString(identityRecord, "display_name"));
            Assert.Equal(result.IdentityId, PassportTestWorkspace.GetString(identityRecord, "archrealms_identity_id"));
        }
        finally
        {
            if (Directory.Exists(root))
            {
                Directory.Delete(root, true);
            }
        }
    }

    [Fact]
    public void CreateNewIdentityUsesFriendlyDisplayNameFallback()
    {
        var root = Path.Combine(Path.GetTempPath(), "archrealms-passport-tests", Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);

        try
        {
            var service = new PassportRecordService();
            var result = service.CreateNewIdentity(root, "", "named", "", false);

            Assert.True(result.Succeeded, result.Message);

            var identityRecord = PassportTestWorkspace.ReadJson(result.IdentityRecordPath);
            var suffix = result.IdentityId[^6..];
            Assert.Equal("Passport " + suffix, PassportTestWorkspace.GetString(identityRecord, "display_name"));
        }
        finally
        {
            if (Directory.Exists(root))
            {
                Directory.Delete(root, true);
            }
        }
    }

    [Fact]
    public void CreateNodeCapacitySnapshotNormalizesSettingsAndSignsPayload()
    {
        using var workspace = PassportTestWorkspace.Create();
        var service = new PassportRecordService();

        var result = service.CreateNodeCapacitySnapshot(
            workspace.Root,
            workspace.IdentityId,
            workspace.DeviceId,
            workspace.KeyReferencePath,
            "node-test",
            5,
            "unexpected participation mode",
            "unexpected cache policy",
            150,
            "",
            true,
            Path.Combine(workspace.Root, "ipfs"));

        Assert.True(result.Succeeded, result.Message);
        Assert.Equal("node_capacity_snapshot_record", result.RecordType);
        Assert.True(workspace.SignedRecordVerifies(result.RecordPath));

        var record = PassportTestWorkspace.ReadJson(result.RecordPath);
        Assert.Equal("Public archive contributor", PassportTestWorkspace.GetString(record, "participation_mode"));
        Assert.Equal("Balanced pinned archive", PassportTestWorkspace.GetString(record, "cache_policy"));
        Assert.Equal("pinned", PassportTestWorkspace.GetString(record, "provide_strategy"));
        Assert.Equal(99, PassportTestWorkspace.GetInt64(record, "storage_gc_watermark"));
    }

    [Fact]
    public void StorageMeteringRoundTripVerifiesLocalRecordsAndSummarizesProofs()
    {
        using var workspace = PassportTestWorkspace.Create();
        var service = new PassportRecordService();
        var proofSource = workspace.WriteProofSource("proof-source.bin", "storage proof source content");
        var proofLength = new FileInfo(proofSource).Length;

        var capacity = service.CreateNodeCapacitySnapshot(
            workspace.Root,
            workspace.IdentityId,
            workspace.DeviceId,
            workspace.KeyReferencePath,
            "node-test",
            5,
            "Public archive contributor",
            "Balanced pinned archive",
            80,
            "pinned",
            false,
            Path.Combine(workspace.Root, "ipfs"));
        var acknowledgment = service.CreateStorageAssignmentAcknowledgment(
            workspace.Root,
            workspace.IdentityId,
            workspace.DeviceId,
            workspace.KeyReferencePath,
            "node-test",
            "assignment-test",
            "bafytestcontent",
            "",
            "stewarded_archive_storage",
            proofLength,
            true);
        var proof = service.CreateStorageEpochProof(
            workspace.Root,
            workspace.IdentityId,
            workspace.DeviceId,
            workspace.KeyReferencePath,
            "node-test",
            "assignment-test",
            "bafytestcontent",
            "",
            "stewarded_archive_storage",
            proofSource);
        var status = service.CreateLocalMeteringStatus(workspace.Root, workspace.IdentityId, workspace.DeviceId, "node-test");
        var verification = service.VerifyLocalMeteringRecords(
            workspace.Root,
            workspace.IdentityId,
            workspace.DeviceId,
            workspace.KeyReferencePath);

        Assert.True(capacity.Succeeded, capacity.Message);
        Assert.True(acknowledgment.Succeeded, acknowledgment.Message);
        Assert.True(proof.Succeeded, proof.Message);
        Assert.True(status.Succeeded, status.Message);
        Assert.True(verification.Succeeded, verification.Message);
        Assert.True(workspace.SignedRecordVerifies(capacity.RecordPath));
        Assert.True(workspace.SignedRecordVerifies(acknowledgment.RecordPath));
        Assert.True(workspace.SignedRecordVerifies(proof.RecordPath));

        var statusRecord = PassportTestWorkspace.ReadJson(status.RecordPath);
        var verifiedService = statusRecord.GetProperty("verified_service");
        Assert.Equal(1, PassportTestWorkspace.GetInt64(verifiedService, "submitted_proof_count"));
        Assert.Equal(proofLength, PassportTestWorkspace.GetInt64(verifiedService, "claimed_storage_bytes"));

        var verificationReport = PassportTestWorkspace.ReadJson(verification.RecordPath);
        Assert.Equal(3, PassportTestWorkspace.GetInt64(verificationReport, "verified_record_count"));
        Assert.Equal(0, PassportTestWorkspace.GetInt64(verificationReport, "failed_record_count"));
    }

    [Fact]
    public void VerifyLocalMeteringRecordsFailsWhenSignedPayloadHashIsTampered()
    {
        using var workspace = PassportTestWorkspace.Create();
        var service = new PassportRecordService();

        var acknowledgment = service.CreateStorageAssignmentAcknowledgment(
            workspace.Root,
            workspace.IdentityId,
            workspace.DeviceId,
            workspace.KeyReferencePath,
            "node-test",
            "assignment-test",
            "bafytestcontent",
            "",
            "stewarded_archive_storage",
            128,
            true);
        Assert.True(acknowledgment.Succeeded, acknowledgment.Message);

        var acknowledgmentRecord = PassportTestWorkspace.ReadJson(acknowledgment.RecordPath);
        var payloadPath = workspace.ResolveWorkspaceRelativePath(
            PassportTestWorkspace.GetString(acknowledgmentRecord.GetProperty("signature"), "signed_payload_path"));
        File.AppendAllText(payloadPath, "tamper");

        var verification = service.VerifyLocalMeteringRecords(
            workspace.Root,
            workspace.IdentityId,
            workspace.DeviceId,
            workspace.KeyReferencePath);

        Assert.False(verification.Succeeded);
        var verificationReport = PassportTestWorkspace.ReadJson(verification.RecordPath);
        Assert.Equal(1, PassportTestWorkspace.GetInt64(verificationReport, "failed_record_count"));
        Assert.Equal("signed_payload_hash_mismatch", PassportTestWorkspace.GetString(verificationReport.GetProperty("checked_records")[0], "reason"));
    }

    [Fact]
    public void StorageAssignmentAcknowledgmentRequiresContentCid()
    {
        using var workspace = PassportTestWorkspace.Create();
        var service = new PassportRecordService();

        var result = service.CreateStorageAssignmentAcknowledgment(
            workspace.Root,
            workspace.IdentityId,
            workspace.DeviceId,
            workspace.KeyReferencePath,
            "node-test",
            "assignment-test",
            "",
            "",
            "stewarded_archive_storage",
            128,
            true);

        Assert.False(result.Succeeded);
        Assert.Contains("content CID is required", result.Message, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public void StorageEpochProofRequiresReadableProofSource()
    {
        using var workspace = PassportTestWorkspace.Create();
        var service = new PassportRecordService();

        var result = service.CreateStorageEpochProof(
            workspace.Root,
            workspace.IdentityId,
            workspace.DeviceId,
            workspace.KeyReferencePath,
            "node-test",
            "assignment-test",
            "bafytestcontent",
            "",
            "stewarded_archive_storage",
            Path.Combine(workspace.Root, "missing.bin"));

        Assert.False(result.Succeeded);
        Assert.Contains("proof source file is required", result.Message, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public void MeteringReviewWorkflowCreatesSignedAdmissionChallengeDisputeCorrectionAndHandoff()
    {
        using var workspace = PassportTestWorkspace.Create();
        var service = new PassportRecordService();
        var proofSource = workspace.WriteProofSource("proof-source.bin", "storage proof source content");
        var proof = service.CreateStorageEpochProof(
            workspace.Root,
            workspace.IdentityId,
            workspace.DeviceId,
            workspace.KeyReferencePath,
            "node-test",
            "assignment-test",
            "bafytestcontent",
            "",
            "stewarded_archive_storage",
            proofSource);
        Assert.True(proof.Succeeded, proof.Message);

        var packageRoot = workspace.CreateVerifiedMeteringPackage(proof.RecordPath, proof.RecordId);
        var packageVerificationPath = Path.Combine(packageRoot, "metering-package-verification-report.json");

        var admission = service.CreateMeteringPackageAdmission(
            workspace.Root,
            workspace.IdentityId,
            workspace.DeviceId,
            workspace.KeyReferencePath,
            packageRoot,
            packageVerificationPath);
        var audit = service.CreateMeteringAuditChallenge(
            workspace.Root,
            workspace.IdentityId,
            workspace.DeviceId,
            workspace.KeyReferencePath,
            admission.RecordPath,
            "registrar-test",
            "routine_sample");
        var dispute = service.CreateMeteringDispute(
            workspace.Root,
            workspace.IdentityId,
            workspace.DeviceId,
            workspace.KeyReferencePath,
            admission.RecordPath,
            audit.RecordPath,
            "registrar",
            "registrar-test",
            "proof_count_or_service_units",
            "audit_review",
            "exclude_or_correct_challenged_units");
        var correction = service.CreateMeteringCorrection(
            workspace.Root,
            workspace.IdentityId,
            workspace.DeviceId,
            workspace.KeyReferencePath,
            admission.RecordPath,
            audit.RecordPath,
            dispute.RecordPath,
            "registrar-test",
            "dispute_resolution",
            0,
            1,
            0);
        var handoff = service.CreateMeteringSettlementHandoff(
            workspace.Root,
            workspace.IdentityId,
            workspace.DeviceId,
            workspace.KeyReferencePath,
            admission.RecordPath,
            audit.RecordPath,
            dispute.RecordPath,
            correction.RecordPath,
            "registrar-test",
            "eligible_for_settlement_review");

        Assert.True(admission.Succeeded, admission.Message);
        Assert.True(audit.Succeeded, audit.Message);
        Assert.True(dispute.Succeeded, dispute.Message);
        Assert.True(correction.Succeeded, correction.Message);
        Assert.True(handoff.Succeeded, handoff.Message);

        Assert.Equal("passport_metering_admission_record", admission.RecordType);
        Assert.Equal("passport_metering_audit_challenge_record", audit.RecordType);
        Assert.Equal("passport_metering_dispute_record", dispute.RecordType);
        Assert.Equal("passport_metering_correction_record", correction.RecordType);
        Assert.Equal("passport_metering_settlement_handoff_record", handoff.RecordType);
        Assert.True(workspace.SignedRecordVerifies(admission.RecordPath));
        Assert.True(workspace.SignedRecordVerifies(audit.RecordPath));
        Assert.True(workspace.SignedRecordVerifies(dispute.RecordPath));
        Assert.True(workspace.SignedRecordVerifies(correction.RecordPath));
        Assert.True(workspace.SignedRecordVerifies(handoff.RecordPath));
    }
}
