using Xunit;

namespace ArchrealmsPassport.HostedServices.Tests;

public sealed class PassportHostedOperationsReadinessTests
{
    [Fact]
    public void OperationsReadinessAcceptsManagedStorageSigningTelemetryAndIncidentConfiguration()
    {
        var readiness = PassportHostedOperationsReadiness.FromValues(
            dataRoot: "/managed/passport-hosted",
            storageProvider: "managed-object-storage",
            backupPolicyUri: "archrealms://runbooks/backup-policy-v1",
            restoreRunbookUri: "archrealms://runbooks/restore-v1",
            signingKeyProvider: "cloud-kms",
            signingKeyId: "passport-hosted-signing-key",
            signingKeyCustody: "kms",
            localSigningKeyPath: null,
            telemetryDestination: "managed-telemetry",
            telemetryRetentionPolicyUri: "archrealms://policies/telemetry-retention-v1",
            incidentResponseRunbookUri: "archrealms://runbooks/incident-response-v1",
            incidentResponseOwner: "ops-duty-officer");

        Assert.True(readiness.Ready, string.Join("; ", readiness.Missing));
        Assert.Equal("managed-object-storage", readiness.StorageProvider);
        Assert.False(readiness.LocalSigningKeyPathConfigured);
    }

    [Fact]
    public void OperationsReadinessRejectsMissingConfigAndLocalSigningKeyPath()
    {
        var readiness = PassportHostedOperationsReadiness.FromValues(
            dataRoot: "",
            storageProvider: "",
            backupPolicyUri: "",
            restoreRunbookUri: "",
            signingKeyProvider: "",
            signingKeyId: "",
            signingKeyCustody: "local-file",
            localSigningKeyPath: "keys/hosted-service-signing-key.pkcs8",
            telemetryDestination: "",
            telemetryRetentionPolicyUri: "",
            incidentResponseRunbookUri: "",
            incidentResponseOwner: "");

        Assert.False(readiness.Ready);
        Assert.Contains("ARCHREALMS_PASSPORT_HOSTED_DATA_ROOT", readiness.Missing);
        Assert.Contains("ARCHREALMS_PASSPORT_HOSTED_SIGNING_KEY_CUSTODY must be managed/kms/hsm", readiness.Missing);
        Assert.Contains("ARCHREALMS_PASSPORT_HOSTED_SIGNING_KEY_PATH must not be used for production managed custody", readiness.Missing);
    }
}
