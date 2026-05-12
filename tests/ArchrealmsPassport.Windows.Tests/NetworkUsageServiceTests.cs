using ArchrealmsPassport.Windows.Services;
using Windows.Networking.Connectivity;
using Xunit;

namespace ArchrealmsPassport.Windows.Tests;

public sealed class NetworkUsageServiceTests
{
    [Fact]
    public void StandardNetworkUseAllowsMeteredConnections()
    {
        var result = NetworkUsageService.EvaluateConnectionCost(
            false,
            NetworkCostType.Variable,
            roaming: true,
            overDataLimit: true,
            approachingDataLimit: true);

        Assert.True(result.StorageAllowed);
    }

    [Fact]
    public void UnmeteredRequirementAllowsUnrestrictedNetwork()
    {
        var result = NetworkUsageService.EvaluateConnectionCost(
            true,
            NetworkCostType.Unrestricted,
            roaming: false,
            overDataLimit: false,
            approachingDataLimit: false);

        Assert.True(result.StorageAllowed);
    }

    [Theory]
    [InlineData(NetworkCostType.Fixed)]
    [InlineData(NetworkCostType.Variable)]
    [InlineData(NetworkCostType.Unknown)]
    public void UnmeteredRequirementBlocksMeteredOrUnknownNetworks(NetworkCostType networkCostType)
    {
        var result = NetworkUsageService.EvaluateConnectionCost(
            true,
            networkCostType,
            roaming: false,
            overDataLimit: false,
            approachingDataLimit: false);

        Assert.False(result.StorageAllowed);
        Assert.Contains("requires an unmetered network", result.Message);
    }

    [Theory]
    [InlineData(true, false, false)]
    [InlineData(false, true, false)]
    [InlineData(false, false, true)]
    public void UnmeteredRequirementBlocksDataLimitRisk(bool roaming, bool overDataLimit, bool approachingDataLimit)
    {
        var result = NetworkUsageService.EvaluateConnectionCost(
            true,
            NetworkCostType.Unrestricted,
            roaming,
            overDataLimit,
            approachingDataLimit);

        Assert.False(result.StorageAllowed);
    }
}
