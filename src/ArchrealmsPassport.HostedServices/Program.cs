using ArchrealmsPassport.HostedServices;
using ArchrealmsPassport.HostedServices.Contracts;

var builder = WebApplication.CreateBuilder(args);
var app = builder.Build();

var store = PassportHostedFileStore.FromEnvironment();

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

app.MapPost("/capacity/reports/cc", (PassportCcCapacityReportRequest request) =>
{
    var result = PassportHostedPolicy.CreateCcCapacityReport(request);
    if (!result.Succeeded || result.Record == null)
    {
        return Results.BadRequest(result);
    }

    store.SaveRecord(result.RecordId, result.Record, result.RecordSha256);
    return Results.Json(result);
});

app.MapPost("/arch/genesis/manifests", (PassportArchGenesisManifestRequest request) =>
{
    var result = PassportHostedPolicy.CreateArchGenesisManifest(request);
    if (!result.Succeeded || result.Record == null)
    {
        return Results.BadRequest(result);
    }

    store.SaveRecord(result.RecordId, result.Record, result.RecordSha256);
    return Results.Json(result);
});

app.MapPost("/admin/authority/validate", (PassportAdminAuthorityValidationRequest request) =>
{
    var result = PassportHostedPolicy.ValidateAdminAuthority(request);
    return result.Succeeded ? Results.Json(result) : Results.BadRequest(result);
});

app.MapPost("/storage/delivery/requests", (PassportStorageDeliveryRequest request) =>
{
    var result = PassportHostedPolicy.AcceptStorageDeliveryRequest(request);
    if (!result.Succeeded || result.Record == null)
    {
        return Results.BadRequest(result);
    }

    store.SaveRecord(result.RecordId, result.Record, result.RecordSha256);
    return Results.Json(result);
});

app.Run();

public partial class Program
{
}
