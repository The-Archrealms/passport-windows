using System.Collections.Generic;
using System.IO;
using ArchrealmsPassport.Core.Protocol;
using ArchrealmsPassport.Windows.Services;
using ArchrealmsPassport.Windows.Tests.Infrastructure;
using Xunit;

namespace ArchrealmsPassport.Windows.Tests;

public sealed class PassportCrownCreditCapacityServiceTests
{
    [Fact]
    public void ValidateIssuanceAcceptsConservativeQualifiedCapacityReport()
    {
        using var workspace = PassportTestWorkspace.Create();
        var releaseLane = PassportReleaseLane.CreateDefault("production-mvp");
        var service = new PassportCrownCreditCapacityService(releaseLane);
        var report = service.CreateCapacityReport(
            workspace.Root,
            "storage",
            conservativeServiceLiabilityCapacityBaseUnits: 1_000,
            outstandingCrownCreditBeforeBaseUnits: 100,
            maxIssuanceBaseUnits: 250,
            capacityHaircutBasisPoints: 6500,
            independentVolumeQualified: true,
            thinMarketIssuanceZero: false,
            continuityReserveExcluded: true,
            operationalReserveExcluded: true,
            capacityReportAuthorityRecordSha256: Hash('a'),
            conservativeMethodologySha256: Hash('b'),
            issuanceAuthorityRecordSha256: Hash('c'),
            issuanceRecordSchemaSha256: Hash('d'),
            noArchCreationValidationSha256: Hash('e'));
        Assert.True(report.Succeeded, report.Message);
        Assert.True(File.Exists(report.ReportPath));
        var inspection = PassportRegistryRecordInspector.Inspect(File.ReadAllBytes(report.ReportPath), report.ReportPath);
        Assert.True(inspection.IsEnvelopeValid, string.Join("; ", inspection.ValidationFailures));

        var validation = service.ValidateIssuance(
            workspace.Root,
            200,
            new Dictionary<string, string>
            {
                ["capacity_report_path"] = report.ReportPath,
                ["capacity_report_sha256"] = report.ReportSha256
            });

        Assert.True(validation.Succeeded, validation.Message);
        Assert.Equal(250, validation.MaxIssuanceBaseUnits);
    }

    [Fact]
    public void ValidateIssuanceRejectsThinMarketZeroIssuanceReport()
    {
        using var workspace = PassportTestWorkspace.Create();
        var releaseLane = PassportReleaseLane.CreateDefault("production-mvp");
        var service = new PassportCrownCreditCapacityService(releaseLane);
        var report = service.CreateCapacityReport(
            workspace.Root,
            "storage",
            conservativeServiceLiabilityCapacityBaseUnits: 1_000,
            outstandingCrownCreditBeforeBaseUnits: 100,
            maxIssuanceBaseUnits: 0,
            capacityHaircutBasisPoints: 6500,
            independentVolumeQualified: true,
            thinMarketIssuanceZero: true,
            continuityReserveExcluded: true,
            operationalReserveExcluded: true,
            capacityReportAuthorityRecordSha256: Hash('a'),
            conservativeMethodologySha256: Hash('b'),
            issuanceAuthorityRecordSha256: Hash('c'),
            issuanceRecordSchemaSha256: Hash('d'),
            noArchCreationValidationSha256: Hash('e'));
        Assert.True(report.Succeeded, report.Message);

        var validation = service.ValidateIssuance(
            workspace.Root,
            200,
            new Dictionary<string, string>
            {
                ["capacity_report_path"] = report.ReportPath,
                ["capacity_report_sha256"] = report.ReportSha256
            });

        Assert.False(validation.Succeeded);
        Assert.Contains("thin-market", validation.Message, System.StringComparison.OrdinalIgnoreCase);
    }

    private static string Hash(char value)
    {
        return new string(value, 64);
    }
}
