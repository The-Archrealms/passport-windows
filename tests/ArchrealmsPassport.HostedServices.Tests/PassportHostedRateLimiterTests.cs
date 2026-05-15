using Xunit;

namespace ArchrealmsPassport.HostedServices.Tests;

public sealed class PassportHostedRateLimiterTests
{
    [Fact]
    public void RateLimiterRejectsRequestsBeyondWindowLimit()
    {
        var limiter = new PassportHostedRateLimiter();

        Assert.True(limiter.Check("client-1", 2, TimeSpan.FromMinutes(1)).Succeeded);
        Assert.True(limiter.Check("client-1", 2, TimeSpan.FromMinutes(1)).Succeeded);
        var rejected = limiter.Check("client-1", 2, TimeSpan.FromMinutes(1));

        Assert.False(rejected.Succeeded);
        Assert.True(rejected.RetryAfter > TimeSpan.Zero);
    }

    [Fact]
    public void RateLimiterKeepsIndependentKeysSeparate()
    {
        var limiter = new PassportHostedRateLimiter();

        Assert.True(limiter.Check("client-1", 1, TimeSpan.FromMinutes(1)).Succeeded);
        Assert.True(limiter.Check("client-2", 1, TimeSpan.FromMinutes(1)).Succeeded);
        Assert.False(limiter.Check("client-1", 1, TimeSpan.FromMinutes(1)).Succeeded);
    }
}
