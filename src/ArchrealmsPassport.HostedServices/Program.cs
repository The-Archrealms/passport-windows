using ArchrealmsPassport.HostedServices;
using ArchrealmsPassport.HostedServices.Contracts;

var builder = WebApplication.CreateBuilder(args);
var app = builder.Build();

var store = PassportHostedFileStore.FromEnvironment();
var registryStore = PassportHostedRegistryStore.FromDataRoot(store.Root);
var knowledgeStore = PassportHostedKnowledgeStore.FromDataRoot(store.Root);
var signer = PassportHostedServiceSigner.FromDataRoot(store.Root);
var operatorGate = PassportHostedOperatorGate.FromEnvironment();
var rateLimiter = new PassportHostedRateLimiter();
var aiInferenceGateway = PassportHostedAiInferenceGateway.FromEnvironment();

app.MapGet("/health", () => Results.Json(new
{
    service = "archrealms-passport-hosted-services",
    status = "ok",
    contract_version = PassportHostedPolicy.ContractVersion,
    utc = DateTimeOffset.UtcNow
}));

app.MapPost("/ai/session", (HttpRequest httpRequest, PassportAiSessionAuthorizationRequest request) =>
{
    var rateLimit = AuthorizeRate(httpRequest, rateLimiter, "ai-session", maxRequests: 30, window: TimeSpan.FromMinutes(1));
    if (rateLimit != null)
    {
        return rateLimit;
    }

    var result = PassportHostedPolicy.AuthorizeAiSession(request);
    if (!result.Succeeded || result.Session == null)
    {
        return Results.BadRequest(result);
    }

    store.SaveAiSession(result.Session);
    return Results.Json(result);
});

app.MapPost("/ai/chat", async (HttpRequest httpRequest, PassportAiChatRequest request, CancellationToken cancellationToken) =>
{
    var rateLimit = AuthorizeRate(httpRequest, rateLimiter, "ai-chat:" + request.SessionId, maxRequests: 60, window: TimeSpan.FromMinutes(1));
    if (rateLimit != null)
    {
        return rateLimit;
    }

    var bearerToken = PassportHostedPolicy.ReadBearerToken(httpRequest.Headers.Authorization.ToString());
    var result = await PassportHostedPolicy.CreateAiChatResponseAsync(
        request,
        bearerToken,
        store,
        knowledgeStore,
        aiInferenceGateway,
        cancellationToken);
    return result.Succeeded ? Results.Json(result) : Results.BadRequest(result);
});

app.MapPost("/capacity/reports/cc", (HttpRequest httpRequest, PassportCcCapacityReportRequest request) =>
{
    var operatorAuthorization = AuthorizeOperator(httpRequest, operatorGate);
    if (operatorAuthorization != null)
    {
        return operatorAuthorization;
    }

    var rateLimit = AuthorizeRate(httpRequest, rateLimiter, "operator-capacity", maxRequests: 20, window: TimeSpan.FromMinutes(1));
    if (rateLimit != null)
    {
        return rateLimit;
    }

    var result = PassportHostedPolicy.CreateCcCapacityReport(request);
    if (!result.Succeeded || result.Record == null)
    {
        return Results.BadRequest(result);
    }

    result = signer.Sign(result, "cc_capacity_report");
    store.SaveRecord(result.RecordId, result.Record!, result.RecordSha256);
    return Results.Json(result);
});

app.MapPost("/arch/genesis/manifests", (HttpRequest httpRequest, PassportArchGenesisManifestRequest request) =>
{
    var operatorAuthorization = AuthorizeOperator(httpRequest, operatorGate);
    if (operatorAuthorization != null)
    {
        return operatorAuthorization;
    }

    var rateLimit = AuthorizeRate(httpRequest, rateLimiter, "operator-genesis", maxRequests: 10, window: TimeSpan.FromMinutes(1));
    if (rateLimit != null)
    {
        return rateLimit;
    }

    var result = PassportHostedPolicy.CreateArchGenesisManifest(request);
    if (!result.Succeeded || result.Record == null)
    {
        return Results.BadRequest(result);
    }

    result = signer.Sign(result, "arch_genesis_manifest");
    store.SaveRecord(result.RecordId, result.Record!, result.RecordSha256);
    return Results.Json(result);
});

