using System.Net;
using System.Security.Cryptography;
using System.Text.Json;
using Xunit;

namespace ArchrealmsPassport.HostedServices.Tests;

public sealed class PassportHostedServiceSignerTests
{
    [Fact]
    public void ServiceSignerAddsVerifiableSignatureAndChangesRecordHash()
    {
        using var workspace = TemporaryDirectory.Create();
        var signer = new PassportHostedServiceSigner(System.IO.Path.Combine(workspace.Path, "keys", "service.pkcs8"));
        var response = new Contracts.PassportHostedRecordResponse
        {
            Succeeded = true,
            Message = "created",
            RecordId = "record-1",
            RecordSha256 = new string('a', 64),
            Record = new Dictionary<string, object?>
            {
                ["schema_version"] = 1,
                ["record_type"] = "passport_cc_capacity_report",
                ["record_id"] = "record-1"
            }
        };

        var signed = signer.Sign(response, "cc_capacity_report");

        Assert.NotEqual(response.RecordSha256, signed.RecordSha256);
        Assert.NotNull(signed.Record);
        Assert.True(signed.Record!.ContainsKey("service_signature"));
        Assert.True(PassportHostedServiceSigner.VerifySignedRecord(signed.Record));
        Assert.True(File.Exists(System.IO.Path.Combine(workspace.Path, "keys", "service.pkcs8")));
        Assert.True(File.Exists(System.IO.Path.Combine(workspace.Path, "keys", "service.spki.der")));
    }

    [Fact]
    public void ServiceSignerRejectsTamperedSignedRecords()
    {
        using var workspace = TemporaryDirectory.Create();
        var signer = new PassportHostedServiceSigner(System.IO.Path.Combine(workspace.Path, "keys", "service.pkcs8"));
        var signed = signer.Sign(new Contracts.PassportHostedRecordResponse
        {
            Succeeded = true,
            Message = "created",
            RecordId = "record-1",
            RecordSha256 = new string('a', 64),
            Record = new Dictionary<string, object?>
            {
                ["schema_version"] = 1,
                ["record_type"] = "passport_cc_capacity_report",
                ["record_id"] = "record-1"
            }
        }, "cc_capacity_report");

        signed.Record!["record_type"] = "tampered";

        Assert.False(PassportHostedServiceSigner.VerifySignedRecord(signed.Record));
    }

    [Fact]
    public void ManagedServiceSignerUsesEndpointAndDoesNotCreateLocalPrivateKey()
    {
        using var workspace = TemporaryDirectory.Create();
        using var rsa = RSA.Create(3072);
        var handler = new ManagedSigningHandler(rsa);
        var signer = new PassportHostedServiceSigner(
            new PassportManagedSigningOptions
            {
                Endpoint = "https://signing.archrealms.example/sign",
                Provider = "cloud-kms",
                KeyId = "passport-hosted-signing-key",
                Custody = "kms",
                ApiKey = "managed-signing-secret",
                TimeoutSeconds = 5
            },
            handler);
        var response = new Contracts.PassportHostedRecordResponse
        {
            Succeeded = true,
            Message = "created",
            RecordId = "record-1",
            RecordSha256 = new string('a', 64),
            Record = new Dictionary<string, object?>
            {
                ["schema_version"] = 1,
                ["record_type"] = "passport_cc_capacity_report",
                ["record_id"] = "record-1"
            }
        };

        var signed = signer.Sign(response, "cc_capacity_report");

        Assert.Equal("https://signing.archrealms.example/sign", handler.RequestUri);
        Assert.Equal("managed-signing-secret", handler.ApiKey);
        Assert.Equal("passport-hosted-signing-key", handler.KeyId);
        Assert.True(PassportHostedServiceSigner.VerifySignedRecord(signed.Record!));
        var signature = JsonSerializer.SerializeToElement(signed.Record!["service_signature"]);
        Assert.Equal("cloud-kms", signature.GetProperty("signing_key_provider").GetString());
        Assert.Equal("passport-hosted-signing-key", signature.GetProperty("signing_key_id").GetString());
        Assert.Equal("kms", signature.GetProperty("signing_key_custody").GetString());
        Assert.False(File.Exists(System.IO.Path.Combine(workspace.Path, "keys", "service.pkcs8")));
    }

    private sealed class ManagedSigningHandler : HttpMessageHandler
    {
        private readonly RSA rsa;

        public ManagedSigningHandler(RSA rsa)
        {
            this.rsa = rsa;
        }

        public string RequestUri { get; private set; } = string.Empty;

        public string ApiKey { get; private set; } = string.Empty;

        public string KeyId { get; private set; } = string.Empty;

        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            return await CreateResponseAsync(request, cancellationToken);
        }

        protected override HttpResponseMessage Send(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            return CreateResponseAsync(request, cancellationToken).GetAwaiter().GetResult();
        }

        private async Task<HttpResponseMessage> CreateResponseAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            RequestUri = request.RequestUri?.ToString() ?? string.Empty;
            ApiKey = request.Headers.TryGetValues("X-Archrealms-Managed-Signing-Key", out var values)
                ? values.FirstOrDefault() ?? string.Empty
                : string.Empty;
            var body = await request.Content!.ReadAsStringAsync(cancellationToken);
            using var document = JsonDocument.Parse(body);
            KeyId = document.RootElement.GetProperty("key_id").GetString() ?? string.Empty;
            var payload = Convert.FromBase64String(document.RootElement.GetProperty("payload_base64").GetString() ?? string.Empty);
            var payloadSha256 = document.RootElement.GetProperty("payload_sha256").GetString() ?? string.Empty;
            var signature = rsa.SignData(payload, HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1);
            var publicKey = rsa.ExportSubjectPublicKeyInfo();
            var response = new Dictionary<string, object?>
            {
                ["signature_algorithm"] = "RSA_PKCS1_SHA256",
                ["signed_payload_sha256"] = payloadSha256,
                ["signature_base64"] = Convert.ToBase64String(signature),
                ["public_key_spki_der_base64"] = Convert.ToBase64String(publicKey),
                ["public_key_sha256"] = Convert.ToHexString(SHA256.HashData(publicKey)).ToLowerInvariant()
            };
            return new HttpResponseMessage(HttpStatusCode.OK)
            {
                Content = new StringContent(JsonSerializer.Serialize(response))
            };
        }
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
            return new TemporaryDirectory(System.IO.Path.Combine(System.IO.Path.GetTempPath(), "archrealms-hosted-signer-tests", Guid.NewGuid().ToString("N")));
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
