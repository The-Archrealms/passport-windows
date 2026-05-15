using ArchrealmsPassport.ManagedSigning;

var builder = WebApplication.CreateBuilder(args);
var app = builder.Build();

var options = ManagedSigningOptions.FromEnvironment();
var service = new ManagedSigningService(options);

app.MapGet("/health", () => Results.Json(new
{
    schema = "archrealms.passport.managed_signing_health.v1",
    ok = true
}));

app.MapGet("/signing/status", () => Results.Json(options.GetStatus()));

app.MapPost("/sign", (HttpRequest httpRequest, ManagedSigningRequest request) =>
{
    var apiKey = httpRequest.Headers.TryGetValue("X-Archrealms-Managed-Signing-Key", out var values)
        ? values.FirstOrDefault() ?? string.Empty
        : string.Empty;
    if (!options.IsAuthorized(apiKey))
    {
        return Results.Json(new
        {
            error = "managed_signing_unauthorized",
            message = "Managed signing key was not authorized."
        }, statusCode: StatusCodes.Status401Unauthorized);
    }

    var result = service.Sign(request);
    if (!result.Succeeded || result.Response == null)
    {
        return Results.Json(new
        {
            error = "managed_signing_failed",
            message = result.Message
        }, statusCode: StatusCodes.Status400BadRequest);
    }

    return Results.Json(result.Response);
});

app.Run();