app.MapPost("/admin/authority/validate", (HttpRequest httpRequest, PassportAdminAuthorityValidationRequest request) =>
{
    var operatorAuthorization = AuthorizeOperator(httpRequest, operatorGate);
    if (operatorAuthorization != null)
    {
        return operatorAuthorization;
    }

    var rateLimit = AuthorizeRate(httpRequest, rateLimiter, "operator-authority", maxRequests: 60, window: TimeSpan.FromMinutes(1));
    if (rateLimit != null)
    {
        return rateLimit;
    }

    var result = PassportHostedPolicy.ValidateAdminAuthority(request, registryStore);
    return result.Succeeded ? Results.Json(result) : Results.BadRequest(result);
});

app.MapPost("/telemetry/access", (HttpRequest httpRequest, PassportTelemetryAccessRequest request) =>
{
    var operatorAuthorization = AuthorizeOperator(httpRequest, operatorGate);
    if (operatorAuthorization != null)
    {
        return operatorAuthorization;
    }

    var rateLimit = AuthorizeRate(httpRequest, rateLimiter, "operator-telemetry", maxRequests: 30, window: TimeSpan.FromMinutes(1));
    if (rateLimit != null)
    {
        return rateLimit;
    }

    var result = PassportHostedPolicy.CreateTelemetryAccessRecord(request, registryStore);
    if (!result.Succeeded || result.Record == null)
    {
        return Results.BadRequest(result);
    }

    result = signer.Sign(result, "telemetry_access");
    store.SaveRecord(result.RecordId, result.Record!, result.RecordSha256);
    var entries = PassportHostedPolicy.TryReadUtc(request.FromUtc, out var fromUtc)
        && PassportHostedPolicy.TryReadUtc(request.ToUtc, out var toUtc)
            ? store.ReadAppendLogTelemetry(fromUtc, toUtc, request.MaxEntries)
            : Array.Empty<PassportHostedTelemetryEntry>();
    return Results.Json(new PassportTelemetryAccessResponse
    {
        Succeeded = true,
        Message = result.Message,
        RecordId = result.RecordId,
        RecordSha256 = result.RecordSha256,
        Record = result.Record,
        Entries = entries
    });
});

app.MapPost("/storage/delivery/requests", (HttpRequest httpRequest, PassportStorageDeliveryRequest request) =>
{
    var operatorAuthorization = AuthorizeOperator(httpRequest, operatorGate);
    if (operatorAuthorization != null)
    {
        return operatorAuthorization;
    }

    var rateLimit = AuthorizeRate(httpRequest, rateLimiter, "operator-storage-delivery", maxRequests: 60, window: TimeSpan.FromMinutes(1));
    if (rateLimit != null)
    {
        return rateLimit;
    }

    var result = PassportHostedPolicy.AcceptStorageDeliveryRequest(request);
    if (!result.Succeeded || result.Record == null)
    {
        return Results.BadRequest(result);
    }

    result = signer.Sign(result, "storage_delivery_acceptance");
    store.SaveRecord(result.RecordId, result.Record!, result.RecordSha256);
    return Results.Json(result);
});

app.Run();

static IResult? AuthorizeOperator(HttpRequest request, PassportHostedOperatorGate operatorGate)
{
    var authorization = operatorGate.Authorize(request.Headers[PassportHostedOperatorGate.HeaderName].ToString());
    if (authorization.Succeeded)
    {
        return null;
    }

    var body = new
    {
        succeeded = false,
        message = authorization.Message
    };
    return authorization.ConfigurationMissing
        ? Results.Json(body, statusCode: StatusCodes.Status503ServiceUnavailable)
        : Results.Json(body, statusCode: StatusCodes.Status401Unauthorized);
}

static IResult? AuthorizeRate(
    HttpRequest request,
    PassportHostedRateLimiter rateLimiter,
    string scope,
    int maxRequests,
    TimeSpan window)
{
    var key = scope + ":" + (request.HttpContext.Connection.RemoteIpAddress?.ToString() ?? "local");
    var result = rateLimiter.Check(key, maxRequests, window);
    if (result.Succeeded)
    {
        return null;
    }

    request.HttpContext.Response.Headers.RetryAfter = Math.Ceiling(result.RetryAfter.TotalSeconds).ToString("0");
    return Results.Json(new
    {
        succeeded = false,
        message = result.Message,
        max_requests = result.MaxRequests,
        window_seconds = Math.Ceiling(result.Window.TotalSeconds),
        retry_after_seconds = Math.Ceiling(result.RetryAfter.TotalSeconds)
    }, statusCode: StatusCodes.Status429TooManyRequests);
}

public partial class Program
{
}
