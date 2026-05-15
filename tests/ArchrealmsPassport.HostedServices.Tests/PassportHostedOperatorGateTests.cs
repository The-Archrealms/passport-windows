using Xunit;

namespace ArchrealmsPassport.HostedServices.Tests;

public sealed class PassportHostedOperatorGateTests
{
    [Fact]
    public void OperatorGateAcceptsMatchingKeyHash()
    {
        var key = "operator-test-key";
        var gate = new PassportHostedOperatorGate(PassportHostedOperatorGate.ComputeKeySha256(key), allowMissingKeyForDevelopment: false);

        var result = gate.Authorize(key);

        Assert.True(result.Succeeded, result.Message);
    }

    [Fact]
    public void OperatorGateRejectsMissingProductionConfigurationAndWrongKeys()
    {
        var missing = new PassportHostedOperatorGate(string.Empty, allowMissingKeyForDevelopment: false).Authorize("anything");
        Assert.False(missing.Succeeded);
        Assert.True(missing.ConfigurationMissing);

        var gate = new PassportHostedOperatorGate(PassportHostedOperatorGate.ComputeKeySha256("expected"), allowMissingKeyForDevelopment: false);
        var wrong = gate.Authorize("wrong");
        Assert.False(wrong.Succeeded);
        Assert.False(wrong.ConfigurationMissing);
    }
}
