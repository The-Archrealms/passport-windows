using System;
using System.IO;
using System.Text.Json;

namespace ArchrealmsPassport.Windows.Services
{
    public sealed class PassportReleaseLane
    {
        public const string ManifestFileName = "passport-release-lane.json";

        public string Lane { get; set; } = "dev";
        public string LaneDisplayName { get; set; } = "Development";
        public string PackageChannel { get; set; } = "unpackaged";
        public string PackageIdentity { get; set; } = string.Empty;
        public string LedgerNamespace { get; set; } = "archrealms-passport-dev";
        public string ApiBaseUrl { get; set; } = string.Empty;
        public string AiGatewayUrl { get; set; } = string.Empty;
        public string TelemetryEnvironment { get; set; } = "dev";
        public string IssuerKeyScope { get; set; } = "passport-dev";
        public string FeatureFlagScope { get; set; } = "passport-dev";
        public string PolicyVersion { get; set; } = "passport-release-lanes-v1";
        public string CrownAuthorityIdentityId { get; set; } = string.Empty;
        public bool AllowProductionTokenRecords { get; set; }
        public bool AllowStagingRecords { get; set; }
        public bool ProductionLedger { get; set; }

        public string AppDataFolderName
        {
            get
            {
                if (string.Equals(Lane, "production-mvp", StringComparison.Ordinal))
                {
                    return "PassportWindows";
                }

                return "PassportWindows-" + Lane;
            }
        }

        public string Summary
        {
            get
            {
                return LaneDisplayName + " (" + Lane + "); ledger " + LedgerNamespace;
            }
        }

        public static PassportReleaseLane Load()
        {
            var path = ResolveManifestPath();
            if (string.IsNullOrWhiteSpace(path) || !File.Exists(path))
            {
                return CreateDefault("dev");
            }

            using (var document = JsonDocument.Parse(File.ReadAllText(path)))
            {
                return FromJson(document.RootElement);
            }
        }

        public static PassportReleaseLane FromJson(JsonElement root)
        {
            var lane = NormalizeLane(ReadString(root, "lane", ReadString(root, "environment", "dev")));
            var defaults = CreateDefault(lane);

            return new PassportReleaseLane
            {
                Lane = lane,
                LaneDisplayName = ReadString(root, "lane_display_name", defaults.LaneDisplayName),
                PackageChannel = ReadString(root, "package_channel", defaults.PackageChannel),
                PackageIdentity = ReadString(root, "package_identity", defaults.PackageIdentity),
                LedgerNamespace = ReadString(root, "ledger_namespace", defaults.LedgerNamespace),
                ApiBaseUrl = ReadString(root, "api_base_url", defaults.ApiBaseUrl),
                AiGatewayUrl = ReadString(root, "ai_gateway_url", defaults.AiGatewayUrl),
                TelemetryEnvironment = ReadString(root, "telemetry_environment", defaults.TelemetryEnvironment),
                IssuerKeyScope = ReadString(root, "issuer_key_scope", defaults.IssuerKeyScope),
                FeatureFlagScope = ReadString(root, "feature_flag_scope", defaults.FeatureFlagScope),
                PolicyVersion = ReadString(root, "policy_version", defaults.PolicyVersion),
                CrownAuthorityIdentityId = ReadString(root, "crown_authority_identity_id", defaults.CrownAuthorityIdentityId),
                AllowProductionTokenRecords = ReadBool(root, "allow_production_token_records", defaults.AllowProductionTokenRecords),
                AllowStagingRecords = ReadBool(root, "allow_staging_records", defaults.AllowStagingRecords),
                ProductionLedger = ReadBool(root, "production_ledger", defaults.ProductionLedger)
            };
        }

        public static PassportReleaseLane CreateDefault(string lane)
        {
            var normalizedLane = NormalizeLane(lane);
            var displayName = normalizedLane switch
            {
                "internal-verification" => "Internal Verification",
                "staging" => "Staging",
                "canary-mvp" => "Canary MVP",
                "production-mvp" => "Production MVP",
                _ => "Development"
            };

            var productionLedger = string.Equals(normalizedLane, "canary-mvp", StringComparison.Ordinal)
                || string.Equals(normalizedLane, "production-mvp", StringComparison.Ordinal);

            return new PassportReleaseLane
            {
                Lane = normalizedLane,
                LaneDisplayName = displayName,
                LedgerNamespace = "archrealms-passport-" + normalizedLane,
                TelemetryEnvironment = normalizedLane,
                IssuerKeyScope = "passport-" + normalizedLane,
                FeatureFlagScope = "passport-" + normalizedLane,
                AllowProductionTokenRecords = productionLedger,
                AllowStagingRecords = string.Equals(normalizedLane, "staging", StringComparison.Ordinal),
                ProductionLedger = productionLedger
            };
        }

        public static string NormalizeLane(string lane)
        {
            var normalized = (lane ?? string.Empty).Trim().ToLowerInvariant().Replace("_", "-");
            return normalized switch
            {
                "" => "dev",
                "dev" => "dev",
                "development" => "dev",
                "internalverification" => "internal-verification",
                "internal-verification" => "internal-verification",
                "internal" => "internal-verification",
                "stage" => "staging",
                "staging" => "staging",
                "canary" => "canary-mvp",
                "canary-mvp" => "canary-mvp",
                "production" => "production-mvp",
                "production-mvp" => "production-mvp",
                "prod" => "production-mvp",
                _ => throw new InvalidOperationException("Unsupported Passport release lane: " + lane)
            };
        }

        private static string ResolveManifestPath()
        {
            var overridePath = Environment.GetEnvironmentVariable("ARCHREALMS_PASSPORT_RELEASE_LANE_CONFIG");
            if (!string.IsNullOrWhiteSpace(overridePath))
            {
                return Path.GetFullPath(overridePath);
            }

            return Path.Combine(AppContext.BaseDirectory, ManifestFileName);
        }

        private static string ReadString(JsonElement root, string propertyName, string fallback)
        {
            if (root.TryGetProperty(propertyName, out var property) && property.ValueKind == JsonValueKind.String)
            {
                return property.GetString() ?? fallback;
            }

            return fallback;
        }

        private static bool ReadBool(JsonElement root, string propertyName, bool fallback)
        {
            if (root.TryGetProperty(propertyName, out var property))
            {
                if (property.ValueKind == JsonValueKind.True)
                {
                    return true;
                }

                if (property.ValueKind == JsonValueKind.False)
                {
                    return false;
                }
            }

            return fallback;
        }
    }
}
