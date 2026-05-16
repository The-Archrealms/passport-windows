using Xunit;

namespace ArchrealmsPassport.HostedServices.Tests;

public sealed class PassportHostedRouteContractTests
{
    [Fact]
    public void ProductionRouteContractMatchesHostedProgram()
    {
        var programPath = FindHostedProgramPath();
        var program = File.ReadAllText(programPath);

        string[] requiredRoutes =
        [
            "app.MapGet(\"/health\"",
            "app.MapGet(\"/ops/runtime/status\"",
            "app.MapGet(\"/ops/operator/status\"",
            "app.MapGet(\"/ops/storage/status\"",
            "app.MapPost(\"/ops/backup/manifests\"",
            "app.MapPost(\"/ops/incidents\"",
            "app.MapPost(\"/arch/genesis/manifests\"",
            "app.MapPost(\"/capacity/reports/cc\"",
            "app.MapPost(\"/storage/delivery/requests\"",
            "app.MapGet(\"/ai/status\"",
            "app.MapPost(\"/ai/challenge\"",
            "app.MapPost(\"/ai/session\"",
            "app.MapGet(\"/ai/quota\"",
            "app.MapPost(\"/ai/chat\"",
            "app.MapPost(\"/ai/feedback\"",
            "app.MapGet(\"/ai/runtime/status\"",
            "app.MapGet(\"/ai/runtime/probe\""
        ];

        foreach (var requiredRoute in requiredRoutes)
        {
            Assert.Contains(requiredRoute, program, StringComparison.Ordinal);
        }

        Assert.DoesNotContain("app.MapPost(\"/ai/runtime/probe\"", program, StringComparison.Ordinal);
        Assert.DoesNotContain("app.MapPost(\"/storage/delivery\",", program, StringComparison.Ordinal);
    }

    private static string FindHostedProgramPath()
    {
        var current = new DirectoryInfo(AppContext.BaseDirectory);
        while (current != null)
        {
            var candidate = Path.Combine(
                current.FullName,
                "src",
                "ArchrealmsPassport.HostedServices",
                "Program.cs");
            if (File.Exists(candidate))
            {
                return candidate;
            }

            current = current.Parent;
        }

        throw new InvalidOperationException("Could not find src/ArchrealmsPassport.HostedServices/Program.cs.");
    }
}
