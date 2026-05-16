using System.Net;
using System.Net.Http.Json;
using System.Text.Json;
using ArchrealmsPassport.Core.Protocol;
using ArchrealmsPassport.HostedServices;
using Microsoft.AspNetCore.Mvc.Testing;
using Xunit;

namespace ArchrealmsPassport.HostedServices.Tests;

[CollectionDefinition("Hosted API environment", DisableParallelization = true)]
public sealed class HostedApiEnvironmentCollection
{
    public const string Name = "Hosted API environment";
}

[Collection(HostedApiEnvironmentCollection.Name)]
public sealed class PassportHostedApiIntegrationTests
{
    private const string OperatorKey = "passport-hosted-integration-operator-key";

    [Fact]
    public async Task OperatorEndpointsRequireConfiguredProductionOperatorKey()
    {
        using var missingEnvironment = ScopedEnvironment.Create(configureOperatorKey: false);
        await using (var missingFactory = new WebApplicationFactory<Program>())
        {
            using var missingClient = missingFactory.CreateClient();
            var missingResponse = await missingClient.GetAsync("/ops/operator/status");
            Assert.Equal(HttpStatusCode.ServiceUnavailable, missingResponse.StatusCode);
        }

        using var configuredEnvironment = ScopedEnvironment.Create(configureOperatorKey: true);
        await using var configuredFactory = new WebApplicationFactory<Program>();
        using var configuredClient = configuredFactory.CreateClient();

        var noHeader = await configuredClient.GetAsync("/ops/operator/status");
        Assert.Equal(HttpStatusCode.Unauthorized, noHeader.StatusCode);

        using var wrongRequest = new HttpRequestMessage(HttpMethod.Get, "/ops/operator/status");
        wrongRequest.Headers.Add(PassportHostedOperatorGate.HeaderName, "wrong-key");
        var wrongResponse = await configuredClient.SendAsync(wrongRequest);
        Assert.Equal(HttpStatusCode.Unauthorized, wrongResponse.StatusCode);

        using var authorizedRequest = new HttpRequestMessage(HttpMethod.Get, "/ops/operator/status");
        authorizedRequest.Headers.Add(PassportHostedOperatorGate.HeaderName, OperatorKey);
        var authorizedResponse = await configuredClient.SendAsync(authorizedRequest);
        Assert.Equal(HttpStatusCode.OK, authorizedResponse.StatusCode);

        using var document = JsonDocument.Parse(await authorizedResponse.Content.ReadAsStringAsync());
        Assert.True(document.RootElement.GetProperty("authorized").GetBoolean());
        Assert.Equal("authorized", document.RootElement.GetProperty("status").GetString());
    }

    [Fact]
    public async Task HostedStatusEndpointsReturnProductionReadinessContracts()
    {
        using var environment = ScopedEnvironment.Create(configureOperatorKey: true, configureAiRuntime: true);
        await using var factory = new WebApplicationFactory<Program>();
        using var client = factory.CreateClient();

        using (var healthResponse = await client.GetAsync("/health"))
        {
            Assert.Equal(HttpStatusCode.OK, healthResponse.StatusCode);
            using var health = JsonDocument.Parse(await healthResponse.Content.ReadAsStringAsync());
            Assert.Equal("archrealms-passport-hosted-services", health.RootElement.GetProperty("service").GetString());
            Assert.Equal("ok", health.RootElement.GetProperty("status").GetString());
        }

        using (var aiRuntimeResponse = await client.GetAsync("/ai/runtime/status"))
        {
            Assert.Equal(HttpStatusCode.OK, aiRuntimeResponse.StatusCode);
            using var aiRuntime = JsonDocument.Parse(await aiRuntimeResponse.Content.ReadAsStringAsync());
            Assert.True(aiRuntime.RootElement.GetProperty("ready").GetBoolean());
            Assert.Equal("llama-3.1-8b-instruct-test", aiRuntime.RootElement.GetProperty("model_id").GetString());
        }

        using var storageRequest = new HttpRequestMessage(HttpMethod.Get, "/ops/storage/status");
        storageRequest.Headers.Add(PassportHostedOperatorGate.HeaderName, OperatorKey);
        using var storageResponse = await client.SendAsync(storageRequest);
        Assert.Equal(HttpStatusCode.OK, storageResponse.StatusCode);

        using var storage = JsonDocument.Parse(await storageResponse.Content.ReadAsStringAsync());
        Assert.True(storage.RootElement.GetProperty("ready").GetBoolean());
        Assert.True(storage.RootElement.GetProperty("data_root_configured").GetBoolean());
        Assert.True(storage.RootElement.GetProperty("records_writable").GetBoolean());
        Assert.True(storage.RootElement.GetProperty("append_log_writable").GetBoolean());
    }

