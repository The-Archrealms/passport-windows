namespace ArchrealmsPassport.Core.Protocol;

public sealed record PassportWalletKeyBindingDescriptor
{
    public string IdentityId { get; init; } = string.Empty;

    public string AuthorizingDeviceId { get; init; } = string.Empty;

    public string WalletKeyId { get; init; } = string.Empty;

    public string WalletKeyAlgorithm { get; init; } = string.Empty;

    public int WalletKeySizeBits { get; init; }

    public string WalletPublicKeyPath { get; init; } = string.Empty;

    public string WalletPublicKeySha256 { get; init; } = string.Empty;

    public IReadOnlyList<string> AuthorizedScopes { get; init; } = Array.Empty<string>();

    public IReadOnlyList<string> ProhibitedScopes { get; init; } = Array.Empty<string>();
}

public sealed record PassportWalletKeyBindingValidation
{
    public IReadOnlyList<string> Failures { get; init; } = Array.Empty<string>();

    public bool IsValid => Failures.Count == 0;
}

public static class PassportWalletKeyBindingValidator
{
    private const int MinimumRsaKeySizeBits = 3072;

    public static PassportWalletKeyBindingValidation Validate(PassportWalletKeyBindingDescriptor binding)
    {
        var failures = new List<string>();
        var identityId = NormalizeRequired(binding.IdentityId, "identity_id_required", failures);
        var authorizingDeviceId = NormalizeRequired(binding.AuthorizingDeviceId, "authorizing_device_id_required", failures);
        var walletKeyId = NormalizeRequired(binding.WalletKeyId, "wallet_key_id_required", failures);

        NormalizeRequired(binding.WalletPublicKeyPath, "wallet_public_key_path_required", failures);
        NormalizeRequired(binding.WalletPublicKeySha256, "wallet_public_key_sha256_required", failures);

        if (!string.IsNullOrWhiteSpace(identityId)
            && !string.IsNullOrWhiteSpace(walletKeyId)
            && string.Equals(identityId, walletKeyId, StringComparison.Ordinal))
        {
            failures.Add("wallet_key_must_be_distinct_from_identity");
        }

        if (!string.IsNullOrWhiteSpace(authorizingDeviceId)
            && !string.IsNullOrWhiteSpace(walletKeyId)
            && string.Equals(authorizingDeviceId, walletKeyId, StringComparison.Ordinal))
        {
            failures.Add("wallet_key_must_be_distinct_from_device");
        }

        if (!string.Equals((binding.WalletKeyAlgorithm ?? string.Empty).Trim(), "RSA", StringComparison.OrdinalIgnoreCase))
        {
            failures.Add("wallet_key_algorithm_unsupported");
        }

        if (binding.WalletKeySizeBits < MinimumRsaKeySizeBits)
        {
            failures.Add("wallet_key_size_too_small");
        }

        ValidateAuthorizedScopes(binding.AuthorizedScopes ?? Array.Empty<string>(), failures);
        ValidateProhibitedScopes(binding.ProhibitedScopes ?? Array.Empty<string>(), failures);

        return new PassportWalletKeyBindingValidation
        {
            Failures = failures.ToArray()
        };
    }

    public static string[] NormalizeScopes(IEnumerable<string> scopes)
    {
        return (scopes ?? Array.Empty<string>())
            .Select(PassportMonetaryProtocol.NormalizeScope)
            .Where(scope => !string.IsNullOrWhiteSpace(scope))
            .Distinct(StringComparer.Ordinal)
            .OrderBy(scope => scope, StringComparer.Ordinal)
            .ToArray();
    }

    private static void ValidateAuthorizedScopes(IEnumerable<string> authorizedScopes, List<string> failures)
    {
        var normalizedScopes = NormalizeScopes(authorizedScopes);
        foreach (var requiredScope in PassportMonetaryProtocol.WalletAuthorizedScopes)
        {
            if (!normalizedScopes.Contains(requiredScope, StringComparer.Ordinal))
            {
                failures.Add("authorized_scope_required:" + requiredScope);
            }
        }

        foreach (var scope in normalizedScopes)
        {
            if (PassportMonetaryProtocol.IsWalletProhibitedScope(scope))
            {
                failures.Add("authorized_scope_forbidden:" + scope);
            }
            else if (!PassportMonetaryProtocol.IsWalletAuthorizedScope(scope))
            {
                failures.Add("authorized_scope_unknown:" + scope);
            }
        }
    }

    private static void ValidateProhibitedScopes(IEnumerable<string> prohibitedScopes, List<string> failures)
    {
        var normalizedScopes = NormalizeScopes(prohibitedScopes);
        foreach (var requiredScope in PassportMonetaryProtocol.WalletProhibitedScopes)
        {
            if (!normalizedScopes.Contains(requiredScope, StringComparer.Ordinal))
            {
                failures.Add("prohibited_scope_required:" + requiredScope);
            }
        }
    }

    private static string NormalizeRequired(string value, string failureCode, List<string> failures)
    {
        var normalized = (value ?? string.Empty).Trim();
        if (string.IsNullOrWhiteSpace(normalized))
        {
            failures.Add(failureCode);
        }

        return normalized;
    }
}
