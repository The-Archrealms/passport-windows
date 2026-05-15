namespace ArchrealmsPassport.Core.Protocol;

public static class PassportMonetaryProtocol
{
    public const string AssetArch = "ARCH";
    public const string AssetCrownCredit = "CC";

    public const string EventArchGenesisAllocation = "arch_genesis_allocation";
    public const string EventArchTransferIn = "arch_transfer_in";
    public const string EventArchTransferOut = "arch_transfer_out";

    public const string EventCrownCreditIssue = "cc_issue";
    public const string EventCrownCreditEscrow = "cc_escrow";
    public const string EventCrownCreditBurn = "cc_burn";
    public const string EventCrownCreditRefund = "cc_refund";
    public const string EventCrownCreditRecredit = "cc_recredit";
    public const string EventCrownCreditTransferIn = "cc_transfer_in";
    public const string EventCrownCreditTransferOut = "cc_transfer_out";

    public const string SignatureUnsignedLocalFoundation = "unsigned-local-ledger-foundation";
    public const string SignatureWalletSigned = "wallet_signed";
    public const string SignatureDualControlAdminAuthorized = "dual_control_admin_authorized";

    public static readonly string[] WalletAuthorizedScopes =
    [
        "sign_arch_operations",
        "sign_cc_operations",
        "sign_conversion_quotes",
        "sign_escrow_redemption"
    ];

    public static readonly string[] WalletProhibitedScopes =
    [
        "alter_identity",
        "alter_citizenship",
        "alter_office",
        "alter_registry_authority",
        "alter_constitutional_status",
        "alter_crown_authority"
    ];

    public static string NormalizeAssetCode(string assetCode)
    {
        var normalized = (assetCode ?? string.Empty).Trim().ToUpperInvariant().Replace(" ", "_");
        return normalized is "CROWN_CREDIT" or "CROWN-CREDIT" or "CROWN_CREDITS" or "CROWN-CREDITS"
            ? AssetCrownCredit
            : normalized;
    }

    public static string NormalizeEventType(string eventType)
    {
        return (eventType ?? string.Empty).Trim().ToLowerInvariant().Replace(" ", "_").Replace("-", "_");
    }

    public static bool IsSupportedAssetCode(string assetCode)
    {
        var normalized = NormalizeAssetCode(assetCode);
        return normalized is AssetArch or AssetCrownCredit;
    }

    public static bool IsArchEventType(string eventType)
    {
        return NormalizeEventType(eventType) is EventArchGenesisAllocation or EventArchTransferIn or EventArchTransferOut;
    }

    public static bool IsCrownCreditEventType(string eventType)
    {
        return NormalizeEventType(eventType) is EventCrownCreditIssue
            or EventCrownCreditEscrow
            or EventCrownCreditBurn
            or EventCrownCreditRefund
            or EventCrownCreditRecredit
            or EventCrownCreditTransferIn
            or EventCrownCreditTransferOut;
    }

    public static bool IsSupportedEventForAsset(string assetCode, string eventType)
    {
        var normalizedAsset = NormalizeAssetCode(assetCode);
        return normalizedAsset switch
        {
            AssetArch => IsArchEventType(eventType),
            AssetCrownCredit => IsCrownCreditEventType(eventType),
            _ => false
        };
    }

    public static bool IsWalletAuthorizedScope(string scope)
    {
        return WalletAuthorizedScopes.Contains(NormalizeScope(scope), StringComparer.Ordinal);
    }

    public static bool IsWalletProhibitedScope(string scope)
    {
        return WalletProhibitedScopes.Contains(NormalizeScope(scope), StringComparer.Ordinal);
    }

    public static string NormalizeScope(string scope)
    {
        return (scope ?? string.Empty).Trim().ToLowerInvariant().Replace(" ", "_").Replace("-", "_");
    }
}