    [Fact]
    public async Task StorageDeliveryEndpointAcceptsValidRequestAndPersistsSignedRecord()
    {
        using var environment = ScopedEnvironment.Create(configureOperatorKey: true);
        await using var factory = new WebApplicationFactory<Program>();
        using var client = factory.CreateClient();

        using var unauthorizedResponse = await client.PostAsJsonAsync("/storage/delivery/requests", CreateStorageDeliveryRequest());
        Assert.Equal(HttpStatusCode.Unauthorized, unauthorizedResponse.StatusCode);

        using var invalidRequest = new HttpRequestMessage(HttpMethod.Post, "/storage/delivery/requests")
        {
            Content = JsonContent.Create(new
            {
                service_delivery_request_record = new
                {
                    record_type = "wrong_record_type"
                }
            })
        };
        invalidRequest.Headers.Add(PassportHostedOperatorGate.HeaderName, OperatorKey);
        using var invalidResponse = await client.SendAsync(invalidRequest);
        Assert.Equal(HttpStatusCode.BadRequest, invalidResponse.StatusCode);

        using var validRequest = new HttpRequestMessage(HttpMethod.Post, "/storage/delivery/requests")
        {
            Content = JsonContent.Create(CreateStorageDeliveryRequest())
        };
        validRequest.Headers.Add(PassportHostedOperatorGate.HeaderName, OperatorKey);
        using var response = await client.SendAsync(validRequest);
        Assert.Equal(HttpStatusCode.OK, response.StatusCode);

        var responseBody = await response.Content.ReadAsStringAsync();
        using var document = JsonDocument.Parse(responseBody);
        var root = document.RootElement;
        Assert.True(root.GetProperty("succeeded").GetBoolean());

        var recordId = root.GetProperty("record_id").GetString();
        Assert.False(string.IsNullOrWhiteSpace(recordId));

        var record = root.GetProperty("record");
        Assert.Equal(PassportRecordTypes.StorageDeliveryAcceptance, record.GetProperty("record_type").GetString());
        Assert.Equal("accepted_pending_epoch_proofs", record.GetProperty("assignment_status").GetString());
        Assert.False(record.GetProperty("proof_requirements").GetProperty("burn_without_verified_epoch_allowed").GetBoolean());
        Assert.True(record.TryGetProperty("service_signature", out _));

        var persistedPath = Path.Combine(environment.DataRoot, "records", "hosted", recordId + ".json");
        Assert.True(File.Exists(persistedPath), "Expected hosted storage acceptance record to be persisted.");
        using var persisted = JsonDocument.Parse(File.ReadAllText(persistedPath));
        Assert.Equal(PassportRecordTypes.StorageDeliveryAcceptance, persisted.RootElement.GetProperty("record_type").GetString());

        var appendLogText = string.Join(Environment.NewLine, Directory.GetFiles(
                Path.Combine(environment.DataRoot, "append-log"),
                "*.jsonl")
            .Select(File.ReadAllText));
        Assert.Contains(PassportRecordTypes.StorageDeliveryAcceptance, appendLogText, StringComparison.Ordinal);
    }

