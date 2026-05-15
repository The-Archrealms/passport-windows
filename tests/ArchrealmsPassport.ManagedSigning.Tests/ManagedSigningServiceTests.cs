using System.Security.Cryptography;
using ArchrealmsPassport.ManagedSigning;
using Xunit;

namespace ArchrealmsPassport.ManagedSigning.Tests;

public sealed class ManagedSigningServiceTests
{
    [Fact]
    public void LocalValidationSignerReturnsVerifiableSignatureAndCustodyEvidence()
    {
        using var workspace = TemporaryDirectory.Create();
        var options = new ManagedSigningOptions
        {
            Provider = "local-validation",
            KeyId = "managed-signing-test-key",
            Custody = "local-validation",
            LocalPkcs8Path = Path.Combine(workspace.Path, "keys", "managed-signing.pkcs8")
        };
        var service = new ManagedSigningService(options);
        var request = CreateRequest(options);

        var result = service.Sign(request);

        Assert.True(result.Succeeded, result.Message);
        Assert.NotNull(result.Response);
        Assert.True(result.Response!.LocalValidationOnly);
        Assert.Equal("local-validation", result.Response.SigningKeyProvider);
        Assert.Equal("managed-signing-test-key", result.Response.SigningKeyId);
        Assert.Equal("local-validation", result.Response.SigningKeyCustody);
        Assert.Equal(string.Empty, service.ValidateResponse(request, result.Response));
        Assert.True(File.Exists(options.LocalPkcs8Path));
    }

    [Fact]
    public void SigningRejectsMismatchedPayloadHash()
    {
        using var workspace = TemporaryDirectory.Create();
        var options = new ManagedSigningOptions
        {
            Provider = "local-validation",
            KeyId = "managed-signing-test-key",
            Custody = "local-validation",
            LocalPkcs8Path = Path.Combine(workspace.Path, "keys", "managed-signing.pkcs8")
        };
        var service = new ManagedSigningService(options);
        var request = CreateRequest(options) with { PayloadSha256 = new string('f', 64) };

        var result = service.Sign(request);

        Assert.False(result.Succeeded);
        Assert.Contains("payload_sha256", result.Message, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public void ApiKeyAuthorizationUsesConfiguredSha256()
    {
        var secret = "operator-secret";
        var options = new ManagedSigningOptions
        {
            Provider = "cloud-kms",
            KeyId = "managed-signing-test-key",
            Custody = "kms",
            ApiKeySha256 = Convert.ToHexString(SHA256.HashData(System.Text.Encoding.UTF8.GetBytes(secret))).ToLowerInvariant()
        };

        Assert.True(options.IsAuthorized(secret));
        Assert.False(options.IsAuthorized("wrong-secret"));
        Assert.False(options.IsAuthorized(string.Empty));
    }

    [Fact]
    public void StatusReportsMissingValuesAndLocalValidationMode()
    {
        var status = new ManagedSigningOptions
        {
            Provider = "local-validation",
            KeyId = "managed-signing-test-key",
            Custody = "local-validation"
        }.GetStatus();

        Assert.False(status.Ready);
        Assert.True(status.LocalValidationOnly);
        Assert.Equal("local-pkcs8-validation", status.Mode);
        Assert.Contains("ARCHREALMS_MANAGED_SIGNING_LOCAL_PKCS8_PATH", status.Missing);
        Assert.Contains("production_mvp_readiness_probe", status.AllowedPurposes);
    }

    private static ManagedSigningRequest CreateRequest(ManagedSigningOptions options)
    {
        var payload = System.Text.Encoding.UTF8.GetBytes("managed signing test payload");
        return new ManagedSigningRequest
        {
            KeyId = options.KeyId,
            Provider = options.Provider,
            Custody = options.Custody,
            Purpose = "production_mvp_readiness_probe",
            PayloadSha256 = Convert.ToHexString(SHA256.HashData(payload)).ToLowerInvariant(),
            PayloadBase64 = Convert.ToBase64String(payload)
        };
    }

    private sealed class TemporaryDirectory : IDisposable
    {
        private TemporaryDirectory(string path)
        {
            Path = path;
            Directory.CreateDirectory(path);
        }

        public string Path { get; }

        public static TemporaryDirectory Create()
        {
            return new TemporaryDirectory(System.IO.Path.Combine(System.IO.Path.GetTempPath(), "archrealms-managed-signing-tests", Guid.NewGuid().ToString("N")));
        }

        public void Dispose()
        {
            try
            {
                if (Directory.Exists(Path))
                {
                    Directory.Delete(Path, true);
                }
            }
            catch
            {
            }
        }
    }
}
