using System.Text.Json;
using System.Text.RegularExpressions;

namespace ArchrealmsPassport.Core.Protocol;

public static class PassportAiAuthorityPolicy
{
    public static readonly string[] ForbiddenAuthorityFields =
    {
        "can_approve_recovery",
        "can_issue_credits",
        "can_release_escrow",
        "can_mark_service_delivered",
        "can_burn_credits",
        "can_change_registry_authority",
        "can_execute_wallet_operations",
        "can_override_identity_status",
        "can_approve_admin_authority"
    };

    public static Dictionary<string, object?> CreateNonAuthorityBoundaries()
    {
        return ForbiddenAuthorityFields.ToDictionary(field => field, _ => (object?)false, StringComparer.Ordinal);
    }

    public static bool IsNonAuthoritative(JsonElement authority)
    {
        return ForbiddenAuthorityFields.All(name => !ReadBoolean(authority, name));
    }

    public static bool ContainsSecretMaterial(string value)
    {
        if (string.IsNullOrWhiteSpace(value))
        {
            return false;
        }

        return Regex.IsMatch(value, "-----BEGIN [A-Z ]*PRIVATE KEY-----", RegexOptions.IgnoreCase)
            || Regex.IsMatch(value, "(wallet private key|device private key|recovery secret|seed phrase)\\s*[:=]\\s*\\S+", RegexOptions.IgnoreCase)
            || Regex.IsMatch(value, "\\b(seed|mnemonic)\\s*[:=]\\s*([a-z]+\\s+){11,23}[a-z]+\\b", RegexOptions.IgnoreCase);
    }

    private static bool ReadBoolean(JsonElement root, string propertyName)
    {
        return root.TryGetProperty(propertyName, out var property)
            && (property.ValueKind == JsonValueKind.True
                || (property.ValueKind == JsonValueKind.String && bool.TryParse(property.GetString(), out var parsed) && parsed));
    }
}