    private static object CreateStorageDeliveryRequest()
    {
        return new
        {
            service_delivery_request_record = new
            {
                schema_version = 1,
                record_type = PassportRecordTypes.StorageServiceDeliveryRequest,
                record_id = "storage-delivery-request-integration-test",
                release_lane = "production-mvp",
                ledger_namespace = "archrealms-passport-production",
                policy_version = "token-ready-mvp-v1",
                redemption_id = "redemption-integration-test",
                storage_gb = 1,
                service_epoch_count = 1
            },
            service_delivery_request_sha256 = string.Empty
        };
    }

    private sealed class ScopedEnvironment : IDisposable
    {
        private readonly Dictionary<string, string?> previousValues;

        private ScopedEnvironment(string dataRoot, Dictionary<string, string?> previousValues)
        {
            DataRoot = dataRoot;
            this.previousValues = previousValues;
        }

        public string DataRoot { get; }

        public static ScopedEnvironment Create(bool configureOperatorKey, bool configureAiRuntime = false)
        {
            var dataRoot = Path.Combine(Path.GetTempPath(), "archrealms-passport-hosted-api-" + Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(dataRoot);

            var values = new Dictionary<string, string?>
            {
                ["ASPNETCORE_ENVIRONMENT"] = "Production",
                ["ARCHREALMS_PASSPORT_HOSTED_DATA_ROOT"] = dataRoot,
                ["ARCHREALMS_PASSPORT_HOSTED_OPERATOR_API_KEY_SHA256"] = configureOperatorKey
                    ? PassportHostedOperatorGate.ComputeKeySha256(OperatorKey)
                    : null,
                ["ARCHREALMS_PASSPORT_HOSTED_SIGNING_ENDPOINT"] = null,
                ["ARCHREALMS_PASSPORT_HOSTED_SIGNING_KEY_PROVIDER"] = null,
                ["ARCHREALMS_PASSPORT_HOSTED_SIGNING_KEY_ID"] = null,
                ["ARCHREALMS_PASSPORT_HOSTED_SIGNING_KEY_CUSTODY"] = null,
                ["ARCHREALMS_PASSPORT_HOSTED_SIGNING_ENDPOINT_API_KEY"] = null,
                ["ARCHREALMS_PASSPORT_HOSTED_SIGNING_KEY_PATH"] = null,
                ["ARCHREALMS_PASSPORT_AI_INFERENCE_BASE_URL"] = configureAiRuntime ? "https://ai.integration.test" : null,
                ["ARCHREALMS_PASSPORT_AI_MODEL_ID"] = configureAiRuntime ? "llama-3.1-8b-instruct-test" : null,
                ["ARCHREALMS_PASSPORT_AI_MODEL_ARTIFACT_SHA256"] = configureAiRuntime
                    ? new string('a', 64)
                    : null,
                ["ARCHREALMS_PASSPORT_AI_MODEL_LICENSE_APPROVAL_ID"] = configureAiRuntime ? "license-approval-integration-test" : null,
                ["ARCHREALMS_PASSPORT_AI_VECTOR_STORE_PROVIDER"] = configureAiRuntime ? "integration-vector-store" : null,
                ["ARCHREALMS_PASSPORT_AI_VECTOR_STORE_ID"] = configureAiRuntime ? "passport-knowledge-integration-test" : null,
                ["ARCHREALMS_PASSPORT_AI_KNOWLEDGE_APPROVAL_ROOT"] = configureAiRuntime
                    ? new string('b', 64)
                    : null
            };

            var previousValues = new Dictionary<string, string?>(StringComparer.Ordinal);
            foreach (var (name, value) in values)
            {
                previousValues[name] = Environment.GetEnvironmentVariable(name);
                Environment.SetEnvironmentVariable(name, value);
            }

            return new ScopedEnvironment(dataRoot, previousValues);
        }

        public void Dispose()
        {
            foreach (var (name, value) in previousValues)
            {
                Environment.SetEnvironmentVariable(name, value);
            }

            try
            {
                if (Directory.Exists(DataRoot))
                {
                    Directory.Delete(DataRoot, recursive: true);
                }
            }
            catch (IOException)
            {
            }
            catch (UnauthorizedAccessException)
            {
            }
        }
    }
}
