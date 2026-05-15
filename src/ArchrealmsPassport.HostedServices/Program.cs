using ArchrealmsPassport.HostedServices;
using ArchrealmsPassport.HostedServices.Contracts;

var builder = WebApplication.CreateBuilder(args);
var app = builder.Build();

var store = PassportHostedFileStore.FromEnvironment();
var signer = PassportHostedServiceSigner.FromDataRoot(store.Root);
var operatorGate = PassportHostedOperatorGate.FromEnvironment();

app.MapGet("/health", () => Results.Json(new
{
    service = "archrealms-passport-hosted-services",
    status = "ok",
    contract_version = PassportHostedPolicy.ContractVersion,
    utc = DateTimeOffset.UtcNow
}));

app.MapPost("/ai/session", (PassportAiSessionAuthorizationRequest request) =>
{
    var result = PassportHostedPolicy.AuthorizeAiSession(request);
    if (!result.Succeeded || result.Session == null)
    {
        return Results.BadRequest(result);
    }

    store.SaveAiSession(result.Session);
    return Results.Json(result);
});

app.MapPost("/ai/chat", (HttpRequest httpRequest, PassportAiChatRequest request) =>
{
    var bearerToken = PassportHostedPolicy.ReadBearerToken(httpRequest.Headers.Authorization.ToString());
    var result = PassportHostedPolicy.CreateAiChatResponse(request, bearerToken, store);
    return result.Succeeded ? Results.Json(result) : Results.BadRequest(result);
});

app.MapPost("/capacity/reports/cc", (HttpRequest httpRequest, PassportCcCapacityReportRequest request) =>
{
    var operatorAuthorization = AuthorizeOperator(httpRequest, operatorGate);
    if (operatorAuthorization != null)
    {
        return operatorAuthorization;
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

    var result = PassportHostedPolicy.ValidateAdminAuthority(request);
    return result.Succeeded ? Results.Json(result) : Results.BadRequest(result);
});

app.MapPost("/storage/delivery/requests", (HttpRequest httpRequest, PassportStorageDeliveryRequest request) =>
{
    var operatorAuthorization = AuthorizeOperator(httpRequest, operatorGate);
    if (operatorAuthorization != null)
    {
        return operatorAuthorization;
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

public partial class Program
{
}
