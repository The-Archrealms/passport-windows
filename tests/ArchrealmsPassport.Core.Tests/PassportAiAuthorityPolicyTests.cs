using System.Text.Json;
using ArchrealmsPassport.Core.Protocol;
using Xunit;

namespace ArchrealmsPassport.Core.Tests;

public sealed class PassportAiAuthorityPolicyTests
{
    [Fact]
    public void NonAuthorityBoundariesDisableAllForbiddenAuthorityFields()
    {
        var boundaries = PassportAiAuthorityPolicy.CreateNonAuthorityBoundaries();
        var element = JsonDocument.Parse(JsonSerializer.Serialize(boundaries)).RootElement;

        Assert.True(PassportAiAuthorityPolicy.IsNonAuthoritative(element));
        Assert.All(PassportAiAuthorityPolicy.ForbiddenAuthorityFields, field => Assert.Equal(false, boundaries[field]));
    }

    [Fact]
    public void AuthorityPolicyRejectsAiAuthorityEscalation()
    {
        var element = JsonDocument.Parse("{\"can_execute_wallet_operations\":true}").RootElement;

        Assert.False(PassportAiAuthorityPolicy.IsNonAuthoritative(element));
    }

    [Theory]
    [InlineData("wallet private key: abc123")]
    [InlineData("seed phrase: alpha beta gamma delta epsilon zeta eta theta iota kappa lambda mu")]
    [InlineData("-----BEGIN PRIVATE KEY-----")]
    public void SecretMaterialDetectionBlocksSensitivePrompts(string prompt)
    {
        Assert.True(PassportAiAuthorityPolicy.ContainsSecretMaterial(prompt));
    }
}
