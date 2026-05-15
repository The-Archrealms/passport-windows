using ArchrealmsPassport.Core.Protocol;
using Xunit;

namespace ArchrealmsPassport.Core.Tests;

public sealed class PassportWalletKeyBindingValidatorTests
{
    [Fact]
    public void AcceptsSeparatedWalletKeyWithMonetaryScopes()
    {
        var validation = PassportWalletKeyBindingValidator.Validate(CreateValidBinding());

        Assert.True(validation.IsValid, string.Join("; ", validation.Failures));
    }

    [Fact]
    public void RejectsWalletKeyThatCanAlterIdentityAuthority()
    {
        var binding = CreateValidBinding() with
        {
            AuthorizedScopes = PassportMonetaryProtocol.WalletAuthorizedScopes
                .Append("alter_identity")
                .ToArray()
        };

        var validation = PassportWalletKeyBindingValidator.Validate(binding);

        Assert.False(validation.IsValid);
        Assert.Contains("authorized_scope_forbidden:alter_identity", validation.Failures);
    }

    [Fact]
    public void RequiresAllMonetaryAndProhibitedScopes()
    {
        var binding = CreateValidBinding() with
        {
            AuthorizedScopes = new[] { "sign_arch_operations" },
            ProhibitedScopes = new[] { "alter_identity" }
        };

        var validation = PassportWalletKeyBindingValidator.Validate(binding);

        Assert.False(validation.IsValid);
        Assert.Contains("authorized_scope_required:sign_cc_operations", validation.Failures);
        Assert.Contains("prohibited_scope_required:alter_citizenship", validation.Failures);
    }

    [Fact]
    public void RequiresWalletKeyToBeSeparateFromIdentityAndDevice()
    {
        var identityValidation = PassportWalletKeyBindingValidator.Validate(CreateValidBinding() with
        {
            WalletKeyId = "identity-1"
        });
        var deviceValidation = PassportWalletKeyBindingValidator.Validate(CreateValidBinding() with
        {
            WalletKeyId = "device-1"
        });

        Assert.Contains("wallet_key_must_be_distinct_from_identity", identityValidation.Failures);
        Assert.Contains("wallet_key_must_be_distinct_from_device", deviceValidation.Failures);
    }

    [Fact]
    public void RequiresProductionStrengthWalletKeyParameters()
    {
        var validation = PassportWalletKeyBindingValidator.Validate(CreateValidBinding() with
        {
            WalletKeyAlgorithm = "ECDSA",
            WalletKeySizeBits = 256
        });

        Assert.Contains("wallet_key_algorithm_unsupported", validation.Failures);
        Assert.Contains("wallet_key_size_too_small", validation.Failures);
    }

    private static PassportWalletKeyBindingDescriptor CreateValidBinding()
    {
        return new PassportWalletKeyBindingDescriptor
        {
            IdentityId = "identity-1",
            AuthorizingDeviceId = "device-1",
            WalletKeyId = "wallet-1",
            WalletKeyAlgorithm = "RSA",
            WalletKeySizeBits = 3072,
            WalletPublicKeyPath = "records/passport/wallet/public-keys/wallet-1.spki.der",
            WalletPublicKeySha256 = new string('a', 64),
            AuthorizedScopes = PassportMonetaryProtocol.WalletAuthorizedScopes,
            ProhibitedScopes = PassportMonetaryProtocol.WalletProhibitedScopes
        };
    }
}
