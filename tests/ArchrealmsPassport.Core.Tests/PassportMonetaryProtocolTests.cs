using ArchrealmsPassport.Core.Protocol;
using Xunit;

namespace ArchrealmsPassport.Core.Tests;

public sealed class PassportMonetaryProtocolTests
{
    [Fact]
    public void NormalizesArchAndCrownCreditAssetCodes()
    {
        Assert.Equal(PassportMonetaryProtocol.AssetArch, PassportMonetaryProtocol.NormalizeAssetCode("arch"));
        Assert.Equal(PassportMonetaryProtocol.AssetCrownCredit, PassportMonetaryProtocol.NormalizeAssetCode("Crown Credit"));
        Assert.Equal(PassportMonetaryProtocol.AssetCrownCredit, PassportMonetaryProtocol.NormalizeAssetCode("crown-credit"));
    }

    [Fact]
    public void DefinesSupportedEventTypesByAssetWithoutPostGenesisArchMint()
    {
        Assert.True(PassportMonetaryProtocol.IsSupportedEventForAsset("ARCH", "arch_genesis_allocation"));
        Assert.True(PassportMonetaryProtocol.IsSupportedEventForAsset("ARCH", "arch_transfer_in"));
        Assert.True(PassportMonetaryProtocol.IsSupportedEventForAsset("CC", "cc_burn"));
        Assert.True(PassportMonetaryProtocol.IsSupportedEventForAsset("Crown Credit", "cc_recredit"));

        Assert.False(PassportMonetaryProtocol.IsSupportedEventForAsset("ARCH", "arch_mint"));
        Assert.False(PassportMonetaryProtocol.IsSupportedEventForAsset("CC", "cc_stake"));
        Assert.False(PassportMonetaryProtocol.IsSupportedEventForAsset("USD", "cc_issue"));
    }

    [Fact]
    public void DefinesWalletAuthorityBoundaryScopes()
    {
        Assert.True(PassportMonetaryProtocol.IsWalletAuthorizedScope("sign-arch-operations"));
        Assert.True(PassportMonetaryProtocol.IsWalletAuthorizedScope("sign_cc_operations"));
        Assert.True(PassportMonetaryProtocol.IsWalletProhibitedScope("alter identity"));
        Assert.True(PassportMonetaryProtocol.IsWalletProhibitedScope("alter_crown_authority"));

        Assert.False(PassportMonetaryProtocol.IsWalletAuthorizedScope("alter_registry_authority"));
        Assert.False(PassportMonetaryProtocol.IsWalletProhibitedScope("sign_conversion_quotes"));
    }
}
