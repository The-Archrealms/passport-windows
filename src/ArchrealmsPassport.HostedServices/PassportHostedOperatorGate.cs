using System.Security.Cryptography;
using System.Text;

namespace ArchrealmsPassport.HostedServices;

public sealed class PassportHostedOperatorGate
{
    public const string HeaderName = "X-Archrealms-Operator-Key";

    private readonly string expectedKeySha256;
    private readonly bool allowMissingKeyForDevelopment;

    public PassportHostedOperatorGate(string expectedKeySha256, bool allowMissingKeyForDevelopment)
    {
        this.expectedKeySha256 = (expectedKeySha256 ?? string.Empty).Trim().ToLowerInvariant();
        this.allowMissingKeyForDevelopment = allowMissingKeyForDevelopment;
    }

    public static PassportHostedOperatorGate FromEnvironment()
    {
        var expectedHash = Environment.GetEnvironmentVariable("ARCHREALMS_PASSPORT_HOSTED_OPERATOR_API_KEY_SHA256") ?? string.Empty;
        var environment = Environment.GetEnvironmentVariable("ASPNETCORE_ENVIRONMENT") ?? "Production";
        var allowMissing = string.Equals(environment, "Development", StringComparison.OrdinalIgnoreCase)
            || string.Equals(environment, "Local", StringComparison.OrdinalIgnoreCase);
        return new PassportHostedOperatorGate(expectedHash, allowMissing);
    }

    public PassportHostedOperatorGateResult Authorize(string presentedKey)
    {
        if (string.IsNullOrWhiteSpace(expectedKeySha256))
        {
            return allowMissingKeyForDevelopment
                ? PassportHostedOperatorGateResult.Success()
                : PassportHostedOperatorGateResult.Failed("Hosted operator key hash is not configured.", configurationMissing: true);
        }

        if (string.IsNullOrWhiteSpace(presentedKey))
        {
            return PassportHostedOperatorGateResult.Failed("Hosted operator key is required.", configurationMissing: false);
        }

        var actual = ComputeSha256(Encoding.UTF8.GetBytes(presentedKey.Trim()));
        return string.Equals(actual, expectedKeySha256, StringComparison.OrdinalIgnoreCase)
            ? PassportHostedOperatorGateResult.Success()
            : PassportHostedOperatorGateResult.Failed("Hosted operator key is invalid.", configurationMissing: false);
    }

    public static string ComputeKeySha256(string key)
    {
        return ComputeSha256(Encoding.UTF8.GetBytes((key ?? string.Empty).Trim()));
    }

    private static string ComputeSha256(byte[] value)
    {
        return Convert.ToHexString(SHA256.HashData(value)).ToLowerInvariant();
    }
}

public sealed record PassportHostedOperatorGateResult(bool Succeeded, string Message, bool ConfigurationMissing)
{
    public static PassportHostedOperatorGateResult Success()
    {
        return new PassportHostedOperatorGateResult(true, "Operator authorized.", false);
    }

    public static PassportHostedOperatorGateResult Failed(string message, bool configurationMissing)
    {
        return new PassportHostedOperatorGateResult(false, message, configurationMissing);
    }
}
